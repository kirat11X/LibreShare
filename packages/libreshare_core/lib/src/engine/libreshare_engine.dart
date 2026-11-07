/// LibreShareEngine (UML "LibreShareApp" core facade). UI and CLI use only this.
///
/// * Transfers: an HTTP server + receiver + sender (Inc 1).
/// * Receive mode (Inc 2, design 01): the engine is the [ReceiveGate] of its
///   [receive] controller. Constructing or `start()`ing the engine does not by
///   itself open the listener; `receive.turnOn()` does (and `start()` calls it
///   for the configured initial mode, which defaults to Always so a plain
///   engine still listens after `start()`).
/// * Discovery (Inc 2): a shared [PeerRegistry] fed by multicast, the /24 scan,
///   mDNS, `POST /register`, manual entry and `libreshare://peer` links. While
///   Receive is Off the engine still looks around (send-only probes) but is
///   neither announced nor listed.
/// * `GET /info`, `POST /register` and every announcement report the port the
///   listener really bound after the FR-01 fallback and the current local
///   addresses, never the port that was asked for.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../client/api_client.dart';
import '../clock.dart';
import '../discovery/announce_codec.dart';
import '../discovery/device_discovery.dart';
import '../discovery/manual_peer.dart';
import '../discovery/mdns_backend.dart';
import '../discovery/multicast_discovery.dart';
import '../discovery/multicast_transport.dart';
import '../discovery/peer_registrar.dart';
import '../discovery/peer_registry.dart';
import '../discovery/subnet_scanner.dart';
import '../model/device.dart';
import '../model/events.dart';
import '../model/ls_exception.dart';
import '../protocol.dart';
import '../client/peer_security_exceptions.dart';
import '../security/cert_factory.dart' show parseCertificate;
import '../security/crypto_primitives.dart' show fingerprintHex;
import '../security/contracts.dart';
import '../security/pairing_service.dart';
import '../security/pin_guard.dart';
import '../security/tls_context.dart';
import '../security/trust_store.dart'
    show FingerprintInUseException, KeyChangedException;
import '../receive/receive_controller.dart';
import '../receive/receive_gate.dart';
import '../receive/receive_scheduler.dart';
import '../receive/receive_state.dart';
import '../server/api_server.dart';
import '../storage/receive_settings_store.dart';
import '../transfer/file_receiver.dart';
import '../transfer/file_sender.dart';
import '../connection/candidate.dart';
import '../connection/connection.dart';
import '../connection/connection_manager.dart';
import '../monitor/event_log.dart';
import '../storage/session_store.dart';
import 'discovery_config.dart';
import 'outgoing_send.dart';
import 'security_wiring.dart';

class LibreShareEngine implements ReceiveGate {
  LibreShareEngine({
    required this.self,
    required this.downloadDir,
    this.partialDir,
    this.preferredPort = kDefaultPort,
    this.autoAccept = true,
    this.bindAddress,
    this.enableRateLimit = true,
    this.clock = const SystemClock(),
    this.permissionTimeout = kPermissionTimeout,
    this.discovery = DiscoveryConfig.disabled,
    this.receiveConfig = const ReceiveConfig(),
    this.security,
    this.advertiseIp,
    this.eventLog,
    this.sessionStore,
  }) : _registry = PeerRegistry(
         selfDeviceId: self.deviceId,
         clock: clock,
         expiry: discovery.peerExpiry,
         trust: security?.trust,
       ) {
    final wiring = security;
    if (wiring != null && wiring.identity.identity.deviceId != self.deviceId) {
      // Otherwise peers would pin a certificate CN that disagrees with the id they are told.
      throw ArgumentError.value('differs from the identity', 'self.deviceId');
    }
    final adv = advertiseIp;
    if (adv != null && InternetAddress.tryParse(adv) == null) {
      throw ArgumentError.value('not an IP address', 'advertiseIp');
    }
    receive = ReceiveController(
      gate: this,
      store: receiveConfig.store ?? InMemoryReceiveSettingsStore(),
      clock: clock,
      scheduler: receiveConfig.scheduler ?? const SystemReceiveScheduler(),
      caps: receiveConfig.caps,
      env: receiveConfig.env,
      contactsSupported: wiring != null,
    );
    if (wiring != null) {
      wiring.onBruteForce = () => _emit(const PinBruteForceSuspected());
      _pairing = PairingService(
        identity: wiring.identity,
        trust: wiring.trust,
        secrets: wiring.secrets,
        self: () => deviceInfo,
        clock: clock,
        onEvent: _emit,
      );
    }
    _registrar = ApiPeerRegistrar(
      self: () => deviceInfo,
      timeout: discovery.registerTimeout,
      security: _config,
      onCertificate: (der) => _registry.learnCertificate(der),
    );
    _resolver = ManualPeerResolver(
      probe:
          discovery.infoProbe ?? (wiring == null ? null : _secureResolveProbe),
    );
  }

  /// Identity template: id, alias, platform, type, fingerprint, caps. Its
  /// `port` and `addrs` are ignored; see [deviceInfo].
  final DeviceInfo self;
  final Directory downloadDir;
  final Directory? partialDir;

  /// First port to try; FR-01 falls back to the next free one up to 53327.
  final int preferredPort;
  final bool autoAccept;
  final InternetAddress? bindAddress;
  final bool enableRateLimit;
  final Clock clock;

  /// How long an incoming session may wait for [FileReceiver.accept] /
  /// [FileReceiver.reject] (only with `autoAccept: false`) before it fails with
  /// `FAILED(TIMEOUT)` (FR-06; spec: 120 s).
  final Duration permissionTimeout;

  /// Discovery wiring; [DiscoveryConfig.disabled] by default.
  final DiscoveryConfig discovery;

  /// How [receive] is set up and what `start()` enters.
  final ReceiveConfig receiveConfig;

  /// The secure profile (LSP/1.1): persistent identity, contacts and PIN guard.
  /// Null = the plaintext profile, byte for byte what Increments 1 and 2 did.
  /// The engine uses it but does not close it.
  final SecurityWiring? security;

  /// The address told to other devices (`/info` addrs, announcements, peer
  /// links, pair invites) instead of the listener's own; for a device behind
  /// NAT such as a container. Must be an IP literal.
  final String? advertiseIp;
  final EventLog? eventLog;
  final SessionStore? sessionStore;

  /// Owner of Receive mode (Off / For(N) / Always, visibility, pauses). Its
  /// gate is this engine.
  late final ReceiveController receive;

  static final Logger _log = Logger('libreshare.engine');

  SecurityConfig get _config =>
      security?.config ?? const SecurityConfig.plaintext();
  bool get _secure => security != null;

  final StreamController<LsEvent> _events =
      StreamController<LsEvent>.broadcast();
  final StreamController<int> _activeCounts = StreamController<int>.broadcast();
  final PeerRegistry _registry;
  late final ApiPeerRegistrar _registrar;
  late final ManualPeerResolver _resolver;
  late final SubnetScanner _scanner = SubnetScanner(
    ifaces: discovery.interfaces,
    sink: _FnSink(_onScanFound),
    probe: discovery.infoProbe,
    concurrency: discovery.scanConcurrency,
    timeout: discovery.scanTimeout,
    port: discovery.scanPort,
    allowLoopback: discovery.allowLoopbackScan,
    clock: clock,
    security: _config,
    onCertificate: (der) => _registry.learnCertificate(der),
  );

  PairingService? _pairing;
  FileReceiver? _receiver;
  ApiServer? _server;
  bool _started = false;
  bool _acceptingSessions = true;
  AnnouncePolicy _policy = AnnouncePolicy.none;
  List<DeviceAddress> _addrs = const [];
  Timer? _addrTimer;
  MulticastDiscovery? _multicast;
  ScanPolicy? _scanPolicy;
  StreamSubscription<DiscoveryEvent>? _scanWatch;
  StreamSubscription<MdnsPeer>? _mdnsSub;
  StreamSubscription<int>? _activeSub;
  StreamSubscription<DiscoveryEvent>? _certWatch;
  StreamSubscription<void>? _trustWatch;
  final Set<String> _greeted = {};
  final Map<String, Timer> _greetRetry = {};
  final Set<String> _learning = {};
  Future<void> _mdnsTail = Future<void>.value();
  int? _mdnsPort;

  // ---------------------------------------------------------------- state

  /// All sender- and receiver-side events.
  Stream<LsEvent> get events => _events.stream;

  /// The receiving side. Available from `start()` on, also while Receive is Off
  /// (sessions only arrive while the listener is open).
  FileReceiver get receiver =>
      _receiver ?? (throw StateError('engine not started'));

  /// `start()` was called and `stop()` was not.
  bool get isStarted => _started;

  /// The listener is open (Receive On or Draining).
  bool get isRunning => _server?.isRunning ?? false;

  /// Same as [isRunning].
  bool get isListening => isRunning;

  /// The port the listener is bound to. Throws [StateError] unless listening.
  int get port => _server?.port ?? (throw StateError('engine not started'));

  /// What this device is right now: [self] with the **bound** port (0 while no
  /// listener is open) and the current local addresses. This is what
  /// `GET /info`, `POST /register`, announcements, "My QR" and outgoing
  /// sessions carry.
  DeviceInfo get deviceInfo {
    final s = _server;
    final id = security?.identity.identity;
    return DeviceInfo(
      deviceId: self.deviceId,
      alias: self.alias,
      platform: self.platform,
      deviceType: self.deviceType,
      fingerprint: id?.fingerprint ?? self.fingerprint,
      port: s != null && s.isRunning ? s.port : 0,
      addrs: _addrs,
      caps: id == null
          ? self.caps
          : [
              ...self.caps,
              for (final c in const ['sas', 'pair'])
                if (!self.caps.contains(c)) c,
            ],
      version: id == null ? self.version : kProtocolVersionSecure,
    );
  }

  // ------------------------------------------------------------ security

  /// Public side of this device's identity; null in the plaintext profile.
  DeviceIdentity? get identity => security?.identity.identity;

  /// Uppercase hex fingerprint of this device's certificate ('' in plaintext).
  String get ownFingerprint => identity?.fingerprint ?? '';

  /// PIN guard of the receiver; null in the plaintext profile.
  PinGuard? get pinGuard => security?.pinGuard;

  /// QR pairing (inviter and scanner side). Secure profile only.
  PairingService get pairing =>
      _pairing ?? (throw StateError('pairing needs the secure profile'));

  SecurityWiring get _wiring =>
      security ?? (throw UnsupportedError('needs the secure profile'));

  /// Contacts now (empty in the plaintext profile).
  List<Contact> get currentContacts =>
      security == null ? const [] : security!.trust.contacts;

  /// The contact list now (first event) and after every change.
  Stream<List<Contact>> get contacts {
    final w = security;
    if (w == null) return Stream.value(const <Contact>[]);
    late StreamController<List<Contact>> c;
    StreamSubscription<void>? sub;
    c = StreamController<List<Contact>>(
      onListen: () {
        c.add(w.trust.contacts);
        sub = w.trust.changes.listen((_) => c.add(w.trust.contacts));
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  /// Pins [fingerprint] for [deviceId]. Throws [KeyChangedException] when
  /// the id is pinned with another key (never replaced silently) and
  /// [ArgumentError] for a malformed fingerprint.
  Future<void> addContact({
    required String deviceId,
    required String fingerprint,
    required String alias,
    PeerTrust trust = PeerTrust.known,
  }) async {
    await _wiring.trust.pin(
      deviceId: deviceId,
      fingerprint: fingerprint,
      alias: alias,
      trust: trust,
    );
    _emit(ContactChanged(deviceId));
  }

  /// Forgets a contact (and its pairing key).
  Future<void> removeContact(String deviceId) async {
    final w = _wiring;
    await w.trust.remove(deviceId);
    try {
      await w.secrets.delete('kpair/$deviceId');
    } on Object catch (e) {
      _log.fine('pair key not removed: ${e.runtimeType}');
    }
    _emit(ContactChanged(deviceId));
  }

  Future<void> block(String fingerprint) => _wiring.trust.block(fingerprint);

  Future<void> unblock(String fingerprint) =>
      _wiring.trust.unblock(fingerprint);

  Future<void> setTrust(String deviceId, PeerTrust trust) async {
    await _wiring.trust.setTrust(deviceId, trust);
    _emit(ContactChanged(deviceId));
  }

  /// What the user needs to decide about incoming [sessionId]; null if unknown.
  IncomingSessionInfo? incomingInfo(String sessionId) =>
      _receiver?.incomingInfo(sessionId);

  /// `libreshare://pair?v=1&s=...` for a new single-use invite (LSP-1 5.3).
  /// Throws [StateError] without an open listener or a usable address.
  String createPairInvite() {
    final svc = pairing;
    final info = deviceInfo;
    if (info.port < 1 || info.addrs.isEmpty) {
      throw StateError('no open listener or address to invite to');
    }
    final best = _bestAddress(info);
    final invite = svc.createInvite();
    return Uri(
      scheme: 'libreshare',
      host: 'pair',
      queryParameters: {
        'v': '1',
        's': invite.secretB64,
        'id': info.deviceId,
        'fp': info.fingerprint,
        'n': info.alias,
        'ip': best,
        'port': '${info.port}',
      },
    ).toString();
  }

  static String _bestAddress(DeviceInfo info) =>
      (info.addrs.where((a) => a.iface == 'wifi').firstOrNull ??
              info.addrs.where((a) => a.iface == 'ethernet').firstOrNull ??
              info.addrs.first)
          .ip;

  /// Scans a pair invite: true when the inviter accepted, false when it
  /// declined. [FormatException] for anything that is not a pair invite,
  /// [PeerFingerprintMismatchException] when the listener's certificate is
  /// not the one in the invite, [LsException] for a protocol refusal.
  Future<bool> redeemPairInvite(String uri) async {
    final svc = pairing;
    final u = Uri.tryParse(uri.trim());
    if (u == null ||
        u.scheme.toLowerCase() != 'libreshare' ||
        u.host.toLowerCase() != 'pair') {
      throw const FormatException('not a libreshare://pair invite');
    }
    final q = u.queryParameters;
    final s = q['s'];
    final id = q['id'];
    final fp = q['fp'];
    final ip = q['ip'];
    final port = int.tryParse(q['port'] ?? '');
    if (q['v'] != '1' ||
        s == null ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(s) ||
        id == null ||
        id.isEmpty ||
        fp == null ||
        !RegExp(r'^[0-9A-Fa-f]{64}$').hasMatch(fp) ||
        ip == null ||
        InternetAddress.tryParse(ip) == null ||
        port == null ||
        port < 1 ||
        port > 65535) {
      throw const FormatException('malformed pair invite');
    }
    final client = ApiClient(
      host: ip,
      port: port,
      security: _config,
      expectedFingerprint: fp.toUpperCase(),
    );
    try {
      final PairScan scan;
      try {
        scan = svc.startScan(
          inviteSecretB64: s,
          inviter: DeviceInfo(
            deviceId: id,
            alias: q['n'] ?? '',
            platform: 'unknown',
            fingerprint: fp.toUpperCase(),
            port: port,
          ),
        );
      } on ArgumentError {
        // A secret that is not 32 bytes of base64url is a wrong secret.
        throw LsException(LsErrorCode.authInvalid, 'pairing secret invalid');
      }
      final response = await client.pair(scan.request);
      return await scan.complete(response);
    } finally {
      client.close();
    }
  }

  /// Starts the engine and returns the bound port, or 0 when Receive is Off.
  ///
  /// Creates the receiver, starts discovery (when configured) and then enters
  /// the initial Receive mode: [ReceiveConfig.initialMode] (default Always,
  /// which binds the listener like before Receive mode existed), or whatever
  /// `receive.restore()` finds when a [ReceiveConfig.store] is given.
  ///
  /// If the initial mode could not open its listener (no free port in
  /// 53318..53327) the bind error is rethrown after everything else is up, so
  /// the engine stays usable; call `dispose()` to give up.
  Future<int> start() async {
    if (_started) throw StateError('engine already started');
    _started = true;
    try {
      await downloadDir.create(recursive: true);
      final receiver = FileReceiver(
        self: self,
        selfProvider: () => deviceInfo,
        downloadDir: downloadDir,
        partialDir: partialDir,
        autoAccept: autoAccept,
        clock: clock,
        permissionTimeout: permissionTimeout,
        onEvent: _emit,
        security: _config,
        pinVerifier: security?.pinGuard,
        pairing: _pairing,
      )..acceptingSessions = _acceptingSessions;
      _receiver = receiver;
      _activeSub = receiver.activeSessionCountChanges.listen(_activeCounts.add);
      await _refreshAddrs();
      _addrTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => unawaited(_refreshAddrs()),
      );
      _registry.start();
      await _startDiscovery();
    } on Object {
      await stop(force: true);
      rethrow;
    }

    final cfg = receiveConfig;
    if (cfg.store != null) {
      await receive.restore(hint: cfg.exitHint);
      final st = receive.state;
      if (st is Off &&
          st.reason == OffReason.neverEnabled &&
          cfg.initialMode is! ReceiveOff) {
        await receive.turnOn(cfg.initialMode);
      }
    } else if (cfg.initialMode is! ReceiveOff) {
      await receive.turnOn(cfg.initialMode);
    }
    final st = receive.state;
    if (st is Failed) throw st.error;
    return isRunning ? port : 0;
  }

  /// Stops listening and discovery. By default waits up to [grace] for
  /// in-flight requests (e.g. the response to `POST /finish`, which fires
  /// `SessionFinished` before it is flushed) and only then forces connections
  /// closed. The engine can be started again afterwards.
  Future<void> stop({
    bool force = false,
    Duration grace = const Duration(seconds: 5),
  }) async {
    // Closing the listener starts synchronously: stop() is routinely called
    // from inside an event handler that runs before a response is flushed.
    final server = _server;
    _server = null;
    final serverClosed = server == null
        ? Future<void>.value()
        : force
        ? server.stop(force: true)
        : server.stop().timeout(
            grace,
            onTimeout: () => server.stop(force: true),
          );
    if (!_started) {
      await serverClosed;
      return;
    }
    _started = false;
    final receiveDone = receive.shutdown();

    _addrTimer?.cancel();
    _addrTimer = null;
    _pairing?.dispose();
    _scanPolicy?.dispose();
    _scanPolicy = null;
    _scanner.cancel();
    await _scanWatch?.cancel();
    _scanWatch = null;
    await _certWatch?.cancel();
    _certWatch = null;
    await _trustWatch?.cancel();
    _trustWatch = null;
    _greeted.clear();
    for (final t in _greetRetry.values) {
      t.cancel();
    }
    _greetRetry.clear();
    _registry.stop();
    await _stopMdns();
    final multicast = _multicast;
    _multicast = null;
    if (multicast != null) {
      if (server != null) await _goodbye(multicast);
      await multicast.stop();
    }

    await serverClosed;
    _receiver?.dispose();
    _receiver = null;
    await _activeSub?.cancel();
    _activeSub = null;
    _policy = AnnouncePolicy.none;
    await receiveDone;
  }

  /// Releases everything. Stops gracefully if still running.
  Future<void> dispose({bool force = false}) async {
    await stop(force: force);
    await receive.dispose();
    _registry.dispose();
    await _activeCounts.close();
    await _events.close();
  }

  // ----------------------------------------------------- ReceiveGate (driven
  // by [receive]; call receive.turnOn()/turnOff() instead of these)

  @override
  Future<int> openListener() async {
    final receiver = _receiver ?? (throw StateError('engine not started'));
    final existing = _server;
    if (existing != null && existing.isRunning) return existing.port;
    final server = ApiServer(
      handler: receiver,
      bindAddress: bindAddress,
      preferredPort: preferredPort,
      enableRateLimit: enableRateLimit,
      onRegister: _onRegister,
      security: _config,
      contactsOnly: _secure ? _isContactsOnly : null,
    );
    final bound = await server.start();
    _server = server;
    await _refreshAddrs();
    _announceChanged();
    return bound;
  }

  @override
  Future<void> closeListener({required bool graceful}) async {
    final server = _server;
    if (server == null) return;
    _server = null;
    _announceChanged();
    final m = _multicast;
    if (m != null) await _goodbye(m);
    if (graceful) {
      await server.stop().timeout(
        const Duration(seconds: 5),
        onTimeout: () => server.stop(force: true),
      );
    } else {
      await server.stop(force: true);
    }
  }

  @override
  void setAnnounce(AnnouncePolicy policy) {
    if (_policy == policy) return;
    _policy = policy;
    _announceChanged();
  }

  @override
  void setAcceptingSessions(bool accepting) {
    _acceptingSessions = accepting;
    _receiver?.acceptingSessions = accepting;
  }

  @override
  int get activeSessions => _receiver?.activeSessionCount ?? 0;

  @override
  Stream<int> get activeSessionCount => _activeCounts.stream;

  // ------------------------------------------------------------ discovery

  /// Snapshot of the devices around, now and after every change (first event
  /// on listen: the current list). Only receivable devices are listed; this
  /// device never is.
  Stream<List<DiscoveredDevice>> get devices {
    late StreamController<List<DiscoveredDevice>> controller;
    StreamSubscription<List<DiscoveredDevice>>? sub;
    controller = StreamController<List<DiscoveredDevice>>(
      onListen: () {
        controller.add(_registry.current);
        sub = _registry.devices.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () => sub?.cancel(),
    );
    return controller.stream;
  }

  /// The devices around right now, in first-seen order.
  List<DiscoveredDevice> get currentDevices => _registry.current;

  /// Looks around again: refreshes the local addresses, re-announces (or
  /// re-probes while Off) and scans the local /24. Completes when the scan has.
  Future<void> refresh() async {
    await _refreshAddrs();
    final multicast = _multicast;
    if (multicast != null && multicast.isRunning) {
      await multicast.refresh(); // announce + the scan hook
    } else {
      await scanNetwork();
    }
  }

  /// Subnet scan on demand (spec 4.2 rule 4): `GET /api/v1/info` across the
  /// local /24 of every private interface address. Peers are reported to
  /// [devices] the moment they answer.
  Future<ScanResult> scanNetwork() async {
    await _refreshAddrs();
    return _scanner.scan();
  }

  /// Asks the device at [ip]:[port] who it is without adding it to the list.
  /// Throws [PeerUnreachable] or [FormatException]. The result's
  /// `fingerprintToConfirm` is what the user compares out of band.
  Future<ResolvedPeer> resolvePeer(
    String ip,
    int port, {
    Duration timeout = ManualPeerResolver.defaultTimeout,
  }) => _resolver.resolve(ip, port, timeout: timeout);

  /// Adds a [resolvePeer] result to the device list.
  DiscoveredDevice addResolvedPeer(
    ResolvedPeer peer, {
    DiscoverySource source = DiscoverySource.manual,
  }) {
    final reported = peer.info;
    // The port that answered beats the one the peer claims.
    final clean = _sanitizePeer(_copyInfo(reported, port: peer.port));
    if (clean == null) {
      throw const FormatException('The device reported unusable identity data');
    }
    if (clean.deviceId == self.deviceId) {
      throw ArgumentError('That is this device');
    }
    _registry.seen(clean, peer.address, source);
    return _registry.byId(clean.deviceId)!;
  }

  /// Manual entry (screen 8): resolves [ip]:[port], adds the device and
  /// returns it. `result.info.fingerprint` is what the UI shows for the user to
  /// confirm (empty before TLS, Inc 3). Throws what [resolvePeer] throws.
  Future<DiscoveredDevice> addManualPeer(String ip, int port) async =>
      addResolvedPeer(await resolvePeer(ip, port));

  /// Scanned `libreshare://peer` link: resolves it, checks the fingerprint and
  /// device id the link pins and adds the device (source `qr`). Throws
  /// [PeerUnreachable], [FingerprintMismatch] or [DeviceIdMismatch].
  Future<DiscoveredDevice> addPeerLink(
    PeerLink link, {
    Duration timeout = ManualPeerResolver.defaultTimeout,
  }) async => addResolvedPeer(
    await _resolver.resolveLink(link, timeout: timeout),
    source: DiscoverySource.qr,
  );

  /// The link others scan to reach this device ("My QR"), or null while there
  /// is nothing to reach: no open listener (Receive Off) or no usable address.
  PeerLink? get myPeerLink {
    final info = deviceInfo;
    if (info.port < 1 || info.addrs.isEmpty) return null;
    final best =
        info.addrs.where((a) => a.iface == 'wifi').firstOrNull ??
        info.addrs.where((a) => a.iface == 'ethernet').firstOrNull ??
        info.addrs.first;
    try {
      return PeerLink.fromDevice(info, best.ip);
    } on FormatException {
      return null;
    }
  }

  // ---------------------------------------------------------------- sending

  Future<DeviceInfo> peerInfo(String host, int port) async {
    if (_secure) {
      final plan = await _plan(host, port);
      if (plan.plaintext) {
        final c = ApiClient(host: host, port: port);
        try {
          return await c.info();
        } finally {
          c.close();
        }
      }
      final pin = plan.pin;
      if (pin == null) {
        final known = plan.info;
        if (known != null) return known;
        throw plan.error ?? StateError('peer did not answer');
      }
      final known = plan.info;
      if (known != null) return known;
      final c = ApiClient(
        host: host,
        port: port,
        security: _config,
        expectedFingerprint: pin,
      );
      try {
        return await c.info();
      } finally {
        c.close();
      }
    }
    final client = ApiClient(host: host, port: port);
    try {
      return await client.info();
    } finally {
      client.close();
    }
  }

  /// FR-04/07/08/09/11: sends [files] to the engine listening at [host]:[port].
  /// Use [beginSendFiles] to be able to cancel it or to follow its progress.
  Future<SendResult> sendFiles(
    List<File> files, {
    required String host,
    required int port,
    String? pin,
    int chunkConcurrency = 3,
    Duration acceptTimeout = kPermissionTimeout,
  }) async => beginSendFiles(
    files,
    host: host,
    port: port,
    pin: pin,
    chunkConcurrency: chunkConcurrency,
    acceptTimeout: acceptTimeout,
  ).result;

  /// FR-04: sends [files] to a device from [devices]. The address it was heard
  /// at is tried first, then its other addresses; the first that answers
  /// `GET /info` as the same device id wins. If none does the result is
  /// `FAILED(NO_CONNECTION)` (and one failed `SessionFinished` is emitted).
  /// Use [beginSendTo] to be able to cancel it or to follow its progress.
  Future<SendResult> sendTo(
    DiscoveredDevice device,
    List<File> files, {
    String? pin,
    int chunkConcurrency = 3,
    Duration acceptTimeout = kPermissionTimeout,
    Duration probeTimeout = const Duration(milliseconds: 1500),
  }) async => beginSendTo(
    device,
    files,
    pin: pin,
    chunkConcurrency: chunkConcurrency,
    acceptTimeout: acceptTimeout,
    probeTimeout: probeTimeout,
  ).result;

  /// [sendFiles] as a handle: starts sending [files] to [host]:[port] now and
  /// returns at once. The [OutgoingSend] carries this send's own events, its
  /// result and `cancel()`, which is safe at any moment. Its events are also
  /// published on [events], like those of [sendFiles].
  ///
  /// Throws [ArgumentError] for an empty list. A missing or unreadable file
  /// surfaces as a [FileSystemException] from `result`, as with [sendFiles].
  OutgoingSend beginSendFiles(
    List<File> files, {
    required String host,
    required int port,
    String? pin,
    int chunkConcurrency = 3,
    Duration acceptTimeout = kPermissionTimeout,
  }) => _beginSend(
    files,
    find: (_) async => (host: host, port: port),
    pin: pin,
    chunkConcurrency: chunkConcurrency,
    acceptTimeout: acceptTimeout,
  );

  /// [sendTo] as a handle (see [beginSendFiles]): looks for a reachable address
  /// of [device] (the one it was heard at first, then the others; one that
  /// answers as a different device id is skipped), then sends. A `cancel()`
  /// during the lookup ends it at once with `FAILED(CANCELLED)`.
  OutgoingSend beginSendTo(
    DiscoveredDevice device,
    List<File> files, {
    String? pin,
    int chunkConcurrency = 3,
    Duration acceptTimeout = kPermissionTimeout,
    Duration probeTimeout = const Duration(milliseconds: 1500),
  }) => beginSendToCandidates(
    device,
    files,
    pin: pin,
    chunkConcurrency: chunkConcurrency,
    acceptTimeout: acceptTimeout,
    probeTimeout: probeTimeout,
  );

  /// [beginSendTo] with explicit candidates and fallback controls (Increment 4).
  OutgoingSend beginSendToCandidates(
    DiscoveredDevice device,
    List<File> files, {
    String? pin,
    int chunkConcurrency = 3,
    Duration acceptTimeout = kPermissionTimeout,
    Duration probeTimeout = const Duration(milliseconds: 1500),
    List<Candidate>? candidates,
    bool enableFallback = true,
  }) => _beginSend(
    files,
    find: (cancel) => _findEndpointWithLadder(
      device: device,
      probeTimeout: probeTimeout,
      cancel: cancel,
      candidates: candidates,
      enableFallback: enableFallback,
    ),
    pin: pin,
    chunkConcurrency: chunkConcurrency,
    acceptTimeout: acceptTimeout,
  );

  OutgoingSend _beginSend(
    List<File> files, {
    required FindEndpoint find,
    required String? pin,
    required int chunkConcurrency,
    required Duration acceptTimeout,
  }) {
    if (!_secure) {
      return OutgoingSend.start(
        files: files,
        find: find,
        connect: (to) => ApiClient(host: to.host, port: to.port),
        newSender: (client, onEvent) => FileSender(
          client: client,
          self: deviceInfo,
          pin: pin,
          chunkConcurrency: chunkConcurrency,
          acceptTimeout: acceptTimeout,
          onEvent: onEvent,
        ),
        publish: _emit,
      );
    }
    _SendPlan? plan;
    return OutgoingSend.start(
      files: files,
      // The receiver is looked at before anything is sent: a pinned key that
      // changed is refused here, an unpinned one goes through the SAS.
      find: (cancel) async {
        final ep = await find(cancel);
        if (ep == null || cancel.isCancelled) return ep;
        final made = plan = await _plan(ep.host, ep.port);
        // Nothing is sent to a device without TLS unless that was allowed.
        if (made.error is InsecurePeerException) throw made.error!;
        return ep;
      },
      connect: (to) {
        final p = plan!;
        return p.plaintext
            ? ApiClient(host: to.host, port: to.port)
            : ApiClient(
                host: to.host,
                port: to.port,
                security: _config,
                expectedFingerprint: p.pin,
              );
      },
      newSender: (client, onEvent) {
        final p = plan!;
        return _PinningSender(
          client: client,
          self: deviceInfo,
          pin: pin,
          chunkConcurrency: chunkConcurrency,
          acceptTimeout: acceptTimeout,
          onEvent: onEvent,
          security: p.plaintext ? const SecurityConfig.plaintext() : _config,
          pinnedReceiverFingerprint: p.pin,
          onAccepted: (fp) => _pinReceiver(p, fp),
        );
      },
      publish: _emit,
    );
  }

  /// Looks at the receiver at [host]:[port] before a send: who it is, whether
  /// it is a contact, whether its key is the pinned one. Throws
  /// [PeerFingerprintMismatchException] (and emits [PeerKeyChanged]) when a
  /// pinned device shows another key. Never replaces a pin.
  Future<_SendPlan> _plan(String host, int port) async {
    final trust = _wiring.trust;
    final probe = ApiClient(
      host: host,
      port: port,
      security: _config,
      requestTimeout: const Duration(seconds: 10),
    );
    try {
      final info = await probe.info();
      final fp = probe.serverFingerprint;
      if (fp == null) return _SendPlan(error: const InsecurePeerException());
      // The device id is only believed when the certificate says the same.
      final der = probe.serverCertificateDer;
      String? cn;
      try {
        cn = der == null ? null : parseCertificate(der).subjectCn;
      } on Object {
        cn = null;
      }
      if (cn != info.deviceId) {
        final byFp = trust.classifyFingerprint(fp);
        final ok =
            byFp.trust == PeerTrust.known || byFp.trust == PeerTrust.trusted;
        return _SendPlan(pin: ok ? fp : null, info: null);
      }
      final ti = trust.classify(info.deviceId, fp);
      if (ti.keyChanged) {
        final pinned = ti.pinnedFingerprint ?? '';
        _emit(
          PeerKeyChanged(
            deviceId: info.deviceId,
            pinnedFingerprint: pinned,
            presentedFingerprint: fp,
          ),
        );
        throw PeerFingerprintMismatchException(shortFp(pinned), shortFp(fp));
      }
      final pinnedNow =
          ti.trust == PeerTrust.known || ti.trust == PeerTrust.trusted;
      return _SendPlan(pin: pinnedNow ? fp : null, info: info);
    } on InsecurePeerException catch (e) {
      if (_config.allowInsecurePeers) return _SendPlan(plaintext: true);
      return _SendPlan(error: e);
    } on LsException catch (e) {
      // A Contacts-only receiver answers a stranger with 404: if we pinned it,
      // introduce ourselves with a proof.
      final fp = probe.serverFingerprint;
      if (fp != null) {
        final c = trust.classifyFingerprint(fp);
        if (!c.keyChanged &&
            (c.trust == PeerTrust.known || c.trust == PeerTrust.trusted)) {
          return _SendPlan(pin: fp);
        }
      }
      if (fp == null && await _speaksPlaintext(host, port)) {
        if (_config.allowInsecurePeers) return _SendPlan(plaintext: true);
        return _SendPlan(error: const InsecurePeerException());
      }
      return _SendPlan(error: e);
    } on PeerFingerprintMismatchException {
      rethrow;
    } on Object catch (e) {
      if (probe.serverFingerprint == null &&
          await _speaksPlaintext(host, port)) {
        if (_config.allowInsecurePeers) return _SendPlan(plaintext: true);
        return _SendPlan(error: const InsecurePeerException());
      }
      return _SendPlan(error: e);
    } finally {
      probe.close();
    }
  }

  /// Whether [host]:[port] answers `GET /info` in plain HTTP: the TLS probe
  /// failed before any certificate was seen, so this tells a legacy
  /// (plaintext) device from one that is simply not there.
  Future<bool> _speaksPlaintext(String host, int port) async {
    final plain = ApiClient(
      host: host,
      port: port,
      security: const SecurityConfig.plaintext(),
      connectTimeout: const Duration(seconds: 3),
      requestTimeout: const Duration(seconds: 3),
    );
    try {
      await plain.info();
      return true;
    } on Object {
      return false;
    } finally {
      plain.close();
    }
  }

  /// After a send that went through the SAS and was accepted: the receiver is
  /// now a pinned `known` contact (never replacing a pin).
  Future<void> _pinReceiver(_SendPlan plan, String fingerprint) async {
    final info = plan.info;
    if (info == null) return;
    try {
      await _wiring.trust.pin(
        deviceId: info.deviceId,
        fingerprint: fingerprint,
        alias: info.alias,
        trust: PeerTrust.known,
      );
      _emit(ContactChanged(info.deviceId));
    } on KeyChangedException {
      _log.warning('not pinned: key conflict');
    } on FingerprintInUseException {
      _log.warning('not pinned: fingerprint belongs to another device');
    } on Object catch (e) {
      _log.warning('not pinned: ${e.runtimeType}');
    }
  }

  /// First-contact `GET /info` over TLS for manual entry and links.
  Future<DeviceInfo?> _secureResolveProbe(
    String ip,
    int port,
    Duration timeout,
  ) async {
    final c = ApiClient(
      host: ip,
      port: port,
      security: _config,
      connectTimeout: timeout,
      requestTimeout: timeout,
    );
    try {
      return await c.info();
    } on Object {
      return null;
    } finally {
      c.close();
    }
  }

  /// Contacts-only: a device that announced before it became a contact is
  /// already in the table, so its next announce is not answered ("known").
  /// When the contact list changes, tell the new contacts we are here.
  void _greetContacts() {
    if (!_started || !_isContactsOnly() || deviceInfo.port < 1) return;
    final trust = security!.trust;
    for (final d in _registry.current) {
      final fp = d.info.fingerprint.toUpperCase();
      if (fp.isEmpty) continue;
      final t = trust.classifyFingerprint(fp).trust;
      final contact = t == PeerTrust.known || t == PeerTrust.trusted;
      if (contact && _greeted.add(fp)) {
        unawaited(_greet(fp, 0));
      } else if (!contact) {
        _greeted.remove(fp);
        _greetRetry.remove(fp)?.cancel();
      }
    }
  }

  /// Number of greeting retry timers currently pending (E5 R4c). For tests.
  @visibleForTesting
  int get greetingRetryPendingCount => _greetRetry.length;

  /// How many pending greeting retry timers are still active. For tests.
  @visibleForTesting
  int get greetingRetryActiveTimerCount =>
      _greetRetry.values.where((t) => t.isActive).length;

  /// Fingerprints of the contacts greeted so far (read-only copy). For tests.
  @visibleForTesting
  Set<String> get greetedFingerprints => Set.unmodifiable(_greeted);

  /// Back-off between greeting retries (about 40 s in 16 tries; the first
  /// eight cover 4 s at 0.5 s steps, because a contact usually pins us within
  /// seconds).
  static const List<Duration> _greetBackoff = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 500),
    Duration(milliseconds: 500),
    Duration(milliseconds: 500),
    Duration(milliseconds: 500),
    Duration(milliseconds: 500),
    Duration(milliseconds: 500),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 10),
  ];

  /// One greeting attempt ([attempt] 0 is the first). A refused or failed
  /// `POST /register` (the contact may not have pinned us yet) is retried
  /// with back-off while it is still a listed contact and we are running.
  Future<void> _greet(String fp, int attempt) async {
    _greetRetry.remove(fp)?.cancel();
    if (!_started || !_isContactsOnly() || !_greeted.contains(fp)) return;
    DiscoveredDevice? d;
    for (final x in _registry.current) {
      if (x.info.fingerprint.toUpperCase() == fp) d = x;
    }
    if (d == null) {
      _greeted.remove(fp);
      return;
    }
    final t = security!.trust.classifyFingerprint(fp).trust;
    if (t != PeerTrust.known && t != PeerTrust.trusted) {
      _greeted.remove(fp);
      return;
    }
    var ok = false;
    try {
      ok = await _registrar.call(d.info, d.address);
    } on Object catch (e) {
      _log.fine('greeting failed: ${e.runtimeType}');
    }
    if (ok || !_started || !_greeted.contains(fp)) return;
    if (attempt >= _greetBackoff.length) return;
    _greetRetry[fp] = Timer(_greetBackoff[attempt], () {
      _greetRetry.remove(fp);
      unawaited(_greet(fp, attempt + 1));
    });
  }

  Future<void> _learnCertificate(DiscoveredDevice d) async {
    final fp = d.info.fingerprint.toUpperCase();
    final port = d.info.port;
    if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(fp) || port < 1) return;
    if (_registry.certificateFor(fp) != null || !_learning.add(fp)) return;
    SecureSocket? socket;
    try {
      socket = await SecureSocket.connect(
        d.address,
        port,
        context: buildClientContext(),
        onBadCertificate: (c) => certificateMatchesPin(c, fp),
        timeout: const Duration(seconds: 2),
      );
      final der = socket.peerCertificate?.der;
      if (der != null && fingerprintHex(der) == fp) {
        _registry.learnCertificate(Uint8List.fromList(der));
      }
    } on Object {
      // unreachable or not a peer with that certificate: nothing learnt
    } finally {
      socket?.destroy();
      _learning.remove(fp);
    }
  }

  bool _isContactsOnly() =>
      receive.settings.visibility == ReceiveVisibility.contacts;

  Future<void> _goodbye(MulticastDiscovery m) async {
    try {
      await m.sendGoodbye().timeout(const Duration(milliseconds: 1500));
    } on Object catch (e) {
      _log.fine('goodbye not sent: ${e.runtimeType}');
    }
  }

  /// The address ladder of [sendTo]: where [device] was heard first, then its
  /// other addresses; the first that answers `GET /info` with the same device
  /// id wins. Null when none does (or [cancel] fired).
  Future<SendEndpoint?> _findEndpoint(
    DiscoveredDevice device,
    Duration probeTimeout,
    CancelSignal cancel,
  ) async {
    final port = device.info.port;
    if (port < 1) return null;
    final hosts = <String>{
      device.address,
      for (final a in device.info.addrs) a.ip,
    };
    for (final host in hosts) {
      if (cancel.isCancelled) return null;
      // Do not sit out the probe timeout when the caller cancels meanwhile.
      final answers = await Future.any<bool>([
        _answersAs(host, port, device.id, probeTimeout),
        cancel.whenCancelled.then((_) => false),
      ]);
      if (answers) return (host: host, port: port);
    }
    return null;
  }

  Future<SendEndpoint?> _findEndpointWithLadder({
    required DiscoveredDevice device,
    required Duration probeTimeout,
    required CancelSignal cancel,
    List<Candidate>? candidates,
    bool enableFallback = true,
  }) async {
    if (cancel.isCancelled) return null;
    if (device.info.port < 1) return null;
    if (discovery.infoProbe != null) {
      return _findEndpoint(device, probeTimeout, cancel);
    }
    final list = candidates ?? candidatesForDevice(device);
    if (list.isEmpty) {
      return _findEndpoint(device, probeTimeout, cancel);
    }
    final mgr = ConnectionManager(
      candidates: list,
      security: _secure ? _config : const SecurityConfig.plaintext(),
      tierBudget: probeTimeout,
      eventLog: eventLog,
      pinnedFingerprint: device.info.fingerprint.isNotEmpty
          ? device.info.fingerprint
          : null,
      enableFallback: enableFallback,
    );
    final sub = mgr.events.listen((e) {
      _emit(ChannelStateChanged(e));
    });
    try {
      while (!cancel.isCancelled) {
        try {
          if (mgr.activeCandidate == null) {
            final connectFuture = mgr.connect(timeout: probeTimeout);
            await Future.any([connectFuture, cancel.whenCancelled]);
            if (cancel.isCancelled) return null;
          } else {
            final fallbackFuture = mgr.fallbackToNext(
              reason: 'device_id_mismatch',
            );
            await Future.any([fallbackFuture, cancel.whenCancelled]);
            if (cancel.isCancelled) return null;
          }
        } on ConnectionException {
          break;
        }
        final active = mgr.activeCandidate;
        if (active == null) break;
        final answers = await Future.any<bool>([
          _answersAs(active.host, active.port, device.id, probeTimeout),
          cancel.whenCancelled.then((_) => false),
        ]);
        if (cancel.isCancelled) return null;
        if (answers) {
          return (host: active.host, port: active.port);
        }
        if (!enableFallback) break;
      }
    } on Object catch (e) {
      _log.warning('Connection ladder resolution failed: $e');
    } finally {
      await sub.cancel();
      await mgr.close();
    }
    return null;
  }

  List<Candidate> candidatesForDevice(DiscoveredDevice device) {
    if (device.info.port < 1 || device.info.port > 65535) return const [];
    final res = <Candidate>[];
    final fp = device.info.fingerprint;
    final primaryKind = _classifyCandidateKind(device.address);
    res.add(
      Candidate.create(
        kind: primaryKind,
        host: device.address,
        port: device.info.port,
        peerFingerprint: fp,
        costHint: primaryKind.defaultCostHint,
      ),
    );
    for (final addr in device.info.addrs) {
      if (addr.ip != device.address) {
        final kind = _classifyCandidateKind(addr.ip, iface: addr.iface);
        res.add(
          Candidate.create(
            kind: kind,
            host: addr.ip,
            port: device.info.port,
            peerFingerprint: fp,
            costHint: kind.defaultCostHint,
          ),
        );
      }
    }
    return res;
  }

  CandidateKind _classifyCandidateKind(String host, {String? iface}) {
    if (host == '127.0.0.1' || host == 'localhost' || host == '::1') {
      return CandidateKind.loopback;
    }
    if (iface == 'wifi') return CandidateKind.wifi;
    if (iface == 'ethernet') return CandidateKind.lan;
    if (host.startsWith('192.168.1.') || host.startsWith('192.168.0.')) {
      return CandidateKind.wifi;
    }
    return CandidateKind.lan;
  }

  Future<bool> _answersAs(
    String host,
    int port,
    String deviceId,
    Duration timeout,
  ) async {
    if (_secure && discovery.infoProbe == null) {
      final info = await _secureResolveProbe(host, port, timeout);
      return info != null && info.deviceId == deviceId;
    }
    final info = await (discovery.infoProbe ?? defaultInfoProbe)(
      host,
      port,
      timeout,
    );
    return info != null && info.deviceId == deviceId;
  }

  // ---------------------------------------------------------------- inside

  void _emit(LsEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  bool get _announcesReceivable =>
      _policy == AnnouncePolicy.periodic ||
      _policy == AnnouncePolicy.replyToAll;

  // A listener bound to one specific address (tests, multi-homed hosts)
  // reports exactly that address.
  bool get _pinnedBind {
    final b = bindAddress;
    return b != null && b.address != '0.0.0.0' && b.address != '::';
  }

  /// What the announcer puts on the wire: the real port while receivable and
  /// announcing, else 0 (a send-only probe, LSP-1 4.2 rule 8). Contacts-only
  /// (`replyToTrusted`) is a probe until the trust store exists (Inc 3).
  DeviceInfo _announceInfo() {
    final i = deviceInfo;
    // Contacts-only keeps the real port: nothing is multicast, but a reply to
    // a contact must name it.
    final receivable =
        i.port >= 1 &&
        (_announcesReceivable || _policy == AnnouncePolicy.replyToTrusted);
    return _copyInfo(
      i,
      port: receivable ? i.port : 0,
      addrs: _pinnedBind || advertiseIp != null ? i.addrs : const [],
    );
  }

  void _announceChanged() {
    if (!_started) return;
    _multicast?.announceNow();
    _mdnsTail = _mdnsTail.then((_) => _syncMdns());
  }

  Future<void> _refreshAddrs() async {
    final adv = advertiseIp;
    if (adv != null) {
      _addrs = [DeviceAddress(adv)];
      return;
    }
    if (_pinnedBind) {
      _addrs = [DeviceAddress(bindAddress!.address)];
      return;
    }
    try {
      final list = await discovery.interfaces.list();
      final seen = <String>{};
      _addrs = [
        for (final i in list)
          if (!i.address.isLoopback && seen.add(i.address.address))
            i.toDeviceAddress(),
      ].take(kMaxAnnounceAddrs).toList();
    } on Object catch (e) {
      _log.fine('listing interfaces failed: ${e.runtimeType}');
    }
  }

  Future<void> _startDiscovery() async {
    if (!discovery.enabled) return;
    if (_secure) {
      // A `bye` is verified against a certificate we already hold, so learn the
      // certificate of every listed peer by a bare handshake pinned to the
      // fingerprint it announced (no HTTP request is made).
      _certWatch = _registry.events.listen((e) {
        if (e is DeviceLost) return;
        unawaited(_learnCertificate(e.device));
      });
      _trustWatch = security!.trust.changes.listen((_) => _greetContacts());
    }
    final multicast = MulticastDiscovery(
      selfInfo: _announceInfo,
      transport:
          discovery.multicastTransport?.call() ??
          RawMulticastTransport(ifaces: discovery.interfaces),
      registry: _registry,
      registrar: _registrar.call,
      ifaces: discovery.interfaces,
      clock: clock,
      interfacePoll: discovery.interfacePoll,
      announceSchedule: discovery.announceSchedule,
      periodicInterval: discovery.announceInterval,
      registerTimeout: discovery.registerTimeout,
      onRefresh: () async {
        await _scanner.scan();
      },
      probes: true,
      security: _config,
      contactsOnly: _secure ? _isContactsOnly : null,
    );
    try {
      await multicast.start();
      _multicast = multicast;
    } on Object catch (e) {
      // Sandboxes and some CI hosts cannot open UDP 53318: the scan, mDNS and
      // manual entry still work.
      _log.warning('multicast discovery unavailable: ${e.runtimeType}');
    }

    if (discovery.autoScan) {
      final policy = ScanPolicy(_scanner);
      _scanPolicy = policy;
      void arm() => policy.scheduleIfNoPeers(
        hasPeers: () => _registry.current.isNotEmpty,
        after: discovery.autoScanDelay,
      );
      arm();
      _scanWatch = _registry.events.listen((e) {
        if (e is DeviceLost && _registry.current.isEmpty) arm();
      });
    }

    final mdns = discovery.mdns;
    if (mdns != null) {
      try {
        _mdnsSub = mdns.browse().listen(
          _onMdnsPeer,
          onError: (Object e) => _log.fine('mDNS browse error: $e'),
        );
      } on Object catch (e) {
        _log.warning('mDNS browsing unavailable: ${e.runtimeType}');
      }
    }
  }

  Future<void> _syncMdns() async {
    final backend = discovery.mdns;
    if (backend == null || !_started) return;
    final i = deviceInfo;
    final want = i.port >= 1 && _announcesReceivable;
    try {
      if (want) {
        if (_mdnsPort == i.port) return;
        if (_mdnsPort != null) await backend.stopAdvertising();
        final fp = shortFingerprint(i.fingerprint);
        await backend.advertise(
          MdnsService(
            name: i.alias,
            port: i.port,
            txt: {
              'id': i.deviceId,
              if (fp.isNotEmpty) 'fp': fp,
              'v': i.version,
              'pf': i.platform,
            },
          ),
        );
        _mdnsPort = i.port;
      } else if (_mdnsPort != null) {
        _mdnsPort = null;
        await backend.stopAdvertising();
      }
    } on Object catch (e) {
      _log.warning('mDNS advertising failed: ${e.runtimeType}');
    }
  }

  Future<void> _stopMdns() async {
    final backend = discovery.mdns;
    await _mdnsSub?.cancel();
    _mdnsSub = null;
    await _mdnsTail;
    if (backend == null) return;
    _mdnsPort = null;
    try {
      await backend.stopAdvertising();
      await backend.stopBrowsing();
    } on Object catch (e) {
      _log.fine('stopping mDNS failed: ${e.runtimeType}');
    }
  }

  void _onMdnsPeer(MdnsPeer p) {
    final id = p.txt['id'];
    if (id == null || id.isEmpty || p.port < 1 || p.addresses.isEmpty) return;
    // Prefer IPv4: the rest of the stack (scan, multicast, links) is IPv4.
    final address = p.addresses.firstWhere(
      (a) => InternetAddress.tryParse(a)?.type == InternetAddressType.IPv4,
      orElse: () => p.addresses.first,
    );
    final info = _sanitizePeer(
      DeviceInfo(
        deviceId: id,
        alias: p.name,
        platform: p.txt['pf'] ?? 'unknown',
        port: p.port,
        addrs: [for (final a in p.addresses) DeviceAddress(a)],
        version: p.txt['v'] ?? kProtocolVersion,
      ),
    );
    if (info == null) return;
    _registry.seen(info, address, DiscoverySource.mdns);
  }

  /// `POST /register` arrived: the caller wants to be listed here.
  void _onRegister(DeviceInfo peer, String remoteAddress) {
    final clean = _sanitizePeer(peer);
    if (clean == null || clean.port < 1) return;
    _registry.seen(clean, remoteAddress, DiscoverySource.register);
  }

  /// The scan found [info] at [ip]. A peer that is new to us does not know us
  /// yet (nothing announced to it), so introduce ourselves; this is what makes
  /// discovery two-way when multicast is blocked.
  void _onScanFound(DeviceInfo info, String ip, DiscoverySource source) {
    final isNew = _registry.byId(info.deviceId) == null;
    _registry.seen(info, ip, source);
    if (!isNew || info.deviceId == self.deviceId) return;
    if (!_started || !_announcesReceivable || info.port < 1) return;
    if (deviceInfo.port < 1) return;
    unawaited(_registrar.call(info, ip));
  }

  /// Round-trips [peer] through the announce codec: the same validation and
  /// alias sanitising as for a datagram. Null when it would be dropped.
  static DeviceInfo? _sanitizePeer(DeviceInfo peer) {
    try {
      return decodeAnnounce(encodeAnnounce(peer, announce: false))?.info;
    } on Object {
      return null;
    }
  }

  static DeviceInfo _copyInfo(
    DeviceInfo i, {
    int? port,
    List<DeviceAddress>? addrs,
  }) => DeviceInfo(
    deviceId: i.deviceId,
    alias: i.alias,
    platform: i.platform,
    deviceType: i.deviceType,
    fingerprint: i.fingerprint,
    port: port ?? i.port,
    addrs: addrs ?? i.addrs,
    caps: i.caps,
    version: i.version,
  );
}

class _FnSink implements PeerSink {
  _FnSink(this._f);
  final void Function(DeviceInfo info, String address, DiscoverySource source)
  _f;

  @override
  void seen(DeviceInfo info, String address, DiscoverySource source) =>
      _f(info, address, source);
}

/// What a send learned about its receiver before talking to it.
class _SendPlan {
  _SendPlan({this.pin, this.info, this.error, this.plaintext = false});

  /// Fingerprint the receiver must present; null = first contact (SAS).
  final String? pin;

  /// The receiver's `/info`, only when its certificate agrees with it.
  final DeviceInfo? info;

  /// Why the probe failed (the sender then fails the same way, by itself).
  final Object? error;

  /// `--allow-insecure` against a peer without TLS.
  final bool plaintext;
}

/// A [FileSender] that pins the receiver as `known` once a SAS-confirmed
/// session was accepted (before `send` returns).
class _PinningSender extends FileSender {
  _PinningSender({
    required super.client,
    required super.self,
    required super.chunkConcurrency,
    required super.acceptTimeout,
    required super.security,
    required super.pinnedReceiverFingerprint,
    required this.onAccepted,
    super.pin,
    super.onEvent,
  });

  final Future<void> Function(String fingerprint) onAccepted;

  @override
  Future<SendResult> send(List<File> files) async {
    final r = await super.send(files);
    final fp = r.receiverFingerprint;
    if (fp != null && pinnedReceiverFingerprint == null) await onAccepted(fp);
    return r;
  }
}

/// UDP multicast discovery (spec §4.2, LSP-1 §4.2).
///
/// * Announces `announce:true` at start, +1 s, +3 s, every 30 s and whenever
///   the local interface set changes (the transport re-joins the group first).
/// * Listens on the group; drops datagrams the [decodeAnnounce] rules reject,
///   our own announcements, and anything beyond 20 packets/s per source IP.
/// * Every accepted announcement is recorded in the [PeerRegistry]. An
///   `announce:true` from a peer that was not yet known (or whose fingerprint
///   changed) is answered once: via [PeerRegistrar] (`POST /register`, 2 s
///   timeout) and, if that is absent, returns false, throws or times out, via
///   a UNICAST `announce:false`. `announce:false` is recorded but never
///   answered, so replies cannot ping-pong.
///
/// **Send-only probes** (LSP-1 4.2 rule 8; enabled with [probes]). While the
/// device has no listener (`selfInfo().port == 0`, Receive mode Off) it still
/// multicasts `announce:true` with `port:0` so the devices around answer at
/// once. A probe heard from somebody else is never recorded, never registered
/// back and never listed; it is answered with a UNICAST `announce:false` when
/// we are receivable ourselves, and ignored otherwise.
///
/// The [PeerRegistry] and the [MulticastTransport] are injected: the registry
/// is shared with the other discovery sources and is NOT disposed here.
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import '../clock.dart';
import '../model/device.dart';
import '../security/contracts.dart';
import '../security/identity_proof.dart' show verifySignature;
import '../server/rate_limiter.dart';
import 'announce_codec.dart';
import 'device_discovery.dart';
import 'multicast_transport.dart';
import 'network_interfaces.dart';
import 'peer_registry.dart';

class MulticastDiscovery implements DeviceDiscovery {
  MulticastDiscovery({
    required this.selfInfo,
    required this.transport,
    required this.registry,
    this.registrar,
    this.ifaces = const SystemNetworkInterfaceProvider(),
    Clock clock = const SystemClock(),
    this.interfacePoll = const Duration(seconds: 5),
    this.announceSchedule = const [Duration(seconds: 1), Duration(seconds: 3)],
    this.periodicInterval = const Duration(seconds: 30),
    this.registerTimeout = const Duration(seconds: 2),
    int maxPacketsPerSecond = 20,
    this.maxPendingRegistrations = 32,
    this.onRefresh,
    this.probes = false,
    this.security = const SecurityConfig.plaintext(),
    this.contactsOnly,
  }) : _clock = clock,
       _limiter = RateLimiter(
         capacity: maxPacketsPerSecond,
         window: const Duration(seconds: 1),
         clock: clock.now,
         maxKeys: 1024,
       );

  /// Evaluated at every announce, so port/addresses/alias may change.
  final DeviceInfo Function() selfInfo;
  final MulticastTransport transport;

  /// Shared peer table; not disposed by [stop].
  final PeerRegistry registry;

  /// `POST /register` on a newly seen peer (null: always reply via UDP).
  final PeerRegistrar? registrar;
  final NetworkInterfaceProvider ifaces;

  /// How often the interface set is re-read (change => re-join + re-announce).
  final Duration interfacePoll;

  /// Extra announcements after the one at start, as offsets from start.
  final List<Duration> announceSchedule;

  /// Steady-state announce interval.
  final Duration periodicInterval;

  /// How long a [PeerRegistrar] call may take before the UDP fallback.
  final Duration registerTimeout;

  /// Registrar calls allowed in flight; beyond that replies go out as UDP.
  final int maxPendingRegistrations;

  /// Called at the end of [refresh] (the engine hooks the subnet scan here).
  final Future<void> Function()? onRefresh;

  /// Speak and understand send-only probes (port 0). Off by default so a
  /// device with no listener stays silent, as in Increment 2 phase 1.
  final bool probes;

  /// Secure profile (LSP/1.1): signed `bye` datagrams are sent and verified,
  /// announces carry the identity's fingerprint. The plaintext profile behaves
  /// exactly like LSP/1.0 (a `bye` is dropped as malformed input).
  final SecurityConfig security;

  /// Evaluated at every announce and every datagram. While true (Contacts-only
  /// visibility, LSP-1 4.2 rule 10 / 5.4) nothing is multicast, and a probe or
  /// announce is answered only when its fingerprint belongs to a contact.
  final bool Function()? contactsOnly;

  final Clock _clock;

  /// Most `bye` signature verifications per second, across all sources.
  static const int byeVerificationsPerSecond = 5;

  /// Accepted `bye` timestamps are within this distance of the local clock.
  static const Duration byeWindow = Duration(seconds: 60);
  static const int _maxByeMemory = 4096;

  static final Logger _log = Logger('libreshare.discovery.multicast');

  final RateLimiter _limiter;

  StreamSubscription<MulticastPacket>? _sub;
  final List<Timer> _timers = [];
  Timer? _periodic;
  Timer? _ifacePoll;
  Future<void>? _starting;
  bool _running = false;
  bool _ownsRegistrySweep = false;
  bool _polling = false;
  bool _warnedPort = false;
  int _pendingRegistrations = 0;
  String? _ifaceSignature;
  List<DeviceAddress> _localAddrs = const [];

  // fingerprint -> highest accepted bye ts (replay memory; outlives removal).
  final Map<String, int> _lastByeTs = {};

  /// Per-source failed `bye` verifications (E5 R4b): at most
  /// [_maxByeFailuresPerSource] in any sliding second, at most
  /// [_maxByeFailureSources] sources tracked (oldest evicted).
  final Map<String, List<DateTime>> _byeFailures = {};
  static const int _maxByeFailuresPerSource = 2;
  static const int _maxByeFailureSources = 256;

  /// Number of sources currently tracked in the failed-bye table (E5 R4b). For tests.
  @visibleForTesting
  int get byeFailureSourceCount => _byeFailures.length;
  final List<DateTime> _byeVerifications = [];

  int _announcesSent = 0;
  int _repliesSent = 0;
  int _rateLimited = 0;
  int _malformed = 0;

  /// Multicast announcements sent so far.
  int get announcesSent => _announcesSent;

  /// Unicast `announce:false` replies sent so far.
  int get repliesSent => _repliesSent;

  /// Datagrams dropped by the per-IP rate limit.
  int get rateLimitedPackets => _rateLimited;

  /// Datagrams dropped as malformed / foreign protocol / unknown major.
  int get malformedPackets => _malformed;

  /// Source IPs currently tracked by the rate limiter (bounded to 1024).
  int get trackedSources => _limiter.trackedKeys;

  bool get isRunning => _running;

  @override
  Stream<List<DiscoveredDevice>> get devices => registry.devices;

  @override
  Stream<DiscoveryEvent> get events => registry.events;

  @override
  List<DiscoveredDevice> get current => registry.current;

  /// Opens the transport and starts announcing. Throws if the transport cannot
  /// start (e.g. UDP port unavailable); the caller may carry on with the other
  /// discovery sources.
  @override
  Future<void> start() {
    final existing = _starting;
    if (existing != null) return existing;
    final attempt = _start();
    _starting = attempt;
    // A failed start must not be cached: allow a retry.
    unawaited(
      attempt.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_starting, attempt)) _starting = null;
        },
      ),
    );
    return attempt;
  }

  Future<void> _start() async {
    if (_running) return;
    _running = true;
    try {
      _sub = transport.packets.listen(
        _onPacket,
        onError: (Object e) => _log.fine('packet stream error: $e'),
      );
      await transport.start();
    } on Object {
      _running = false;
      await _sub?.cancel();
      _sub = null;
      rethrow;
    }
    if (!_running) {
      // stop() raced with start().
      await transport.stop();
      return;
    }
    _ownsRegistrySweep = !registry.isRunning;
    registry.start();

    await _readInterfaces();
    if (!_running) return;
    _announce();
    for (final offset in announceSchedule) {
      _timers.add(Timer(offset, _announce));
    }
    _periodic = Timer.periodic(periodicInterval, (_) => _announce());
    _ifacePoll = Timer.periodic(interfacePoll, (_) => unawaited(_pollIfaces()));
  }

  /// Cancels timers and closes the transport. Sends nothing.
  @override
  Future<void> stop() async {
    final starting = _starting;
    _starting = null;
    if (!_running) return;
    _running = false;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _periodic?.cancel();
    _periodic = null;
    _ifacePoll?.cancel();
    _ifacePoll = null;
    await _sub?.cancel();
    _sub = null;
    if (_ownsRegistrySweep) {
      registry.stop();
      _ownsRegistrySweep = false;
    }
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // start() failed; nothing more to undo.
      }
    }
    await transport.stop();
  }

  /// Announces once right now (no interface re-read, no scan hook): for the
  /// owner to call after its own port or policy changed.
  void announceNow() => _announce();

  /// Re-announces now (re-joining first if the interfaces changed) and runs
  /// [onRefresh], if any.
  @override
  Future<void> refresh() async {
    if (!_running) return;
    await _pollIfaces();
    _announce();
    final hook = onRefresh;
    if (hook != null) {
      try {
        await hook();
      } on Object catch (e) {
        _log.warning('refresh hook failed: $e');
      }
    }
  }

  // ---------------------------------------------------------------- sending

  bool get _contactsOnly {
    final f = contactsOnly;
    if (f == null) return false;
    try {
      return f();
    } on Object {
      return true; // fail closed: stay invisible
    }
  }

  /// Multicasts two signed `bye` datagrams 50 ms apart (LSP-1 4.2 rule 9).
  /// The owner calls it when the listener closes or Receive goes Off; [stop]
  /// itself stays silent. A no-op in the plaintext profile or when not running.
  Future<void> sendGoodbye() async {
    final identity = security.identity;
    if (identity == null || !_running || _contactsOnly) return;
    for (var i = 0; i < 2; i++) {
      if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!_running || _contactsOnly) return;
      try {
        transport.sendMulticast(encodeBye(identity, now: _clock.now()));
      } on Object catch (e) {
        _log.fine('goodbye send failed: ${e.runtimeType}');
      }
    }
  }

  void _announce() {
    if (!_running) return;
    if (_contactsOnly) return; // invisible: no announcement of any kind
    final bytes = _encodeSelf(announce: true);
    if (bytes == null) return;
    try {
      transport.sendMulticast(bytes);
      _announcesSent++;
    } on Object catch (e) {
      _log.warning('multicast announce failed: $e');
    }
  }

  List<int>? _encodeSelf({required bool announce}) {
    try {
      final info = _selfInfo();
      if (probes && info.port == 0) {
        // No listener: a probe asks who is around; a reply would claim a port
        // we do not have, so there is none.
        if (!announce) return null;
        return encodeAnnounce(
          info,
          announce: true,
          probe: true,
          addrs: info.addrs.isNotEmpty ? info.addrs : _localAddrs,
        );
      }
      if (info.port < 1 || info.port > 65535) {
        if (!_warnedPort) {
          _warnedPort = true;
          _log.warning(
            'not announcing: own API port is ${info.port} '
            '(an announcement must name a real port)',
          );
        }
        return null;
      }
      return encodeAnnounce(
        info,
        announce: announce,
        addrs: info.addrs.isNotEmpty ? info.addrs : _localAddrs,
      );
    } on Object catch (e) {
      _log.warning('cannot build announcement: $e');
      return null;
    }
  }

  /// [selfInfo] with, in the secure profile, the identity's fingerprint and
  /// version (an announce must carry the certificate hash, never an empty one).
  DeviceInfo _selfInfo() {
    final info = selfInfo();
    final id = security.identity?.identity;
    if (id == null || info.fingerprint.toUpperCase() == id.fingerprint) {
      return info;
    }
    return DeviceInfo(
      deviceId: info.deviceId,
      alias: info.alias,
      platform: info.platform,
      deviceType: info.deviceType,
      fingerprint: id.fingerprint,
      port: info.port,
      addrs: info.addrs,
      caps: info.caps,
      version: info.version,
    );
  }

  // -------------------------------------------------------------- receiving

  void _onPacket(MulticastPacket packet) {
    if (!_running) return;
    try {
      _handle(packet);
    } on Object catch (e) {
      // Hostile input must never take the listener down.
      _log.warning('dropping packet after internal error: $e');
    }
  }

  void _handle(MulticastPacket packet) {
    final ip = packet.source.address;
    if (!_limiter.tryAcquire(ip)) {
      _rateLimited++;
      return;
    }
    if (security.isSecure) {
      final bye = decodeBye(packet.data);
      if (bye != null) {
        _handleBye(bye, ip);
        return;
      }
    }
    final msg = decodeAnnounce(packet.data, allowProbe: probes);
    if (msg == null) {
      _malformed++;
      return;
    }
    final peer = msg.info;

    final me = _selfInfo();
    if (peer.deviceId == me.deviceId) return;
    if (me.fingerprint.isNotEmpty &&
        peer.fingerprint == me.fingerprint.toUpperCase()) {
      return;
    }

    if (msg.isProbe) {
      // Not receivable: never listed, never registered with. Answer by
      // unicast if we are receivable, so its device list fills at once.
      if (me.port >= 1 && _mayAnswer(peer)) {
        unawaited(_reply(packet, peer, register: false));
      }
      return;
    }
    if (probes && me.port < 1) {
      // We have no listener either: record what we heard, answer nobody.
      registry.seen(peer, ip, DiscoverySource.multicast);
      return;
    }

    final previous = registry.byId(peer.deviceId);
    registry.seen(peer, ip, DiscoverySource.multicast);

    if (!msg.announce) return; // replies are recorded, never answered
    if (!_mayAnswer(peer)) return; // Contacts-only: strangers get nothing

    final known =
        previous != null &&
        previous.info.fingerprint.toUpperCase() == peer.fingerprint;
    if (known) return;

    unawaited(_reply(packet, peer));
  }

  /// Contacts-only (LSP-1 4.2 rule 10): only a contact's fingerprint is
  /// answered (best effort, the claim is not authenticated). Always true when
  /// not Contacts-only.
  bool _mayAnswer(DeviceInfo peer) {
    if (!_contactsOnly) return true;
    final trust = security.trust;
    final fp = peer.fingerprint;
    if (trust == null || fp.isEmpty) return false;
    try {
      final t = trust.classifyFingerprint(fp).trust;
      return t == PeerTrust.known || t == PeerTrust.trusted;
    } on Object {
      return false;
    }
  }

  // ------------------------------------------------------------------- bye

  /// LSP-1 4.2 rule 9. Cheap checks first (they do not spend the verification
  /// budget); the replay memory is written only after the signature verified.
  void _handleBye(ByeMessage bye, String source) {
    final now = _clock.now();
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    if ((nowMs - bye.ts).abs() > byeWindow.inMilliseconds) return;

    // The named device must be listed with exactly this fingerprint, and we
    // must hold the certificate of that fingerprint.
    final listed = registry.byId(bye.deviceId);
    if (listed == null) return;
    if (listed.info.fingerprint.toUpperCase() != bye.fingerprint) return;
    final cert = registry.certificateFor(bye.fingerprint);
    if (cert == null) return;

    final last = _lastByeTs[bye.fingerprint];
    if (last != null && bye.ts <= last) return; // replay

    // A source whose byes keep failing verification is cut off before the
    // verify, so a forger cannot spend the shared budget; it recovers once its
    // failures are older than one second.
    if (_byeFailureCount(source, now) >= _maxByeFailuresPerSource) return;
    if (!_takeByeBudget(now)) return;
    if (!verifySignature(
      certDer: cert,
      domain: SigDomain.bye,
      message: byeSignedText(bye),
      signature: bye.signature,
    )) {
      _noteByeFailure(source, now);
      return;
    }
    _lastByeTs.remove(bye.fingerprint);
    _lastByeTs[bye.fingerprint] = bye.ts;
    while (_lastByeTs.length > _maxByeMemory) {
      _lastByeTs.remove(_lastByeTs.keys.first);
    }
    registry.remove(bye.deviceId);
  }

  int _byeFailureCount(String source, DateTime now) {
    final list = _byeFailures[source];
    if (list == null) return 0;
    list.removeWhere((t) => now.difference(t) >= const Duration(seconds: 1));
    if (list.isEmpty) {
      _byeFailures.remove(source);
      return 0;
    }
    return list.length;
  }

  void _noteByeFailure(String source, DateTime now) {
    (_byeFailures[source] ??= []).add(now);
    if (_byeFailures.length > _maxByeFailureSources) {
      _byeFailures.removeWhere(
        (_, l) =>
            l.every((t) => now.difference(t) >= const Duration(seconds: 1)),
      );
      while (_byeFailures.length > _maxByeFailureSources) {
        _byeFailures.remove(_byeFailures.keys.first);
      }
    }
  }

  // At most 5 verifications in any sliding second, across all sources.
  bool _takeByeBudget(DateTime now) {
    _byeVerifications.removeWhere(
      (t) => now.difference(t) >= const Duration(seconds: 1),
    );
    if (_byeVerifications.length >= byeVerificationsPerSecond) return false;
    _byeVerifications.add(now);
    return true;
  }

  /// Tells a newly seen peer about us: `POST /register` first, UDP unicast
  /// `announce:false` if that does not work out.
  Future<void> _reply(
    MulticastPacket packet,
    DeviceInfo peer, {
    bool register = true,
  }) async {
    var registered = false;
    final registrarFn = register ? registrar : null;
    if (registrarFn != null &&
        _pendingRegistrations < maxPendingRegistrations) {
      _pendingRegistrations++;
      try {
        registered = await _register(registrarFn, peer, packet.source.address);
      } finally {
        _pendingRegistrations--;
      }
    }
    if (registered || !_running) return;

    final bytes = _encodeSelf(announce: false);
    if (bytes == null) return;
    try {
      transport.sendUnicast(bytes, packet.source, packet.port);
      _repliesSent++;
    } on Object catch (e) {
      _log.fine('unicast reply to ${packet.source.address} failed: $e');
    }
  }

  /// Runs the registrar with [registerTimeout]; any failure (sync throw, async
  /// error, timeout, `false`) yields false. Listeners are attached
  /// synchronously on purpose: `Future.timeout` on an already-failed future
  /// would surface the error as unhandled.
  Future<bool> _register(PeerRegistrar register, DeviceInfo peer, String ip) {
    final done = Completer<bool>();
    void finish(bool ok) {
      if (!done.isCompleted) done.complete(ok);
    }

    final timer = Timer(registerTimeout, () {
      _log.fine('register at $ip timed out');
      finish(false);
    });
    try {
      register(peer, ip).then(
        finish,
        onError: (Object e) {
          _log.fine('register at $ip failed: $e');
          finish(false);
        },
      );
    } on Object catch (e) {
      _log.fine('register at $ip failed: $e');
      finish(false);
    }
    return done.future.whenComplete(timer.cancel);
  }

  // ------------------------------------------------------------- interfaces

  Future<void> _readInterfaces() async {
    try {
      _applyInterfaces(await ifaces.list());
    } on Object catch (e) {
      _log.fine('listing interfaces failed: $e');
    }
  }

  // Returns true if the set differs from the previous reading.
  bool _applyInterfaces(List<LocalInterface> list) {
    final signature =
        (list.map((i) => '${i.name}|${i.address.address}').toList()..sort())
            .join(',');
    final changed = _ifaceSignature != null && signature != _ifaceSignature;
    _ifaceSignature = signature;
    final seen = <String>{};
    _localAddrs = [
      for (final i in list)
        if (!i.address.isLoopback && seen.add(i.address.address))
          i.toDeviceAddress(),
    ].take(kMaxAnnounceAddrs).toList();
    return changed;
  }

  Future<void> _pollIfaces() async {
    if (_polling || !_running) return;
    _polling = true;
    try {
      final changed = _applyInterfaces(await ifaces.list());
      if (changed && _running) {
        _log.info('network interfaces changed; re-joining and re-announcing');
        try {
          await transport.rejoin();
        } on Object catch (e) {
          _log.warning('rejoin failed: $e');
        }
        _announce();
      }
    } on Object catch (e) {
      _log.fine('interface poll failed: $e');
    } finally {
      _polling = false;
    }
  }
}

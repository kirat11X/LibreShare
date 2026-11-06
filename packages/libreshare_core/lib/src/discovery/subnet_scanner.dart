/// Subnet scan fallback (spec §4.2 rule 4, LSP/1 §4.2): when multicast is
/// blocked, `GET /api/v1/info` is issued across the local /24 and every
/// answering LibreShare peer is reported to a [PeerSink] the moment it answers.
///
/// Safety properties (this code makes outbound connections to many hosts):
/// * only private address space is ever swept (RFC 1918, link-local
///   169.254/16, CGNAT 100.64/10; loopback only on explicit opt-in for tests),
///   so an interface with a public address can never turn a scan into a
///   public-internet port sweep;
/// * a bounded worker pool, never "254 futures at once";
/// * a hard cap on the number of probes per scan ([maxProbes]);
/// * every probe is time-boxed, and a hung custom probe is cut off.
///
/// **Netmask caveat.** `dart:io`'s `NetworkInterface` does not expose prefix
/// lengths, so every interface address is assumed to sit in a /24 (hosts
/// `.1`-`.254`, the address itself excluded). On a wider network (/16, /22)
/// only the local /24 slice is covered; on a narrower one a few probes go to
/// hosts outside the real subnet and time out harmlessly. The protocol rule
/// "a network larger than /22 is skipped" therefore cannot be honoured and is
/// moot: the sweep is always at most 254 hosts per interface address.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../client/api_client.dart';
import '../clock.dart';
import '../model/device.dart';
import '../protocol.dart';
import '../security/cert_factory.dart' show parseCertificate;
import '../security/contracts.dart';
import '../security/crypto_primitives.dart' show fingerprintHex;
import '../security/tls_context.dart';
import 'device_discovery.dart';
import 'network_interfaces.dart';

/// Asks the host at [ip]:[port] for its `GET /info`. Returns null on *any*
/// failure (refused, timeout, not a LibreShare peer, malformed answer); never
/// throws. [timeout] bounds the whole attempt.
typedef InfoProbe = Future<DeviceInfo?> Function(
  String ip,
  int port,
  Duration timeout,
);

/// The production [InfoProbe]: a throw-away [ApiClient] that is always closed.
Future<DeviceInfo?> defaultInfoProbe(
  String ip,
  int port,
  Duration timeout,
) async {
  final client = ApiClient(
    host: ip,
    port: port,
    connectTimeout: timeout,
    requestTimeout: timeout,
  );
  try {
    return await client.info();
  } on Object {
    return null;
  } finally {
    client.close();
  }
}

/// Result of one secure probe: the peer (null when nothing usable answered)
/// plus the certificate it presented, and whether it answered but was refused.
class _SecureProbe {
  const _SecureProbe({this.info, this.cert, this.rejected = false});
  final DeviceInfo? info;
  final Uint8List? cert;
  final bool rejected;
}

const int _maxInfoBytes = 64 * 1024;

/// Secure-profile probe (LSP-1 0.3, inc3 seams item 7): `GET https://ip:port/
/// api/v1/info` over TLS 1.3 with no trusted roots, no `X-LS-Auth` (an
/// unauthenticated server is never offered our identity) and never a plain
/// HTTP fallback. The answer is accepted only if its `fingerprint` equals the
/// SHA-256 of the certificate presented in that very handshake; a lying,
/// empty or malformed answer is `rejected`. Never throws.
Future<_SecureProbe> _secureInfoProbe(
  String ip,
  int port,
  Duration timeout,
) async {
  Uint8List? presented;
  final http = HttpClient(context: buildClientContext())
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = false
    ..userAgent = 'LibreShare/$kProtocolVersionSecure'
    ..badCertificateCallback = (X509Certificate cert, String host, int p) {
      presented = Uint8List.fromList(cert.der);
      return true; // judged below, against the fingerprint /info claims
    };
  try {
    final request =
        await http
              .getUrl(
                Uri(
                  scheme: 'https',
                  host: ip,
                  port: port,
                  path: '/api/v1/info',
                ),
              )
              .timeout(timeout)
          ..followRedirects = false; // LSP-1 0.3: never a redirect
    final response = await request.close().timeout(timeout);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      await response.drain<void>().timeout(timeout);
      return const _SecureProbe(rejected: true); // a redirect is never followed
    }
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(timeout);
      return const _SecureProbe();
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(timeout)) {
      body.add(chunk);
      if (body.length > _maxInfoBytes) return const _SecureProbe();
    }
    final cert = presented;
    if (cert == null) return const _SecureProbe();
    DeviceInfo info;
    try {
      final json = jsonDecode(utf8.decode(body.takeBytes()));
      info = DeviceInfo.fromJson((json as Map).cast<String, Object?>());
    } on Object {
      return const _SecureProbe(rejected: true); // not a LibreShare answer
    }
    if (info.fingerprint.isEmpty ||
        info.fingerprint.toUpperCase() != fingerprintHex(cert)) {
      return const _SecureProbe(rejected: true);
    }
    try {
      parseCertificate(cert, verifySelfSignature: true);
    } on Object {
      return const _SecureProbe(rejected: true);
    }
    return _SecureProbe(info: info, cert: cert);
  } on Object {
    return const _SecureProbe();
  } finally {
    http.close(force: true);
  }
}

/// Outcome of one sweep.
class ScanResult {
  const ScanResult({
    required this.probed,
    required this.found,
    required this.elapsed,
    this.rejected = 0,
  });

  /// Probes started (answered, refused, timed out or abandoned by a cancel).
  final int probed;

  /// Peers that answered, in the order they answered. Duplicates of our own
  /// device are *not* filtered here: that is the [PeerSink]'s job.
  final List<DeviceInfo> found;
  final Duration elapsed;

  /// Hosts that answered but were refused (secure profile: the `/info`
  /// fingerprint differs from the presented certificate, or is empty).
  final int rejected;

  @override
  String toString() =>
      'ScanResult(probed: $probed, found: ${found.length}, elapsed: $elapsed)';
}

/// True for addresses a scan may sweep: IPv4 in 10/8, 172.16/12, 192.168/16,
/// 169.254/16 or 100.64/10 (and 127/8 when [allowLoopback]).
bool isScannablePrivateAddress(
  InternetAddress address, {
  bool allowLoopback = false,
}) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  if (b.length != 4) return false;
  final a = b[0], c = b[1];
  if (a == 10) return true;
  if (a == 172 && c >= 16 && c <= 31) return true;
  if (a == 192 && c == 168) return true;
  if (a == 169 && c == 254) return true;
  if (a == 100 && c >= 64 && c <= 127) return true;
  if (a == 127 && allowLoopback) return true;
  return false;
}

class SubnetScanner {
  /// Spec §4.2: 64 concurrent requests.
  static const int defaultConcurrency = 64;

  /// Spec §4.2: 800 ms per request.
  static const Duration defaultTimeout = Duration(milliseconds: 800);

  /// Upper bound on probes per scan (16 full /24s).
  static const int defaultMaxProbes = 4096;

  /// How much later than [timeout] a probe that ignores its timeout is
  /// abandoned.
  static const Duration _hardCutoffGrace = Duration(milliseconds: 100);

  SubnetScanner({
    required this.ifaces,
    required this.sink,
    this._probe,
    this.concurrency = defaultConcurrency,
    this.timeout = defaultTimeout,
    this.port = kDefaultPort,
    this.maxProbes = defaultMaxProbes,
    this.allowLoopback = false,
    this.clock = const SystemClock(),
    this.security = const SecurityConfig.plaintext(),
    this.onCertificate,
  }) {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'must be >= 1');
    }
    if (maxProbes < 1) {
      throw ArgumentError.value(maxProbes, 'maxProbes', 'must be >= 1');
    }
  }

  final NetworkInterfaceProvider ifaces;
  final PeerSink sink;

  /// Number of worker loops; also the maximum number of probes in flight.
  final int concurrency;

  /// Per-probe timeout.
  final Duration timeout;

  /// TCP port probed on every host (peers on a fallback port are not found).
  final int port;

  /// Hard cap on probes per scan; candidates beyond it are not probed.
  final int maxProbes;

  /// Allow sweeping 127/8 (tests / loopback labs). Never enable in the app.
  final bool allowLoopback;
  final Clock clock;
  final InfoProbe? _probe;

  /// Secure profile: probes use HTTPS only and check the fingerprint against
  /// the presented certificate. A custom [InfoProbe] is a plaintext/test hook only and is ignored here.
  final SecurityConfig security;

  /// Secure profile: receives the DER of the certificate of every peer that
  /// passed the fingerprint check (never an unverified one).
  final void Function(Uint8List certDer)? onCertificate;

  _Run? _current;

  /// Sweeps the local /24 of every private IPv4 interface address (only the
  /// interface named [onlyInterface] if given) and reports each answering peer
  /// to the sink immediately via `seen(info, ip, DiscoverySource.subnetScan)`.
  ///
  /// Never throws: a failing interface provider yields an empty result and a
  /// throwing sink or probe is contained. A scan requested while one for the
  /// same [onlyInterface] is running joins it (same future); one for a
  /// different interface waits for it.
  Future<ScanResult> scan({String? onlyInterface}) {
    final running = _current;
    if (running != null) {
      if (running.onlyInterface == onlyInterface) return running.future;
      return running.future.then((_) => scan(onlyInterface: onlyInterface));
    }
    final run = _Run(onlyInterface);
    _current = run;
    run.future = _sweep(run).whenComplete(() {
      if (identical(_current, run)) _current = null;
    });
    return run.future;
  }

  /// Stops the scan in progress (if any) as soon as possible; its future
  /// completes with whatever was found so far. The scanner stays usable.
  void cancel() => _current?.cancel();

  // ------------------------------------------------------------------ sweep

  Future<ScanResult> _sweep(_Run run) async {
    final started = clock.now();
    final found = <DeviceInfo>[];
    var probed = 0;
    var rejected = 0;

    final targets = await _targets(run.onlyInterface);
    var next = 0;

    Future<void> worker() async {
      while (!run.cancelled && next < targets.length) {
        final ip = targets[next++];
        probed++;
        final outcome = await _probeOne(ip, run);
        if (outcome.rejected) rejected++;
        final info = outcome.info;
        if (info == null) continue;
        found.add(info);
        final cert = outcome.cert;
        if (cert != null) {
          try {
            onCertificate?.call(cert);
          } on Object {
            // a faulty callback must not abort the sweep
          }
        }
        try {
          sink.seen(info, ip, DiscoverySource.subnetScan);
        } on Object {
          // A faulty sink must not abort the sweep.
        }
      }
    }

    final workers = targets.length < concurrency ? targets.length : concurrency;
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    return ScanResult(
      probed: probed,
      found: List.unmodifiable(found),
      elapsed: clock.now().difference(started),
      rejected: rejected,
    );
  }

  /// Runs one probe, never throwing, never outliving timeout + grace and
  /// returning early (null) when the run is cancelled.
  Future<_SecureProbe> _probeOne(String ip, _Run run) {
    Future<_SecureProbe> attempt() async {
      try {
        // A custom InfoProbe is a plaintext/test hook only: the secure profile
        // always uses its own verified HTTPS probe.
        final custom = security.isSecure ? null : _probe;
        if (security.isSecure) {
          return await _secureInfoProbe(
            ip,
            port,
            timeout,
          ).timeout(timeout + _hardCutoffGrace);
        }
        final info = await (custom ?? defaultInfoProbe)(
          ip,
          port,
          timeout,
        ).timeout(timeout + _hardCutoffGrace);
        return _SecureProbe(info: info);
      } on Object {
        return const _SecureProbe();
      }
    }

    return Future.any([attempt(), run.cancelSignal.future]);
  }

  /// Candidate IPs: hosts .1-.254 of each distinct private /24, minus every
  /// local address, truncated to [maxProbes].
  Future<List<String>> _targets(String? onlyInterface) async {
    final List<LocalInterface> all;
    try {
      all = await ifaces.list();
    } on Object {
      return const [];
    }
    final own = <String>{for (final i in all) i.address.address};
    final prefixes = <String>{}; // insertion-ordered
    for (final i in all) {
      if (onlyInterface != null && i.name != onlyInterface) continue;
      if (!isScannablePrivateAddress(i.address, allowLoopback: allowLoopback)) {
        continue;
      }
      final b = i.address.rawAddress;
      prefixes.add('${b[0]}.${b[1]}.${b[2]}');
    }
    final out = <String>[];
    for (final prefix in prefixes) {
      for (var host = 1; host <= 254; host++) {
        if (out.length >= maxProbes) return out;
        final ip = '$prefix.$host';
        if (!own.contains(ip)) out.add(ip);
      }
    }
    return out;
  }
}

class _Run {
  _Run(this.onlyInterface);
  final String? onlyInterface;
  late final Future<ScanResult> future;
  final Completer<_SecureProbe> cancelSignal = Completer<_SecureProbe>();
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    if (!cancelSignal.isCompleted) cancelSignal.complete(const _SecureProbe());
  }
}

/// Spec §4.2: "After 5 s with no peers, or on demand" a subnet scan runs.
/// This is the "after 5 s with no peers" half; on demand is
/// [SubnetScanner.scan].
class ScanPolicy {
  ScanPolicy(this.scanner, {this.onScanComplete});

  static const Duration defaultDelay = Duration(seconds: 5);

  final SubnetScanner scanner;

  /// Called with the result of every scan this policy started (not when the
  /// callback itself throws: that is swallowed).
  final void Function(ScanResult result)? onScanComplete;

  Timer? _timer;
  bool _disposed = false;
  bool _scanning = false;

  /// A scan is armed and has not fired yet.
  bool get isScheduled => _timer != null;

  /// Arms one scan for [after] from now, unless one is already armed (then
  /// this is a no-op). When the timer fires, the scan runs only if
  /// `hasPeers()` is still false, so peers found by multicast in the meantime
  /// cancel it. After firing, the policy can be armed again (the engine does
  /// so on start and whenever the last peer disappears).
  void scheduleIfNoPeers({
    required bool Function() hasPeers,
    Duration after = defaultDelay,
  }) {
    if (_disposed || _timer != null) return;
    _timer = Timer(after, () {
      _timer = null;
      if (_disposed) return;
      bool known;
      try {
        known = hasPeers();
      } on Object {
        known = false;
      }
      if (!known) unawaited(_scan());
    });
  }

  Future<void> _scan() async {
    _scanning = true;
    try {
      final result = await scanner.scan();
      try {
        onScanComplete?.call(result);
      } on Object {
        // callback bugs must not surface as unhandled async errors
      }
    } finally {
      _scanning = false;
    }
  }

  /// Cancels a pending timer and any scan this policy started. Idempotent;
  /// the policy cannot be re-armed afterwards.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    if (_scanning) scanner.cancel();
  }
}

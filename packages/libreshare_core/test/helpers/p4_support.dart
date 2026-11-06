// Shared fixtures for the P4 receiver / consent / SAS / pairing tests (Increment 3).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart'
    show sha256Hex;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'manual_clock.dart';

const String kRxId = 'rx-id';
const String kTxId = 'tx-id';

final Map<String, KeyIdentity> _identityCache = {};

/// One cached identity per [name] (key generation costs ~20 ms): stable across the tests of a
/// file, but never share an identity between roles that must differ.
KeyIdentity p4Identity(String name, {String? deviceId}) =>
    _identityCache.putIfAbsent(name, () => freshIdentity(deviceId ?? name));

/// A brand new key pair and certificate for [deviceId] (the "same device, new key" case).
KeyIdentity freshIdentity(String deviceId) =>
    KeyIdentity.fromGenerated(generateIdentityFor(deviceId));

String fpOf(KeyIdentity k) => k.identity.fingerprint;

/// What the HTTP layer hands over after a valid `X-LS-Auth` proof of [k].
AuthenticatedPeer peerOf(
  KeyIdentity k, {
  String? deviceId,
  bool noCn = false,
}) => AuthenticatedPeer(
  fingerprint: k.identity.fingerprint,
  certDer: k.identity.certDer,
  deviceId: noCn ? null : (deviceId ?? k.identity.deviceId),
);

/// The `DeviceInfo` a secure sender puts in `SessionRequest.sender`.
DeviceInfo infoOf(
  KeyIdentity k, {
  String alias = 'Sender',
  String? deviceId,
  String? fingerprint,
  String version = kProtocolVersionSecure,
}) => DeviceInfo(
  deviceId: deviceId ?? k.identity.deviceId,
  alias: alias,
  platform: 'linux',
  fingerprint: fingerprint ?? k.identity.fingerprint,
  version: version,
);

const int p4ChunkSize = 64 * 1024;

/// The 5 content bytes of file `f<i>` in a [p4Request] manifest.
List<int> p4Bytes(int i) => [i & 0xff, (i >> 8) & 0xff, 3, 4, 5];

/// A consistent manifest of [fileCount] tiny files. Real SHA-256 values are used on purpose: a
/// receiver that dumps the manifest into a log would put 64-hex runs there.
SessionRequest p4Request(
  KeyIdentity sender, {
  String? commit,
  String? pin,
  DeviceInfo? info,
  int fileCount = 1,
  int chunkSize = p4ChunkSize,
  String alias = 'Sender',
  int? totalSize,
}) {
  final items = <FileItem>[
    for (var i = 0; i < fileCount; i++)
      FileItem(
        fileId: 'f$i',
        fileName: fileCount == 1 ? 'a.bin' : 'file-$i.bin',
        size: 5,
        chunkCount: 1,
        sha256: sha256Hex(p4Bytes(i)),
      ),
  ];
  return SessionRequest(
    sender: info ?? infoOf(sender, alias: alias),
    files: items,
    totalSize: totalSize ?? 5 * fileCount,
    chunkSize: chunkSize,
    pin: pin,
    sasCommit: commit,
  );
}

/// The sender's half of the SAS commit/reveal, built with the real P1 functions.
class SasSender {
  SasSender(
    this.sender,
    String receiverFingerprintSeenBySender, {
    List<int>? ns,
  }) : ns = Uint8List.fromList(
         ns ?? List<int>.generate(16, (i) => (0x30 + i) & 0xff),
       ),
       commit = sasCommit(
         ns: ns ?? List<int>.generate(16, (i) => (0x30 + i) & 0xff),
         senderFingerprint: sender.identity.fingerprint,
         receiverFingerprintSeenBySender: receiverFingerprintSeenBySender,
       );

  final KeyIdentity sender;
  final Uint8List ns;
  final String commit;

  String get nonceB64 => b64urlEncode(ns);

  /// The code both screens must show once `Nr` ([nrB64]) is known.
  String codeWith(String nrB64, String receiverFingerprint) => sasCode(
    ns: ns,
    nr: b64urlDecode(nrB64),
    fingerprintA: sender.identity.fingerprint,
    fingerprintB: receiverFingerprint,
  );
}

class PinCheckCall {
  PinCheckCall(this.remoteAddress, this.pin, this.exempt);
  final String remoteAddress;
  final String? pin;
  final bool exempt;
}

/// A recording [PinVerifier]. Throws [failWith] when set; counts `consume()` calls.
class RecordingPinVerifier implements PinVerifier {
  RecordingPinVerifier({this.enforced = true, this.failWith});

  @override
  bool enforced;
  LsException? failWith;
  final List<PinCheckCall> checks = [];
  int consumed = 0;

  @override
  void check({
    required String remoteAddress,
    required String? pin,
    required bool exempt,
  }) {
    checks.add(PinCheckCall(remoteAddress, pin, exempt));
    final f = failWith;
    if (f != null) throw f;
  }

  @override
  void consume() => consumed++;
}

Matcher isLs(LsErrorCode code) =>
    isA<LsException>().having((e) => e.code, 'code', code);

/// Awaits [future], expects an [LsException] with [code], and returns it for further checks.
Future<LsException> expectLs(Future<Object?> future, LsErrorCode code) async {
  try {
    await future;
  } on LsException catch (e) {
    expect(e.code, code, reason: 'got ${e.code.wire}: ${e.message}');
    return e;
  }
  fail('expected LsException(${code.wire}) but the call succeeded');
}

/// A receiver wired like the engine will wire it, with in-memory trust and a temp download dir.
class P4Rig {
  P4Rig({
    ConsentPolicy consent = const ConsentPolicy(),
    PinPolicy pin = const PinPolicy.off(),
    this.pinVerifier,
    bool autoAccept = false,
    ManualClock? clock,
    Duration? sessionTtl,
    Directory? downloadDir,
    bool secure = true,
    KeyIdentity? receiverIdentity,
  }) : clock = clock ?? ManualClock(),
       tmp = Directory.systemTemp.createTempSync('ls_p4_'),
       rxIdentity = receiverIdentity ?? p4Identity(kRxId) {
    trust = InMemoryTrustStore(clock: this.clock);
    dl = downloadDir ?? Directory('${tmp.path}/Downloads');
    if (downloadDir == null) dl.createSync(recursive: true);
    receiver = FileReceiver(
      self: DeviceInfo(
        deviceId: kRxId,
        alias: 'Receiver',
        platform: 'linux',
        fingerprint: secure ? rxIdentity.identity.fingerprint : '',
        version: secure ? kProtocolVersionSecure : kProtocolVersion,
      ),
      downloadDir: dl,
      autoAccept: autoAccept,
      clock: this.clock,
      onEvent: events.add,
      freeSpaceProbe: (_) async => free,
      sessionTtl: sessionTtl ?? const Duration(hours: 24),
      security: secure
          ? SecurityConfig.tls(
              identity: rxIdentity,
              trust: trust,
              pin: pin,
              consent: consent,
            )
          : const SecurityConfig.plaintext(),
      pinVerifier: pinVerifier,
    );
  }

  final ManualClock clock;
  final Directory tmp;
  final KeyIdentity rxIdentity;
  final PinVerifier? pinVerifier;
  late final InMemoryTrustStore trust;
  late final Directory dl;
  late final FileReceiver receiver;
  final List<LsEvent> events = [];

  /// Free bytes the probe reports; null = unknown (always enough).
  int? free;

  String get rxFp => rxIdentity.identity.fingerprint;

  Future<SessionStatus> open(
    KeyIdentity sender, {
    String? commit,
    String? pin,
    String remote = '192.0.2.10',
    SessionRequest? request,
    AuthenticatedPeer? peer,
    int fileCount = 1,
  }) => receiver.createAuthenticatedSession(
    request ??
        p4Request(sender, commit: commit, pin: pin, fileCount: fileCount),
    remoteAddress: remote,
    peer: peer ?? peerOf(sender),
  );

  /// Pins [k] for the receiver as [level] (a previously made contact).
  Future<void> pinContact(
    KeyIdentity k,
    PeerTrust level, {
    String alias = 'Pinned',
  }) => trust.pin(
    deviceId: k.identity.deviceId,
    fingerprint: k.identity.fingerprint,
    alias: alias,
    trust: level,
  );

  Iterable<T> eventsOf<T extends LsEvent>() => events.whereType<T>();

  void dispose() {
    receiver.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best effort
    }
  }
}

// ----------------------------------------------------------------- log capture

class LogCapture {
  final List<LogRecord> records = [];
  StreamSubscription<LogRecord>? _sub;
  Level? _old;

  void start() {
    _old = Logger.root.level;
    Logger.root.level = Level.ALL;
    _sub = Logger.root.onRecord.listen(records.add);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final old = _old;
    if (old != null) Logger.root.level = old;
  }

  /// Everything a log reader could see: logger, level, message, error and stack trace.
  String get text => records
      .map(
        (r) =>
            '${r.loggerName} ${r.level.name} ${r.message} '
            '${r.error ?? ''} ${r.stackTrace ?? ''}',
      )
      .join('\n');
}

final RegExp _uuid = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
);

/// Names every kind of leak the hygiene rules forbid in [text]: a sentinel value, a 64-hex run
/// (a full fingerprint or SHA-256), a base64url run of 40 or more characters (keys, commits,
/// secrets), or a full session id. An empty result means clean.
List<String> p4Leaks(String text, {Map<String, String> sentinels = const {}}) {
  final out = <String>[];
  sentinels.forEach((label, value) {
    if (value.isNotEmpty && text.contains(value)) out.add('sentinel:$label');
  });
  if (RegExp(r'[0-9A-Fa-f]{64}').hasMatch(text)) out.add('64-hex-run');
  if (RegExp(r'[A-Za-z0-9_-]{40,}').hasMatch(text)) out.add('base64url-run');
  if (_uuid.hasMatch(text)) out.add('full-session-id');
  return out;
}

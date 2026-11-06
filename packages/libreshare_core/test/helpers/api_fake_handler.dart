/// Scriptable [IncomingTransferHandler] used by the ApiServer conformance
/// suite and the ApiClient round-trip tests. Every method records its
/// arguments; override the `on*` hooks to script behaviour or throw
/// [LsException]s.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';

/// What the fake saw for the most recent chunk PUT.
class ChunkRecord {
  ChunkRecord({
    required this.sessionId,
    required this.fileId,
    required this.index,
    required this.token,
    required this.chunkSha256,
    required this.byteCount,
    required this.eventCount,
    required this.sha256Hex,
  });
  final String sessionId;
  final String fileId;
  final int index;
  final String token;
  final String? chunkSha256;
  final int byteCount;
  final int eventCount;

  /// SHA-256 (lowercase hex) of the bytes the handler actually received.
  final String sha256Hex;
}

class FakeIncomingHandler implements IncomingTransferHandler {
  DeviceInfo info = const DeviceInfo(
    deviceId: 'dev-receiver',
    alias: 'Receiver',
    platform: 'linux',
    port: 53318,
    addrs: [DeviceAddress('10.0.0.5', iface: 'wifi')],
  );

  /// Method names in call order (e.g. `createSession`, `putChunk`).
  final List<String> calls = [];

  // --- scripting hooks -------------------------------------------------
  Future<SessionStatus> Function(SessionRequest request, String remoteAddress)?
  onCreateSession;
  Future<SessionStatus> Function(String sessionId, Duration wait)? onGetSession;
  Future<FileState> Function(String sessionId, String fileId, String token)?
  onFileState;
  Future<void> Function(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body,
    String token,
    String? chunkSha256,
  )?
  onPutChunk;
  Future<FileVerification> Function(
    String sessionId,
    String fileId,
    String token,
    String? sha256,
  )?
  onComplete;
  Future<SessionStatus> Function(String sessionId)? onFinish;
  Future<void> Function(String sessionId)? onCancel;
  DeviceInfo Function(DeviceInfo peer)? onRegister;
  DeviceInfo Function()? onDeviceInfo;

  // --- recorded arguments ----------------------------------------------
  SessionRequest? lastRequest;
  String? lastRemoteAddress;
  String? lastSessionId;
  Duration? lastWait;
  String? lastFileId;
  String? lastToken;
  String? lastSha256;
  DeviceInfo? lastRegistered;
  ChunkRecord? lastChunk;

  @override
  DeviceInfo get deviceInfo {
    calls.add('deviceInfo');
    return onDeviceInfo?.call() ?? info;
  }

  @override
  DeviceInfo register(DeviceInfo peer) {
    calls.add('register');
    lastRegistered = peer;
    return onRegister?.call(peer) ?? info;
  }

  @override
  Future<SessionStatus> createSession(
    SessionRequest request, {
    required String remoteAddress,
  }) async {
    calls.add('createSession');
    lastRequest = request;
    lastRemoteAddress = remoteAddress;
    final hook = onCreateSession;
    if (hook != null) return hook(request, remoteAddress);
    return const SessionStatus(
      sessionId: 'sess-1',
      status: TransferStatus.pending,
    );
  }

  @override
  Future<SessionStatus> getSession(
    String sessionId, {
    Duration wait = Duration.zero,
  }) async {
    calls.add('getSession');
    lastSessionId = sessionId;
    lastWait = wait;
    final hook = onGetSession;
    if (hook != null) return hook(sessionId, wait);
    return SessionStatus(sessionId: sessionId, status: TransferStatus.pending);
  }

  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) async {
    calls.add('fileState');
    lastSessionId = sessionId;
    lastFileId = fileId;
    lastToken = token;
    final hook = onFileState;
    if (hook != null) return hook(sessionId, fileId, token);
    return const FileState(
      receivedRanges: [
        [0, 1],
        [4, 4],
      ],
      chunkCount: 6,
    );
  }

  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required String token,
    String? chunkSha256,
  }) async {
    calls.add('putChunk');
    lastSessionId = sessionId;
    lastFileId = fileId;
    lastToken = token;
    final hook = onPutChunk;
    if (hook != null) {
      await hook(sessionId, fileId, index, body, token, chunkSha256);
      return;
    }
    lastChunk = await drainChunk(
      body,
      sessionId: sessionId,
      fileId: fileId,
      index: index,
      token: token,
      sha: chunkSha256,
    );
  }

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async {
    calls.add('completeFile');
    lastSessionId = sessionId;
    lastFileId = fileId;
    lastToken = token;
    lastSha256 = sha256;
    final hook = onComplete;
    if (hook != null) return hook(sessionId, fileId, token, sha256);
    return FileVerification(verified: true, sha256: sha256 ?? 'ab' * 32);
  }

  @override
  Future<SessionStatus> finish(String sessionId) async {
    calls.add('finish');
    lastSessionId = sessionId;
    final hook = onFinish;
    if (hook != null) return hook(sessionId);
    return SessionStatus(
      sessionId: sessionId,
      status: TransferStatus.completed,
    );
  }

  @override
  Future<void> cancel(String sessionId) async {
    calls.add('cancel');
    lastSessionId = sessionId;
    await onCancel?.call(sessionId);
  }
}

/// Consumes [body] fully, hashing incrementally, and returns what it saw.
Future<ChunkRecord> drainChunk(
  Stream<List<int>> body, {
  required String sessionId,
  required String fileId,
  required int index,
  required String token,
  String? sha,
}) async {
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  var bytes = 0;
  var events = 0;
  await for (final c in body) {
    events++;
    bytes += c.length;
    input.add(c);
  }
  input.close();
  return ChunkRecord(
    sessionId: sessionId,
    fileId: fileId,
    index: index,
    token: token,
    chunkSha256: sha,
    byteCount: bytes,
    eventCount: events,
    sha256Hex: out.digest.toString(),
  );
}

class _DigestSink implements Sink<Digest> {
  late Digest digest;
  @override
  void add(Digest data) => digest = data;
  @override
  void close() {}
}

/// Deterministic, non-repeating-looking test payload.
Uint8List patternBytes(int length, {int seed = 7}) {
  final data = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    data[i] = (x >> 16) & 0xff;
  }
  return data;
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// A syntactically valid, minimal [SessionRequest] for tests.
SessionRequest sampleRequest({
  String version = '1.0',
  List<FileItem>? files,
  String? pin,
}) {
  final items =
      files ??
      const [
        FileItem(fileId: 'f1', fileName: 'a.bin', size: 10, chunkCount: 1),
        FileItem(fileId: 'f2', fileName: 'b.bin', size: 0, chunkCount: 0),
      ];
  return SessionRequest(
    sender: DeviceInfo(
      deviceId: 'dev-sender',
      alias: 'Sender',
      platform: 'windows',
      version: version,
    ),
    files: items,
    totalSize: items.fold<int>(0, (a, f) => a + f.size),
    pin: pin,
  );
}

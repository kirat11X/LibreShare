// A scriptable SecurePeerClient for FileSender tests: the receiver side of the LSP/1.1 SAS flow
// (LSP-1 5.1) without any network. It behaves like the real receiver where that matters for the
// sender: it verifies the commitment against ITS OWN fingerprint when Ns is revealed, it cannot
// accept before the reveal, and a cancel makes pending long polls answer 410 CANCELLED.
import 'dart:async';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';

enum CreateMode {
  /// 202 PENDING; carries `sas.nonce` iff the request carried a `sasCommit`.
  pending,

  /// 202 PENDING, never a `sas` member (a receiver that ignores `sasCommit`).
  pendingWithoutSas,

  /// 200 IN_PROGRESS at once (auto-accept despite the commit).
  immediateAccept,

  /// 202 PENDING with a `sas.nonce` that is not 16 bytes of base64url.
  pendingBadNonce,
}

class FakeSecurePeer implements SecurePeerClient {
  FakeSecurePeer({
    required this.senderFp,
    required this.receiverFp,
    String? seenFp,
    this.legacy = false,
  }) : fingerprintSeenBySender = legacy ? null : (seenFp ?? receiverFp);

  /// Fingerprint of the sending device (the one whose commit the receiver checks).
  final String senderFp;

  /// The real receiver's own fingerprint: what it recomputes the commitment with.
  final String receiverFp;

  /// What the sender's TLS handshake showed; differs from [receiverFp] for a relaying MITM.
  /// Null = plaintext/legacy peer: [serverFingerprint] stays null.
  String? fingerprintSeenBySender;
  final bool legacy;

  // ---- knobs ----
  CreateMode mode = CreateMode.pending;
  final Uint8List nr = Uint8List.fromList(List.generate(16, (i) => 0xA0 + i));
  Object? createError;
  Object? infoError;
  Object? revealError;
  Completer<void>? revealGate;
  final Completer<void> revealEntered = Completer<void>();

  /// Holds the answer of waitSession (the receiver's user has not decided yet).
  Completer<void>? holdAccept;
  FailureReason? failAfterReveal;
  bool neverAccept = false;

  // ---- observations ----
  final List<String> calls = [];
  SessionRequest? request;
  Uint8List? revealedNs;
  int reveals = 0;
  int puts = 0;
  final List<String> cancelled = [];
  bool _revealed = false;
  String? _seen;
  final Completer<void> _cancel = Completer<void>();

  static const sessionId = 'sess-sas';

  void _touch(String call) {
    calls.add(call);
    _seen ??= fingerprintSeenBySender;
  }

  @override
  String? get serverFingerprint => _seen;

  Map<String, AcceptedFile> _accepted() => {
    for (final f in request!.files)
      f.fileId: AcceptedFile(token: 'tok-${f.fileId}'),
  };

  @override
  Future<DeviceInfo> info() async {
    _touch('info');
    final e = infoError;
    if (e != null) throw e;
    return DeviceInfo(
      deviceId: 'rx',
      alias: 'rx',
      platform: 'linux',
      fingerprint: legacy ? '' : receiverFp,
      version: legacy ? kProtocolVersion : kProtocolVersionSecure,
    );
  }

  @override
  Future<DeviceInfo> register(DeviceInfo self) =>
      throw UnimplementedError('unused by FileSender');

  @override
  Future<PairResponse> pair(PairRequest request) =>
      throw UnimplementedError('unused by FileSender');

  @override
  Future<SessionStatus> createSession(SessionRequest r) async {
    _touch('createSession');
    final e = createError;
    if (e != null) throw e;
    request = r;
    switch (mode) {
      case CreateMode.immediateAccept:
        return SessionStatus(
          sessionId: sessionId,
          status: TransferStatus.inProgress,
          acceptedFiles: _accepted(),
        );
      case CreateMode.pendingWithoutSas:
        return const SessionStatus(
          sessionId: sessionId,
          status: TransferStatus.pending,
        );
      case CreateMode.pendingBadNonce:
        return const SessionStatus(
          sessionId: sessionId,
          status: TransferStatus.pending,
          sas: SasChallenge(nonce: 'short'),
        );
      case CreateMode.pending:
        return SessionStatus(
          sessionId: sessionId,
          status: TransferStatus.pending,
          sas: r.sasCommit == null
              ? null
              : SasChallenge(nonce: b64urlEncode(nr)),
        );
    }
  }

  Future<T> _orCancelled<T>(Future<T> f) => Future.any([
    f,
    _cancel.future.then<T>((_) => throw LsException(LsErrorCode.cancelled)),
  ]);

  @override
  Future<SessionStatus> revealSas(
    String sessionId, {
    required String nonce,
  }) async {
    _touch('revealSas');
    reveals++;
    if (!revealEntered.isCompleted) revealEntered.complete();
    final gate = revealGate;
    if (gate != null) await _orCancelled(gate.future);
    final e = revealError;
    if (e != null) throw e;
    final ns = b64urlDecode(nonce);
    final ok =
        request?.sasCommit != null &&
        sasCommitMatches(
          commit: request!.sasCommit!,
          ns: ns,
          senderFingerprint: senderFp,
          receiverFingerprintSeenBySender: receiverFp,
        );
    if (!ok) throw LsException(LsErrorCode.authInvalid);
    revealedNs = Uint8List.fromList(ns);
    _revealed = true;
    return SessionStatus(
      sessionId: sessionId,
      status: TransferStatus.pending,
      sas: SasChallenge(nonce: b64urlEncode(nr)),
    );
  }

  @override
  Future<SessionStatus> waitSession(
    String sessionId, {
    int waitSeconds = 25,
  }) async {
    _touch('waitSession');
    final hold = holdAccept;
    if (hold != null) await _orCancelled(hold.future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final needsReveal = request?.sasCommit != null && !_revealed;
    if (neverAccept || needsReveal) {
      return SessionStatus(
        sessionId: sessionId,
        status: TransferStatus.pending,
        sas: request?.sasCommit == null
            ? null
            : SasChallenge(nonce: b64urlEncode(nr)),
      );
    }
    final fail = failAfterReveal;
    if (fail != null) {
      return SessionStatus(
        sessionId: sessionId,
        status: TransferStatus.failed,
        failureReason: fail,
      );
    }
    return SessionStatus(
      sessionId: sessionId,
      status: TransferStatus.inProgress,
      acceptedFiles: _accepted(),
    );
  }

  @override
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  }) async {
    _touch('fileState');
    final item = request!.files.firstWhere((f) => f.fileId == fileId);
    return FileState(receivedRanges: const [], chunkCount: item.chunkCount);
  }

  @override
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  }) async {
    _touch('putChunk');
    puts++;
    await body.drain<void>();
  }

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async {
    _touch('completeFile');
    return FileVerification(verified: true, sha256: sha256 ?? '00' * 32);
  }

  @override
  Future<SessionStatus> finish(String sessionId) async {
    _touch('finish');
    return SessionStatus(
      sessionId: sessionId,
      status: TransferStatus.completed,
    );
  }

  @override
  Future<void> cancel(String sessionId) async {
    _touch('cancel');
    cancelled.add(sessionId);
    if (!_cancel.isCompleted) _cancel.complete();
  }

  @override
  void close() {}

  /// The code the receiver's screen shows once the reveal verified.
  String expectedCode() => sasCode(
    ns: revealedNs!,
    nr: nr,
    fingerprintA: senderFp,
    fingerprintB: receiverFp,
  );
}

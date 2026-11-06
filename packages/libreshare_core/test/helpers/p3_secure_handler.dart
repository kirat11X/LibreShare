/// Recording fake [SecureTransferHandler] for the P3 (secure ApiServer + PIN guard) tests.
///
/// Every call is appended to [calls] with the arguments the HTTP layer passed (method name,
/// authenticated peer, remote address). Behaviour is scriptable: set the `on*` hooks or [failWith]
/// to answer with an [LsException]. Defaults return canned, valid results.
library;

import 'dart:async';

import 'package:crypto/crypto.dart' as c;
import 'package:libreshare_core/libreshare_core.dart';

/// One recorded handler invocation.
class P3Call {
  P3Call(
    this.method, {
    this.peer,
    this.remoteAddress,
    this.sessionId,
    this.nonce,
    this.request,
    this.pairRequest,
    this.chunkSha256,
    this.token,
    this.byteCount,
  });

  final String method;
  final AuthenticatedPeer? peer;
  final String? remoteAddress;
  final String? sessionId;
  final String? nonce;
  final SessionRequest? request;
  final PairRequest? pairRequest;
  final String? chunkSha256;
  final String? token;
  final int? byteCount;

  @override
  String toString() => 'P3Call($method)';
}

class P3SecureHandler implements SecureTransferHandler {
  P3SecureHandler({DeviceInfo? info})
    : info =
          info ??
          const DeviceInfo(
            deviceId: 'dev-receiver',
            alias: 'Receiver',
            platform: 'linux',
            port: 53318,
            version: kProtocolVersionSecure,
          );

  DeviceInfo info;

  final List<P3Call> calls = [];

  /// Method names in call order.
  List<String> get names => [for (final c in calls) c.method];

  /// Number of recorded calls to [method].
  int count(String method) => calls.where((c) => c.method == method).length;

  P3Call last(String method) => calls.lastWhere((c) => c.method == method);

  /// When set, every handler method that returns a result throws this instead.
  LsException? failWith;

  Future<SessionStatus> Function(
    SessionRequest request,
    String remoteAddress,
    AuthenticatedPeer? peer,
  )?
  onCreateAuthenticated;
  Future<SessionStatus> Function(
    String sessionId,
    String nonce,
    AuthenticatedPeer? peer,
  )?
  onRevealSas;
  Future<PairResponse> Function(
    PairRequest request,
    String remoteAddress,
    AuthenticatedPeer peer,
  )?
  onPair;
  Future<SessionStatus> Function(String sessionId, Duration wait)? onGetSession;
  Future<void> Function(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body,
  )?
  onPutChunk;

  void _maybeFail() {
    final f = failWith;
    if (f != null) throw f;
  }

  @override
  DeviceInfo get deviceInfo {
    calls.add(P3Call('deviceInfo'));
    _maybeFail();
    return info;
  }

  @override
  DeviceInfo register(DeviceInfo peer) {
    calls.add(P3Call('register'));
    _maybeFail();
    return info;
  }

  /// The plaintext entry point. A secure ApiServer must call
  /// [createAuthenticatedSession] instead; tests assert that this stays at zero.
  @override
  Future<SessionStatus> createSession(
    SessionRequest request, {
    required String remoteAddress,
  }) async {
    calls.add(
      P3Call('createSession', request: request, remoteAddress: remoteAddress),
    );
    _maybeFail();
    return const SessionStatus(
      sessionId: 'sess-plain',
      status: TransferStatus.pending,
    );
  }

  @override
  Future<SessionStatus> createAuthenticatedSession(
    SessionRequest request, {
    required String remoteAddress,
    required AuthenticatedPeer? peer,
  }) async {
    calls.add(
      P3Call(
        'createAuthenticatedSession',
        request: request,
        remoteAddress: remoteAddress,
        peer: peer,
      ),
    );
    _maybeFail();
    final hook = onCreateAuthenticated;
    if (hook != null) return hook(request, remoteAddress, peer);
    return const SessionStatus(
      sessionId: 'sess-1',
      status: TransferStatus.pending,
    );
  }

  @override
  Future<SessionStatus> revealSas(
    String sessionId, {
    required String nonce,
    required AuthenticatedPeer? peer,
  }) async {
    calls.add(
      P3Call('revealSas', sessionId: sessionId, nonce: nonce, peer: peer),
    );
    _maybeFail();
    final hook = onRevealSas;
    if (hook != null) return hook(sessionId, nonce, peer);
    return SessionStatus(
      sessionId: sessionId,
      status: TransferStatus.pending,
      sas: SasChallenge(nonce: nonce),
    );
  }

  @override
  Future<PairResponse> pair(
    PairRequest request, {
    required String remoteAddress,
    required AuthenticatedPeer peer,
  }) async {
    calls.add(
      P3Call(
        'pair',
        pairRequest: request,
        remoteAddress: remoteAddress,
        peer: peer,
      ),
    );
    _maybeFail();
    final hook = onPair;
    if (hook != null) return hook(request, remoteAddress, peer);
    return PairResponse(accepted: false, responder: info);
  }

  @override
  IncomingSessionInfo? incomingInfo(String sessionId) {
    calls.add(P3Call('incomingInfo', sessionId: sessionId));
    return null;
  }

  @override
  Future<SessionStatus> getSession(
    String sessionId, {
    Duration wait = Duration.zero,
  }) async {
    calls.add(P3Call('getSession', sessionId: sessionId));
    _maybeFail();
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
    calls.add(P3Call('fileState', sessionId: sessionId, token: token));
    _maybeFail();
    return const FileState(receivedRanges: [], chunkCount: 1);
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
    final hook = onPutChunk;
    if (hook != null) {
      calls.add(
        P3Call(
          'putChunk',
          sessionId: sessionId,
          token: token,
          chunkSha256: chunkSha256,
        ),
      );
      await hook(sessionId, fileId, index, body);
      return;
    }
    var n = 0;
    final digest = c.sha256.startChunkedConversion(_Sink());
    await for (final part in body) {
      n += part.length;
      digest.add(part);
    }
    digest.close();
    calls.add(
      P3Call(
        'putChunk',
        sessionId: sessionId,
        token: token,
        chunkSha256: chunkSha256,
        byteCount: n,
      ),
    );
    _maybeFail();
  }

  @override
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  }) async {
    calls.add(P3Call('completeFile', sessionId: sessionId, token: token));
    _maybeFail();
    return FileVerification(verified: true, sha256: sha256 ?? 'ab' * 32);
  }

  @override
  Future<SessionStatus> finish(String sessionId) async {
    calls.add(P3Call('finish', sessionId: sessionId));
    _maybeFail();
    return SessionStatus(
      sessionId: sessionId,
      status: TransferStatus.completed,
    );
  }

  @override
  Future<void> cancel(String sessionId) async {
    calls.add(P3Call('cancel', sessionId: sessionId));
    _maybeFail();
  }
}

class _Sink implements Sink<c.Digest> {
  @override
  void add(c.Digest data) {}
  @override
  void close() {}
}

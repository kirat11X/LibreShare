/// What the HTTP layer (ApiServer) calls. Implemented by FileReceiver (7.0) /
/// TransferSession logic. Throw [LsException] for protocol errors; the server
/// maps them to the spec §4.3 error envelope + status code.
library;

import '../model/device.dart';
import '../security/contracts.dart';
import '../model/session_models.dart';

abstract interface class IncomingTransferHandler {
  /// POST /sessions. Returns PENDING (202) or IN_PROGRESS with tokens (200, auto-accept).
  Future<SessionStatus> createSession(
    SessionRequest request, {
    required String remoteAddress,
  });

  /// GET /sessions/{sid}?wait=N. Completes when status changes or [wait] elapses.
  Future<SessionStatus> getSession(
    String sessionId, {
    Duration wait = Duration.zero,
  });

  /// GET /sessions/{sid}/files/{fid}/state
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  });

  /// PUT /sessions/{sid}/files/{fid}/chunks/{idx}. [body] is exactly one chunk.
  /// Must verify [chunkSha256] (lowercase hex, may be null only if sender omitted) -> 422.
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required String token,
    String? chunkSha256,
  });

  /// POST .../files/{fid}/complete. [sha256] supplied by sender when manifest had null.
  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  });

  /// POST /sessions/{sid}/finish
  Future<SessionStatus> finish(String sessionId);

  /// POST /sessions/{sid}/cancel
  Future<void> cancel(String sessionId);

  /// GET /info and POST /register
  DeviceInfo get deviceInfo;

  /// POST /register: record the announcing peer, return our own info.
  DeviceInfo register(DeviceInfo peer);
}

/// The secure-profile extension of [IncomingTransferHandler]. A plaintext server (the Inc 1
/// loopback profile) only needs the base interface; a TLS server requires this one, so legacy
/// test fakes keep compiling unchanged. [I3]
abstract interface class SecureTransferHandler
    implements IncomingTransferHandler {
  /// POST /sessions with the authenticated caller ([peer] is null only in the plaintext profile).
  Future<SessionStatus> createAuthenticatedSession(
    SessionRequest request, {
    required String remoteAddress,
    required AuthenticatedPeer? peer,
  });

  /// POST /sessions/{sid}/sas: the sender reveals its nonce. Throws [LsException]
  /// (`authInvalid` if the commitment does not match, `wrongState` if called twice).
  Future<SessionStatus> revealSas(
    String sessionId, {
    required String nonce,
    required AuthenticatedPeer? peer,
  });

  /// POST /pair, held open until the inviter's user decides or [kPairTimeout] elapses.
  Future<PairResponse> pair(
    PairRequest request, {
    required String remoteAddress,
    required AuthenticatedPeer peer,
  });

  /// What a consent prompt for [sessionId] should show (sender identity, trust, SAS code).
  IncomingSessionInfo? incomingInfo(String sessionId);
}

/// Client-side view of a peer's LSP/1 API. Implemented by ApiClient (HTTP[S]) in
/// Inc 1; later by TunnelConnection. FileSender depends only on this interface.
/// Methods throw [LsException] on protocol errors and [SocketException]/
/// [TimeoutException] on transport errors.
library;

import '../model/device.dart';
import '../model/session_models.dart';

abstract interface class PeerClient {
  Future<DeviceInfo> info();
  Future<DeviceInfo> register(DeviceInfo self);
  Future<SessionStatus> createSession(SessionRequest request);
  Future<SessionStatus> waitSession(String sessionId, {int waitSeconds = 25});
  Future<FileState> fileState(
    String sessionId,
    String fileId, {
    required String token,
  });

  /// [length] must equal the byte count of [body]; [chunkSha256] is lowercase hex.
  Future<void> putChunk(
    String sessionId,
    String fileId,
    int index,
    Stream<List<int>> body, {
    required int length,
    required String chunkSha256,
    required String token,
  });

  Future<FileVerification> completeFile(
    String sessionId,
    String fileId, {
    required String token,
    String? sha256,
  });
  Future<SessionStatus> finish(String sessionId);
  Future<void> cancel(String sessionId);
  void close();
}

/// The secure-profile extension of [PeerClient] (TLS with a pinned server, signed requests).
/// Plain [PeerClient] fakes keep working; the secure FileSender path requires this. [I3]
abstract interface class SecurePeerClient implements PeerClient {
  /// Uppercase-hex SHA-256 of the server certificate seen in the TLS handshake of the most
  /// recent connection; null before the first request or in the plaintext profile.
  String? get serverFingerprint;

  /// POST /sessions/{sid}/sas
  Future<SessionStatus> revealSas(String sessionId, {required String nonce});

  /// POST /pair
  Future<PairResponse> pair(PairRequest request);
}

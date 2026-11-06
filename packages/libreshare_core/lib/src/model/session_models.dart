/// Wire DTOs for /sessions (spec §4.3). Unknown JSON fields are ignored.
library;

import '../protocol.dart';
import 'device.dart';
import 'file_item.dart';
import 'transfer_status.dart';

class TunnelOffer {
  const TunnelOffer({
    required this.provider,
    required this.url,
    required this.keyB64,
    required this.expiresAt,
  });
  final String provider;
  final String url;
  final String keyB64;
  final DateTime expiresAt;
  Map<String, Object?> toJson() => {
    'provider': provider,
    'url': url,
    'keyB64': keyB64,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
  factory TunnelOffer.fromJson(Map<String, Object?> j) => TunnelOffer(
    provider: j['provider']! as String,
    url: j['url']! as String,
    keyB64: j['keyB64']! as String,
    expiresAt: DateTime.parse(j['expiresAt']! as String),
  );
}

class SessionRequest {
  const SessionRequest({
    required this.sender,
    required this.files,
    required this.totalSize,
    this.pin,
    this.chunkSize = kChunkSize,
    this.tunnelOffer,
    this.sasCommit,
  });

  /// b64url SHA-256 commitment to the sender's SAS nonce; present iff the sender could not
  /// authenticate the receiver (no pin). [I3]
  final String? sasCommit;
  final DeviceInfo sender;
  final String? pin;
  final int chunkSize;
  final List<FileItem> files;
  final int totalSize;
  final TunnelOffer? tunnelOffer;

  Map<String, Object?> toJson() => {
    'sender': sender.toJson(),
    'pin': pin,
    'chunkSize': chunkSize,
    'files': files.map((f) => f.toJson()).toList(),
    'totalSize': totalSize,
    'tunnelOffer': tunnelOffer?.toJson(),
    if (sasCommit != null) 'sasCommit': sasCommit,
  };

  factory SessionRequest.fromJson(Map<String, Object?> j) => SessionRequest(
    sasCommit: j['sasCommit'] as String?,
    sender: DeviceInfo.fromJson((j['sender']! as Map).cast<String, Object?>()),
    pin: j['pin'] as String?,
    chunkSize: (j['chunkSize'] as int?) ?? kChunkSize,
    files: (j['files']! as List)
        .map((e) => FileItem.fromJson((e as Map).cast<String, Object?>()))
        .toList(),
    totalSize: j['totalSize']! as int,
    tunnelOffer: j['tunnelOffer'] == null
        ? null
        : TunnelOffer.fromJson(
            (j['tunnelOffer']! as Map).cast<String, Object?>(),
          ),
  );
}

/// Inclusive chunk-index ranges [[0,41],[50,50]] -> chunks 0..41 and 50.
typedef ChunkRanges = List<List<int>>;

class AcceptedFile {
  const AcceptedFile({required this.token, this.receivedRanges = const []});
  final String token; // b64url 128-bit
  final ChunkRanges receivedRanges;
  Map<String, Object?> toJson() => {
    'token': token,
    'receivedRanges': receivedRanges,
  };
  factory AcceptedFile.fromJson(Map<String, Object?> j) => AcceptedFile(
    token: j['token']! as String,
    receivedRanges: ((j['receivedRanges'] as List?) ?? const [])
        .map((r) => (r as List).cast<int>())
        .toList(),
  );
}

/// The receiver's SAS nonce (b64url, 16 bytes), returned in the session status. [I3]
class SasChallenge {
  const SasChallenge({required this.nonce});
  final String nonce;
  Map<String, Object?> toJson() => {'nonce': nonce};
  factory SasChallenge.fromJson(Map<String, Object?> j) =>
      SasChallenge(nonce: j['nonce']! as String);
}

class SessionStatus {
  const SessionStatus({
    required this.sessionId,
    required this.status,
    this.failureReason,
    this.acceptedFiles = const {},
    this.sas,
  });

  /// Present while a SAS comparison is pending. [I3]
  final SasChallenge? sas;
  final String sessionId;
  final TransferStatus status;
  final FailureReason? failureReason;
  final Map<String, AcceptedFile> acceptedFiles;

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'status': status.wire,
    'failureReason': failureReason?.wire,
    'acceptedFiles': acceptedFiles.map((k, v) => MapEntry(k, v.toJson())),
    if (sas != null) 'sas': sas!.toJson(),
  };
  factory SessionStatus.fromJson(Map<String, Object?> j) => SessionStatus(
    sas: j['sas'] is Map
        ? SasChallenge.fromJson((j['sas']! as Map).cast<String, Object?>())
        : null,
    sessionId: j['sessionId']! as String,
    status: TransferStatus.fromWire(j['status']! as String),
    failureReason: FailureReason.fromWire(j['failureReason'] as String?),
    acceptedFiles: ((j['acceptedFiles'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(
        k as String,
        AcceptedFile.fromJson((v as Map).cast<String, Object?>()),
      ),
    ),
  );
}

/// GET .../files/{fid}/state
class FileState {
  const FileState({required this.receivedRanges, required this.chunkCount});
  final ChunkRanges receivedRanges;
  final int chunkCount;
  Map<String, Object?> toJson() => {
    'receivedRanges': receivedRanges,
    'chunkCount': chunkCount,
  };
  factory FileState.fromJson(Map<String, Object?> j) => FileState(
    receivedRanges: ((j['receivedRanges'] as List?) ?? const [])
        .map((r) => (r as List).cast<int>())
        .toList(),
    chunkCount: j['chunkCount']! as int,
  );
}

/// POST .../complete response.
class FileVerification {
  const FileVerification({required this.verified, required this.sha256});
  final bool verified;
  final String sha256;
  Map<String, Object?> toJson() => {'verified': verified, 'sha256': sha256};
  factory FileVerification.fromJson(Map<String, Object?> j) => FileVerification(
    verified: j['verified']! as bool,
    sha256: j['sha256']! as String,
  );
}

/// POST /pair (QR pairing, docs/plans/inc3.md D13). [I3]
class PairRequest {
  const PairRequest({
    required this.sender,
    required this.nonce,
    required this.mac,
  });

  /// The scanning device (its fingerprint must equal the TLS/proof identity).
  final DeviceInfo sender;

  /// b64url, 16 random bytes (nB).
  final String nonce;

  /// b64url HMAC-SHA256(S, "LSP1-PAIR-REQ\0" || fpB || fpA || nB).
  final String mac;
  Map<String, Object?> toJson() => {
    'sender': sender.toJson(),
    'nonce': nonce,
    'mac': mac,
  };
  factory PairRequest.fromJson(Map<String, Object?> j) => PairRequest(
    sender: DeviceInfo.fromJson((j['sender']! as Map).cast<String, Object?>()),
    nonce: j['nonce']! as String,
    mac: j['mac']! as String,
  );
}

class PairResponse {
  const PairResponse({
    required this.accepted,
    required this.responder,
    this.nonce,
    this.mac,
  });
  final bool accepted;
  final DeviceInfo responder;

  /// nA (b64url) and the inviter's confirmation MAC; null when [accepted] is false.
  final String? nonce, mac;
  Map<String, Object?> toJson() => {
    'accepted': accepted,
    'responder': responder.toJson(),
    if (nonce != null) 'nonce': nonce,
    if (mac != null) 'mac': mac,
  };
  factory PairResponse.fromJson(Map<String, Object?> j) => PairResponse(
    accepted: j['accepted']! as bool,
    responder: DeviceInfo.fromJson(
      (j['responder']! as Map).cast<String, Object?>(),
    ),
    nonce: j['nonce'] as String?,
    mac: j['mac'] as String?,
  );
}

/// Helpers for [ChunkRanges] <-> index sets.
Set<int> expandRanges(ChunkRanges r) => {
  for (final p in r)
    for (var i = p[0]; i <= p[1]; i++) i,
};

ChunkRanges compactRanges(Iterable<int> indices) {
  final sorted = indices.toSet().toList()..sort();
  final out = <List<int>>[];
  for (final i in sorted) {
    if (out.isNotEmpty && out.last[1] == i - 1) {
      out.last[1] = i;
    } else {
      out.add([i, i]);
    }
  }
  return out;
}

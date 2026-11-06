// ignore_for_file: depend_on_referenced_packages
/// Session persistence models for LibreShare (Increment 4, Decision D2).
///
/// Encapsulates persistent state for both receiver and sender sessions, binding
/// partial download files and chunk progress to the authenticated peer's identity.
///
/// Security Invariants:
/// 1. ZERO SECRET LEAKS: Session records MUST NEVER store PINs, bearer tokens,
///    private keys, or SAS nonces. All authentication is renewed on resume.
/// 2. PEER BINDING: Partial files can only be adopted if the resume request comes
///    from a peer presenting the matching [peerFingerprint].
/// 3. 24H TTL: Sessions older than 24 hours are expired and evicted.
library;

import '../model/session_models.dart';
import '../model/transfer_status.dart';

/// Forbidden keys that must never appear in persisted session records.
const Set<String> kForbiddenSecretKeys = {
  'pin',
  'token',
  'secret',
  'privatekey',
  'private_key',
  'nonce',
  'sascommit',
  'sas_commit',
  'keyb64',
  'password',
  'authheader',
  'x-ls-auth',
  'bearer',
  'authorization',
  'shared_secret',
  'private',
  'master_key',
  'credential',
};

/// Validates that [map] contains no forbidden secret keys recursively.
void assertNoSecretKeys(Map<String, Object?> map) {
  for (final key in map.keys) {
    if (kForbiddenSecretKeys.contains(key.toLowerCase())) {
      throw ArgumentError(
        'Security violation: SessionRecord must never persist secret: $key',
      );
    }
    final val = map[key];
    if (val is Map) {
      assertNoSecretKeys(val.cast<String, Object?>());
    } else if (val is List) {
      for (final item in val) {
        if (item is Map) {
          assertNoSecretKeys(item.cast<String, Object?>());
        }
      }
    }
  }
}

/// The role of the local peer in the transfer session.
enum SessionRole {
  sender('sender'),
  receiver('receiver');

  const SessionRole(this.wire);
  final String wire;

  static SessionRole fromWire(String wire) {
    for (final role in SessionRole.values) {
      if (role.wire == wire) return role;
    }
    throw ArgumentError.value(wire, 'wire', 'Unknown session role');
  }
}

/// Persistent record of an individual file within a session.
class SessionFileRecord {
  const SessionFileRecord({
    required this.fileId,
    required this.name,
    required this.size,
    required this.chunkSize,
    required this.chunkCount,
    this.sha256,
    this.partialPath,
    this.receivedRanges = const [],
    this.isComplete = false,
  }) : assert(size >= 0, 'size must be non-negative'),
       assert(chunkSize > 0, 'chunkSize must be positive'),
       assert(chunkCount >= 0, 'chunkCount must be non-negative');

  /// Unique file identifier within the session.
  final String fileId;

  /// Sanitized relative file path or name.
  final String name;

  /// Total expected file size in bytes.
  final int size;

  /// Chunk size used for transfer partitioning (typically 4 MiB).
  final int chunkSize;

  /// Total number of chunks in this file.
  final int chunkCount;

  /// Expected SHA-256 digest of the complete file, if declared in manifest.
  final String? sha256;

  /// Path to the in-progress partial file (`.lspart`), if local to receiver.
  final String? partialPath;

  /// Inclusive ranges of acknowledged chunk indices (e.g. `[[0, 4], [8, 8]]`).
  final ChunkRanges receivedRanges;

  /// Whether all chunks have been received and verified.
  final bool isComplete;

  /// Total number of acknowledged received chunks.
  int get receivedChunkCount {
    var count = 0;
    for (final range in receivedRanges) {
      if (range.length == 2 && range[1] >= range[0]) {
        count += (range[1] - range[0] + 1);
      }
    }
    return count;
  }

  /// Creates a copy of this file record with updated properties.
  SessionFileRecord copyWith({
    String? fileId,
    String? name,
    int? size,
    int? chunkSize,
    int? chunkCount,
    String? sha256,
    String? partialPath,
    ChunkRanges? receivedRanges,
    bool? isComplete,
  }) {
    return SessionFileRecord(
      fileId: fileId ?? this.fileId,
      name: name ?? this.name,
      size: size ?? this.size,
      chunkSize: chunkSize ?? this.chunkSize,
      chunkCount: chunkCount ?? this.chunkCount,
      sha256: sha256 ?? this.sha256,
      partialPath: partialPath ?? this.partialPath,
      receivedRanges: receivedRanges ?? this.receivedRanges,
      isComplete: isComplete ?? this.isComplete,
    );
  }

  Map<String, Object?> toJson() => {
    'fileId': fileId,
    'name': name,
    'size': size,
    'chunkSize': chunkSize,
    'chunkCount': chunkCount,
    if (sha256 != null) 'sha256': sha256,
    if (partialPath != null) 'partialPath': partialPath,
    'receivedRanges': receivedRanges,
    'isComplete': isComplete,
  };

  factory SessionFileRecord.fromJson(Map<String, Object?> json) {
    assertNoSecretKeys(json);
    return SessionFileRecord(
      fileId: json['fileId']! as String,
      name: json['name']! as String,
      size: json['size']! as int,
      chunkSize: json['chunkSize']! as int,
      chunkCount: json['chunkCount']! as int,
      sha256: json['sha256'] as String?,
      partialPath: json['partialPath'] as String?,
      receivedRanges: ((json['receivedRanges'] as List?) ?? const [])
          .map((r) => (r as List).cast<int>())
          .toList(),
      isComplete: (json['isComplete'] as bool?) ?? false,
    );
  }
}

/// Persistent record of an active, paused, or completed transfer session.
class SessionRecord {
  const SessionRecord({
    required this.sessionId,
    required this.role,
    required this.peerDeviceId,
    required this.peerFingerprint,
    required this.status,
    this.failureReason,
    required this.files,
    required this.totalSize,
    this.chosenCandidateId,
    required this.createdAt,
    required this.updatedAt,
    this.extraMetadata = const {},
  }) : assert(sessionId.length > 0, 'sessionId must not be empty'),
       assert(peerDeviceId.length > 0, 'peerDeviceId must not be empty'),
       assert(peerFingerprint.length > 0, 'peerFingerprint must not be empty');

  /// Unique session UUID.
  final String sessionId;

  /// Role of the local host in this session (sender or receiver).
  final SessionRole role;

  /// Device ID of the remote peer.
  final String peerDeviceId;

  /// SHA-256 pinned certificate fingerprint of the remote peer.
  ///
  /// Invariant: Resume is only permitted if the peer authenticates with this fingerprint.
  final String peerFingerprint;

  /// Current transfer status.
  final TransferStatus status;

  /// Detailed cause if status is [TransferStatus.failed].
  final FailureReason? failureReason;

  /// Files included in this transfer session.
  final List<SessionFileRecord> files;

  /// Total size of all files in bytes.
  final int totalSize;

  /// ID of the candidate network path used by sender, if known.
  final String? chosenCandidateId;

  /// Session creation timestamp.
  final DateTime createdAt;

  /// Last observed activity or chunk transmission timestamp.
  final DateTime updatedAt;

  /// Non-secret extension properties.
  final Map<String, Object?> extraMetadata;

  /// Returns true if this session has exceeded [maxAge] since [updatedAt].
  bool isExpired(DateTime now, {Duration maxAge = const Duration(hours: 24)}) {
    return now.difference(updatedAt) > maxAge;
  }

  /// Creates a copy of this session record with updated properties.
  SessionRecord copyWith({
    String? sessionId,
    SessionRole? role,
    String? peerDeviceId,
    String? peerFingerprint,
    TransferStatus? status,
    FailureReason? failureReason,
    List<SessionFileRecord>? files,
    int? totalSize,
    String? chosenCandidateId,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, Object?>? extraMetadata,
  }) {
    return SessionRecord(
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      peerDeviceId: peerDeviceId ?? this.peerDeviceId,
      peerFingerprint: peerFingerprint ?? this.peerFingerprint,
      status: status ?? this.status,
      failureReason: failureReason ?? this.failureReason,
      files: files ?? this.files,
      totalSize: totalSize ?? this.totalSize,
      chosenCandidateId: chosenCandidateId ?? this.chosenCandidateId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      extraMetadata: extraMetadata ?? this.extraMetadata,
    );
  }

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'sessionId': sessionId,
      'role': role.wire,
      'peerDeviceId': peerDeviceId,
      'peerFingerprint': peerFingerprint,
      'status': status.wire,
      if (failureReason != null) 'failureReason': failureReason!.wire,
      'files': files.map((f) => f.toJson()).toList(),
      'totalSize': totalSize,
      if (chosenCandidateId != null) 'chosenCandidateId': chosenCandidateId,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      if (extraMetadata.isNotEmpty) 'extraMetadata': extraMetadata,
    };
    assertNoSecretKeys(json);
    return json;
  }

  factory SessionRecord.fromJson(Map<String, Object?> json) {
    assertNoSecretKeys(json);
    return SessionRecord(
      sessionId: json['sessionId']! as String,
      role: SessionRole.fromWire(json['role']! as String),
      peerDeviceId: json['peerDeviceId']! as String,
      peerFingerprint: json['peerFingerprint']! as String,
      status: TransferStatus.fromWire(json['status']! as String),
      failureReason: FailureReason.fromWire(json['failureReason'] as String?),
      files: (json['files']! as List)
          .map(
            (f) =>
                SessionFileRecord.fromJson((f as Map).cast<String, Object?>()),
          )
          .toList(),
      totalSize: json['totalSize']! as int,
      chosenCandidateId: json['chosenCandidateId'] as String?,
      createdAt: DateTime.parse(json['createdAt']! as String),
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      extraMetadata: ((json['extraMetadata'] as Map?) ?? const {})
          .cast<String, Object?>(),
    );
  }

  @override
  String toString() =>
      'SessionRecord($sessionId, role=${role.wire}, peer=$peerDeviceId, '
      'status=${status.wire}${failureReason != null ? " ($failureReason)" : ""}, '
      'files=${files.length}, size=$totalSize)';
}

// ignore_for_file: depend_on_referenced_packages
/// Receiver restart sidecar adoption helper with cryptographic ownership validation (Increment 4, P4-5).
///
/// Implements the FR-15 restart-resume requirements and Increment 4 Decisions D2 & D3:
/// 1. Receiver restart: When a receiver restarts, in-memory session tables are empty.
/// 2. Sidecar check: Existing `<name>.lspart` and `.lspart.json` sidecars are checked.
/// 3. Peer authentication validation (D2/D3): Validates cryptographic peer identity against
///    prior [SessionRecord]s before adopting chunks. Partial files are NEVER adopted by or
///    revealed to an unauthenticated or mismatched peer.
/// 4. 24h TTL eviction: Sidecars older than 24 hours are expired and deleted.
/// 5. Manifest integrity: If file size, chunk size, chunk count, sha256, or modified timestamp
///    differ from the manifest, stale partials are discarded and download restarts from byte 0.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final Logger _log = Logger('ReceiverAdoptionHelper');

/// Outcome of attempting to adopt an existing partial file and sidecar.
enum AdoptionStatus {
  /// Sidecar successfully verified and adopted with existing chunks.
  adopted,

  /// No prior sidecar exists; file transfer starts fresh from byte 0.
  fresh,

  /// Sidecar existed but is older than 24 hours; partial file and sidecar deleted.
  expired,

  /// Request is unauthenticated; partial file adoption refused for security.
  rejectedUnauthenticated,

  /// Partial file belongs to another authenticated peer; adoption strictly forbidden.
  rejectedPeerMismatch,

  /// Manifest parameters (size, chunkSize, sha256, etc.) do not match sidecar; discarded.
  rejectedManifestMismatch,

  /// Sidecar exists without a matching authenticated session record; discarded.
  orphanDiscarded,
}

/// Detailed result of evaluating sidecar adoption for an individual file.
class FileAdoptionResult {
  const FileAdoptionResult({
    required this.fileItem,
    required this.status,
    this.store,
    this.adoptedRanges = const [],
    this.adoptedChunkCount = 0,
    this.adoptedBytes = 0,
    this.reason,
    this.expectedFingerprint,
    this.presentedFingerprint,
  });

  final FileItem fileItem;
  final AdoptionStatus status;
  final ResumeStore? store;
  final ChunkRanges adoptedRanges;
  final int adoptedChunkCount;
  final int adoptedBytes;
  final String? reason;
  final String? expectedFingerprint;
  final String? presentedFingerprint;

  bool get isAdopted => status == AdoptionStatus.adopted;
}

/// Comprehensive outcome of evaluating sidecar adoption across an entire session manifest.
class SessionAdoptionResult {
  const SessionAdoptionResult({
    required this.sessionId,
    required this.fileResults,
    required this.totalAdoptedBytes,
    required this.totalAdoptedChunks,
  });

  final String sessionId;
  final Map<String, FileAdoptionResult> fileResults;
  final int totalAdoptedBytes;
  final int totalAdoptedChunks;

  bool get hasAdoptedChunks => totalAdoptedChunks > 0;

  /// Returns wire-format acceptedFiles mapping for LSP-1 session acceptance:
  /// `{fileId: {'receivedRanges': [[0, 4]]}}`.
  Map<String, Map<String, Object?>> get acceptedFilesMap {
    final map = <String, Map<String, Object?>>{};
    for (final entry in fileResults.entries) {
      map[entry.key] = {'receivedRanges': entry.value.adoptedRanges};
    }
    return map;
  }
}

/// Helper that inspects on-disk sidecars, validates cryptographic ownership,
/// enforces 24h TTL, and adopts chunks across receiver restarts.
class ReceiverAdoptionHelper {
  ReceiverAdoptionHelper({
    required this.downloadDir,
    this.partialDir,
    required this.sessionStore,
    this.clock = const SystemClock(),
    this.maxAge = kResumeWindow,
    this.isSecure = true,
  });

  final Directory downloadDir;
  final Directory? partialDir;
  final SessionStore sessionStore;
  final Clock clock;
  final Duration maxAge;
  final bool isSecure;

  /// Resolves the in-progress `.lspart` file corresponding to [target].
  File partialFileFor(File target) {
    final dir = partialDir;
    if (dir == null) return File('${target.path}$kPartialSuffix');
    final rel = p.relative(
      target.path,
      from: p.normalize(downloadDir.absolute.path),
    );
    final h = sha256.convert(utf8.encode(rel)).toString().substring(0, 24);
    return File(p.join(dir.path, '$h$kPartialSuffix'));
  }

  /// Evaluates and performs sidecar adoption for all files in a [SessionRequest].
  Future<SessionAdoptionResult> adoptSession({
    required String sessionId,
    required SessionRequest request,
    required AuthenticatedPeer? peer,
  }) async {
    final fileResults = <String, FileAdoptionResult>{};
    var totalBytes = 0;
    var totalChunks = 0;

    // Load persisted prior sessions for peer verification
    final priorSessions = await sessionStore.listSessions(
      role: SessionRole.receiver,
    );

    for (final item in request.files) {
      final res = await adoptFile(
        item: item,
        chunkSize: request.chunkSize,
        peer: peer,
        priorSessions: priorSessions,
      );
      fileResults[item.fileId] = res;
      if (res.isAdopted) {
        totalBytes += res.adoptedBytes;
        totalChunks += res.adoptedChunkCount;
      }
    }

    // Persist new session record reflecting adopted files into SessionStore
    final sessionFiles = <SessionFileRecord>[];
    for (final item in request.files) {
      final res = fileResults[item.fileId]!;
      sessionFiles.add(
        SessionFileRecord(
          fileId: item.fileId,
          name: item.fileName,
          size: item.size,
          chunkSize: request.chunkSize,
          chunkCount: item.chunkCount,
          sha256: item.sha256,
          partialPath: res.store?.partialFile.path,
          receivedRanges: res.adoptedRanges,
          isComplete: res.store?.isComplete ?? false,
        ),
      );
    }

    final record = SessionRecord(
      sessionId: sessionId,
      role: SessionRole.receiver,
      peerDeviceId: peer?.deviceId ?? request.sender.deviceId,
      peerFingerprint: peer?.fingerprint ?? '',
      status: TransferStatus.inProgress,
      files: sessionFiles,
      totalSize: request.totalSize,
      createdAt: clock.now(),
      updatedAt: clock.now(),
    );

    await sessionStore.saveSession(record);

    return SessionAdoptionResult(
      sessionId: sessionId,
      fileResults: fileResults,
      totalAdoptedBytes: totalBytes,
      totalAdoptedChunks: totalChunks,
    );
  }

  /// Evaluates sidecar adoption for an individual [FileItem].
  Future<FileAdoptionResult> adoptFile({
    required FileItem item,
    required int chunkSize,
    required AuthenticatedPeer? peer,
    List<SessionRecord>? priorSessions,
  }) async {
    final target = resolveTarget(
      downloadDir: downloadDir,
      fileName: item.fileName,
      relativePath: item.relativePath,
      isReserved: (_) => false,
    );
    final partial = partialFileFor(target);
    final sidecar = ResumeStore.sidecarFor(partial);

    if (!sidecar.existsSync()) {
      // No sidecar exists. If an unmanaged partial file exists, it is not ours.
      return FileAdoptionResult(fileItem: item, status: AdoptionStatus.fresh);
    }

    // Step 1: Check 24-hour sidecar TTL expiration
    final sidecarMeta = _readSidecarMetadata(sidecar);
    if (sidecarMeta == null) {
      _deleteQuietly(sidecar);
      _deleteQuietly(partial);
      return FileAdoptionResult(
        fileItem: item,
        status: AdoptionStatus.fresh,
        reason: 'Unreadable or corrupt sidecar deleted',
      );
    }

    final sidecarAge = clock.now().difference(sidecarMeta.updatedAt);
    if (sidecarAge > maxAge) {
      _log.info(
        'Discarding expired sidecar for ${item.fileName} (age: ${sidecarAge.inHours}h)',
      );
      _deleteQuietly(sidecar);
      _deleteQuietly(partial);
      return FileAdoptionResult(
        fileItem: item,
        status: AdoptionStatus.expired,
        reason: 'Sidecar exceeded 24h TTL (${sidecarAge.inHours}h old)',
      );
    }

    // Step 2: Peer Authentication & Cryptographic Ownership Validation (D2/D3)
    if (isSecure) {
      if (peer == null || peer.fingerprint.trim().isEmpty) {
        _log.warning(
          'Refusing sidecar adoption for ${item.fileName}: peer is unauthenticated',
        );
        return FileAdoptionResult(
          fileItem: item,
          status: AdoptionStatus.rejectedUnauthenticated,
          reason: 'Cannot adopt partial download for unauthenticated peer',
        );
      }

      final sessions =
          priorSessions ??
          await sessionStore.listSessions(role: SessionRole.receiver);

      // Search prior sessions for ownership of this partial file
      final matchingRecord = _findSessionOwningFile(
        sessions,
        partial.path,
        item.fileName,
      );

      if (matchingRecord == null) {
        // Orphan sidecar without session record under secure profile: discard
        _log.warning(
          'Orphan sidecar found without SessionStore record for ${item.fileName}; discarding',
        );
        _deleteQuietly(sidecar);
        _deleteQuietly(partial);
        return FileAdoptionResult(
          fileItem: item,
          status: AdoptionStatus.orphanDiscarded,
          reason:
              'Sidecar has no cryptographic ownership record in SessionStore',
        );
      }

      final recordFp = matchingRecord.peerFingerprint.toUpperCase();
      final peerFp = peer.fingerprint.toUpperCase();

      if (recordFp != peerFp) {
        _log.severe(
          'Ownership mismatch on partial file ${item.fileName}: '
          'expected $recordFp, presented $peerFp',
        );
        return FileAdoptionResult(
          fileItem: item,
          status: AdoptionStatus.rejectedPeerMismatch,
          expectedFingerprint: recordFp,
          presentedFingerprint: peerFp,
          reason: 'Partial file belongs to a different authenticated peer',
        );
      }
    }

    // Step 3: Manifest Integrity Check
    if (item.size != sidecarMeta.size ||
        chunkSize != sidecarMeta.chunkSize ||
        item.chunkCount != sidecarMeta.chunkCount ||
        (item.sha256 != null &&
            sidecarMeta.sha256 != null &&
            item.sha256!.toLowerCase() != sidecarMeta.sha256!.toLowerCase()) ||
        (item.modified != null &&
            sidecarMeta.modified != null &&
            item.modified!.toUtc().toIso8601String() !=
                sidecarMeta.modified!.toUtc().toIso8601String())) {
      _log.warning(
        'Manifest mismatch for ${item.fileName}; resetting transfer',
      );
      _deleteQuietly(sidecar);
      _deleteQuietly(partial);
      return FileAdoptionResult(
        fileItem: item,
        status: AdoptionStatus.rejectedManifestMismatch,
        reason: 'Manifest parameters differ from persisted sidecar metadata',
      );
    }

    // Step 4: Open ResumeStore safely
    final store = await ResumeStore.open(
      partialFile: partial,
      size: item.size,
      chunkSize: chunkSize,
      chunkCount: item.chunkCount,
      sha256: item.sha256,
      modified: item.modified,
      clock: clock,
      maxAge: maxAge,
    );

    if (!store.resumed) {
      return FileAdoptionResult(
        fileItem: item,
        status: AdoptionStatus.fresh,
        store: store,
        reason: 'ResumeStore rejected inconsistent partial data',
      );
    }

    // Step 5: Successful Adoption
    final chunker = Chunker(chunkSize);
    var bytes = 0;
    for (final range in store.ranges) {
      for (var i = range[0]; i <= range[1]; i++) {
        final r = chunker.range(item.size, i);
        bytes += (r.end - r.start);
      }
    }

    _log.info(
      'Adopted ${store.receivedCount}/${item.chunkCount} chunks '
      '($bytes bytes) for ${item.fileName}',
    );

    return FileAdoptionResult(
      fileItem: item,
      status: AdoptionStatus.adopted,
      store: store,
      adoptedRanges: store.ranges,
      adoptedChunkCount: store.receivedCount,
      adoptedBytes: bytes,
    );
  }

  SessionRecord? _findSessionOwningFile(
    List<SessionRecord> sessions,
    String partialPath,
    String fileName,
  ) {
    final normalizedPartial = p.normalize(partialPath).toLowerCase();
    for (final session in sessions) {
      for (final file in session.files) {
        if (file.partialPath != null &&
            p.normalize(file.partialPath!).toLowerCase() == normalizedPartial) {
          return session;
        }
        if (file.name == fileName) {
          return session;
        }
      }
    }
    return null;
  }

  _SidecarMeta? _readSidecarMetadata(File sidecar) {
    try {
      final json =
          jsonDecode(sidecar.readAsStringSync()) as Map<String, Object?>;
      final size = json['size'] as int?;
      final chunkSize = json['chunkSize'] as int?;
      final chunkCount = json['chunkCount'] as int?;
      final updatedAt = DateTime.parse(json['updatedAt'] as String);
      final sha256 = json['sha256'] as String?;
      final modifiedStr = json['modified'] as String?;
      final modified = modifiedStr != null ? DateTime.parse(modifiedStr) : null;

      if (size == null || chunkSize == null || chunkCount == null) return null;

      return _SidecarMeta(
        size: size,
        chunkSize: chunkSize,
        chunkCount: chunkCount,
        updatedAt: updatedAt,
        sha256: sha256,
        modified: modified,
      );
    } catch (_) {
      return null;
    }
  }

  static void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Best effort deletion
    }
  }
}

class _SidecarMeta {
  const _SidecarMeta({
    required this.size,
    required this.chunkSize,
    required this.chunkCount,
    required this.updatedAt,
    this.sha256,
    this.modified,
  });

  final int size;
  final int chunkSize;
  final int chunkCount;
  final DateTime updatedAt;
  final String? sha256;
  final DateTime? modified;
}

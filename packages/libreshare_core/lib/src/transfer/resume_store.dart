/// Per-file chunk bitmap persisted next to the partial file (spec §4.4, §8).
///
/// `<name>.lspart` holds the bytes written so far, `<name>.lspart.json` (the
/// sidecar) records which chunks are complete. The sidecar is persisted every
/// [persistEvery] chunks, when the file becomes complete, and on [flush]. It
/// only ever claims chunks whose data was synced to disk first
/// ([beforePersist]), so after a crash every claimed chunk really is there.
/// On [open] a sidecar is accepted only if size, chunkSize, chunkCount, sha256
/// and modified match the manifest, the partial file is consistent with it and
/// it is younger than [kResumeWindow] (24 h); otherwise it is discarded.
library;

import 'dart:convert';
import 'dart:io';

import '../clock.dart';
import '../model/session_models.dart';
import 'chunker.dart';

/// Sessions are resumable for 24 hours (spec §4.4).
const Duration kResumeWindow = Duration(hours: 24);

/// Persist the bitmap every this many newly received chunks.
const int kResumePersistEvery = 8;

const int _kSidecarVersion = 1;

class ResumeStore {
  ResumeStore._({
    required this.partialFile,
    required this.size,
    required this.chunkSize,
    required this.chunkCount,
    required this.sha256,
    required this.modified,
    required this._clock,
    required this.persistEvery,
    required this.beforePersist,
    required this._received,
    required this.resumed,
    required this._createdAt,
  });

  /// Loads the sidecar for [partialFile] if it is valid for the given
  /// manifest values, otherwise starts fresh (deleting stale state we wrote).
  static Future<ResumeStore> open({
    required File partialFile,
    required int size,
    required int chunkSize,
    required int chunkCount,
    String? sha256,
    DateTime? modified,
    Clock clock = const SystemClock(),
    int persistEvery = kResumePersistEvery,
    Duration maxAge = kResumeWindow,
    Future<void> Function()? beforePersist,
  }) async {
    final sidecar = sidecarFor(partialFile);
    Set<int>? loaded;
    DateTime createdAt = clock.now();
    if (sidecar.existsSync()) {
      final r = _tryLoad(
        sidecar: sidecar,
        partialFile: partialFile,
        size: size,
        chunkSize: chunkSize,
        chunkCount: chunkCount,
        sha256: sha256,
        modified: modified,
        now: clock.now(),
        maxAge: maxAge,
      );
      if (r == null) {
        _deleteQuietly(sidecar);
        _deleteQuietly(partialFile);
      } else {
        loaded = r.received;
        createdAt = r.createdAt;
      }
    }
    final store = ResumeStore._(
      partialFile: partialFile,
      size: size,
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      sha256: sha256?.toLowerCase(),
      modified: modified,
      clock: clock,
      persistEvery: persistEvery < 1 ? 1 : persistEvery,
      beforePersist: beforePersist,
      received: loaded ?? <int>{},
      resumed: loaded != null,
      createdAt: createdAt,
    );
    // Sidecar first, data second: a partial file without sidecar is never ours.
    await store._persist();
    return store;
  }

  /// `<partial>.json`
  static File sidecarFor(File partialFile) => File('${partialFile.path}.json');

  /// Deletes expired `*.lspart` + `*.lspart.json` pairs under [dir]. Partial
  /// files without a sidecar are never touched. Returns the number removed.
  static Future<int> sweepExpired(
    Directory dir, {
    Clock clock = const SystemClock(),
    Duration maxAge = kResumeWindow,
    bool recursive = true,
  }) async {
    if (!dir.existsSync()) return 0;
    var removed = 0;
    await for (final e in dir.list(recursive: recursive, followLinks: false)) {
      if (e is! File || !e.path.endsWith('.lspart.json')) continue;
      try {
        final j = jsonDecode(await e.readAsString()) as Map<String, Object?>;
        final updated = DateTime.parse(j['updatedAt']! as String);
        if (clock.now().difference(updated) > maxAge) {
          _deleteQuietly(File(e.path.substring(0, e.path.length - 5)));
          _deleteQuietly(e);
          removed++;
        }
      } catch (_) {
        // unreadable sidecar: leave it alone
      }
    }
    return removed;
  }

  final File partialFile;
  final int size;
  final int chunkSize;
  final int chunkCount;
  final String? sha256;
  final DateTime? modified;
  final int persistEvery;

  /// Called (and awaited) right before the sidecar is written; the owner of
  /// the data file should fsync it here so the sidecar never over-claims.
  final Future<void> Function()? beforePersist;

  /// True if state was restored from a valid sidecar.
  final bool resumed;

  final Clock _clock;
  final Set<int> _received;
  final DateTime _createdAt;
  int _dirty = 0;
  Future<void> _queue = Future<void>.value();

  File get sidecarFile => sidecarFor(partialFile);
  int get receivedCount => _received.length;
  bool get isComplete => _received.length >= chunkCount;
  bool has(int index) => _received.contains(index);

  /// Inclusive ranges of received chunk indices (wire format).
  ChunkRanges get ranges => compactRanges(_received);

  /// Records that chunk [index] was fully written (call AFTER the data write).
  Future<void> markReceived(int index) async {
    if (index < 0 || index >= chunkCount) {
      throw RangeError.range(index, 0, chunkCount - 1, 'index');
    }
    if (!_received.add(index)) return;
    _dirty++;
    if (_dirty >= persistEvery || isComplete) {
      await _persist();
    }
  }

  /// Persists the bitmap now.
  Future<void> flush() => _persist();

  /// Removes the sidecar and, unless [deletePartial] is false, the partial file.
  Future<void> discard({bool deletePartial = true}) async {
    await _queue; // let a running persist finish first
    _deleteQuietly(sidecarFile);
    _deleteQuietly(File('${sidecarFile.path}.tmp'));
    if (deletePartial) _deleteQuietly(partialFile);
  }

  Future<void> _persist() {
    _dirty = 0;
    // Snapshot BEFORE the data sync: every chunk in the snapshot was written
    // before it was marked, hence before the sync below starts.
    final snapshot = ranges;
    final next = _queue.then((_) async {
      await beforePersist?.call();
      await _writeSidecar(snapshot);
    });
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _writeSidecar(ChunkRanges snapshot) async {
    final json = <String, Object?>{
      'version': _kSidecarVersion,
      'size': size,
      'chunkSize': chunkSize,
      'chunkCount': chunkCount,
      'sha256': sha256,
      'modified': modified?.toUtc().toIso8601String(),
      'createdAt': _createdAt.toUtc().toIso8601String(),
      'updatedAt': _clock.now().toUtc().toIso8601String(),
      'received': snapshot,
    };
    final target = sidecarFile;
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(target.path);
  }
}

class _Loaded {
  _Loaded(this.received, this.createdAt);
  final Set<int> received;
  final DateTime createdAt;
}

_Loaded? _tryLoad({
  required File sidecar,
  required File partialFile,
  required int size,
  required int chunkSize,
  required int chunkCount,
  required String? sha256,
  required DateTime? modified,
  required DateTime now,
  required Duration maxAge,
}) {
  try {
    final j = jsonDecode(sidecar.readAsStringSync()) as Map<String, Object?>;
    if (j['version'] != _kSidecarVersion) return null;
    if (j['size'] != size ||
        j['chunkSize'] != chunkSize ||
        j['chunkCount'] != chunkCount) {
      return null;
    }
    if ((j['sha256'] as String?)?.toLowerCase() != sha256?.toLowerCase()) {
      return null;
    }
    if ((j['modified'] as String?) != modified?.toUtc().toIso8601String()) {
      return null;
    }
    final updated = DateTime.parse(j['updatedAt']! as String);
    if (now.difference(updated) > maxAge) return null;
    final created = DateTime.parse(j['createdAt']! as String);

    final received = <int>{};
    for (final r in (j['received']! as List)) {
      final pair = (r as List).cast<int>();
      if (pair.length != 2 ||
          pair[0] < 0 ||
          pair[1] < pair[0] ||
          pair[1] >= chunkCount) {
        return null;
      }
      for (var i = pair[0]; i <= pair[1]; i++) {
        received.add(i);
      }
    }

    if (partialFile.existsSync()) {
      final len = partialFile.lengthSync();
      if (len > size) return null;
      if (received.isNotEmpty) {
        final maxIdx = received.reduce((a, b) => a > b ? a : b);
        if (len < Chunker(chunkSize).range(size, maxIdx).end) return null;
      }
    } else if (received.isNotEmpty) {
      return null;
    }
    return _Loaded(received, created);
  } catch (_) {
    return null;
  }
}

void _deleteQuietly(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } on FileSystemException {
    // best effort
  }
}

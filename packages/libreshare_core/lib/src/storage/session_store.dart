// ignore_for_file: depend_on_referenced_packages
/// Session storage subsystem for LibreShare (Increment 4, Decision D2).
///
/// Provides atomic persistence for [SessionRecord] metadata and chunk bitmap progress.
/// Ensures session continuity across receiver crashes/restarts without permitting
/// unauthenticated partial file adoption.
///
/// Security & Operational Invariants:
/// 1. POSIX Permissions: Mode 0600 on session files, mode 0700 on the storage directory.
/// 2. Atomic Writes: Writes to `<target>.tmp`, flushes, and atomically renames.
/// 3. Zero Secret Leaks: Validates no secret keys exist before writing.
/// 4. 24h TTL Eviction: Expired sessions are swept and deleted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';

/// Exception thrown when a session store operation fails.
class SessionStoreException implements Exception {
  const SessionStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'SessionStoreException: $message${cause != null ? " (cause: $cause)" : ""}';
}

/// Abstract interface for session persistence.
abstract interface class SessionStore {
  /// Initializes the store and ensures storage directories are ready.
  Future<void> init();

  /// Retrieves a session record by its [sessionId].
  ///
  /// Returns `null` if the session does not exist or has expired.
  Future<SessionRecord?> getSession(String sessionId);

  /// Saves or updates a session record atomically.
  ///
  /// Security: Throws [ArgumentError] if the record contains secret fields.
  Future<void> saveSession(SessionRecord record);

  /// Permanently removes a session record.
  Future<void> deleteSession(String sessionId);

  /// Lists all stored session records, optionally filtered by [role].
  Future<List<SessionRecord>> listSessions({SessionRole? role});

  /// Deletes session records older than [maxAge] (default: 24 hours).
  ///
  /// Returns the number of evicted session records.
  Future<int> sweepExpired({Duration maxAge = const Duration(hours: 24)});

  /// Closes the store and flushes any pending writes.
  Future<void> close();
}

Future<int> _defaultChmod(String mode, String path) async {
  if (Platform.isWindows) return 0;
  final r = await Process.run('chmod', [mode, path]);
  return r.exitCode;
}

/// File-backed implementation of [SessionStore] using atomic JSON files.
class FileSessionStore implements SessionStore {
  FileSessionStore(
    this.directory, {
    this._clock = const SystemClock(),
    ChmodRunner? chmodRunner,
  }) : _chmod = chmodRunner ?? _defaultChmod;

  /// Directory containing the `sessions/` JSON files.
  final Directory directory;

  final Clock _clock;
  final ChmodRunner _chmod;
  final Map<String, Future<void>> _locks = {};
  bool _closed = false;

  File _fileFor(String sessionId) =>
      File('${directory.path}${Platform.pathSeparator}$sessionId.json');

  void _checkOpen() {
    if (_closed) throw const SessionStoreException('SessionStore is closed');
  }

  @override
  Future<void> init() async {
    _checkOpen();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      await _chmod('0700', directory.path);
    }
  }

  @override
  Future<SessionRecord?> getSession(String sessionId) async {
    _checkOpen();
    final file = _fileFor(sessionId);
    if (!await file.exists()) return null;

    try {
      final text = await file.readAsString();
      final json = jsonDecode(text) as Map<String, Object?>;
      final record = SessionRecord.fromJson(json);

      // Check TTL
      if (record.isExpired(_clock.now())) {
        await deleteSession(sessionId);
        return null;
      }
      return record;
    } on FormatException {
      // Corrupt file - return null rather than crashing
      return null;
    } on Object catch (e) {
      throw SessionStoreException('Failed to read session $sessionId', e);
    }
  }

  @override
  Future<void> saveSession(SessionRecord record) async {
    _checkOpen();
    await init();

    // Serialize and enforce zero secret leaks
    final json = record.toJson();
    final payload = const JsonEncoder.withIndent('  ').convert(json);
    final target = _fileFor(record.sessionId);
    final tmp = File('${target.path}.tmp');

    // Synchronize writes to the same session file
    final prev = _locks[record.sessionId] ?? Future<void>.value();
    final completer = Completer<void>();
    _locks[record.sessionId] = completer.future;

    try {
      await prev;

      // Atomic write sequence:
      // 1. Write to .tmp file
      // 2. Chmod 0600 on tmp
      // 3. Flush to disk
      // 4. Rename over target
      await tmp.writeAsString(payload, flush: true);
      await _chmod('0600', tmp.path);
      await tmp.rename(target.path);
    } on Object catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      throw SessionStoreException(
        'Failed to save session ${record.sessionId}',
        e,
      );
    } finally {
      completer.complete();
      if (identical(_locks[record.sessionId], completer.future)) {
        unawaited(_locks.remove(record.sessionId));
      }
    }
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _checkOpen();
    final file = _fileFor(sessionId);
    final tmp = File('${file.path}.tmp');
    try {
      if (await file.exists()) await file.delete();
      if (await tmp.exists()) await tmp.delete();
    } on Object catch (e) {
      throw SessionStoreException('Failed to delete session $sessionId', e);
    }
  }

  @override
  Future<List<SessionRecord>> listSessions({SessionRole? role}) async {
    _checkOpen();
    if (!await directory.exists()) return [];

    final records = <SessionRecord>[];
    final now = _clock.now();

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final text = await entity.readAsString();
        final json = jsonDecode(text) as Map<String, Object?>;
        final record = SessionRecord.fromJson(json);

        if (record.isExpired(now)) {
          try {
            await entity.delete();
          } catch (_) {}
          continue;
        }

        if (role == null || record.role == role) {
          records.add(record);
        }
      } catch (_) {
        // Skip invalid/unreadable session files
      }
    }
    return records;
  }

  @override
  Future<int> sweepExpired({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    _checkOpen();
    if (!await directory.exists()) return 0;

    var evicted = 0;
    final now = _clock.now();

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;

      // Clean up orphaned .tmp files older than 1 hour
      if (entity.path.endsWith('.json.tmp')) {
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > const Duration(hours: 1)) {
            await entity.delete();
          }
        } catch (_) {}
        continue;
      }

      if (!entity.path.endsWith('.json')) continue;

      try {
        final text = await entity.readAsString();
        final json = jsonDecode(text) as Map<String, Object?>;
        final record = SessionRecord.fromJson(json);

        if (record.isExpired(now, maxAge: maxAge)) {
          await entity.delete();
          evicted++;
        }
      } catch (_) {
        // Corrupt file or unparseable JSON: if modified > maxAge, remove it
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > maxAge) {
            await entity.delete();
            evicted++;
          }
        } catch (_) {}
      }
    }
    return evicted;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _locks.clear();
  }
}

/// In-memory implementation of [SessionStore] for testing.
class InMemorySessionStore implements SessionStore {
  InMemorySessionStore({this._clock = const SystemClock()});

  final Clock _clock;
  final Map<String, SessionRecord> _sessions = {};
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw const SessionStoreException('SessionStore is closed');
  }

  @override
  Future<void> init() async {
    _checkOpen();
  }

  @override
  Future<SessionRecord?> getSession(String sessionId) async {
    _checkOpen();
    final record = _sessions[sessionId];
    if (record == null) return null;
    if (record.isExpired(_clock.now())) {
      _sessions.remove(sessionId);
      return null;
    }
    return record;
  }

  @override
  Future<void> saveSession(SessionRecord record) async {
    _checkOpen();
    // Validate no secret leaks
    record.toJson();
    _sessions[record.sessionId] = record;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _checkOpen();
    _sessions.remove(sessionId);
  }

  @override
  Future<List<SessionRecord>> listSessions({SessionRole? role}) async {
    _checkOpen();
    final now = _clock.now();
    final expired = <String>[];
    final result = <SessionRecord>[];

    for (final entry in _sessions.entries) {
      if (entry.value.isExpired(now)) {
        expired.add(entry.key);
      } else if (role == null || entry.value.role == role) {
        result.add(entry.value);
      }
    }
    for (final key in expired) {
      _sessions.remove(key);
    }
    return result;
  }

  @override
  Future<int> sweepExpired({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    _checkOpen();
    final now = _clock.now();
    final expired = _sessions.entries
        .where((e) => e.value.isExpired(now, maxAge: maxAge))
        .map((e) => e.key)
        .toList();

    for (final key in expired) {
      _sessions.remove(key);
    }
    return expired.length;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _sessions.clear();
  }
}

// ignore_for_file: depend_on_referenced_packages
/// Structured persistent event logging subsystem for LibreShare (Increment 4, Task P4-3).
///
/// Provides in-memory ring buffer buffering coupled with atomic disk persistence
/// (using single or daily-partitioned JSONL files).
///
/// Security & Operational Invariants:
/// 1. ZERO SECRET LEAKS: Validates every event for forbidden keys or secret patterns.
/// 2. POSIX PERMISSIONS: Storage directory 0700, event log files 0600.
/// 3. ATOMIC DISK PERSISTENCE: Flushed appends and atomic `.tmp` rewrites on prune/compaction.
/// 4. 24H TTL PRUNING: Historical events beyond retention window are pruned from memory and disk.
/// 5. CRASH RECOVERY: Corrupt trailing lines and orphaned `.tmp` files are cleaned up on `init()`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';

/// Exception thrown when an event log operation fails.
class EventLogException implements Exception {
  const EventLogException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'EventLogException: $message${cause != null ? " (cause: $cause)" : ""}';
}

/// A fixed-capacity in-memory ring buffer evicting oldest entries on overflow (FIFO).
class RingBuffer<T> {
  RingBuffer(this.capacity)
    : assert(capacity > 0, 'capacity must be greater than zero');

  final int capacity;
  final ListQueue<T> _queue = ListQueue<T>();

  /// Adds [item] to the end of the buffer, evicting the oldest item if at capacity.
  void add(T item) {
    if (_queue.length >= capacity) {
      _queue.removeFirst();
    }
    _queue.addLast(item);
  }

  /// Current number of items in the buffer.
  int get length => _queue.length;

  /// Whether the buffer is empty.
  bool get isEmpty => _queue.isEmpty;

  /// Whether the buffer contains items.
  bool get isNotEmpty => _queue.isNotEmpty;

  /// Returns an unmodifiable snapshot of the buffered items in insertion order.
  List<T> toList() => List.unmodifiable(_queue);

  /// Iterable view of the current items.
  Iterable<T> get items => _queue;

  /// Removes all items from the ring buffer.
  void clear() => _queue.clear();

  /// Removes items satisfying [test].
  void removeWhere(bool Function(T) test) {
    _queue.removeWhere(test);
  }
}

/// Abstract interface for the LibreShare structured event log.
abstract interface class EventLog {
  /// Initializes storage directories and runs crash recovery.
  Future<void> init();

  /// Records an [event] into the in-memory ring buffer and persistent storage.
  ///
  /// Throws [ArgumentError] if the event violates the zero secret leak invariant.
  Future<void> log(EventRecord event);

  /// Queries events matching specified filters.
  ///
  /// Filters:
  /// - [since]: inclusive lower bound on event timestamp
  /// - [until]: inclusive upper bound on event timestamp
  /// - [type]: exact event type string
  /// - [level]: event severity level
  /// - [sessionId]: transfer session identifier
  /// - [limit]: maximum number of records to return
  /// - [descending]: when true, latest records first; default is false (oldest first)
  Future<List<EventRecord>> query({
    DateTime? since,
    DateTime? until,
    String? type,
    EventLevel? level,
    String? sessionId,
    int? limit,
    bool descending = false,
  });

  /// Prunes events older than [ttl] from both memory and disk storage.
  ///
  /// Returns the total number of pruned event records.
  Future<int> prune(Duration ttl);

  /// Current number of events in the in-memory ring buffer.
  int get inMemoryCount;

  /// Snapshot of events currently held in the in-memory ring buffer.
  List<EventRecord> get recentEvents;

  /// Broadcast stream of events logged through this instance.
  Stream<EventRecord> get events;

  /// Flushes any pending writes to disk.
  Future<void> flush();

  /// Current clock used for timestamping and pruning.
  Clock get clock;

  /// Closes the event log and releases file locks.
  Future<void> close();

  /// Helper: logs a session lifecycle transition from a [SessionRecord].
  Future<void> logSession(
    SessionRecord session, {
    required String message,
    String? type,
    EventLevel? level,
    Map<String, Object?> extraData = const {},
  });

  /// Helper: logs a connection ladder or candidate event from a [ChannelEvent].
  Future<void> logChannel(ChannelEvent channelEvent, {String? sessionId});

  /// Helper: logs a diagnostic error.
  Future<void> logError(
    String message, {
    String? type,
    String? sessionId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  });
}

Future<int> _defaultChmod(String mode, String path) async {
  if (Platform.isWindows) return 0;
  final r = await Process.run('chmod', [mode, path]);
  return r.exitCode;
}

/// File-backed persistent implementation of [EventLog].
///
/// Features:
/// - In-memory ring buffer of configurable [capacity]
/// - JSONL persistence with optional daily partitioning (`events_YYYY-MM-DD.jsonl`)
/// - Directory permission 0700, file permission 0600
/// - Mutex-serialized atomic disk writes and atomic temp-file pruning
/// - Graceful crash recovery handling truncated trailing lines and orphaned `.tmp` files.
class FileEventLog implements EventLog {
  FileEventLog(
    this.directory, {
    this.capacity = 1000,
    this.partitionByDay = true,
    this._clock = const SystemClock(),
    ChmodRunner? chmodRunner,
  }) : _chmod = chmodRunner ?? _defaultChmod,
       _ringBuffer = RingBuffer<EventRecord>(capacity);

  /// Directory holding the event log files.
  final Directory directory;

  /// Capacity of the in-memory ring buffer.
  final int capacity;

  /// If true, creates files partitioned by date (`events_YYYY-MM-DD.jsonl`).
  /// If false, uses a single file (`events.jsonl`).
  final bool partitionByDay;

  final Clock _clock;
  final ChmodRunner _chmod;
  final RingBuffer<EventRecord> _ringBuffer;
  final StreamController<EventRecord> _controller =
      StreamController<EventRecord>.broadcast();

  Future<void> _lock = Future<void>.value();
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw const EventLogException('EventLog is closed');
  }

  Future<T> _synchronized<T>(Future<T> Function() action) async {
    _checkOpen();
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    try {
      await prev;
      return await action();
    } finally {
      completer.complete();
    }
  }

  String _formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  File _targetFileFor(DateTime timestamp) {
    if (partitionByDay) {
      final dateStr = _formatDate(timestamp);
      return File(
        '${directory.path}${Platform.pathSeparator}events_$dateStr.jsonl',
      );
    }
    return File('${directory.path}${Platform.pathSeparator}events.jsonl');
  }

  Future<List<File>> _getEventFiles() async {
    if (!await directory.exists()) return [];
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          entity.path.endsWith('.jsonl') &&
          !entity.path.endsWith('.tmp')) {
        files.add(entity);
      }
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<List<String>> _readValidLines(File file) async {
    if (!await file.exists()) return [];
    try {
      final text = await file.readAsString();
      final lines = const LineSplitter().convert(text);
      return lines.where((l) => l.trim().isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  @override
  int get inMemoryCount => _ringBuffer.length;

  @override
  List<EventRecord> get recentEvents => _ringBuffer.toList();

  bool _initialized = false;

  @override
  Clock get clock => _clock;

  @override
  Stream<EventRecord> get events => _controller.stream;

  @override
  Future<void> init() async {
    _checkOpen();
    if (_initialized) return;
    if (!await directory.exists()) {
      await directory.create(recursive: true);
      await _chmod('0700', directory.path);
    }
    await _synchronized(() async {
      if (_initialized) return;
      await _recoverFromCrash();
      _initialized = true;
    });
  }

  /// Scans event files, discards dangling .tmp files and repairs corrupt trailing lines.
  Future<void> _recoverFromCrash() async {
    // 1. Delete orphaned .tmp files
    if (await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.tmp')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }

    // 2. Validate and clean existing event files
    final files = await _getEventFiles();
    final recoveredRecords = <EventRecord>[];

    for (final file in files) {
      final lines = await _readValidLines(file);
      final validLines = <String>[];
      var hasCorruptLine = false;

      for (final line in lines) {
        try {
          final record = EventRecord.fromJsonLine(line);
          validLines.add(line);
          recoveredRecords.add(record);
        } catch (_) {
          // Truncated or malformed JSON from an un-flushed write / crash
          hasCorruptLine = true;
        }
      }

      if (hasCorruptLine) {
        // Rewrite file atomically with valid lines only
        final tmp = File('${file.path}.tmp');
        final sink = tmp.openWrite();
        for (final validLine in validLines) {
          sink.writeln(validLine);
        }
        await sink.flush();
        await sink.close();
        await _chmod('0600', tmp.path);
        await tmp.rename(file.path);
      }
    }

    // Populate in-memory ring buffer with most recent events
    recoveredRecords.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _ringBuffer.clear();
    final start = recoveredRecords.length > capacity
        ? recoveredRecords.length - capacity
        : 0;
    for (var i = start; i < recoveredRecords.length; i++) {
      _ringBuffer.add(recoveredRecords[i]);
    }
  }

  @override
  Future<void> log(EventRecord event) async {
    _checkOpen();
    // Validate zero secret leak invariant (throws ArgumentError on violation)
    event.toJson();

    await init();

    // Add to in-memory ring buffer
    _ringBuffer.add(event);

    // Broadcast on stream
    if (!_controller.isClosed) {
      _controller.add(event);
    }

    // Atomic append to file
    await _synchronized(() async {
      final target = _targetFileFor(event.timestamp);
      final exists = await target.exists();
      if (!exists) {
        await target.create(recursive: true);
        await _chmod('0600', target.path);
      }

      final line = '${event.toJsonLine()}\n';
      final raf = await target.open(mode: FileMode.append);
      try {
        await raf.writeString(line);
        await raf.flush();
      } finally {
        await raf.close();
      }
    });
  }

  bool _matchesQuery(
    EventRecord event, {
    DateTime? since,
    DateTime? until,
    String? type,
    EventLevel? level,
    String? sessionId,
  }) {
    if (since != null && event.timestamp.isBefore(since)) return false;
    if (until != null && event.timestamp.isAfter(until)) return false;
    if (type != null && event.type != type) return false;
    if (level != null && event.level != level) return false;
    if (sessionId != null && event.sessionId != sessionId) return false;
    return true;
  }

  @override
  Future<List<EventRecord>> query({
    DateTime? since,
    DateTime? until,
    String? type,
    EventLevel? level,
    String? sessionId,
    int? limit,
    bool descending = false,
  }) async {
    _checkOpen();
    return _synchronized(() async {
      final results = <EventRecord>[];
      final seenIds = <String>{};

      // Read records from disk
      final files = await _getEventFiles();
      for (final file in files) {
        final lines = await _readValidLines(file);
        for (final line in lines) {
          try {
            final record = EventRecord.fromJsonLine(line);
            if (_matchesQuery(
              record,
              since: since,
              until: until,
              type: type,
              level: level,
              sessionId: sessionId,
            )) {
              if (seenIds.add(record.id)) {
                results.add(record);
              }
            }
          } catch (_) {}
        }
      }

      // Merge in-memory events if any were buffered
      for (final record in _ringBuffer.items) {
        if (_matchesQuery(
          record,
          since: since,
          until: until,
          type: type,
          level: level,
          sessionId: sessionId,
        )) {
          if (seenIds.add(record.id)) {
            results.add(record);
          }
        }
      }

      // Sort
      results.sort((a, b) {
        final cmp = a.timestamp.compareTo(b.timestamp);
        return cmp != 0 ? cmp : a.id.compareTo(b.id);
      });

      if (descending) {
        results.sort((a, b) {
          final cmp = b.timestamp.compareTo(a.timestamp);
          return cmp != 0 ? cmp : b.id.compareTo(a.id);
        });
      }

      if (limit != null && limit > 0 && results.length > limit) {
        return results.take(limit).toList();
      }
      return results;
    });
  }

  @override
  Future<int> prune(Duration ttl) async {
    _checkOpen();
    return _synchronized(() async {
      final cutoff = _clock.now().subtract(ttl);
      var prunedCount = 0;

      // 1. Prune ring buffer
      _ringBuffer.removeWhere((e) => e.timestamp.isBefore(cutoff));

      // 2. Remove orphaned .tmp files
      if (await directory.exists()) {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.tmp')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }

      // 3. Prune files
      final files = await _getEventFiles();
      for (final file in files) {
        final lines = await _readValidLines(file);
        final keptLines = <String>[];
        var filePruned = 0;

        for (final line in lines) {
          try {
            final record = EventRecord.fromJsonLine(line);
            if (record.timestamp.isBefore(cutoff)) {
              filePruned++;
            } else {
              keptLines.add(line);
            }
          } catch (_) {
            filePruned++;
          }
        }

        if (filePruned > 0) {
          prunedCount += filePruned;
          if (keptLines.isEmpty) {
            try {
              await file.delete();
            } catch (_) {}
          } else {
            // Atomic rewrite
            final tmp = File('${file.path}.tmp');
            final sink = tmp.openWrite();
            for (final line in keptLines) {
              sink.writeln(line);
            }
            await sink.flush();
            await sink.close();
            await _chmod('0600', tmp.path);
            await tmp.rename(file.path);
          }
        }
      }

      return prunedCount;
    });
  }

  @override
  Future<void> flush() async {
    _checkOpen();
    // In FileEventLog, each log() call flushes raf immediately.
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  @override
  Future<void> logSession(
    SessionRecord session, {
    required String message,
    String? type,
    EventLevel? level,
    Map<String, Object?> extraData = const {},
  }) {
    return log(
      EventRecord.fromSession(
        session,
        message: message,
        type: type,
        level: level,
        data: extraData,
      ),
    );
  }

  @override
  Future<void> logChannel(ChannelEvent channelEvent, {String? sessionId}) {
    return log(
      EventRecord.fromChannelEvent(channelEvent, sessionId: sessionId),
    );
  }

  @override
  Future<void> logError(
    String message, {
    String? type,
    String? sessionId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) {
    return log(
      EventRecord.error(
        message,
        type: type,
        sessionId: sessionId,
        error: error,
        stackTrace: stackTrace,
        data: data,
      ),
    );
  }
}

/// In-memory implementation of [EventLog] for lightweight testing and ephemeral engines.
class InMemoryEventLog implements EventLog {
  InMemoryEventLog({this.capacity = 1000, this._clock = const SystemClock()})
    : _ringBuffer = RingBuffer<EventRecord>(capacity);

  final int capacity;
  final Clock _clock;
  final RingBuffer<EventRecord> _ringBuffer;
  final StreamController<EventRecord> _controller =
      StreamController<EventRecord>.broadcast();
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw const EventLogException('InMemoryEventLog is closed');
  }

  @override
  int get inMemoryCount => _ringBuffer.length;

  @override
  List<EventRecord> get recentEvents => _ringBuffer.toList();

  @override
  Clock get clock => _clock;

  @override
  Stream<EventRecord> get events => _controller.stream;

  @override
  Future<void> init() async {
    _checkOpen();
  }

  @override
  Future<void> log(EventRecord event) async {
    _checkOpen();
    // Validate zero secret leaks
    event.toJson();

    _ringBuffer.add(event);
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  bool _matchesQuery(
    EventRecord event, {
    DateTime? since,
    DateTime? until,
    String? type,
    EventLevel? level,
    String? sessionId,
  }) {
    if (since != null && event.timestamp.isBefore(since)) return false;
    if (until != null && event.timestamp.isAfter(until)) return false;
    if (type != null && event.type != type) return false;
    if (level != null && event.level != level) return false;
    if (sessionId != null && event.sessionId != sessionId) return false;
    return true;
  }

  @override
  Future<List<EventRecord>> query({
    DateTime? since,
    DateTime? until,
    String? type,
    EventLevel? level,
    String? sessionId,
    int? limit,
    bool descending = false,
  }) async {
    _checkOpen();
    final matching = _ringBuffer.items
        .where(
          (e) => _matchesQuery(
            e,
            since: since,
            until: until,
            type: type,
            level: level,
            sessionId: sessionId,
          ),
        )
        .toList();

    matching.sort((a, b) {
      final cmp = a.timestamp.compareTo(b.timestamp);
      return cmp != 0 ? cmp : a.id.compareTo(b.id);
    });

    if (descending) {
      matching.sort((a, b) {
        final cmp = b.timestamp.compareTo(a.timestamp);
        return cmp != 0 ? cmp : b.id.compareTo(a.id);
      });
    }

    if (limit != null && limit > 0 && matching.length > limit) {
      return matching.take(limit).toList();
    }
    return matching;
  }

  @override
  Future<int> prune(Duration ttl) async {
    _checkOpen();
    final cutoff = _clock.now().subtract(ttl);
    var count = 0;
    _ringBuffer.removeWhere((e) {
      if (e.timestamp.isBefore(cutoff)) {
        count++;
        return true;
      }
      return false;
    });
    return count;
  }

  @override
  Future<void> flush() async {
    _checkOpen();
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (!_controller.isClosed) {
      await _controller.close();
    }
    _ringBuffer.clear();
  }

  @override
  Future<void> logSession(
    SessionRecord session, {
    required String message,
    String? type,
    EventLevel? level,
    Map<String, Object?> extraData = const {},
  }) {
    return log(
      EventRecord.fromSession(
        session,
        message: message,
        type: type,
        level: level,
        data: extraData,
      ),
    );
  }

  @override
  Future<void> logChannel(ChannelEvent channelEvent, {String? sessionId}) {
    return log(
      EventRecord.fromChannelEvent(channelEvent, sessionId: sessionId),
    );
  }

  @override
  Future<void> logError(
    String message, {
    String? type,
    String? sessionId,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> data = const {},
  }) {
    return log(
      EventRecord.error(
        message,
        type: type,
        sessionId: sessionId,
        error: error,
        stackTrace: stackTrace,
        data: data,
      ),
    );
  }
}

/// A decorating [SessionStore] that records lifecycle events into an [EventLog]
/// on session creation, progress updates, failure, deletion, and TTL sweep.
class EventLoggingSessionStore implements SessionStore {
  EventLoggingSessionStore(this._inner, this._eventLog);

  final SessionStore _inner;
  final EventLog _eventLog;

  SessionStore get inner => _inner;
  EventLog get eventLog => _eventLog;

  @override
  Future<void> init() async {
    await _inner.init();
    await _eventLog.init();
  }

  @override
  Future<SessionRecord?> getSession(String sessionId) =>
      _inner.getSession(sessionId);

  @override
  Future<void> saveSession(SessionRecord record) async {
    await _inner.saveSession(record);

    String message;
    EventLevel level = EventLevel.info;
    if (record.status == TransferStatus.completed) {
      message = 'Session ${record.sessionId} completed successfully';
    } else if (record.status == TransferStatus.failed) {
      message =
          'Session ${record.sessionId} failed: ${record.failureReason?.wire ?? "unknown"}';
      level = EventLevel.error;
    } else {
      message =
          'Session ${record.sessionId} saved (${record.status.wire}, role: ${record.role.wire})';
    }

    await _eventLog.log(
      EventRecord.fromSession(record, message: message, level: level),
    );
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await _inner.deleteSession(sessionId);
    await _eventLog.log(
      EventRecord.create(
        type: 'session_deleted',
        sessionId: sessionId,
        timestamp: _eventLog.clock.now(),
        message: 'Session $sessionId deleted from store',
      ),
    );
  }

  @override
  Future<List<SessionRecord>> listSessions({SessionRole? role}) =>
      _inner.listSessions(role: role);

  @override
  Future<int> sweepExpired({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final evicted = await _inner.sweepExpired(maxAge: maxAge);
    if (evicted > 0) {
      await _eventLog.log(
        EventRecord.create(
          type: 'session_swept',
          message:
              'Swept $evicted expired sessions older than ${maxAge.inHours}h',
          data: {'evictedCount': evicted, 'maxAgeHours': maxAge.inHours},
        ),
      );
    }
    return evicted;
  }

  @override
  Future<void> close() async {
    await _inner.close();
    await _eventLog.close();
  }
}

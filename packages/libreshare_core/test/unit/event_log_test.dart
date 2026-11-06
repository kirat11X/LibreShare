// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart' hide shortFingerprint;
import 'package:libreshare_core/src/monitor/event_record.dart';
import 'package:test/test.dart';

class FakeClock implements Clock {
  FakeClock(this.current);
  DateTime current;

  @override
  DateTime now() => current;

  void advance(Duration duration) {
    current = current.add(duration);
  }
}

void main() {
  group('EventRecord & Security Invariants', () {
    test('constructs valid event and serializes to/from JSON and JSONL', () {
      final now = DateTime.utc(2026, 11, 6, 12, 0, 0);
      final event = EventRecord.create(
        id: 'evt-test-1',
        timestamp: now,
        type: 'test_event',
        level: EventLevel.info,
        sessionId: 'session-42',
        message: 'Normal test message',
        data: {'key1': 'value1', 'count': 5},
      );

      final json = event.toJson();
      expect(json['id'], 'evt-test-1');
      expect(json['timestamp'], '2026-11-06T12:00:00.000Z');
      expect(json['type'], 'test_event');
      expect(json['level'], 'info');
      expect(json['sessionId'], 'session-42');
      expect(json['message'], 'Normal test message');
      expect((json['data'] as Map)['count'], 5);

      final line = event.toJsonLine();
      final restored = EventRecord.fromJsonLine(line);
      expect(restored, equals(event));
      expect(restored.data['key1'], 'value1');
    });

    test('truncates peer fingerprint to 16 hex characters', () {
      const fullFp =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      final short = shortFingerprint(fullFp);
      expect(short.length, 16);
      expect(short, 'e3b0c44298fc1c14');
    });

    test('allows safe 64-character SHA-256 digests in data', () {
      const digest =
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
      expect(
        () => EventRecord.create(
          type: 'digest_test',
          message: 'Hashed file',
          data: {'sha256': digest},
        ),
        returnsNormally,
      );
    });

    group('Security Violations (Zero Secret Leaks)', () {
      test('rejects forbidden keys in data map', () {
        for (final key in kForbiddenSecretKeys) {
          expect(
            () => EventRecord.create(
              type: 'leak_attempt',
              message: 'Attempting leak',
              data: {key: 'secret-val'},
            ),
            throwsA(isA<ArgumentError>()),
            reason: 'Should reject forbidden key: $key',
          );
        }
      });

      test('rejects forbidden key embedded in nested map', () {
        expect(
          () => EventRecord.create(
            type: 'leak_attempt',
            message: 'Nested leak',
            data: {
              'meta': {'nested_pin': '123456'},
            },
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('rejects PEM private key in message or data', () {
        const pem = '-----BEGIN EC PRIVATE KEY-----\nMIGqAgEB\n-----END...';
        expect(
          () => EventRecord.create(
            type: 'leak_attempt',
            message: 'Leaking key: $pem',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => EventRecord.create(
            type: 'leak_attempt',
            message: 'Safe message',
            data: {'details': pem},
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('rejects PIN assignment patterns in message', () {
        expect(
          () => EventRecord.create(
            type: 'leak_attempt',
            message: 'User entered pin=123456',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(
          () => EventRecord.create(
            type: 'leak_attempt',
            message: 'Comparison code: 482913',
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('rejects Bearer tokens in message or data', () {
        expect(
          () => EventRecord.create(
            type: 'leak_attempt',
            message: 'Header was Bearer ya29.a0AfH6SMCx1234567890abcdef',
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('rejects long opaque secret candidates (> 96 chars)', () {
        final longOpaque = 'A' * 100;
        expect(
          () => EventRecord.create(
            type: 'leak_attempt',
            message: 'Normal message',
            data: {'raw': longOpaque},
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('ChannelEvent Adapters', () {
      final candidate = Candidate.create(
        id: 'cand-wifi-1',
        kind: CandidateKind.wifi,
        host: '192.168.1.50',
        port: 52000,
        peerFingerprint:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        costHint: 10,
      );

      test('fromChannelEvent(ChannelActive)', () {
        final event = ChannelActive(
          candidate: candidate,
          sessionId: 'ses-1',
          rtt: const Duration(milliseconds: 14),
          timestamp: DateTime.utc(2026, 11, 6, 12, 0, 0),
        );

        final record = EventRecord.fromChannelEvent(event);
        expect(record.type, 'channel_active');
        expect(record.level, EventLevel.info);
        expect(record.sessionId, 'ses-1');
        expect(record.data['candidateId'], 'cand-wifi-1');
        expect(record.data['kind'], 'wifi');
        expect(record.data['rttMs'], 14);
        expect(record.data['peerFingerprint'], 'e3b0c44298fc1c14');
        expect(record.message, contains('Channel active: wifi'));
      });

      test('fromChannelEvent(ChannelFailed)', () {
        final event = ChannelFailed(
          candidate: candidate,
          sessionId: 'ses-1',
          reason: 'socket_reset',
          consecutiveFailures: 3,
          timestamp: DateTime.utc(2026, 11, 6, 12, 0, 1),
        );

        final record = EventRecord.fromChannelEvent(event);
        expect(record.type, 'channel_failed');
        expect(record.level, EventLevel.warning);
        expect(record.data['reason'], 'socket_reset');
        expect(record.data['consecutiveFailures'], 3);
        expect(record.message, contains('Channel failed on wifi'));
      });

      test('fromChannelEvent(ChannelTierSwitched)', () {
        final lanCandidate = Candidate.create(
          id: 'cand-lan-1',
          kind: CandidateKind.lan,
          host: '10.0.0.2',
          port: 52000,
          peerFingerprint: candidate.peerFingerprint,
          costHint: 20,
        );

        final event = ChannelTierSwitched(
          sessionId: 'ses-1',
          fromCandidate: candidate,
          toCandidate: lanCandidate,
          reason: 'consecutive_chunk_failures',
          timestamp: DateTime.utc(2026, 11, 6, 12, 0, 2),
        );

        final record = EventRecord.fromChannelEvent(event);
        expect(record.type, 'channel_tier_switched');
        expect(record.level, EventLevel.info);
        expect(record.data['fromKind'], 'wifi');
        expect(record.data['toKind'], 'lan');
        expect(record.data['reason'], 'consecutive_chunk_failures');
      });

      test('fromChannelEvent(ChannelCandidateTested)', () {
        final event = ChannelCandidateTested(
          candidate: candidate,
          success: true,
          rtt: const Duration(milliseconds: 8),
          timestamp: DateTime.utc(2026, 11, 6, 12, 0, 3),
        );

        final record = EventRecord.fromChannelEvent(event);
        expect(record.type, 'channel_candidate_tested');
        expect(record.level, EventLevel.debug);
        expect(record.data['success'], true);
        expect(record.data['rttMs'], 8);
      });
    });
  });

  group('EventLog (FileEventLog & InMemoryEventLog)', () {
    late Directory tempDir;
    late FakeClock fakeClock;
    final List<String> chmodLog = [];

    Future<int> mockChmod(String mode, String path) async {
      chmodLog.add('$mode:$path');
      return 0;
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'libreshare_event_log_test_',
      );
      fakeClock = FakeClock(DateTime.utc(2026, 11, 6, 12, 0, 0));
      chmodLog.clear();
    });

    tearDown(() async {
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    EventRecord createSampleEvent({
      String id = 'evt-1',
      String type = 'channel_active',
      EventLevel level = EventLevel.info,
      String? sessionId = 'session-100',
      String message = 'Active channel test',
      DateTime? timestamp,
      Map<String, Object?> data = const {},
    }) {
      return EventRecord.create(
        id: id,
        type: type,
        level: level,
        sessionId: sessionId,
        message: message,
        timestamp: timestamp ?? fakeClock.now(),
        data: data,
      );
    }

    test('FileEventLog sets directory mode 0700 and file mode 0600', () async {
      final logDir = Directory('${tempDir.path}/events');
      final log = FileEventLog(
        logDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
        partitionByDay: false,
      );

      await log.init();
      expect(await logDir.exists(), isTrue);
      expect(chmodLog, contains('0700:${logDir.path}'));

      final event = createSampleEvent();
      await log.log(event);

      final targetFile = File('${logDir.path}/events.jsonl');
      expect(await targetFile.exists(), isTrue);
      expect(chmodLog, contains('0600:${targetFile.path}'));
      await log.close();
    });

    test('Event emission and broadcast stream', () async {
      final logDir = Directory('${tempDir.path}/events');
      final log = FileEventLog(
        logDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      await log.init();
      final emitted = <EventRecord>[];
      final subscription = log.events.listen(emitted.add);

      final e1 = createSampleEvent(id: 'e1', message: 'First event');
      final e2 = createSampleEvent(id: 'e2', message: 'Second event');

      await log.log(e1);
      await log.log(e2);

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(emitted.length, 2);
      expect(emitted[0].id, 'e1');
      expect(emitted[1].id, 'e2');

      await subscription.cancel();
      await log.close();
    });

    test(
      'Querying with filters (since, until, type, level, limit, descending)',
      () async {
        final logDir = Directory('${tempDir.path}/events');
        final log = FileEventLog(
          logDir,
          clock: fakeClock,
          chmodRunner: mockChmod,
        );

        final t0 = fakeClock.now();
        final t1 = t0.add(const Duration(minutes: 5));
        final t2 = t0.add(const Duration(minutes: 10));

        await log.log(
          createSampleEvent(
            id: 'e1',
            type: 'type_a',
            level: EventLevel.info,
            sessionId: 'ses-1',
            timestamp: t0,
          ),
        );
        await log.log(
          createSampleEvent(
            id: 'e2',
            type: 'type_b',
            level: EventLevel.warning,
            sessionId: 'ses-1',
            timestamp: t1,
          ),
        );
        await log.log(
          createSampleEvent(
            id: 'e3',
            type: 'type_a',
            level: EventLevel.error,
            sessionId: 'ses-2',
            timestamp: t2,
          ),
        );

        // Unfiltered query returns all 3 in chronological order
        final all = await log.query();
        expect(all.length, 3);
        expect(all.map((e) => e.id), ['e1', 'e2', 'e3']);

        // Filter by since
        final sinceT1 = await log.query(since: t1);
        expect(sinceT1.map((e) => e.id), ['e2', 'e3']);

        // Filter by until
        final untilT1 = await log.query(until: t1);
        expect(untilT1.map((e) => e.id), ['e1', 'e2']);

        // Filter by type
        final typeA = await log.query(type: 'type_a');
        expect(typeA.map((e) => e.id), ['e1', 'e3']);

        // Filter by level
        final warnings = await log.query(level: EventLevel.warning);
        expect(warnings.map((e) => e.id), ['e2']);

        // Filter by sessionId
        final ses1 = await log.query(sessionId: 'ses-1');
        expect(ses1.map((e) => e.id), ['e1', 'e2']);

        // Limit
        final limited = await log.query(limit: 2);
        expect(limited.length, 2);
        expect(limited.map((e) => e.id), ['e1', 'e2']);

        // Descending
        final desc = await log.query(descending: true);
        expect(desc.map((e) => e.id), ['e3', 'e2', 'e1']);

        await log.close();
      },
    );

    test('Ring buffer bounds and FIFO eviction', () async {
      final logDir = Directory('${tempDir.path}/events');
      const capacity = 5;
      final log = FileEventLog(
        logDir,
        capacity: capacity,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      // Log 10 events with sequential timestamps
      for (var i = 1; i <= 10; i++) {
        await log.log(
          createSampleEvent(
            id: 'evt-$i',
            message: 'Event $i',
            timestamp: fakeClock.now().add(Duration(seconds: i)),
          ),
        );
      }

      // Memory buffer holds exactly capacity items
      expect(log.inMemoryCount, capacity);
      final recent = log.recentEvents;
      expect(recent.length, capacity);
      expect(recent.map((e) => e.id), [
        'evt-6',
        'evt-7',
        'evt-8',
        'evt-9',
        'evt-10',
      ]);

      // Disk holds all 10 events
      final allOnDisk = await log.query();
      expect(allOnDisk.length, 10);
      expect(allOnDisk.map((e) => e.id).toList(), [
        'evt-1',
        'evt-2',
        'evt-3',
        'evt-4',
        'evt-5',
        'evt-6',
        'evt-7',
        'evt-8',
        'evt-9',
        'evt-10',
      ]);

      await log.close();
    });

    test('Crash recovery: cleans orphaned .tmp files and ignores corrupt trailing line', () async {
      final logDir = Directory('${tempDir.path}/events');
      final log1 = FileEventLog(
        logDir,
        partitionByDay: false,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      await log1.init();
      await log1.log(createSampleEvent(id: 'e1', message: 'Valid 1'));
      await log1.log(createSampleEvent(id: 'e2', message: 'Valid 2'));
      await log1.close();

      // Simulate a crash leaving an orphaned .tmp file
      final orphanTmp = File('${logDir.path}/events.jsonl.tmp');
      await orphanTmp.writeAsString('partial uncommitted write');
      expect(await orphanTmp.exists(), isTrue);

      // Simulate power failure corrupting the trailing line in events.jsonl
      final logFile = File('${logDir.path}/events.jsonl');
      await logFile.writeAsString(
        '{"id":"e3_corrupt", "timestamp":"2026-11-06T12', // truncated line
        mode: FileMode.append,
      );

      // Second start of FileEventLog
      final log2 = FileEventLog(
        logDir,
        partitionByDay: false,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      await log2.init();

      // Orphaned .tmp must be deleted
      expect(await orphanTmp.exists(), isFalse);

      // Valid records must be recovered cleanly without throwing
      final recovered = await log2.query();
      expect(recovered.length, 2);
      expect(recovered.map((e) => e.id), ['e1', 'e2']);

      // Ring buffer is warmed up with valid records
      expect(log2.inMemoryCount, 2);
      expect(log2.recentEvents.map((e) => e.id), ['e1', 'e2']);

      await log2.close();
    });

    test(
      '24h TTL Pruning sweeps expired events from memory and disk',
      () async {
        final logDir = Directory('${tempDir.path}/events');
        final log = FileEventLog(
          logDir,
          clock: fakeClock,
          chmodRunner: mockChmod,
          partitionByDay: false,
        );

        final t0 = fakeClock.now();
        await log.log(createSampleEvent(id: 'e0', timestamp: t0));

        // Advance clock by 12 hours
        fakeClock.advance(const Duration(hours: 12));
        final t12 = fakeClock.now();
        await log.log(createSampleEvent(id: 'e12', timestamp: t12));

        // Advance clock by another 13 hours (t0 is 25h old, t12 is 13h old)
        fakeClock.advance(const Duration(hours: 13));

        // Prune with 24h TTL
        final prunedCount = await log.prune(const Duration(hours: 24));
        expect(prunedCount, 1);

        // e0 must be gone, e12 must remain
        final remaining = await log.query();
        expect(remaining.length, 1);
        expect(remaining.first.id, 'e12');

        // Ring buffer also evicted e0
        expect(log.inMemoryCount, 1);
        expect(log.recentEvents.first.id, 'e12');

        // Advance clock past 24h for e12 (advance 12 more hours -> total 37h)
        fakeClock.advance(const Duration(hours: 12));
        final secondPrune = await log.prune(const Duration(hours: 24));
        expect(secondPrune, 1);

        final empty = await log.query();
        expect(empty, isEmpty);
        expect(log.inMemoryCount, 0);

        await log.close();
      },
    );

    test('EventLoggingSessionStore records session transitions into EventLog', () async {
      final sessionDir = Directory('${tempDir.path}/sessions');
      final eventDir = Directory('${tempDir.path}/events');

      final sessionStore = FileSessionStore(sessionDir, clock: fakeClock);
      final eventLog = FileEventLog(eventDir, clock: fakeClock);
      final store = EventLoggingSessionStore(sessionStore, eventLog);

      await store.init();

      final record = SessionRecord(
        sessionId: 'session-201',
        role: SessionRole.receiver,
        peerDeviceId: 'peer-alice',
        peerFingerprint:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        status: TransferStatus.inProgress,
        totalSize: 10 * 1024 * 1024,
        createdAt: fakeClock.now(),
        updatedAt: fakeClock.now(),
        files: [
          const SessionFileRecord(
            fileId: 'f1',
            name: 'archive.tar',
            size: 10 * 1024 * 1024,
            chunkSize: 4 * 1024 * 1024,
            chunkCount: 3,
            receivedRanges: [
              [0, 1],
            ],
            isComplete: false,
          ),
        ],
      );

      // 1. Save session in progress
      await store.saveSession(record);
      var events = await eventLog.query(sessionId: 'session-201');
      expect(events.length, 1);
      expect(events.first.type, 'session_in_progress');
      expect(events.first.data['peerFingerprint'], 'e3b0c44298fc1c14');

      // 2. Update to completed
      fakeClock.advance(const Duration(seconds: 1));
      final completed = record.copyWith(
        status: TransferStatus.completed,
        updatedAt: fakeClock.now(),
      );
      await store.saveSession(completed);
      events = await eventLog.query(sessionId: 'session-201');
      expect(events.length, 2);
      expect(events.last.type, 'session_completed');
      expect(events.last.message, contains('completed successfully'));

      // 3. Delete session
      await store.deleteSession('session-201');
      events = await eventLog.query(sessionId: 'session-201');
      expect(events.length, 3);
      expect(events.last.type, 'session_deleted');

      await store.close();
    });

    test('InMemoryEventLog exhibits complete behavioral parity', () async {
      final inMemory = InMemoryEventLog(capacity: 3, clock: fakeClock);
      await inMemory.init();

      await inMemory.log(createSampleEvent(id: 'm1'));
      await inMemory.log(createSampleEvent(id: 'm2'));
      await inMemory.log(createSampleEvent(id: 'm3'));
      await inMemory.log(createSampleEvent(id: 'm4'));

      // Ring buffer capacity is 3
      expect(inMemory.inMemoryCount, 3);
      expect(inMemory.recentEvents.map((e) => e.id), ['m2', 'm3', 'm4']);

      // Secret checking invariant works in memory
      expect(
        () => inMemory.log(
          createSampleEvent(id: 'm5', data: {'token': 'secret'}),
        ),
        throwsA(isA<ArgumentError>()),
      );

      // TTL pruning works in memory
      fakeClock.advance(const Duration(hours: 25));
      final pruned = await inMemory.prune(const Duration(hours: 24));
      expect(pruned, 3);
      expect(inMemory.inMemoryCount, 0);

      await inMemory.close();
    });
  });
}

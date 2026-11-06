// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import 'session_record.dart';
import 'session_store.dart';

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
  group('SessionStore (FileSessionStore & InMemorySessionStore)', () {
    late Directory tempDir;
    late FakeClock fakeClock;
    final List<String> chmodLog = [];

    Future<int> mockChmod(String mode, String path) async {
      chmodLog.add('$mode:$path');
      return 0;
    }

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'libreshare_session_test_',
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

    SessionRecord sampleRecord({
      String sessionId = 'session-101',
      SessionRole role = SessionRole.receiver,
      TransferStatus status = TransferStatus.inProgress,
      ChunkRanges ranges = const [
        [0, 3],
        [5, 5],
      ],
      DateTime? updated,
    }) {
      return SessionRecord(
        sessionId: sessionId,
        role: role,
        peerDeviceId: 'dev-alice',
        peerFingerprint:
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        status: status,
        totalSize: 40 * 1024 * 1024,
        createdAt: fakeClock.now().subtract(const Duration(minutes: 10)),
        updatedAt: updated ?? fakeClock.now(),
        files: [
          SessionFileRecord(
            fileId: 'file-0',
            name: 'dataset.tar.gz',
            size: 40 * 1024 * 1024,
            chunkSize: 4 * 1024 * 1024,
            chunkCount: 10,
            sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
            partialPath: '/tmp/dataset.tar.gz.lspart',
            receivedRanges: ranges,
            isComplete: false,
          ),
        ],
      );
    }

    test('FileSessionStore initializes directory with mode 0700', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      await store.init();
      expect(await storeDir.exists(), isTrue);
      expect(chmodLog, contains('0700:${storeDir.path}'));
      await store.close();
    });

    test('saveSession and getSession round-trip session record', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      final record = sampleRecord();
      await store.saveSession(record);

      final retrieved = await store.getSession(record.sessionId);
      expect(retrieved, isNotNull);
      expect(retrieved!.sessionId, equals(record.sessionId));
      expect(retrieved.role, equals(record.role));
      expect(retrieved.peerDeviceId, equals(record.peerDeviceId));
      expect(retrieved.peerFingerprint, equals(record.peerFingerprint));
      expect(retrieved.status, equals(record.status));
      expect(retrieved.files.length, equals(1));
      expect(
        retrieved.files.first.receivedRanges,
        equals([
          [0, 3],
          [5, 5],
        ]),
      );
      expect(retrieved.files.first.receivedChunkCount, equals(5));

      await store.close();
    });

    test('FileSessionStore applies 0600 mode on atomic write', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      final record = sampleRecord();
      await store.saveSession(record);

      // Verify that chmod 0600 was applied to the .tmp file
      final chmod600Calls = chmodLog.where(
        (c) => c.startsWith('0600:') && c.endsWith('.tmp'),
      );
      expect(chmod600Calls, isNotEmpty);

      // Verify destination file exists and is valid JSON
      final targetFile = File('${storeDir.path}/${record.sessionId}.json');
      expect(await targetFile.exists(), isTrue);
      final raw = await targetFile.readAsString();
      expect(jsonDecode(raw), isA<Map<String, Object?>>());

      // Verify .tmp was cleaned up via atomic rename
      final tmpFile = File('${targetFile.path}.tmp');
      expect(await tmpFile.exists(), isFalse);

      await store.close();
    });

    test('Atomic update updates chunk bitmap in place', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      final initial = sampleRecord(
        ranges: [
          [0, 1],
        ],
      );
      await store.saveSession(initial);

      // Advance chunks
      final updated = initial.copyWith(
        updatedAt: fakeClock.now().add(const Duration(seconds: 30)),
        files: [
          initial.files.first.copyWith(
            receivedRanges: [
              [0, 5],
            ],
          ),
        ],
      );
      await store.saveSession(updated);

      final retrieved = await store.getSession(initial.sessionId);
      expect(retrieved, isNotNull);
      expect(
        retrieved!.files.first.receivedRanges,
        equals([
          [0, 5],
        ]),
      );
      expect(retrieved.files.first.receivedChunkCount, equals(6));

      await store.close();
    });

    test('Security Invariant: zero secret leaks in serialized file', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      final record = sampleRecord();
      await store.saveSession(record);

      final targetFile = File('${storeDir.path}/${record.sessionId}.json');
      final rawContent = await targetFile.readAsString();

      // Assert no secret substrings exist in file content
      for (final forbidden in kForbiddenSecretKeys) {
        expect(
          rawContent.toLowerCase().contains('"$forbidden"'),
          isFalse,
          reason: 'File must not contain forbidden secret key: $forbidden',
        );
      }

      await store.close();
    });

    test(
      'Security Invariant: records rejecting secret keys in extraMetadata',
      () {
        expect(
          () => sampleRecord()
              .copyWith(extraMetadata: {'pin': '123456'})
              .toJson(),
          throwsA(isA<ArgumentError>()),
        );

        expect(
          () => sampleRecord()
              .copyWith(extraMetadata: {'token': 'bearer-secret'})
              .toJson(),
          throwsA(isA<ArgumentError>()),
        );

        expect(
          () => sampleRecord()
              .copyWith(extraMetadata: {'privateKey': 'priv-key-der'})
              .toJson(),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('24h TTL Eviction in FileSessionStore', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      // Save a fresh session
      final fresh = sampleRecord(sessionId: 'fresh-session');
      await store.saveSession(fresh);

      // Save a session that is 25 hours old
      final stale = sampleRecord(
        sessionId: 'stale-session',
        updated: fakeClock.now().subtract(const Duration(hours: 25)),
      );
      await store.saveSession(stale);

      // getSession on stale session should return null and delete it
      final staleGet = await store.getSession('stale-session');
      expect(staleGet, isNull);

      // sweepExpired removes expired sessions
      final evicted = await store.sweepExpired(
        maxAge: const Duration(hours: 24),
      );
      expect(evicted, equals(0)); // Already deleted by getSession

      // Add another stale session
      final stale2 = sampleRecord(
        sessionId: 'stale-session-2',
        updated: fakeClock.now().subtract(const Duration(hours: 30)),
      );
      await store.saveSession(stale2);

      final evicted2 = await store.sweepExpired(
        maxAge: const Duration(hours: 24),
      );
      expect(evicted2, equals(1));

      // Fresh session remains
      final freshGet = await store.getSession('fresh-session');
      expect(freshGet, isNotNull);

      await store.close();
    });

    test('deleteSession removes target and temp files', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      final record = sampleRecord();
      await store.saveSession(record);
      expect(await store.getSession(record.sessionId), isNotNull);

      await store.deleteSession(record.sessionId);
      expect(await store.getSession(record.sessionId), isNull);

      final targetFile = File('${storeDir.path}/${record.sessionId}.json');
      expect(await targetFile.exists(), isFalse);

      await store.close();
    });

    test('listSessions filters by role and excludes expired', () async {
      final storeDir = Directory('${tempDir.path}/sessions');
      final store = FileSessionStore(
        storeDir,
        clock: fakeClock,
        chmodRunner: mockChmod,
      );

      await store.saveSession(
        sampleRecord(sessionId: 'rec-1', role: SessionRole.receiver),
      );
      await store.saveSession(
        sampleRecord(sessionId: 'send-1', role: SessionRole.sender),
      );
      await store.saveSession(
        sampleRecord(
          sessionId: 'rec-stale',
          role: SessionRole.receiver,
          updated: fakeClock.now().subtract(const Duration(hours: 26)),
        ),
      );

      final receivers = await store.listSessions(role: SessionRole.receiver);
      expect(receivers.length, equals(1));
      expect(receivers.first.sessionId, equals('rec-1'));

      final senders = await store.listSessions(role: SessionRole.sender);
      expect(senders.length, equals(1));
      expect(senders.first.sessionId, equals('send-1'));

      final all = await store.listSessions();
      expect(all.length, equals(2));

      await store.close();
    });

    test('InMemorySessionStore functions identically for unit tests', () async {
      final inMemory = InMemorySessionStore(clock: fakeClock);

      final rec = sampleRecord(sessionId: 'mem-1');
      await inMemory.saveSession(rec);

      final retrieved = await inMemory.getSession('mem-1');
      expect(retrieved, isNotNull);
      expect(retrieved!.sessionId, equals('mem-1'));

      // Advance clock past 24h
      fakeClock.advance(const Duration(hours: 25));
      expect(await inMemory.getSession('mem-1'), isNull);

      await inMemory.close();
    });
  });
}

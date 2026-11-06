import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
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
  group('ReceiverAdoptionHelper', () {
    late Directory tempDir;
    late FakeClock fakeClock;
    late InMemorySessionStore sessionStore;
    late ReceiverAdoptionHelper helper;

    setUp(() async {
      final raw = await Directory.systemTemp.createTemp('adoption_test_');
      tempDir = Directory(raw.resolveSymbolicLinksSync());
      fakeClock = FakeClock(DateTime.utc(2026, 11, 6, 12, 0, 0));
      sessionStore = InMemorySessionStore(clock: fakeClock);
      helper = ReceiverAdoptionHelper(
        downloadDir: tempDir,
        sessionStore: sessionStore,
        clock: fakeClock,
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('fresh file (no sidecar) returns fresh status', () async {
      final item = const FileItem(
        fileId: 'f1',
        fileName: 'test.txt',
        size: 100,
        chunkCount: 2,
        sha256:
            'deadbeef00000000000000000000000000000000000000000000000000000000',
      );

      final result = await helper.adoptFile(
        item: item,
        chunkSize: 50,
        peer: AuthenticatedPeer(
          deviceId: 'device-1',
          fingerprint: 'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234',
          certDer: Uint8List(0),
        ),
      );

      expect(result.status, equals(AdoptionStatus.fresh));
      expect(result.adoptedRanges, isEmpty);
    });

    test('peer fingerprint mismatch rejects adoption and preserves legitimate owner data', () async {
      final item = const FileItem(
        fileId: 'f1',
        fileName: 'secret.bin',
        size: 100,
        chunkCount: 2,
        sha256:
            'abcdef0000000000000000000000000000000000000000000000000000000000',
      );

      final partialFile = File(p.join(tempDir.path, 'secret.bin.lspart'));
      await partialFile.writeAsBytes(List.filled(50, 0x42));
      final sidecarFile = File(p.join(tempDir.path, 'secret.bin.lspart.json'));
      final sidecarJson = {
        'version': 1,
        'size': 100,
        'chunkSize': 50,
        'chunkCount': 2,
        'sha256': item.sha256,
        'modified': null,
        'createdAt': fakeClock.now().toIso8601String(),
        'updatedAt': fakeClock.now().toIso8601String(),
        'received': [
          [0, 0],
        ],
      };
      await sidecarFile.writeAsString(jsonEncode(sidecarJson));

      // Persist prior session with original owner
      await sessionStore.saveSession(
        SessionRecord(
          sessionId: 'session-old',
          role: SessionRole.receiver,
          status: TransferStatus.inProgress,
          totalSize: 100,
          peerDeviceId: 'device-owner',
          peerFingerprint: 'owner11111111111111111111111111111111111111111111111111111111111',
          createdAt: fakeClock.now(),
          updatedAt: fakeClock.now(),
          files: [
            SessionFileRecord(
              fileId: 'f1',
              name: 'secret.bin',
              size: 100,
              chunkSize: 50,
              chunkCount: 2,
              partialPath: partialFile.path,
              receivedRanges: [
                [0, 0],
              ],
            ),
          ],
        ),
      );

      final result = await helper.adoptFile(
        item: item,
        chunkSize: 50,
        peer: AuthenticatedPeer(
          deviceId: 'device-attacker',
          fingerprint: 'attacker222222222222222222222222222222222222222222222222222222222',
          certDer: Uint8List(0),
        ),
      );

      // Security invariant: Attacker cannot adopt owner's partials and cannot delete owner's files
      expect(result.status, equals(AdoptionStatus.rejectedPeerMismatch));
      expect(partialFile.existsSync(), isTrue);
      expect(sidecarFile.existsSync(), isTrue);
    });

    test('valid matching sidecar is adopted successfully', () async {
      const ownerFp =
          'owner11111111111111111111111111111111111111111111111111111111111';
      final item = const FileItem(
        fileId: 'f1',
        fileName: 'data.bin',
        size: 100,
        chunkCount: 2,
        sha256:
            'abcdef0000000000000000000000000000000000000000000000000000000000',
      );

      final partialFile = File(p.join(tempDir.path, 'data.bin.lspart'));
      await partialFile.writeAsBytes(List.filled(50, 0x42));
      final sidecarFile = File(p.join(tempDir.path, 'data.bin.lspart.json'));
      final sidecarJson = {
        'version': 1,
        'size': 100,
        'chunkSize': 50,
        'chunkCount': 2,
        'sha256': item.sha256,
        'modified': null,
        'createdAt': fakeClock.now().toIso8601String(),
        'updatedAt': fakeClock.now().toIso8601String(),
        'received': [
          [0, 0],
        ],
      };
      await sidecarFile.writeAsString(jsonEncode(sidecarJson));

      // Persist prior session with owner
      await sessionStore.saveSession(
        SessionRecord(
          sessionId: 'session-owner',
          role: SessionRole.receiver,
          status: TransferStatus.inProgress,
          totalSize: 100,
          peerDeviceId: 'device-owner',
          peerFingerprint: ownerFp,
          createdAt: fakeClock.now(),
          updatedAt: fakeClock.now(),
          files: [
            SessionFileRecord(
              fileId: 'f1',
              name: 'data.bin',
              size: 100,
              chunkSize: 50,
              chunkCount: 2,
              partialPath: partialFile.path,
              receivedRanges: [
                [0, 0],
              ],
            ),
          ],
        ),
      );

      final result = await helper.adoptFile(
        item: item,
        chunkSize: 50,
        peer: AuthenticatedPeer(
          deviceId: 'device-owner',
          fingerprint: ownerFp,
          certDer: Uint8List(0),
        ),
      );

      expect(result.status, equals(AdoptionStatus.adopted));
      expect(
        result.adoptedRanges,
        equals([
          [0, 0],
        ]),
      );
      expect(result.adoptedBytes, equals(50));
      expect(result.adoptedChunkCount, equals(1));
      expect(partialFile.existsSync(), isTrue);
    });
  });
}

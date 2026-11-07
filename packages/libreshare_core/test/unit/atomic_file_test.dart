// E5 / R1b: the shared atomic-replace helper (lib/src/storage/atomic_file.dart).
//
// API under test (stated by the tester, to be implemented by the coder):
//
//   Future<void> atomicWriteBytes(File target, List<int> bytes,
//       {int? mode, Future<void> Function(File tmp)? prepareTmp});
//   Future<void> atomicReplace(File tmp, File target);
//   typedef AtomicRenameFn = Future<void> Function(File from, String toPath);
//   AtomicRenameFn? atomicRenameOverride;  // test seam, null = File.rename
//
// Contract: after the call the target holds exactly the new bytes or (on any
// failure) exactly the OLD bytes; nothing else (tmp, backup) is left in the
// directory; renaming onto an existing file works even when the OS rename
// refuses to replace (Windows); concurrent writers never expose a partial
// file. `mode` is a POSIX mode (0x180 == 0o600) applied before any byte is
// written; ignored on Windows. `prepareTmp` runs on the still empty tmp file.
//
// Every test name starts with the guard it protects.
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/storage/atomic_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/atomic_hooks.dart';

const int mode600 = 0x180; // 0o600
int permBits(String path) => FileStat.statSync(path).mode & 0x1FF;

Uint8List fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);

void main() {
  late Directory dir;
  late File target;

  List<String> names() =>
      dir.listSync().map((e) => p.basename(e.path)).toList()..sort();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ls_atomic_');
    target = File(p.join(dir.path, 'state.json'));
  });
  tearDown(() {
    atomicRenameOverride = null;
    dir.deleteSync(recursive: true);
  });

  group('atomicWriteBytes basics', () {
    test('guard create-when-absent: target absent -> created with the bytes, '
        'nothing else left', () async {
      await atomicWriteBytes(target, [1, 2, 3]);
      expect(target.readAsBytesSync(), [1, 2, 3]);
      expect(names(), ['state.json']);
    });

    test('guard replace-existing: existing target is replaced (longer and '
        'shorter content), nothing else left', () async {
      target.writeAsBytesSync(fill(10, 7));
      await atomicWriteBytes(target, fill(5000, 9));
      expect(target.readAsBytesSync(), fill(5000, 9));
      await atomicWriteBytes(target, [4]);
      expect(target.readAsBytesSync(), [4]);
      expect(names(), ['state.json']);
    });

    test('guard empty-payload: zero bytes produce an empty file', () async {
      target.writeAsBytesSync([1, 2, 3]);
      await atomicWriteBytes(target, const []);
      expect(target.existsSync(), isTrue);
      expect(target.lengthSync(), 0);
    });

    test('guard stale-tmp-overwritten: a stale <target>.tmp from an earlier '
        'crash neither blocks the write nor survives it', () async {
      File('${target.path}.tmp').writeAsStringSync('{"half');
      await atomicWriteBytes(target, [8, 8]);
      expect(target.readAsBytesSync(), [8, 8]);
      expect(names(), ['state.json']);
    });

    test('guard goes-through-rename-hook: the commit is a rename whose '
        'destination is the target', () async {
      final log = RenameLog();
      atomicRenameOverride = recordingRename(log);
      await atomicWriteBytes(target, [1]);
      expect(log.sawDestination(target.path), isTrue);
    });
  });

  group('atomicWriteBytes failure leaves the OLD file', () {
    test('guard cleanup-on-rename-failure: every rename fails -> throws, '
        'OLD bytes intact, no tmp/backup litter', () async {
      target.writeAsBytesSync(fill(100, 1));
      atomicRenameOverride = failingRename(RenameLog());
      await expectLater(
        atomicWriteBytes(target, fill(100, 2)),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), fill(100, 1));
      expect(names(), ['state.json']);
    });

    test('guard cleanup-on-rename-failure: every rename fails and the target '
        'did not exist -> throws, no target, no litter', () async {
      atomicRenameOverride = failingRename(RenameLog());
      await expectLater(
        atomicWriteBytes(target, [1]),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      expect(names(), isEmpty);
    });

    test('guard never-delete-before-commit: the old file is locked (cannot be '
        'replaced or moved) -> throws, OLD bytes intact, no litter', () async {
      target.writeAsBytesSync(fill(64, 3));
      atomicRenameOverride = lockedFileRename(target.path, RenameLog());
      await expectLater(
        atomicWriteBytes(target, fill(64, 4)),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), fill(64, 3));
      expect(names(), ['state.json']);
    });

    test('guard real-fs-failure-cleanup: the rename fails for real (target '
        'path is a non-empty directory) -> throws, the directory and its '
        'child survive, no tmp litter', () async {
      final asDir = Directory(target.path)..createSync();
      File(p.join(asDir.path, 'child')).writeAsBytesSync([5]);
      await expectLater(
        atomicWriteBytes(target, [1, 2]),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p.join(asDir.path, 'child')).readAsBytesSync(), [5]);
      expect(names(), ['state.json']);
    });

    test('guard prepareTmp-failure-cleanup: prepareTmp throws -> rethrown, '
        'OLD bytes intact, no litter, no byte was written first', () async {
      target.writeAsBytesSync([9, 9, 9]);
      var tmpLengthAtPrepare = -1;
      await expectLater(
        atomicWriteBytes(
          target,
          fill(1000, 1),
          prepareTmp: (tmp) async {
            tmpLengthAtPrepare = tmp.lengthSync();
            throw StateError('prepare failed');
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(tmpLengthAtPrepare, 0);
      expect(target.readAsBytesSync(), [9, 9, 9]);
      expect(names(), ['state.json']);
    });
  });

  group('Windows-like rename (refuses to replace an existing file)', () {
    test('guard replace-fallback: replacing an existing target works, '
        'repeatedly, with no backup/tmp litter', () async {
      target.writeAsBytesSync(fill(10, 1));
      final log = RenameLog();
      atomicRenameOverride = windowsLikeRename(log);
      for (var i = 2; i <= 4; i++) {
        await atomicWriteBytes(target, fill(100 * i, i));
        expect(target.readAsBytesSync(), fill(100 * i, i));
      }
      atomicRenameOverride = null;
      expect(names(), ['state.json']);
      expect(log.sawDestination(target.path), isTrue);
    });

    test('guard replace-fallback: atomicReplace(tmp, target) works too and '
        'consumes the tmp file', () async {
      final tmp = File('${target.path}.tmp')..writeAsBytesSync([7, 7]);
      target.writeAsBytesSync([1]);
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await atomicReplace(tmp, target);
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), [7, 7]);
      expect(names(), ['state.json']);
    });
  });

  group('atomicReplace', () {
    test('guard replace-existing: tmp replaces an existing target', () async {
      final tmp = File('${target.path}.tmp')..writeAsBytesSync([2, 2, 2]);
      target.writeAsBytesSync([1]);
      await atomicReplace(tmp, target);
      expect(target.readAsBytesSync(), [2, 2, 2]);
      expect(tmp.existsSync(), isFalse);
    });

    test('guard create-when-absent: tmp becomes the target', () async {
      final tmp = File('${target.path}.tmp')..writeAsBytesSync([3]);
      await atomicReplace(tmp, target);
      expect(target.readAsBytesSync(), [3]);
      expect(tmp.existsSync(), isFalse);
    });

    test('guard never-delete-before-commit: tmp is missing -> throws '
        'FileSystemException and the OLD target is untouched', () async {
      target.writeAsBytesSync([1, 1]);
      final missing = File(p.join(dir.path, 'nope.tmp'));
      await expectLater(
        atomicReplace(missing, target),
        throwsA(isA<FileSystemException>()),
      );
      expect(target.readAsBytesSync(), [1, 1]);
      expect(names(), ['state.json']);
    });

    test('guard never-delete-before-commit: locked old target -> throws, '
        'OLD bytes intact', () async {
      final tmp = File('${target.path}.tmp')..writeAsBytesSync([2]);
      target.writeAsBytesSync([1]);
      atomicRenameOverride = lockedFileRename(target.path, RenameLog());
      await expectLater(
        atomicReplace(tmp, target),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), [1]);
    });
  });

  group('permissions', () {
    final skip = Platform.isWindows
        ? 'POSIX permission bits do not exist on Windows'
        : null;

    test('guard mode-applied: mode 0600 on a new file', () async {
      await atomicWriteBytes(target, [1], mode: mode600);
      expect(permBits(target.path), mode600);
    }, skip: skip);

    test('guard mode-applied: replacing a 0644 file with mode 0600 leaves '
        'the NEW file at 0600', () async {
      target.writeAsBytesSync([1]);
      Process.runSync('chmod', ['644', target.path]);
      await atomicWriteBytes(target, [2], mode: mode600);
      expect(permBits(target.path), mode600);
      expect(target.readAsBytesSync(), [2]);
    }, skip: skip);

    test('guard prepareTmp-sees-empty-tmp: prepareTmp runs on an empty tmp '
        'and the final file has the requested mode', () async {
      // prepareTmp observes the tmp BEFORE the bytes: it must be empty. The
      // helper must apply [mode] no later than the first byte; we check the
      // final state and that prepareTmp ran on an empty file.
      var empty = false;
      await atomicWriteBytes(
        target,
        fill(32, 1),
        mode: mode600,
        prepareTmp: (tmp) async => empty = tmp.lengthSync() == 0,
      );
      expect(empty, isTrue);
      expect(permBits(target.path), mode600);
    }, skip: skip);
  });

  group('concurrency', () {
    test('guard no-torn-reads: 8 writers x 5 rounds on one target while a '
        'reader polls: every read is exactly one writer payload; all writes '
        'complete; no litter', () async {
      const size = 256 * 1024;
      atomicRenameOverride = null;
      await atomicWriteBytes(target, fill(size, 0));
      var stop = false;
      var reads = 0;
      final bad = <String>[];
      final reader = () async {
        while (!stop) {
          final b = await target.readAsBytes();
          reads++;
          final ok = b.length == size && b.every((x) => x == b[0]);
          if (!ok) bad.add('len=${b.length}');
          await Future<void>.delayed(Duration.zero);
        }
      }();
      final writers = <Future<void>>[];
      for (var w = 1; w <= 8; w++) {
        writers.add(() async {
          for (var r = 0; r < 5; r++) {
            await atomicWriteBytes(target, fill(size, w));
          }
        }());
      }
      await Future.wait(writers);
      stop = true;
      await reader;
      expect(bad, isEmpty);
      expect(reads, greaterThan(0));
      final fin = target.readAsBytesSync();
      expect(fin.length, size);
      expect(fin.every((x) => x == fin[0]), isTrue);
      expect(names(), ['state.json']);
    });
  });
}

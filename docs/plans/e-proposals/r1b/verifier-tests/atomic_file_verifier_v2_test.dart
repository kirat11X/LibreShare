// VERIFIER tests, round 2 (E5 / R1b), written by the verifier agent, NOT by
// the tester and NOT by the coder. New file; no existing test is touched.
//
// Covers the round-2 changes of lib/src/storage/atomic_file.dart (F1 negative
// errno filter, fixed `<target>.bak`, stale-bak rules, recoverAtomicBackup,
// symlinked tmp, normalised queue key, first error rethrown) and kills the
// mutants of those changes. Tests named FINDING assert desired behaviour and
// are red while the defect named in them exists.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/storage/atomic_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/atomic_hooks.dart';

List<int> fill(int n, int v) => List<int>.filled(n, v);

FileSystemException os(String to, int code, [String msg = 'simulated']) =>
    FileSystemException('simulated rename failure', to, OSError(msg, code));

void main() {
  late Directory dir;
  late File target;
  late File bak;
  List<String> names([Directory? d]) =>
      (d ?? dir).listSync().map((e) => p.basename(e.path)).toList()..sort();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ls_verif_v2_');
    target = File(p.join(dir.path, 'state.json'));
    bak = File('${target.path}.bak');
  });
  tearDown(() {
    atomicRenameOverride = null;
    dir.deleteSync(recursive: true);
  });

  group('F1 errno filter', () {
    for (final code in [18, 28]) {
      test('V2-F1-$code: errno $code on tmp->target with an existing target: '
          'ONE rename attempt, no move-aside, target never missing, old bytes, '
          'no litter', () async {
        target.writeAsBytesSync(fill(30, 1));
        final log = RenameLog();
        var missing = false;
        atomicRenameOverride = (from, to) async {
          log.calls.add((from: from.path, to: to));
          if (!target.existsSync()) missing = true;
          throw os(to, code);
        };
        await expectLater(
          atomicWriteBytes(target, fill(30, 2)),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.errorCode,
              'errno',
              code,
            ),
          ),
        );
        atomicRenameOverride = null;
        expect(log.calls, hasLength(1));
        expect(missing, isFalse);
        expect(target.readAsBytesSync(), fill(30, 1));
        expect(names(), ['state.json']);
      }, skip: Platform.isWindows ? 'POSIX errno values' : null);
    }

    test('V2-F1-noerrno: a failure WITHOUT an OS error still takes the '
        'move-aside fallback (only a known-hopeless errno skips it)', () async {
      target.writeAsBytesSync(fill(30, 1));
      var first = true;
      atomicRenameOverride = (from, to) async {
        if (first) {
          first = false;
          throw FileSystemException('no os error', to); // osError == null
        }
        await from.rename(to);
      };
      await atomicWriteBytes(target, fill(30, 2));
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), fill(30, 2));
      expect(names(), ['state.json']);
    });

    test('V2-F1-other-errno: a different errno (EACCES 13) also takes the '
        'fallback', () async {
      target.writeAsBytesSync(fill(30, 1));
      var first = true;
      atomicRenameOverride = (from, to) async {
        if (first) {
          first = false;
          throw os(to, 13, 'Permission denied');
        }
        await from.rename(to);
      };
      await atomicWriteBytes(target, fill(30, 2));
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), fill(30, 2));
      expect(names(), ['state.json']);
    });
  });

  group('fixed <target>.bak and stale-bak rules', () {
    test('V2-bak-name: during the window the old bytes live in exactly '
        '<target>.bak (no random suffix)', () async {
      target.writeAsBytesSync(fill(20, 5));
      String? seenInWindow;
      var n = 0;
      atomicRenameOverride = (from, to) async {
        n++;
        if (n == 1) throw os(to, 5, 'Access is denied.');
        if (n == 3) {
          seenInWindow = names().join(',');
        }
        await from.rename(to);
      };
      await atomicWriteBytes(target, fill(20, 6));
      atomicRenameOverride = null;
      expect(seenInWindow, 'state.json.bak,state.json.tmp');
      expect(target.readAsBytesSync(), fill(20, 6));
      expect(names(), ['state.json']);
    });

    test(
      'V2-stale-bak-removed: a stale <target>.bak next to an EXISTING '
      'target does not block a Windows-like replace and is gone after',
      () async {
        target.writeAsBytesSync(fill(20, 5));
        bak.writeAsBytesSync(fill(20, 9)); // stale
        atomicRenameOverride = windowsLikeRename(RenameLog());
        await atomicWriteBytes(target, fill(20, 6));
        atomicRenameOverride = null;
        expect(target.readAsBytesSync(), fill(20, 6));
        expect(names(), ['state.json']);
      },
    );

    test('V2-bak-survives-failed-write: target MISSING + <target>.bak '
        '(only copy of the old data) + a failing write: bak untouched, still '
        'the same bytes', () async {
      bak.writeAsBytesSync(fill(20, 5));
      atomicRenameOverride = failingRename(RenameLog());
      await expectLater(
        atomicWriteBytes(target, fill(20, 6)),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      expect(bak.readAsBytesSync(), fill(20, 5));
      expect(names(), ['state.json.bak']);
    });

    test('V2-bak-removed-after-plain-success: target MISSING + stale bak + '
        'a successful write: bak removed (documented rule)', () async {
      bak.writeAsBytesSync(fill(20, 5));
      await atomicWriteBytes(target, fill(20, 6));
      expect(target.readAsBytesSync(), fill(20, 6));
      expect(names(), ['state.json']);
    });

    test('V2-target-is-directory: target is a directory, Windows-like '
        'denial: throws, directory and child intact, no bak, no tmp', () async {
      target.createSync();
      target.deleteSync();
      Directory(target.path).createSync();
      File(p.join(target.path, 'child')).writeAsStringSync('X');
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await expectLater(
        atomicWriteBytes(target, fill(5, 1)),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      expect(File(p.join(target.path, 'child')).readAsStringSync(), 'X');
      expect(names(), ['state.json']);
    });

    test(
      'V2-bak-is-directory: <target>.bak is a directory: replace still '
      'works on a normal filesystem and the directory is untouched',
      () async {
        target.writeAsBytesSync(fill(5, 1));
        Directory(bak.path).createSync();
        File(p.join(bak.path, 'keep')).writeAsStringSync('K');
        await atomicWriteBytes(target, fill(5, 2));
        expect(target.readAsBytesSync(), fill(5, 2));
        expect(File(p.join(bak.path, 'keep')).readAsStringSync(), 'K');
      },
    );
  });

  group('recoverAtomicBackup', () {
    test('V2-recover-restores: target missing + bak -> restored, returns '
        'true, bak consumed', () async {
      bak.writeAsBytesSync(fill(8, 3));
      expect(await recoverAtomicBackup(target), isTrue);
      expect(target.readAsBytesSync(), fill(8, 3));
      expect(names(), ['state.json']);
    });

    test('V2-recover-keeps-existing-target: target EXISTS + bak -> returns '
        'false, target keeps its (newer) bytes, bak untouched', () async {
      target.writeAsBytesSync(fill(8, 7));
      bak.writeAsBytesSync(fill(8, 3));
      expect(await recoverAtomicBackup(target), isFalse);
      expect(target.readAsBytesSync(), fill(8, 7));
      expect(bak.readAsBytesSync(), fill(8, 3));
    });

    test('V2-recover-nothing: neither target nor bak -> false, nothing '
        'created', () async {
      expect(await recoverAtomicBackup(target), isFalse);
      expect(names(), isEmpty);
    });

    test('V2-recover-after-double-failure: the sequence that strands the old '
        'data is fully repaired by recoverAtomicBackup', () async {
      target.writeAsBytesSync(fill(8, 4));
      var n = 0;
      atomicRenameOverride = (from, to) async {
        n++;
        if (n == 2) {
          await from.rename(to);
          return;
        }
        throw os(to, 5, 'Access is denied.');
      };
      await atomicWriteBytes(target, fill(8, 5)).catchError((_) {});
      atomicRenameOverride = null;
      expect(names(), ['state.json.bak']);
      expect(await recoverAtomicBackup(target), isTrue);
      expect(target.readAsBytesSync(), fill(8, 4));
    });
  });

  group('symlinked tmp, queue key, error identity', () {
    test('V2-dangling-symlink-tmp: a DANGLING symlink at <target>.tmp is '
        'removed and nothing is created at its destination', () async {
      Link('${target.path}.tmp').createSync('ghost.txt');
      await atomicWriteBytes(target, fill(4, 1));
      expect(File(p.join(dir.path, 'ghost.txt')).existsSync(), isFalse);
      expect(target.readAsBytesSync(), fill(4, 1));
      expect(names(), ['state.json']);
    });

    test(
      'V2-queue-key-dotdot: the same target as dir/sub/../state.json and '
      'dir/state.json is serialised (no failure, one payload wins)',
      () async {
        Directory(p.join(dir.path, 'sub')).createSync();
        final alias = File(p.join(dir.path, 'sub', '..', 'state.json'));
        final jobs = <Future<void>>[
          for (var i = 0; i < 6; i++)
            atomicWriteBytes(i.isEven ? target : alias, fill(150000, i)),
        ];
        await Future.wait(jobs);
        final fin = target.readAsBytesSync();
        expect(fin.length, 150000);
        expect(fin.every((x) => x == fin[0]), isTrue);
        expect(names(), ['state.json', 'sub']);
      },
    );

    test(
      'V2-first-error-moveaside: when the move-aside itself fails, the '
      'error thrown is the FIRST rename error and the old target is intact',
      () async {
        target.writeAsBytesSync(fill(4, 1));
        var n = 0;
        atomicRenameOverride = (from, to) async {
          n++;
          throw os(to, 5, n == 1 ? 'FIRST-ERROR' : 'MOVE-ASIDE-ERROR');
        };
        await expectLater(
          atomicWriteBytes(target, fill(4, 2)),
          throwsA(
            isA<FileSystemException>().having(
              (e) => e.osError?.message,
              'message',
              'FIRST-ERROR',
            ),
          ),
        );
        atomicRenameOverride = null;
        expect(target.readAsBytesSync(), fill(4, 1));
        expect(names(), ['state.json']);
      },
    );

    test('V2-first-error: when the retry sequence fails, the error thrown is '
        'the FIRST rename error, not a later one', () async {
      target.writeAsBytesSync(fill(4, 1));
      var n = 0;
      atomicRenameOverride = (from, to) async {
        n++;
        if (n == 2 || n == 4) {
          await from.rename(to);
          return;
        }
        throw os(to, 5, n == 1 ? 'FIRST-ERROR' : 'LATER-ERROR-$n');
      };
      await expectLater(
        atomicWriteBytes(target, fill(4, 2)),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.message,
            'message',
            'FIRST-ERROR',
          ),
        ),
      );
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), fill(4, 1));
    });
  });

  group('FileReceiver and a user-owned <target>.bak', () {
    Future<File> receive(Directory dl, String name, List<int> data) async {
      const self = DeviceInfo(deviceId: 'rx', alias: 'R', platform: 'linux');
      const tx = DeviceInfo(deviceId: 'tx', alias: 'S', platform: 'linux');
      final rx = FileReceiver(
        self: self,
        downloadDir: dl,
        autoAccept: true,
        freeSpaceProbe: (_) async => null,
      );
      addTearDown(rx.dispose);
      final item = FileItem(
        fileId: 'f',
        fileName: name,
        size: data.length,
        chunkCount: 1,
        sha256: sha256.convert(data).toString(),
      );
      final st = await rx.createSession(
        SessionRequest(
          sender: tx,
          files: [item],
          totalSize: data.length,
          chunkSize: 64 * 1024,
        ),
        remoteAddress: '127.0.0.1',
      );
      final tok = st.acceptedFiles['f']!.token;
      await rx.putChunk(
        st.sessionId,
        'f',
        0,
        Stream.value(data),
        token: tok,
        chunkSha256: sha256.convert(data).toString(),
      );
      await rx.completeFile(st.sessionId, 'f', token: tok);
      return File(p.join(dl.path, name));
    }

    test('FINDING V2-receiver-user-bak: receiving "notes.txt" must not delete '
        'a user file "notes.txt.bak" that already sits in the download '
        'directory', () async {
      final dl = Directory(p.join(dir.path, 'dl'))..createSync();
      final userBak = File(p.join(dl.path, 'notes.txt.bak'))
        ..writeAsStringSync('USER DATA');
      final out = await receive(
        dl,
        'notes.txt',
        List<int>.generate(500, (i) => i % 251),
      );
      expect(out.existsSync(), isTrue);
      expect(userBak.existsSync(), isTrue, reason: 'user file was deleted');
      if (userBak.existsSync()) {
        expect(userBak.readAsStringSync(), 'USER DATA');
      }
    });

    test('FINDING V2-receiver-user-bak-windows: same with a Windows-like '
        'rename (the move-aside path must not clobber an existing '
        '"notes.txt.bak")', () async {
      final dl = Directory(p.join(dir.path, 'dl'))..createSync();
      final userBak = File(p.join(dl.path, 'notes.txt.bak'))
        ..writeAsStringSync('USER DATA');
      atomicRenameOverride = (from, to) async {
        // Windows: refuse to replace; also refuse the .lspart -> target of a
        // target that exists (it does not here, so this only exercises the
        // normal path) - the user .bak must survive either way.
        await windowsLikeRename(RenameLog())(from, to);
      };
      await receive(dl, 'notes.txt', List<int>.generate(300, (i) => i % 251));
      atomicRenameOverride = null;
      expect(userBak.existsSync(), isTrue, reason: 'user file was deleted');
    });
  });
}

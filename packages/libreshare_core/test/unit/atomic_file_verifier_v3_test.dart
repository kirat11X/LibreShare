// VERIFIER tests, round 3 (E5 / R1b), written by the verifier agent, NOT by
// the tester and NOT by the coder. New file; no existing test is touched.
//
// Covers the round-3 change of lib/src/storage/atomic_file.dart: atomicReplace
// (user-visible directories) uses a unique `<target>.lsbak-<hex>` backup and
// only ever deletes that one; the fixed `<target>.bak` rules belong to
// atomicWriteBytes only; POSIX no-fallback errnos 18/28/30/122. Plus attempts
// to break it: crash in the move-aside window, other filesystem, symlink
// target, read-only directory, concurrent replace of one target.
import 'dart:async';
import 'dart:io';

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
  List<String> names([Directory? d]) =>
      (d ?? dir).listSync().map((e) => p.basename(e.path)).toList()..sort();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ls_verif_v3_');
    target = File(p.join(dir.path, 'notes.txt'));
  });
  tearDown(() {
    atomicRenameOverride = null;
    Process.runSync('chmod', ['-R', 'u+rwx', dir.path]);
    dir.deleteSync(recursive: true);
  });

  File makeTmp(int v, [String name = 'notes.txt.tmp']) =>
      File(p.join(dir.path, name))..writeAsBytesSync(fill(16, v));

  group('atomicReplace never touches a file it did not create', () {
    test('V3-user-bak-windows: Windows-like refusal + a user "<t>.bak": '
        'replaced, user file untouched, no litter', () async {
      target.writeAsBytesSync(fill(16, 1));
      final userBak = File('${target.path}.bak')
        ..writeAsStringSync('USER DATA');
      final tmp = makeTmp(2);
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await atomicReplace(tmp, target);
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), fill(16, 2));
      expect(userBak.readAsStringSync(), 'USER DATA');
      expect(names(), ['notes.txt', 'notes.txt.bak']);
    });

    test('V3-user-bak-plain: plain success + a user "<t>.bak" and a user '
        '"<t>.lsbak-deadbeef": both survive', () async {
      target.writeAsBytesSync(fill(16, 1));
      final a = File('${target.path}.bak')..writeAsStringSync('A');
      final b = File('${target.path}.lsbak-deadbeef')..writeAsStringSync('B');
      await atomicReplace(makeTmp(2), target);
      expect(target.readAsBytesSync(), fill(16, 2));
      expect(a.readAsStringSync(), 'A');
      expect(b.readAsStringSync(), 'B');
    });

    test(
      'V3-backup-name: during the window the old bytes are in exactly one '
      '"<t>.lsbak-<hex>" (never "<t>.bak"), removed after the commit',
      () async {
        target.writeAsBytesSync(fill(16, 1));
        final tmp = makeTmp(2);
        String? seen;
        var n = 0;
        atomicRenameOverride = (from, to) async {
          n++;
          if (n == 1) throw os(to, 5, 'Access is denied.');
          if (n == 3) seen = names().join(',');
          await from.rename(to);
        };
        await atomicReplace(tmp, target);
        atomicRenameOverride = null;
        expect(
          seen,
          matches(RegExp(r'^notes\.txt\.lsbak-[0-9a-f]+,notes\.txt\.tmp$')),
        );
        expect(names(), ['notes.txt']);
      },
    );

    test('V3-double-failure: 2nd rename and restore fail: target absent, the '
        'old bytes sit in exactly one .lsbak-<hex>, tmp left for the caller, '
        'error is the FIRST one', () async {
      target.writeAsBytesSync(fill(16, 1));
      final tmp = makeTmp(2);
      var n = 0;
      atomicRenameOverride = (from, to) async {
        n++;
        if (n == 2) {
          await from.rename(to);
          return;
        }
        throw os(to, 5, n == 1 ? 'FIRST' : 'LATER-$n');
      };
      await expectLater(
        atomicReplace(tmp, target),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.osError?.message,
            'message',
            'FIRST',
          ),
        ),
      );
      atomicRenameOverride = null;
      final left = names();
      expect(left.where((x) => x.contains('.lsbak-')), hasLength(1));
      expect(left, contains('notes.txt.tmp'));
      expect(target.existsSync(), isFalse);
      final bakName = left.firstWhere((x) => x.contains('.lsbak-'));
      expect(File(p.join(dir.path, bakName)).readAsBytesSync(), fill(16, 1));
    });

    test(
      'V3-crash-window: commit hangs forever (process dies): the old bytes '
      'are in one .lsbak-<hex>, the new in .tmp, target absent - and '
      'recoverAtomicBackup (fixed name only) does NOT find it (known limit)',
      () async {
        target.writeAsBytesSync(fill(16, 1));
        final tmp = makeTmp(2);
        var n = 0;
        final hang = Completer<void>();
        atomicRenameOverride = (from, to) async {
          n++;
          if (n == 1) throw os(to, 5, 'Access is denied.');
          if (n == 2) {
            await from.rename(to);
            return;
          }
          await hang.future;
        };
        unawaited(atomicReplace(tmp, target).catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final seen = names();
        atomicRenameOverride = null;
        expect(target.existsSync(), isFalse);
        expect(seen.where((x) => x.contains('.lsbak-')), hasLength(1));
        expect(seen, contains('notes.txt.tmp'));
        expect(await recoverAtomicBackup(target), isFalse);
      },
    );
  });

  group('errno list', () {
    for (final code in [30, 122]) {
      test('V3-errno-$code: errno $code (EROFS/EDQUOT) on tmp->target with an '
          'existing target: ONE attempt, target never missing', () async {
        target.writeAsBytesSync(fill(16, 1));
        final tmp = makeTmp(2);
        final log = RenameLog();
        var missing = false;
        atomicRenameOverride = (from, to) async {
          log.calls.add((from: from.path, to: to));
          if (!target.existsSync()) missing = true;
          throw os(to, code);
        };
        await expectLater(
          atomicReplace(tmp, target),
          throwsA(isA<FileSystemException>()),
        );
        atomicRenameOverride = null;
        expect(log.calls, hasLength(1));
        expect(missing, isFalse);
        expect(target.readAsBytesSync(), fill(16, 1));
      }, skip: Platform.isWindows ? 'POSIX errno values' : null);
    }

    test('V3-errno-5-still-falls-back: EIO(5) takes the fallback (the '
        'tester\'s simulations rely on it)', () async {
      target.writeAsBytesSync(fill(16, 1));
      var first = true;
      atomicRenameOverride = (from, to) async {
        if (first) {
          first = false;
          throw os(to, 5);
        }
        await from.rename(to);
      };
      await atomicWriteBytes(target, fill(16, 3));
      atomicRenameOverride = null;
      expect(target.readAsBytesSync(), fill(16, 3));
      expect(names(), ['notes.txt']);
    });
  });

  group('fixedBak split (atomicWriteBytes keeps the fixed name)', () {
    test('V3-fixed-in-write: atomicWriteBytes window uses "<t>.bak" and a '
        'stale "<t>.bak" is replaced, not a ".lsbak-" name', () async {
      target.writeAsBytesSync(fill(16, 1));
      File('${target.path}.bak').writeAsBytesSync(fill(16, 9)); // stale
      String? seen;
      var n = 0;
      atomicRenameOverride = (from, to) async {
        n++;
        if (n == 1) throw os(to, 5);
        if (n == 3) seen = names().join(',');
        await from.rename(to);
      };
      await atomicWriteBytes(target, fill(16, 2));
      atomicRenameOverride = null;
      expect(
        seen,
        'notes.txt,notes.txt.bak,notes.txt.tmp'.replaceFirst('notes.txt,', ''),
      );
      expect(target.readAsBytesSync(), fill(16, 2));
      expect(names(), ['notes.txt']);
    });
  });

  group('attempts to break it', () {
    test('V3-other-filesystem: a REAL cross-device rename (/dev/shm -> temp) '
        'with an existing target: error, ONE rename, old target intact, '
        'target never missing', () async {
      final shm = Directory('/dev/shm');
      if (!shm.existsSync() ||
          shm.statSync().type != FileSystemEntityType.directory) {
        markTestSkipped('no /dev/shm');
        return;
      }
      final other = Directory('/dev/shm').createTempSync('ls_verif_v3_');
      addTearDown(() => other.deleteSync(recursive: true));
      final dirDev = Process.runSync('stat', ['-c', '%d', dir.path]).stdout;
      final shmDev = Process.runSync('stat', ['-c', '%d', other.path]).stdout;
      if (dirDev == shmDev) {
        markTestSkipped('same device');
        return;
      }
      target.writeAsBytesSync(fill(16, 1));
      final tmp = File(p.join(other.path, 'x.tmp'))
        ..writeAsBytesSync(fill(16, 2));
      var renames = 0;
      var missing = false;
      atomicRenameOverride = (from, to) async {
        renames++;
        if (!target.existsSync()) missing = true;
        await from.rename(to);
      };
      FileSystemException? err;
      try {
        await atomicReplace(tmp, target);
      } on FileSystemException catch (e) {
        err = e;
      }
      atomicRenameOverride = null;
      expect(err, isNotNull);
      expect(err!.osError?.errorCode, 18);
      expect(renames, 1);
      expect(missing, isFalse);
      expect(target.readAsBytesSync(), fill(16, 1));
      expect(tmp.existsSync(), isTrue);
      expect(names(), ['notes.txt']);
    }, skip: Platform.isWindows ? 'POSIX only' : null);

    test('V3-symlink-target: target is a symlink to real.json: the link is '
        'replaced by a regular file, real.json is untouched (same as the '
        'pre-patch rename)', () async {
      final real = File(p.join(dir.path, 'real.json'))
        ..writeAsStringSync('REAL');
      Link(target.path).createSync('real.json');
      await atomicWriteBytes(target, fill(4, 7));
      expect(real.readAsStringSync(), 'REAL');
      expect(
        FileSystemEntity.typeSync(target.path, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(target.readAsBytesSync(), fill(4, 7));
      expect(names(), ['notes.txt', 'real.json']);
    }, skip: Platform.isWindows ? 'symlinks need privilege' : null);

    test(
      'V3-symlink-target-windows-like: symlink target + refusal: not a '
      'regular file, so no move-aside: error, link and real file intact',
      () async {
        final real = File(p.join(dir.path, 'real.json'))
          ..writeAsStringSync('REAL');
        Link(target.path).createSync('real.json');
        final tmp = makeTmp(5);
        atomicRenameOverride = windowsLikeRename(RenameLog());
        await expectLater(
          atomicReplace(tmp, target),
          throwsA(isA<FileSystemException>()),
        );
        atomicRenameOverride = null;
        expect(real.readAsStringSync(), 'REAL');
        expect(
          FileSystemEntity.typeSync(target.path, followLinks: false),
          FileSystemEntityType.link,
        );
      },
      skip: Platform.isWindows ? 'symlinks need privilege' : null,
    );

    test(
      'V3-readonly-dir-write: read-only directory: atomicWriteBytes '
      'throws, old target intact, no litter',
      () async {
        target.writeAsBytesSync(fill(16, 1));
        Process.runSync('chmod', ['555', dir.path]);
        await expectLater(
          atomicWriteBytes(target, fill(16, 2)),
          throwsA(isA<FileSystemException>()),
        );
        Process.runSync('chmod', ['755', dir.path]);
        expect(target.readAsBytesSync(), fill(16, 1));
        expect(names(), ['notes.txt']);
      },
      skip:
          (Platform.isWindows ||
              Process.runSync('id', ['-u']).stdout.toString().trim() == '0')
          ? 'needs POSIX non-root'
          : null,
    );

    test(
      'V3-readonly-dir-replace: read-only directory with tmp+target '
      'present: atomicReplace throws, BOTH files intact, no backup',
      () async {
        target.writeAsBytesSync(fill(16, 1));
        final tmp = makeTmp(2);
        Process.runSync('chmod', ['555', dir.path]);
        await expectLater(
          atomicReplace(tmp, target),
          throwsA(isA<FileSystemException>()),
        );
        Process.runSync('chmod', ['755', dir.path]);
        expect(target.readAsBytesSync(), fill(16, 1));
        expect(tmp.readAsBytesSync(), fill(16, 2));
        expect(names(), ['notes.txt', 'notes.txt.tmp']);
      },
      skip:
          (Platform.isWindows ||
              Process.runSync('id', ['-u']).stdout.toString().trim() == '0')
          ? 'needs POSIX non-root'
          : null,
    );

    test('V3-concurrent-replace: 6 UNQUEUED atomicReplace calls to one target '
        '(receiver style, Windows-like refusal): no exception other than '
        'FileSystemException, final target is the old or exactly one new '
        'payload, no backup litter, every un-consumed tmp still has its '
        'bytes', () async {
      target.writeAsBytesSync(fill(16, 1));
      final tmps = [for (var i = 0; i < 6; i++) makeTmp(10 + i, 't$i.tmp')];
      atomicRenameOverride = windowsLikeRename(RenameLog());
      final results = await Future.wait([
        for (final t in tmps)
          atomicReplace(
            t,
            target,
          ).then<Object?>((_) => 'ok', onError: (Object e) => e),
      ]);
      atomicRenameOverride = null;
      for (final r in results) {
        expect(r == 'ok' || r is FileSystemException, isTrue, reason: '$r');
      }
      final fin = target.readAsBytesSync();
      expect(fin.length, 16);
      expect(fin.every((x) => x == fin[0]), isTrue);
      expect([1, 10, 11, 12, 13, 14, 15], contains(fin[0]));
      expect(names().where((x) => x.contains('bak')), isEmpty);
      for (var i = 0; i < 6; i++) {
        if (tmps[i].existsSync()) {
          expect(tmps[i].readAsBytesSync(), fill(16, 10 + i));
        }
      }
      // ignore: avoid_print
      print(
        'V3-concurrent results: ${results.map((e) => e == 'ok' ? 'ok' : 'fail').toList()}',
      );
    });
  });
}

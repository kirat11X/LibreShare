// VERIFIER tests (E5 / R1b), written by the verifier agent, NOT by the tester
// and NOT by the coder. New file; no existing test is touched.
//
// Probes P1..P7 of the verifier brief. Tests whose names start with
// "FINDING" assert the DESIRED behaviour and are expected to be RED when the
// patch has the defect named in the test; the verifier report lists them.
// Everything else documents (and pins) the behaviour of the patched helper.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/storage/atomic_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/atomic_hooks.dart';

const int mode600 = 0x180;
int permBits(String path) => FileStat.statSync(path).mode & 0x1FF;
Uint8List fill(int n, int v) => Uint8List(n)..fillRange(0, n, v);

FileSystemException exdev(String to) => FileSystemException(
  'simulated cross-device rename',
  to,
  const OSError('Invalid cross-device link', 18),
);

void main() {
  late Directory dir;
  late File target;

  List<String> names([Directory? d]) =>
      (d ?? dir).listSync().map((e) => p.basename(e.path)).toList()..sort();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ls_verif_');
    target = File(p.join(dir.path, 'state.json'));
  });
  tearDown(() {
    atomicRenameOverride = null;
    dir.deleteSync(recursive: true);
  });

  group('P1 cross-filesystem (EXDEV) rename with an existing target', () {
    test('P1a helper-level: EXDEV on tmp->target, target exists: final bytes, '
        'litter, rename sequence and missing-target window', () async {
      target.writeAsBytesSync(fill(32, 1));
      final seq = <String>[];
      final missingAfter = <String>[];
      atomicRenameOverride = (from, to) async {
        final tag = '${p.basename(from.path)} -> ${p.basename(to)}';
        seq.add(tag);
        if (norm(to) == norm(target.path) && from.path.endsWith('.tmp')) {
          throw exdev(to);
        }
        await from.rename(to);
        if (!target.existsSync()) missingAfter.add(tag);
      };
      await expectLater(
        atomicWriteBytes(target, fill(32, 2)),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      // ignore: avoid_print
      print('P1a sequence: $seq');
      // ignore: avoid_print
      print('P1a target missing right after: $missingAfter');
      // ignore: avoid_print
      print('P1a dir after: ${names()}');
      // Safety properties (must hold):
      expect(target.readAsBytesSync(), fill(32, 1), reason: 'old bytes kept');
      expect(names(), ['state.json'], reason: 'no tmp/bak litter');
    });

    test('FINDING P1b needless move-aside: an EXDEV refusal must not move the '
        'old target away (the target must never be missing)', () async {
      target.writeAsBytesSync(fill(32, 1));
      var everMissing = false;
      atomicRenameOverride = (from, to) async {
        if (norm(to) == norm(target.path) && from.path.endsWith('.tmp')) {
          throw exdev(to);
        }
        await from.rename(to);
        if (!target.existsSync()) everMissing = true;
      };
      await expectLater(
        atomicWriteBytes(target, fill(32, 2)),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      expect(
        everMissing,
        isFalse,
        reason: 'target was moved to a .bak file although the error was EXDEV',
      );
    });

    test('P1c FileReceiver partialDir fallback still works with an existing '
        'target (race: target appears while the first rename fails)', () async {
      final dl = Directory(p.join(dir.path, 'dl'))..createSync();
      final pd = Directory(p.join(dir.path, 'pd'))..createSync();
      final tgt = File(p.join(dl.path, 'got.bin'));
      var raised = false;
      atomicRenameOverride = (from, to) async {
        // First rename of the .lspart out of partialDir: EXDEV, and a
        // competing file appears at the target meanwhile.
        if (from.path.endsWith('.lspart') &&
            norm(from.path).startsWith(norm(pd.path))) {
          if (!raised) tgt.writeAsBytesSync([9, 9, 9]);
          raised = true;
          throw exdev(to); // every attempt from partialDir fails, as for real
        }
        await from.rename(to);
      };
      final data = List<int>.generate(2000, (i) => (i * 31) % 251);
      final out = await _receiveOne(dl, pd, data, 'got.bin');
      atomicRenameOverride = null;
      expect(raised, isTrue);
      expect(out.readAsBytesSync(), data);
      expect(
        names(dl).where((n) => n.contains('lspart') || n.contains('.bak')),
        isEmpty,
      );
      expect(names(pd).where((n) => n.endsWith('.lspart')), isEmpty);
    });

    test('P1d FileReceiver partialDir fallback, no existing target (normal '
        'cross-device case)', () async {
      final dl = Directory(p.join(dir.path, 'dl'))..createSync();
      final pd = Directory(p.join(dir.path, 'pd'))..createSync();
      var raised = false;
      atomicRenameOverride = (from, to) async {
        if (from.path.endsWith('.lspart') &&
            norm(from.path).startsWith(norm(pd.path))) {
          raised = true;
          throw exdev(to); // every attempt from partialDir fails, as for real
        }
        await from.rename(to);
      };
      final data = List<int>.generate(1500, (i) => (i * 13) % 251);
      final out = await _receiveOne(dl, pd, data, 'got.bin');
      atomicRenameOverride = null;
      expect(raised, isTrue);
      expect(out.readAsBytesSync(), data);
      expect(names(dl), ['got.bin']);
      expect(names(pd).where((n) => n.endsWith('.lspart')), isEmpty);
    });
  });

  group('P2 symlink / directory named <target>.tmp', () {
    test('P2a symlinked tmp (v2 contract): the link is removed, the OTHER '
        'file is untouched, the target is a regular file with the new bytes; '
        '(the pre-patch code wrote through the link, printed for comparison)', () async {
      final other = File(p.join(dir.path, 'other.txt'))
        ..writeAsStringSync('KEEP-ME');
      Link('${target.path}.tmp').createSync('other.txt');
      await atomicWriteBytes(target, utf8.encode('NEW'));
      expect(other.readAsStringSync(), 'KEEP-ME');
      expect(
        FileSystemEntity.typeSync(target.path, followLinks: false),
        FileSystemEntityType.file,
      );
      expect(target.readAsStringSync(), 'NEW');
      expect(names(), ['other.txt', 'state.json']);
      // Characterise the OLD code (replica of the pre-patch writeFileAtomically).
      final dir2 = Directory(p.join(dir.path, 'old'))..createSync();
      final t2 = File(p.join(dir2.path, 'state.json'));
      final other2 = File(p.join(dir2.path, 'other.txt'))
        ..writeAsStringSync('KEEP-ME');
      Link('${t2.path}.tmp').createSync('other.txt');
      await _oldWrite(t2, utf8.encode('NEW'));
      // ignore: avoid_print
      print(
        'P2a OLD code: other.txt="${other2.readAsStringSync()}" '
        'target type=${FileSystemEntity.typeSync(t2.path, followLinks: false)}',
      );
    });

    test('FINDING P2b symlinked tmp must not write THROUGH the link: the other '
        'file must stay untouched', () async {
      final other = File(p.join(dir.path, 'other.txt'))
        ..writeAsStringSync('KEEP-ME');
      Link('${target.path}.tmp').createSync('other.txt');
      await atomicWriteBytes(target, utf8.encode('NEW'));
      expect(other.readAsStringSync(), 'KEEP-ME');
    });

    test('P2c a directory named <target>.tmp: write throws, directory and old '
        'target untouched', () async {
      target.writeAsStringSync('OLD');
      final d = Directory('${target.path}.tmp')..createSync();
      File(p.join(d.path, 'inner')).writeAsStringSync('X');
      await expectLater(
        atomicWriteBytes(target, utf8.encode('NEW')),
        throwsA(isA<FileSystemException>()),
      );
      expect(target.readAsStringSync(), 'OLD');
      expect(File(p.join(d.path, 'inner')).readAsStringSync(), 'X');
    });
  });

  group('P3 double failure / crash between the two renames', () {
    test('P3a second rename throws AND the restore throws: where do the old '
        'bytes live?', () async {
      target.writeAsBytesSync(fill(40, 5));
      var n = 0;
      atomicRenameOverride = (from, to) async {
        n++;
        // 1: tmp->target refused; 2: target->bak real; 3: tmp->target
        // refused; 4: bak->target (restore) refused.
        if (n == 2) {
          await from.rename(to);
          return;
        }
        throw FileSystemException(
          'simulated',
          to,
          const OSError('Access is denied.', 5),
        );
      };
      await expectLater(
        atomicWriteBytes(target, fill(40, 6)),
        throwsA(isA<FileSystemException>()),
      );
      atomicRenameOverride = null;
      final left = names();
      // ignore: avoid_print
      print('P3a dir after: $left; target exists=${target.existsSync()}');
      // v2 contract: exactly one fixed-name <target>.bak holds the old bytes,
      // no random .bak-<hex> names, target absent, tmp removed.
      expect(left, ['state.json.bak']);
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.bak').readAsBytesSync(), fill(40, 5));
    });

    test(
      'P3b "crash" with rename 3 hanging forever: state a restart finds',
      () async {
        target.writeAsBytesSync(fill(40, 5));
        var n = 0;
        final hang = Completer<void>();
        atomicRenameOverride = (from, to) async {
          n++;
          if (n == 1) {
            throw FileSystemException(
              'simulated',
              to,
              const OSError('Access is denied.', 5),
            );
          }
          if (n == 2) {
            await from.rename(to);
            return;
          }
          await hang.future; // never completes: the process "dies" here
        };
        unawaited(atomicWriteBytes(target, fill(40, 6)).catchError((_) {}));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final seen = names();
        // ignore: avoid_print
        print('P3b dir at crash: $seen; target exists=${target.existsSync()}');
        expect(target.existsSync(), isFalse);
        // v2 contract: the old bytes live in exactly one <target>.bak (the
        // new bytes are still in <target>.tmp), no .bak-<hex> names.
        expect(seen, ['state.json.bak', 'state.json.tmp']);
        expect(File('${target.path}.bak').readAsBytesSync(), fill(40, 5));
        expect(seen.where((x) => x.contains('.bak-')), isEmpty);
        atomicRenameOverride = null;
      },
    );

    test('FINDING P3c nobody recovers a stray .bak-<hex>: after a failed '
        'restore, a later successful write must not leave the old data '
        'orphaned forever', () async {
      target.writeAsBytesSync(fill(40, 5));
      var n = 0;
      atomicRenameOverride = (from, to) async {
        n++;
        if (n == 2) {
          await from.rename(to);
          return;
        }
        throw FileSystemException(
          'simulated',
          to,
          const OSError('Access is denied.', 5),
        );
      };
      await atomicWriteBytes(target, fill(40, 6)).catchError((_) {});
      atomicRenameOverride = null;
      await atomicWriteBytes(target, fill(40, 7)); // next run, healthy FS
      expect(
        names().where((x) => x.contains('.bak-')),
        isEmpty,
        reason: 'orphaned backup remains (no startup recovery/cleanup)',
      );
    });
  });

  group('P4 concurrency', () {
    test('two writers to one target are serialised, a writer to ANOTHER '
        'target is not delayed behind them (no global lock)', () async {
      final a = File(p.join(dir.path, 'a.json'));
      final b = File(p.join(dir.path, 'b.json'));
      final gate = Completer<void>();
      final events = <String>[];
      atomicRenameOverride = (from, to) async {
        if (norm(to) == norm(a.path)) {
          events.add('enter ${from.path.hashCode}');
          await gate.future;
          await from.rename(to);
          events.add('exit');
        } else {
          await from.rename(to);
        }
      };
      final a1 = atomicWriteBytes(a, fill(1000, 1));
      final a2 = atomicWriteBytes(a, fill(1000, 2));
      final bDone = atomicWriteBytes(
        b,
        fill(1000, 3),
      ).timeout(const Duration(seconds: 3));
      await bDone; // would time out if B queued behind A
      expect(b.readAsBytesSync(), fill(1000, 3));
      expect(a.existsSync(), isFalse, reason: 'A still blocked in rename');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(events, hasLength(1), reason: 'A2 must not enter while A1 holds');
      gate.complete();
      await Future.wait([a1, a2]);
      atomicRenameOverride = null;
      expect(events, [
        'enter ${events[0].split(' ')[1]}',
        'exit',
        events[2],
        'exit',
      ]);
      expect(a.readAsBytesSync(), fill(1000, 2), reason: 'last writer wins');
      expect(names(), ['a.json', 'b.json']);
    });

    test('FINDING P4b the same target spelled two ways (./ and plain) must '
        'also be serialised', () async {
      final alias = File(p.join(dir.path, '.', 'state.json'));
      final jobs = <Future<void>>[];
      for (var i = 0; i < 6; i++) {
        jobs.add(atomicWriteBytes(i.isEven ? target : alias, fill(200000, i)));
      }
      Object? err;
      try {
        await Future.wait(jobs);
      } on Object catch (e) {
        err = e;
      }
      expect(err, isNull, reason: 'shared tmp path raced');
      final fin = target.readAsBytesSync();
      expect(fin.length, 200000);
      expect(fin.every((x) => x == fin[0]), isTrue);
      expect(names(), ['state.json']);
    });
  });

  group('P5 edge targets', () {
    test('directory does not exist: throws FileSystemException, nothing '
        'created', () async {
      final t = File(p.join(dir.path, 'nope', 'deeper', 's.json'));
      await expectLater(
        atomicWriteBytes(t, [1]),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(p.join(dir.path, 'nope')).existsSync(), isFalse);
    });

    test('path with spaces and non-ASCII characters (fresh and replace, also '
        'with a Windows-like rename)', () async {
      final d = Directory(p.join(dir.path, 'my dir', 'Zażółć gęślą jaźń 日本'))
        ..createSync(recursive: true);
      final t = File(p.join(d.path, 'état #1 & "q".json'));
      await atomicWriteBytes(t, [1, 2, 3]);
      await atomicWriteBytes(t, [4, 5]);
      expect(t.readAsBytesSync(), [4, 5]);
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await atomicWriteBytes(t, [6]);
      atomicRenameOverride = null;
      expect(t.readAsBytesSync(), [6]);
      expect(names(d), [p.basename(t.path)]);
    });

    test('0-byte write on absent and on existing target', () async {
      await atomicWriteBytes(target, const []);
      expect(target.lengthSync(), 0);
      target.writeAsBytesSync([1, 2]);
      await atomicWriteBytes(target, const []);
      expect(target.lengthSync(), 0);
      expect(names(), ['state.json']);
    });

    test('10 MiB write is byte-exact (sha256) and leaves no litter', () async {
      final big = Uint8List(10 * 1024 * 1024);
      for (var i = 0; i < big.length; i++) {
        big[i] = (i * 2654435761 >> 7) & 0xFF;
      }
      await atomicWriteBytes(target, big);
      expect(sha256.convert(target.readAsBytesSync()), sha256.convert(big));
      await atomicWriteBytes(target, big.sublist(0, 1000));
      expect(target.lengthSync(), 1000);
      expect(names(), ['state.json']);
    });
  });

  group('P6 permissions', () {
    final skip = Platform.isWindows ? 'POSIX permission bits' : null;

    test('mode 0600: the tmp is 0600 and EMPTY inside prepareTmp, 0600 when '
        'committed, 0600 after', () async {
      int? permAtPrepare;
      int? lenAtPrepare;
      int? permAtCommit;
      int? lenAtCommit;
      atomicRenameOverride = (from, to) async {
        if (norm(to) == norm(target.path)) {
          permAtCommit = permBits(from.path);
          lenAtCommit = from.lengthSync();
        }
        await from.rename(to);
      };
      await atomicWriteBytes(
        target,
        fill(4096, 3),
        mode: mode600,
        prepareTmp: (tmp) async {
          permAtPrepare = permBits(tmp.path);
          lenAtPrepare = tmp.lengthSync();
        },
      );
      atomicRenameOverride = null;
      expect(permAtPrepare, 384);
      expect(lenAtPrepare, 0);
      expect(permAtCommit, 384);
      expect(lenAtCommit, 4096);
      expect(permBits(target.path), 384);
    }, skip: skip);

    test('mode 0600 also when a 0644 target exists and a Windows-like rename '
        'forces the move-aside path (the .bak keeps the OLD mode)', () async {
      target.writeAsBytesSync([1]);
      Process.runSync('chmod', ['644', target.path]);
      atomicRenameOverride = windowsLikeRename(RenameLog());
      await atomicWriteBytes(target, fill(100, 4), mode: mode600);
      atomicRenameOverride = null;
      expect(permBits(target.path), 384);
      expect(names(), ['state.json']);
    }, skip: skip);

    test('FileSecretStore: the 0600 chmod of the tmp happens while the tmp '
        'is still empty; committed file is 0600 and dir 0700', () async {
      final seen = <String>[];
      final store = FileSecretStore(
        Directory(p.join(dir.path, 'sec')),
        chmod: (mode, path) async {
          final f = File(path);
          seen.add(
            '$mode ${p.basename(path)} len=${f.existsSync() ? f.lengthSync() : -1}',
          );
          final r = await Process.run('chmod', [mode, path]);
          return r.exitCode;
        },
      );
      final commitPerms = <int>[];
      final commitLens = <int>[];
      atomicRenameOverride = (from, to) async {
        if (from.path.endsWith('.tmp')) {
          commitPerms.add(permBits(from.path));
          commitLens.add(from.lengthSync());
        }
        await from.rename(to);
      };
      await store.put('pin', Uint8List.fromList(fill(64, 8)));
      await store.put('pin', Uint8List.fromList(fill(64, 9)));
      atomicRenameOverride = null;
      // ignore: avoid_print
      print('P6 chmod calls: $seen');
      final tmpCalls = seen.where((s) => s.contains('.tmp')).toList();
      expect(tmpCalls, hasLength(2));
      for (final c in tmpCalls) {
        expect(c, startsWith('600 '));
        expect(c, endsWith('len=0'));
      }
      expect(commitPerms, [384, 384]);
      expect(commitLens.every((l) => l > 0), isTrue);
      expect(permBits(store.fileFor('pin').path), 384);
      expect(permBits(store.directory.path), 448);
    }, skip: skip);

    test('FileSecretStore: chmod failure -> SecretStoreException, no tmp, OLD '
        'secret intact', () async {
      var fail = false;
      final store = FileSecretStore(
        Directory(p.join(dir.path, 'sec')),
        chmod: (mode, path) async {
          if (fail && path.endsWith('.tmp')) return 1;
          return (await Process.run('chmod', [mode, path])).exitCode;
        },
      );
      await store.put('pin', Uint8List.fromList([1, 2, 3]));
      fail = true;
      await expectLater(
        store.put('pin', Uint8List.fromList([9, 9])),
        throwsA(isA<SecretStoreException>()),
      );
      fail = false;
      expect(await store.get('pin'), [1, 2, 3]);
      expect(names(store.directory), [p.basename(store.fileFor('pin').path)]);
    }, skip: skip);
  });
}

/// Replica of the pre-patch `writeFileAtomically` (for behaviour comparison).
Future<void> _oldWrite(File target, List<int> data) async {
  final tmp = File('${target.path}.tmp');
  try {
    await tmp.create();
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeFrom(data);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await tmp.rename(target.path);
  } on Object {
    try {
      await tmp.delete();
    } on Object {
      // best effort
    }
    rethrow;
  }
}

List<String> names(Directory d) =>
    d.listSync().map((e) => p.basename(e.path)).toList()..sort();

Future<File> _receiveOne(
  Directory dl,
  Directory pd,
  List<int> data,
  String name,
) async {
  const cs = 64 * 1024;
  const self = DeviceInfo(deviceId: 'rx', alias: 'R', platform: 'linux');
  const tx = DeviceInfo(deviceId: 'tx', alias: 'S', platform: 'linux');
  final rx = FileReceiver(
    self: self,
    downloadDir: dl,
    partialDir: pd,
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
      chunkSize: cs,
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

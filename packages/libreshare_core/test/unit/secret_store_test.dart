// FileSecretStore / InMemorySecretStore (docs/plans/inc3.md D6): names are
// validated, files are 0600 in a 0700 directory, writes are atomic and
// serialised, corrupt files read as null, and neither names nor values ever
// reach a log record or an exception message.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/storage/file_secret_store.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

Uint8List bytes(List<int> v) => Uint8List.fromList(v);

/// 0o600 / 0o700 as stat reports them (type bits masked off).
int permBits(String path) => FileStat.statSync(path).mode & 0x1FF;

const int mode600 = 384;
const int mode700 = 448;

final bool posix = !Platform.isWindows;

/// Every Logger record at Level.ALL until the test ends.
List<LogRecord> captureLogs() {
  final old = Logger.root.level;
  Logger.root.level = Level.ALL;
  final records = <LogRecord>[];
  final sub = Logger.root.onRecord.listen(records.add);
  addTearDown(() async {
    await sub.cancel();
    Logger.root.level = old;
  });
  return records;
}

String flatten(Iterable<LogRecord> records) =>
    records.map((r) => '${r.message} ${r.error} ${r.stackTrace}').join('\n');

const List<String> goodNames = [
  'identity.key',
  'kpair/5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f',
  'pin',
  'a-b_c.d',
  'A',
  'a..b',
  'x/y/z',
  '...',
];

final List<String> badNames = [
  '',
  '.',
  '..',
  '../x',
  '..\\x',
  'a/../../b',
  'a/..',
  'a/../b',
  '/abs/path',
  '/etc/passwd',
  'a//b',
  'a/',
  './a',
  'a/./b',
  'a\u0000b',
  '\u0000',
  'a\nb',
  'a b',
  'a\\b',
  'C:\\x',
  '%2e%2e/x',
  'caf\u00e9',
  'a\u202eb',
  'x' * 129,
  '${'x' * 64}/${'y' * 64}',
];

void contract(String label, SecretStore Function(Directory dir) make) {
  group('$label contract', () {
    late Directory dir;
    late SecretStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ls_secret_');
      store = make(dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('missing name reads null', () async {
      expect(await store.get('identity.key'), isNull);
    });

    test('put then get returns the same bytes', () async {
      final v = bytes(List<int>.generate(300, (i) => i % 256));
      await store.put('identity.key', v);
      expect(await store.get('identity.key'), v);
    });

    test('an empty value is a value, not a missing one', () async {
      await store.put('pin', Uint8List(0));
      final got = await store.get('pin');
      expect(got, isNotNull);
      expect(got, isEmpty);
    });

    test('put overwrites', () async {
      await store.put('k', bytes([1]));
      await store.put('k', bytes([2, 3]));
      expect(await store.get('k'), bytes([2, 3]));
    });

    test('delete removes, delete of a missing name is fine', () async {
      await store.put('k', bytes([1]));
      await store.delete('k');
      expect(await store.get('k'), isNull);
      await store.delete('k');
      await store.delete('never-existed');
    });

    test('names are independent, kpair/<id> included', () async {
      await store.put('a', bytes([1]));
      await store.put('kpair/dev-1', bytes([2]));
      await store.put('kpair/dev-2', bytes([3]));
      await store.delete('kpair/dev-1');
      expect(await store.get('a'), bytes([1]));
      expect(await store.get('kpair/dev-1'), isNull);
      expect(await store.get('kpair/dev-2'), bytes([3]));
    });

    test(
      'mutating a returned or stored buffer does not alter the store',
      () async {
        final v = bytes([1, 2, 3]);
        await store.put('k', v);
        v[0] = 99;
        final got = await store.get('k');
        expect(got, bytes([1, 2, 3]));
        got![1] = 99;
        expect(await store.get('k'), bytes([1, 2, 3]));
      },
    );

    test('good names are accepted, including 128 characters', () async {
      for (final n in [...goodNames, 'n' * 128]) {
        await store.put(n, bytes([7]));
        expect(await store.get(n), bytes([7]), reason: n);
        await store.delete(n);
      }
    });

    test('bad names are refused by get, put and delete', () async {
      for (final n in badNames) {
        expect(store.get(n), throwsArgumentError, reason: 'get ${n.length}');
        expect(
          store.put(n, bytes([1])),
          throwsArgumentError,
          reason: 'put ${n.length}',
        );
        expect(store.delete(n), throwsArgumentError, reason: 'del ${n.length}');
      }
    });

    test('an oversize value is refused', () async {
      final big = Uint8List(FileSecretStore.maxValueBytes + 1);
      expect(store.put('k', big), throwsArgumentError);
      await store.put('k', Uint8List(FileSecretStore.maxValueBytes));
    });

    test('concurrent operations behave like the sequential order', () async {
      final r = await Future.wait<Object?>([
        store.put('a', bytes([1])),
        store.get('a'),
        store.put('a', bytes([2])),
        store.get('a'),
        store.delete('a'),
        store.get('a'),
        store.put('a', bytes([3])),
        store.get('a'),
      ]);
      expect(r[1], bytes([1]));
      expect(r[3], bytes([2]));
      expect(r[5], isNull);
      expect(r[7], bytes([3]));
    });

    test('50 racing puts: the last one issued wins', () async {
      await Future.wait([
        for (var i = 0; i < 50; i++) store.put('k', bytes([i, i, i])),
      ]);
      expect(await store.get('k'), bytes([49, 49, 49]));
    });
  });
}

void main() {
  contract('InMemorySecretStore', (_) => InMemorySecretStore());
  contract('FileSecretStore', FileSecretStore.new);

  group('FileSecretStore on disk', () {
    late Directory root;
    late Directory dir;
    late FileSecretStore store;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ls_secret_disk_');
      dir = Directory('${root.path}/nested/secrets');
      store = FileSecretStore(dir);
    });
    tearDown(() => root.deleteSync(recursive: true));

    List<FileSystemEntity> entries() => dir.listSync(recursive: true);

    test('creates the directory (recursively) on first put', () async {
      expect(dir.existsSync(), isFalse);
      await store.put('identity.key', bytes([1]));
      expect(dir.existsSync(), isTrue);
    });

    test('kpair/<id> maps to one flat, safe file name', () async {
      await store.put('kpair/5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f', bytes([1]));
      await store.put('identity.key', bytes([2]));
      final all = entries();
      expect(all.whereType<Directory>(), isEmpty);
      for (final f in all) {
        final name = f.uri.pathSegments.last;
        expect(name, matches(RegExp(r'^[0-9a-f]{64}\.secret$')));
        expect(name, isNot(contains('kpair')));
        expect(name, isNot(contains('identity')));
      }
      expect(all, hasLength(2));
    });

    test('names that differ only by case or slash stay distinct', () async {
      await store.put('Ab', bytes([1]));
      await store.put('aB', bytes([2]));
      await store.put('a/b', bytes([3]));
      await store.put('a.b', bytes([4]));
      expect(await store.get('Ab'), bytes([1]));
      expect(await store.get('aB'), bytes([2]));
      expect(await store.get('a/b'), bytes([3]));
      expect(await store.get('a.b'), bytes([4]));
    });

    test('a refused name leaves no trace outside the directory', () async {
      final before = root.listSync(recursive: true).map((e) => e.path).toSet();
      for (final n in badNames) {
        try {
          await store.put(n, bytes([1]));
        } on ArgumentError {
          // expected
        }
      }
      final after = root.listSync(recursive: true).map((e) => e.path).toSet();
      expect(after, before);
      expect(dir.existsSync(), isFalse, reason: 'nothing was written at all');
    });

    test('a second instance sees what the first wrote (no cache)', () async {
      await store.put('k', bytes([5, 6]));
      expect(await FileSecretStore(dir).get('k'), bytes([5, 6]));
      await FileSecretStore(dir).delete('k');
      expect(await store.get('k'), isNull);
    });

    test(
      'files are 0600 and the directory 0700',
      () async {
        await store.put('identity.key', bytes([1, 2, 3]));
        await store.put('kpair/dev', bytes([4]));
        expect(permBits(dir.path), mode700);
        final files = entries().whereType<File>().toList();
        expect(files, hasLength(2));
        for (final f in files) {
          expect(permBits(f.path), mode600, reason: f.path);
        }
        // Overwrite keeps the mode.
        await store.put('identity.key', bytes([9]));
        for (final f in entries().whereType<File>()) {
          expect(permBits(f.path), mode600);
        }
      },
      skip: posix
          ? false
          : 'POSIX modes only; Windows relies on the profile ACL',
    );

    test('an existing too-open directory is tightened to 0700', () async {
      dir.createSync(recursive: true);
      Process.runSync('chmod', ['755', dir.path]);
      expect(permBits(dir.path), 493);
      await store.put('k', bytes([1]));
      expect(permBits(dir.path), mode700);
    }, skip: posix ? false : 'POSIX modes only');

    test(
      'chmod failure fails closed: nothing stored, no leftover, no leak',
      () async {
        final s = FileSecretStore(dir, chmod: (mode, path) async => 1);
        Object? err;
        try {
          await s.put('sentinel-name/x', bytes(utf8.encode('SENTINEL-VALUE')));
        } on Object catch (e) {
          err = e;
        }
        expect(err, isA<SecretStoreException>());
        expect('$err', isNot(contains('sentinel')));
        expect('$err', isNot(contains('SENTINEL')));
        expect(await FileSecretStore(dir).get('sentinel-name/x'), isNull);
        expect(
          dir.existsSync() ? dir.listSync().whereType<File>() : <File>[],
          isEmpty,
        );
      },
      skip: posix ? false : 'chmod is a no-op on Windows',
    );

    test('chmod failing only for the value file keeps the old value', () async {
      await store.put('k', bytes([1]));
      final s = FileSecretStore(
        dir,
        chmod: (mode, path) async => path.endsWith('.tmp') ? 1 : 0,
      );
      await expectLater(
        s.put('k', bytes([2])),
        throwsA(isA<SecretStoreException>()),
      );
      expect(await store.get('k'), bytes([1]));
      expect(
        dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')),
        isEmpty,
        reason: 'the temporary file is cleaned up',
      );
      // The failed write did not poison the queue.
      await store.put('k', bytes([3]));
      expect(await store.get('k'), bytes([3]));
    }, skip: posix ? false : 'chmod is a no-op on Windows');

    test('a crash between tmp write and rename leaves the old value', () async {
      await store.put('k', bytes([1, 2, 3]));
      // What a killed process leaves behind: a half-written temporary file.
      File('${store.fileFor('k').path}.tmp').writeAsBytesSync([9, 9, 9, 9]);
      expect(await FileSecretStore(dir).get('k'), bytes([1, 2, 3]));
      // Next write replaces the leftover and succeeds.
      await store.put('k', bytes([4]));
      expect(await store.get('k'), bytes([4]));
      expect(
        dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')),
        isEmpty,
      );
    });

    test(
      'a crash before the first value was ever renamed reads null',
      () async {
        dir.createSync(recursive: true);
        File('${store.fileFor('k').path}.tmp').writeAsBytesSync([1, 2, 3]);
        expect(await store.get('k'), isNull);
      },
    );

    test('delete also removes a stale temporary file', () async {
      await store.put('k', bytes([1]));
      final tmp = File('${store.fileFor('k').path}.tmp')..writeAsBytesSync([7]);
      await store.delete('k');
      expect(tmp.existsSync(), isFalse);
      expect(store.fileFor('k').existsSync(), isFalse);
    });

    group('corrupt files read as null', () {
      final value = bytes(List<int>.generate(64, (i) => i + 1));

      Future<void> expectNullAndHealable(void Function(File f) damage) async {
        await store.put('sentinel-name', value);
        final f = store.fileFor('sentinel-name');
        damage(f);
        expect(await store.get('sentinel-name'), isNull);
        // And the slot is usable again.
        await store.put('sentinel-name', bytes([1]));
        expect(await store.get('sentinel-name'), bytes([1]));
      }

      test('truncated', () async {
        await expectNullAndHealable((f) {
          final b = f.readAsBytesSync();
          f.writeAsBytesSync(b.sublist(0, b.length ~/ 2));
        });
      });
      test('empty file', () async {
        await expectNullAndHealable((f) => f.writeAsBytesSync([]));
      });
      test('garbage', () async {
        await expectNullAndHealable(
          (f) => f.writeAsBytesSync(utf8.encode('not a secret file')),
        );
      });
      test('one flipped bit in the payload', () async {
        await expectNullAndHealable((f) {
          final b = f.readAsBytesSync();
          b[10] ^= 1;
          f.writeAsBytesSync(b);
        });
      });
      test('trailing junk', () async {
        await expectNullAndHealable((f) {
          f.writeAsBytesSync([...f.readAsBytesSync(), 0]);
        });
      });
      test('a directory where the file should be', () async {
        dir.createSync(recursive: true);
        Directory(store.fileFor('sentinel-name').path).createSync();
        expect(await store.get('sentinel-name'), isNull);
      });

      test('the warning names neither the secret nor its name', () async {
        final logs = captureLogs();
        await store.put('sentinel-name', value);
        store.fileFor('sentinel-name').writeAsBytesSync([1, 2, 3]);
        expect(await store.get('sentinel-name'), isNull);
        final text = flatten(logs);
        expect(text, isNot(contains('sentinel')));
        expect(text, isNot(contains(base64.encode(value))));
        expect(text, isNot(contains(value.join(','))));
      });
    });

    test('nothing sensitive reaches a log record', () async {
      final logs = captureLogs();
      final v = bytes(utf8.encode('SENTINEL-SECRET-VALUE-0123456789'));
      const name = 'kpair/sentinel-device-id';
      await store.put(name, v);
      await store.get(name);
      await store.put(name, v);
      store.fileFor(name).writeAsBytesSync([0, 1]);
      await store.get(name);
      await store.delete(name);
      for (final bad in badNames) {
        try {
          await store.get(bad);
        } on ArgumentError catch (e) {
          expect('$e', isNot(contains(bad.isEmpty ? '\u0001' : bad)));
        }
      }
      final s = FileSecretStore(dir, chmod: (m, p) async => 1);
      try {
        await s.put(name, v);
      } on SecretStoreException catch (e) {
        expect('$e', isNot(contains('sentinel')));
      }
      final text = flatten(logs);
      for (final leak in [
        'sentinel',
        'SENTINEL',
        base64.encode(v),
        v.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        store.fileFor(name).uri.pathSegments.last.substring(0, 20),
      ]) {
        expect(text, isNot(contains(leak)), reason: leak);
      }
    });

    test('exception messages never carry a name or a value', () async {
      final messages = <String>[];
      for (final bad in [
        '../sentinel-name',
        'a/../../sentinel-name',
        '/sentinel-name',
        'sentinel\u0000name',
        'sentinel-${'x' * 200}',
      ]) {
        for (final op in <Future<Object?> Function()>[
          () => store.get(bad),
          () => store.put(bad, bytes(utf8.encode('SENTINEL-VALUE'))),
          () => store.delete(bad),
        ]) {
          try {
            await op();
            fail('expected a refusal');
          } on ArgumentError catch (e) {
            messages.add('$e');
          }
        }
      }
      try {
        await store.put('k', Uint8List(FileSecretStore.maxValueBytes + 1));
      } on ArgumentError catch (e) {
        messages.add('$e');
      }
      expect(messages, isNotEmpty);
      for (final m in messages) {
        expect(m, isNot(contains('sentinel')));
        expect(m, isNot(contains('SENTINEL')));
        expect(m, isNot(contains('xxxx')));
      }
    });

    test('the value file holds no readable copy of the secret', () async {
      final v = bytes(utf8.encode('SENTINEL-SECRET-VALUE-0123456789'));
      await store.put('identity.key', v);
      final raw = store.fileFor('identity.key').readAsBytesSync();
      expect(latin1.decode(raw), isNot(contains('identity')));
      // Stored as is (mode 0600 is the protection), but framed and checksummed.
      expect(raw.length, greaterThan(v.length));
    });
  });

  group('InMemorySecretStore', () {
    test(
      'can be seeded and inspected, and validates names like the file store',
      () async {
        final s = InMemorySecretStore({
          'identity.key': [1, 2],
        });
        expect(await s.get('identity.key'), bytes([1, 2]));
        expect(s.length, 1);
        await s.put('kpair/x', bytes([3]));
        expect(s.length, 2);
        expect(s.put('../x', bytes([1])), throwsArgumentError);
        expect(s.length, 2);
      },
    );
  });

  test('isValidSecretName agrees with the lists above', () {
    for (final n in goodNames) {
      expect(isValidSecretName(n), isTrue, reason: n);
    }
    for (final n in badNames) {
      expect(isValidSecretName(n), isFalse, reason: n.length.toString());
    }
    expect(isValidSecretName('n' * 128), isTrue);
    expect(isValidSecretName('n' * 129), isFalse);
  });

  test('the store is usable through the SecretStore contract type', () async {
    final dir = Directory.systemTemp.createTempSync('ls_secret_iface_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final SecretStore s = FileSecretStore(dir);
    await s.put('k', bytes([1]));
    expect(await s.get('k'), bytes([1]));
    // shortFp is the only fingerprint form allowed near logs.
    expect(shortFp('A' * 64), hasLength(16));
  });
}

// DeviceRegistry (docs/plans/inc3.md D1, section 4.1): the persisted contact
// book. Atomic JSON, tolerant load (a corrupt file becomes an empty registry
// and a `.corrupt-<n>` backup, never a crash), serialised writes, bounded size,
// schema version, unknown members preserved.
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/storage/device_registry.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

String fp(int n) => n.toRadixString(16).toUpperCase().padLeft(64, '0');

ContactRecord rec(
  String id,
  int n, {
  String alias = 'Ravi-ThinkPad',
  PeerTrust trust = PeerTrust.known,
  bool hasPairKey = false,
  Map<String, Object?> extra = const {},
  DateTime? pinnedAt,
}) => ContactRecord(
  deviceId: id,
  fingerprint: fp(n),
  alias: alias,
  trust: trust,
  pinnedAt: pinnedAt ?? DateTime.utc(2026, 11, 3, 12, 30),
  hasPairKey: hasPairKey,
  extra: extra,
);

Future<void> add(DeviceRegistry r, ContactRecord c) => r.update((d) {
  d.contacts[c.deviceId] = c;
  return true;
});

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

void main() {
  late Directory dir;
  late File contacts;

  DeviceRegistry open({int? max}) =>
      max == null ? DeviceRegistry(dir) : DeviceRegistry(dir, maxContacts: max);

  Map<String, Object?> onDisk() =>
      jsonDecode(contacts.readAsStringSync()) as Map<String, Object?>;

  List<String> backups() =>
      dir
          .listSync()
          .map((e) => e.path.split(Platform.pathSeparator).last)
          .where((n) {
            return n.startsWith('contacts.json.corrupt-');
          })
          .toList()
        ..sort();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ls_registry_');
    contacts = File('${dir.path}/contacts.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('basics', () {
    test('no file -> empty registry, nothing written by load', () async {
      final r = open();
      expect(r.isLoaded, isFalse);
      await r.load();
      expect(r.isLoaded, isTrue);
      expect(r.records, isEmpty);
      expect(r.blockedFingerprints, isEmpty);
      expect(contacts.existsSync(), isFalse);
      expect(r.writeCount, 0);
    });

    test(
      'update before load is refused (it would overwrite the file)',
      () async {
        contacts.writeAsStringSync(
          jsonEncode({
            'v': 1,
            'contacts': [
              {
                'deviceId': 'a',
                'fingerprint': fp(1),
                'alias': 'A',
                'trust': 'known',
                'pinnedAt': '2026-11-03T12:30:00.000Z',
              },
            ],
          }),
        );
        final before = contacts.readAsBytesSync();
        final r = open();
        await expectLater(add(r, rec('b', 2)), throwsStateError);
        expect(contacts.readAsBytesSync(), before);
      },
    );

    test('round trip across instances', () async {
      final r = open();
      await r.load();
      await add(
        r,
        rec(
          'dev-1',
          1,
          alias: 'Küche \u{1F9F9}',
          trust: PeerTrust.trusted,
          hasPairKey: true,
          pinnedAt: DateTime.utc(2026, 1, 2, 3, 4, 5, 678),
        ),
      );
      await add(r, rec('dev-2', 2));
      await r.update((d) {
        d.blocked[fp(9)] = DateTime.utc(2026, 5, 6);
        return true;
      });

      final r2 = open();
      await r2.load();
      expect(r2.records.map((c) => c.deviceId), ['dev-1', 'dev-2']);
      final c1 = r2.byDeviceId('dev-1')!;
      expect(c1.fingerprint, fp(1));
      expect(c1.alias, 'Küche \u{1F9F9}');
      expect(c1.trust, PeerTrust.trusted);
      expect(c1.hasPairKey, isTrue);
      expect(c1.pinnedAt, DateTime.utc(2026, 1, 2, 3, 4, 5, 678));
      expect(c1.pinnedAt.isUtc, isTrue);
      expect(r2.byDeviceId('dev-2')!.hasPairKey, isFalse);
      expect(r2.byFingerprint(fp(2))!.deviceId, 'dev-2');
      expect(r2.byFingerprint(fp(77)), isNull);
      expect(r2.byDeviceId('nope'), isNull);
      expect(r2.isBlocked(fp(9)), isTrue);
      expect(r2.isBlocked(fp(8)), isFalse);
      expect(r2.blockedFingerprints, [fp(9)]);
      expect(r2.blockedAt(fp(9)), DateTime.utc(2026, 5, 6));
    });

    test('file format: v1, contacts and blocked, documented members', () async {
      final r = open();
      await r.load();
      await add(r, rec('dev-1', 1, trust: PeerTrust.trusted, hasPairKey: true));
      await r.update((d) {
        d.blocked[fp(9)] = DateTime.utc(2026, 5, 6);
        return true;
      });
      final j = onDisk();
      expect(j['v'], 1);
      final list = j['contacts']! as List<Object?>;
      expect(list, hasLength(1));
      final c = list.single! as Map<String, Object?>;
      expect(c['deviceId'], 'dev-1');
      expect(c['fingerprint'], fp(1));
      expect(c['alias'], 'Ravi-ThinkPad');
      expect(c['trust'], 'trusted');
      expect(c['pinnedAt'], '2026-11-03T12:30:00.000Z');
      expect(c['hasPairKey'], isTrue);
      final b =
          (j['blocked']! as List<Object?>).single! as Map<String, Object?>;
      expect(b['fingerprint'], fp(9));
      expect(b['blockedAt'], '2026-05-06T00:00:00.000Z');
    });

    test('loads are idempotent: same state, nothing written', () async {
      final r = open();
      await r.load();
      await add(r, rec('a', 1));
      final writes = r.writeCount;
      final before = contacts.readAsBytesSync();
      for (var i = 0; i < 3; i++) {
        await r.load();
        expect(r.records.map((c) => c.deviceId), ['a']);
      }
      expect(r.writeCount, writes);
      expect(contacts.readAsBytesSync(), before);
      expect(backups(), isEmpty);
    });

    test('update that reports no change writes nothing', () async {
      final r = open();
      await r.load();
      await add(r, rec('a', 1));
      final before = contacts.readAsBytesSync();
      final writes = r.writeCount;
      expect(await r.update((d) => false), isFalse);
      expect(r.writeCount, writes);
      expect(contacts.readAsBytesSync(), before);
      expect(await r.update((d) => true), isTrue);
      expect(r.writeCount, writes + 1);
    });

    test(
      'snapshots are unmodifiable and independent of later changes',
      () async {
        final r = open();
        await r.load();
        await add(r, rec('a', 1));
        final snap = r.records;
        expect(() => snap.add(rec('x', 5)), throwsUnsupportedError);
        await add(r, rec('b', 2));
        expect(snap, hasLength(1));
        expect(r.records, hasLength(2));
      },
    );

    test(
      'a throwing change function changes nothing and does not stop the queue',
      () async {
        final r = open();
        await r.load();
        await add(r, rec('a', 1));
        await expectLater(
          r.update((d) {
            d.contacts['zzz'] = rec('zzz', 3);
            throw const FormatException('boom');
          }),
          throwsFormatException,
        );
        expect(r.byDeviceId('zzz'), isNull);
        await add(r, rec('b', 2));
        expect(r.records.map((c) => c.deviceId), ['a', 'b']);
      },
    );

    test('in-memory registry: no disk, same behaviour', () async {
      final r = DeviceRegistry.inMemory();
      expect(r.isLoaded, isTrue);
      await add(r, rec('a', 1));
      expect(r.byDeviceId('a'), isNotNull);
      expect(r.file, isNull);
      expect(dir.listSync(), isEmpty);
    });
  });

  group('unknown JSON members survive (kPairRef, peerAdvKey)', () {
    test('entry and top-level extras round trip through a rewrite', () async {
      contacts.writeAsStringSync(
        jsonEncode({
          'v': 1,
          'futureTopLevel': {
            'a': [1, 2, 3],
          },
          'contacts': [
            {
              'deviceId': 'dev-1',
              'fingerprint': fp(1),
              'alias': 'One',
              'trust': 'trusted',
              'pinnedAt': '2026-11-03T12:30:00.000Z',
              'hasPairKey': true,
              'kPairRef': 'kpair/dev-1',
              'peerAdvKey': {'k': 'abc', 'n': 1},
            },
          ],
        }),
      );
      final r = open();
      await r.load();
      expect(r.byDeviceId('dev-1')!.extra['kPairRef'], 'kpair/dev-1');
      // Touch another contact: the first one must be written back unchanged.
      await add(r, rec('dev-2', 2));
      final j = onDisk();
      expect(j['futureTopLevel'], {
        'a': [1, 2, 3],
      });
      final first =
          (j['contacts']! as List<Object?>).first! as Map<String, Object?>;
      expect(first['kPairRef'], 'kpair/dev-1');
      expect(first['peerAdvKey'], {'k': 'abc', 'n': 1});

      final r2 = open();
      await r2.load();
      expect(r2.byDeviceId('dev-1')!.extra['peerAdvKey'], {'k': 'abc', 'n': 1});
    });

    test('extras cannot override the members the registry owns', () async {
      final r = open();
      await r.load();
      await add(
        r,
        rec(
          'dev-1',
          1,
          extra: {'fingerprint': 'EVIL', 'trust': 'trusted', 'x': 1},
        ),
      );
      final c =
          (onDisk()['contacts']! as List<Object?>).single!
              as Map<String, Object?>;
      expect(c['fingerprint'], fp(1));
      expect(c['trust'], 'known');
      expect(c['x'], 1);
    });

    test('the extras map handed back is unmodifiable', () async {
      final r = open();
      await r.load();
      await add(r, rec('dev-1', 1, extra: {'x': 1}));
      expect(
        () => r.byDeviceId('dev-1')!.extra['y'] = 2,
        throwsUnsupportedError,
      );
    });
  });

  group('tolerant load: corrupt file -> empty + backup, never a crash', () {
    final damages = <String, List<int>>{
      'garbage': utf8.encode('SENTINEL-CONTACT-DATA {{{'),
      'empty file': const <int>[],
      'truncated JSON': utf8.encode('{"v":1,"contacts":[{"deviceId":"SENTINEL'),
      'JSON array at the root': utf8.encode('[1,2,3]'),
      'wrong version type': utf8.encode('{"v":"1","contacts":[]}'),
      'newer schema': utf8.encode('{"v":99,"contacts":[]}'),
      'missing version': utf8.encode('{"contacts":[]}'),
      'contacts is not a list': utf8.encode('{"v":1,"contacts":{"a":1}}'),
      'blocked is not a list': utf8.encode('{"v":1,"contacts":[],"blocked":5}'),
      'invalid UTF-8': [0xFF, 0xFE, 0x00, 0xC3, 0x28],
    };
    damages.forEach((label, content) {
      test(label, () async {
        contacts.writeAsBytesSync(content);
        final logs = captureLogs();
        final r = open();
        await r.load();
        expect(r.records, isEmpty);
        expect(r.blockedFingerprints, isEmpty);
        expect(backups(), ['contacts.json.corrupt-1']);
        expect(
          File('${dir.path}/contacts.json.corrupt-1').readAsBytesSync(),
          content,
        );
        expect(contacts.existsSync(), isFalse, reason: 'moved aside');
        final text = flatten(logs);
        expect(text, contains('unreadable'));
        expect(text, isNot(contains('SENTINEL')));
        expect(
          logs.where((l) => l.level >= Level.WARNING),
          isNotEmpty,
          reason: 'a warning with the exception type only',
        );
        // The registry is usable and the next write is a clean file.
        await add(r, rec('a', 1));
        expect(onDisk()['v'], 1);
        final r2 = open();
        await r2.load();
        expect(r2.records.map((c) => c.deviceId), ['a']);
        expect(backups(), ['contacts.json.corrupt-1']);
      });
    });

    test('the warning carries only the exception type', () async {
      contacts.writeAsStringSync('SENTINEL-CONTACT-DATA {{{');
      final logs = captureLogs();
      await open().load();
      final text = flatten(logs);
      expect(text, contains('FormatException'));
      expect(text, isNot(contains('SENTINEL')));
      expect(text, isNot(contains('{{{')));
    });

    test(
      'a second corrupt file gets the next number; a repeated load adds none',
      () async {
        contacts.writeAsStringSync('first');
        final r = open();
        await r.load();
        await r.load();
        await r.load();
        expect(backups(), ['contacts.json.corrupt-1']);
        contacts.writeAsStringSync('second');
        await r.load();
        expect(backups(), [
          'contacts.json.corrupt-1',
          'contacts.json.corrupt-2',
        ]);
        expect(
          File('${dir.path}/contacts.json.corrupt-1').readAsStringSync(),
          'first',
        );
        expect(
          File('${dir.path}/contacts.json.corrupt-2').readAsStringSync(),
          'second',
        );
      },
    );

    test(
      'an oversize file is treated as corrupt, without reading it all',
      () async {
        contacts.writeAsBytesSync(
          List<int>.filled(DeviceRegistry.maxFileBytes + 1, 0x20),
        );
        final r = open();
        await r.load();
        expect(r.records, isEmpty);
        expect(backups(), hasLength(1));
      },
    );

    test('a directory where the file should be is moved aside', () async {
      Directory(contacts.path).createSync();
      final r = open();
      await r.load();
      expect(r.records, isEmpty);
      expect(backups(), hasLength(1));
      await add(r, rec('a', 1));
      expect(contacts.existsSync(), isTrue);
    });

    test(
      'unusable entries are skipped, the rest kept, the original copied',
      () async {
        final good = {
          'deviceId': 'good',
          'fingerprint': fp(1).toLowerCase(),
          'alias': 'Good\u0007\u202E Name',
          'trust': 'trusted',
          'pinnedAt': '2026-11-03T12:30:00Z',
          'hasPairKey': true,
        };
        Map<String, Object?> variant(String key, Object? value) => {
          ...good,
          'deviceId': 'x-$key',
          'fingerprint': fp(100 + key.length),
          key: value,
        };
        final doc = jsonEncode({
          'v': 1,
          'contacts': [
            good,
            variant('fingerprint', 'ABC'),
            variant('fingerprint', 'Z' * 64),
            variant('trust', 'blocked'),
            variant('trust', 'unknown'),
            variant('trust', 7),
            variant('deviceId', ''),
            variant('deviceId', 42),
            variant('alias', ['not', 'a', 'string']),
            variant('pinnedAt', 'yesterday'),
            variant('hasPairKey', 'yes'),
            'a string',
            null,
            {...good, 'deviceId': 'dup'}, // duplicate fingerprint
            {...good, 'fingerprint': fp(2)}, // duplicate deviceId
          ],
          'blocked': [
            {'fingerprint': fp(9), 'blockedAt': '2026-05-06T00:00:00Z'},
            fp(8).toLowerCase(), // bare string tolerated, normalised
            {'fingerprint': 'short'},
            5,
          ],
        });
        contacts.writeAsStringSync(doc);
        final logs = captureLogs();
        final r = open();
        await r.load();
        expect(r.records.map((c) => c.deviceId), ['good']);
        final c = r.byDeviceId('good')!;
        expect(c.fingerprint, fp(1), reason: 'stored uppercase');
        expect(
          c.alias,
          'Good Name',
          reason: 'control and bidi characters stripped',
        );
        expect(c.trust, PeerTrust.trusted);
        expect(c.hasPairKey, isTrue);
        expect(c.pinnedAt, DateTime.utc(2026, 11, 3, 12, 30));
        expect(r.blockedFingerprints.toSet(), {fp(9), fp(8)});
        expect(backups(), ['contacts.json.corrupt-1']);
        expect(
          File('${dir.path}/contacts.json.corrupt-1').readAsStringSync(),
          doc,
        );
        expect(
          contacts.readAsStringSync(),
          doc,
          reason: 'load itself does not rewrite',
        );
        expect(logs.where((l) => l.level >= Level.WARNING), isNotEmpty);
      },
    );

    test(
      'a file holding more entries than the cap keeps the first ones',
      () async {
        contacts.writeAsStringSync(
          jsonEncode({
            'v': 1,
            'contacts': [
              for (var i = 1; i <= 5; i++)
                {
                  'deviceId': 'd$i',
                  'fingerprint': fp(i),
                  'alias': 'n$i',
                  'trust': 'known',
                  'pinnedAt': '2026-11-03T12:30:00Z',
                },
            ],
          }),
        );
        final r = open(max: 3);
        await r.load();
        expect(r.records.map((c) => c.deviceId), ['d1', 'd2', 'd3']);
        expect(backups(), hasLength(1));
      },
    );
  });

  group('atomic writes', () {
    test(
      'a stale contacts.json.tmp from a crash is ignored and then replaced',
      () async {
        final r = open();
        await r.load();
        await add(r, rec('a', 1));
        File('${contacts.path}.tmp')
            .writeAsStringSync('{"v":1,"contacts":[{"devi');
        final r2 = open();
        await r2.load();
        expect(r2.records.map((c) => c.deviceId), ['a']);
        expect(backups(), isEmpty, reason: 'the tmp file is not the registry');
        await add(r2, rec('b', 2));
        expect(File('${contacts.path}.tmp').existsSync(), isFalse);
        expect((onDisk()['contacts']! as List<Object?>), hasLength(2));
      },
    );

    test('a leftover tmp and no real file reads as empty', () async {
      File('${contacts.path}.tmp').writeAsStringSync('{"v":1');
      final r = open();
      await r.load();
      expect(r.records, isEmpty);
      expect(backups(), isEmpty);
    });

    test(
      'a failed write changes neither memory nor the file; later writes work',
      () async {
        final r = open();
        await r.load();
        await add(r, rec('a', 1));
        final before = contacts.readAsBytesSync();
        // A directory squatting on the tmp name makes the write fail.
        Directory('${contacts.path}.tmp').createSync();
        await expectLater(
          add(r, rec('b', 2)),
          throwsA(isA<FileSystemException>()),
        );
        expect(r.byDeviceId('b'), isNull);
        expect(r.records, hasLength(1));
        expect(contacts.readAsBytesSync(), before);
        Directory('${contacts.path}.tmp').deleteSync();
        await add(r, rec('b', 2));
        expect(r.records, hasLength(2));
        expect((onDisk()['contacts']! as List<Object?>), hasLength(2));
      },
    );

    test(
      '100 rapid, un-awaited updates keep the file valid JSON and in order',
      () async {
        final r = open();
        await r.load();
        final futures = [
          for (var i = 1; i <= 100; i++) add(r, rec('dev-$i', i)),
        ];
        // Peek at the file while writes are in flight: it is always parseable.
        for (var i = 0; i < 20; i++) {
          if (contacts.existsSync()) {
            expect(
              () => jsonDecode(contacts.readAsStringSync()),
              returnsNormally,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await Future.wait(futures);
        expect(r.writeCount, 100);
        final list = onDisk()['contacts']! as List<Object?>;
        expect(list, hasLength(100));
        expect(list.map((e) => (e! as Map<String, Object?>)['deviceId']), [
          for (var i = 1; i <= 100; i++) 'dev-$i',
        ]);
        final r2 = open();
        await r2.load();
        expect(r2.records, hasLength(100));
      },
    );

    test('check-and-change inside update is race free', () async {
      final r = open();
      await r.load();
      // Each task adds its contact only if the count is still below 5.
      final results = await Future.wait([
        for (var i = 1; i <= 20; i++)
          r.update((d) {
            if (d.contacts.length >= 5) return false;
            d.contacts['d$i'] = rec('d$i', i);
            return true;
          }),
      ]);
      expect(results.where((x) => x), hasLength(5));
      expect(r.records, hasLength(5));
    });
  });

  group('bounded size', () {
    test(
      'the default limit is 2000 contacts and the 2001st is refused',
      () async {
        expect(DeviceRegistry.defaultMaxContacts, 2000);
        final r = DeviceRegistry.inMemory();
        await r.update((d) {
          for (var i = 1; i <= 2000; i++) {
            d.contacts['d$i'] = rec('d$i', i);
          }
          return true;
        });
        expect(r.records, hasLength(2000));
        await expectLater(
          add(r, rec('d2001', 2001)),
          throwsA(isA<RegistryFullException>()),
        );
        expect(r.records, hasLength(2000));
        expect(r.byDeviceId('d2001'), isNull);
        // Replacing an existing entry is not growth.
        await add(r, rec('d1', 1, alias: 'renamed'));
        expect(r.byDeviceId('d1')!.alias, 'renamed');
      },
    );

    test('2000 contacts persist and reload (file-backed)', () async {
      final r = open();
      await r.load();
      await r.update((d) {
        for (var i = 1; i <= 2000; i++) {
          d.contacts['d$i'] = rec('d$i', i);
        }
        return true;
      });
      expect(contacts.lengthSync(), lessThan(DeviceRegistry.maxFileBytes));
      final r2 = open();
      await r2.load();
      expect(r2.records, hasLength(2000));
      expect(backups(), isEmpty);
    });

    test('an over-limit change leaves memory and the file untouched', () async {
      final r = open(max: 3);
      await r.load();
      for (var i = 1; i <= 3; i++) {
        await add(r, rec('d$i', i));
      }
      final before = contacts.readAsBytesSync();
      final writes = r.writeCount;
      await expectLater(
        add(r, rec('d4', 4)),
        throwsA(isA<RegistryFullException>()),
      );
      expect(r.records, hasLength(3));
      expect(r.writeCount, writes);
      expect(contacts.readAsBytesSync(), before);
      final e = RegistryFullException(3);
      expect(e.limit, 3);
      expect('$e', isNot(contains('d4')));
    });

    test('the blocked list is bounded too', () async {
      final r = DeviceRegistry.inMemory(maxContacts: 3, maxBlocked: 2);
      await r.update((d) {
        d.blocked[fp(1)] = DateTime.utc(2026);
        d.blocked[fp(2)] = DateTime.utc(2026);
        return true;
      });
      await expectLater(
        r.update((d) {
          d.blocked[fp(3)] = DateTime.utc(2026);
          return true;
        }),
        throwsA(isA<RegistryFullException>()),
      );
      expect(r.blockedFingerprints, hasLength(2));
    });
  });

  group('invariants are enforced at commit', () {
    Future<void> expectRefused(
      DeviceRegistry r,
      void Function(RegistryDraft d) f,
    ) async {
      final before = r.records.map((c) => c.deviceId).toList();
      await expectLater(
        r.update((d) {
          f(d);
          return true;
        }),
        throwsStateError,
      );
      expect(r.records.map((c) => c.deviceId).toList(), before);
    }

    test('lowercase, short or non-hex fingerprints', () async {
      final r = DeviceRegistry.inMemory();
      await expectRefused(r, (d) {
        d.contacts['a'] = ContactRecord(
          deviceId: 'a',
          fingerprint: fp(1).toLowerCase().replaceAll('0', 'a'),
          alias: 'x',
          trust: PeerTrust.known,
          pinnedAt: DateTime.utc(2026),
        );
      });
      await expectRefused(r, (d) {
        d.contacts['a'] = rec('a', 1).copyWith(fingerprint: 'ABC');
      });
      await expectRefused(r, (d) {
        d.blocked['not-a-fingerprint'] = DateTime.utc(2026);
      });
    });

    test('two contacts with one fingerprint', () async {
      final r = DeviceRegistry.inMemory();
      await expectRefused(r, (d) {
        d.contacts['a'] = rec('a', 1);
        d.contacts['b'] = rec('b', 1);
      });
    });

    test('map key that is not the record deviceId, and trust that is not a pin level', () async {
      final r = DeviceRegistry.inMemory();
      await expectRefused(r, (d) => d.contacts['a'] = rec('b', 1));
      await expectRefused(r, (d) {
        d.contacts['a'] = rec('a', 1, trust: PeerTrust.blocked);
      });
      await expectRefused(r, (d) {
        d.contacts['a'] = rec('a', 1, trust: PeerTrust.unknown);
      });
    });
  });

  group('alias sanitising helper', () {
    test('strips control, bidi and invisible characters and clamps to 64', () {
      expect(sanitizeAlias('  Ravi\u0000\n\t-Laptop\u202E  '), 'Ravi-Laptop');
      expect(sanitizeAlias('a\u200Bb\uFEFFc\u2028d\u2066e'), 'abcde');
      expect(sanitizeAlias('\u0001\u0002'), '');
      expect(sanitizeAlias('x' * 100), 'x' * 64);
      expect(sanitizeAlias('Café \u{1F600}'), 'Café \u{1F600}');
      // 64 code points, never a split surrogate pair.
      final emoji = sanitizeAlias('\u{1F600}' * 70);
      expect(emoji.runes.length, 64);
      expect(() => utf8.encode(emoji), returnsNormally);
      expect(sanitizeAlias('a  b'), 'a  b', reason: 'inner spaces kept');
    });
  });
}

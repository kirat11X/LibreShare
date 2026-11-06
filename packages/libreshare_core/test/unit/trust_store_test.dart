// FileTrustStore / InMemoryTrustStore (docs/plans/inc3.md D1, D3, section 4.1):
// pinned contacts, key-change detection that never auto-replaces, blocked
// fingerprints that win over any deviceId, and the pin rules (no silent
// downgrade of trust, replace only on request).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/src/clock.dart';
import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/security/trust_store.dart';
import 'package:libreshare_core/src/storage/device_registry.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// 64 uppercase hex characters containing letters, unique per [n] (< 65536).
String fp(int n) => ('ABCDEF0123456789' * 4).replaceRange(
  60,
  64,
  n.toRadixString(16).toUpperCase().padLeft(4, '0'),
);

const String devA = 'dev-A-5b0f7d8e';
const String devB = 'dev-B-0f6c2a9e';

class FixedClock implements Clock {
  FixedClock(this.t);
  DateTime t;
  @override
  DateTime now() => t;
}

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

/// Counts `changes` events; call [settle] before reading.
class ChangeCounter {
  ChangeCounter(Stream<void> s) {
    _sub = s.listen((_) => count++);
  }
  late final StreamSubscription<void> _sub;
  int count = 0;
  Future<int> settle() async {
    await pumpEventQueue();
    return count;
  }

  Future<void> cancel() => _sub.cancel();
}

typedef MakeStore = Future<RegistryTrustStore> Function(
  Clock clock, {
  int? max,
});

void semantics(String label, MakeStore make) {
  group('$label semantics', () {
    late FixedClock clock;
    late RegistryTrustStore store;
    late ChangeCounter changes;

    setUp(() async {
      clock = FixedClock(DateTime.utc(2026, 11, 3, 12));
      store = await make(clock);
      changes = ChangeCounter(store.changes);
    });
    tearDown(() async {
      await changes.cancel();
      await store.close();
    });

    Future<void> pin(
      String id,
      int n, {
      String alias = 'Ravi',
      PeerTrust trust = PeerTrust.known,
      bool replace = false,
    }) => store.pin(
      deviceId: id,
      fingerprint: fp(n),
      alias: alias,
      trust: trust,
      replace: replace,
    );

    group('classification', () {
      test('classify and classifyFingerprint are synchronous', () {
        // A compile-time property too: no Future in the type.
        final PeerTrustInfo a = store.classify(devA, fp(1));
        final PeerTrustInfo b = store.classifyFingerprint(fp(1));
        expect(a.trust, PeerTrust.unknown);
        expect(b.trust, PeerTrust.unknown);
      });

      test('unknown deviceId and unknown fingerprint -> unknown', () {
        final i = store.classify(devA, fp(1));
        expect(i.trust, PeerTrust.unknown);
        expect(i.keyChanged, isFalse);
        expect(i.pinnedFingerprint, isNull);
        expect(i.alias, isNull);
        expect(i.hasPairKey, isFalse);
        expect(store.classifyFingerprint(fp(1)).trust, PeerTrust.unknown);
        expect(store.contacts, isEmpty);
      });

      test('a pinned contact with the same fingerprint -> its trust', () async {
        await pin(devA, 1, alias: 'Ravi-ThinkPad');
        final i = store.classify(devA, fp(1));
        expect(i.trust, PeerTrust.known);
        expect(i.keyChanged, isFalse);
        expect(i.alias, 'Ravi-ThinkPad');
        final byFp = store.classifyFingerprint(fp(1));
        expect(byFp.trust, PeerTrust.known);
        expect(byFp.alias, 'Ravi-ThinkPad');
        expect(store.classifyFingerprint(fp(2)).trust, PeerTrust.unknown);
        // Another device id with an unrelated fingerprint is simply unknown.
        expect(store.classify(devB, fp(2)).trust, PeerTrust.unknown);
      });

      for (final trust in [PeerTrust.known, PeerTrust.trusted]) {
        test(
          '${trust.name} contact presenting another key -> keyChanged, old trust, no replacement',
          () async {
            await pin(devA, 1, trust: trust);
            final i = store.classify(devA, fp(2));
            expect(
              i.trust,
              trust,
              reason: 'carries the old trust, as a warning',
            );
            expect(i.keyChanged, isTrue);
            expect(i.pinnedFingerprint, fp(1));
            expect(i.alias, 'Ravi');
            // Asking never mutates anything.
            expect(store.classify(devA, fp(1)).keyChanged, isFalse);
            expect(store.classify(devA, fp(1)).trust, trust);
            expect(store.contacts.single.fingerprint, fp(1));
            expect(store.classifyFingerprint(fp(2)).trust, PeerTrust.unknown);
            expect(store.classify(devA, fp(2)).keyChanged, isTrue);
          },
        );
      }

      test(
        'a malformed fingerprint from a known device counts as a changed key',
        () async {
          await pin(devA, 1, trust: PeerTrust.trusted);
          for (final bad in [
            '',
            'zz',
            fp(1).substring(1),
            '${fp(1)}00',
            'G' * 64,
          ]) {
            final i = store.classify(devA, bad);
            expect(i.keyChanged, isTrue, reason: bad);
            expect(i.pinnedFingerprint, fp(1));
          }
          expect(store.classify(devB, 'nonsense').trust, PeerTrust.unknown);
          expect(
            store.classifyFingerprint('nonsense').trust,
            PeerTrust.unknown,
          );
        },
      );

      test('a blocked fingerprint is blocked regardless of deviceId', () async {
        await pin(devA, 1, trust: PeerTrust.trusted);
        await store.block(fp(5));
        for (final id in [devA, devB, 'never-seen', '']) {
          final i = store.classify(id, fp(5));
          expect(i.trust, PeerTrust.blocked, reason: id);
          expect(i.keyChanged, isFalse);
        }
        expect(store.classifyFingerprint(fp(5)).trust, PeerTrust.blocked);
        expect(store.blockedFingerprints, [fp(5)]);
        // The trusted contact itself is unaffected.
        expect(store.classify(devA, fp(1)).trust, PeerTrust.trusted);
      });

      test('blocking a pinned contact blocks its fingerprint and shows in the list', () async {
        await pin(devA, 1, trust: PeerTrust.trusted);
        await store.block(fp(1));
        expect(store.classify(devA, fp(1)).trust, PeerTrust.blocked);
        expect(store.classifyFingerprint(fp(1)).trust, PeerTrust.blocked);
        expect(store.contacts.single.trust, PeerTrust.blocked);
        // Its replacement key is still flagged against the (blocked) pin.
        final other = store.classify(devA, fp(2));
        expect(other.keyChanged, isTrue);
        expect(other.trust, PeerTrust.blocked);
        // Unblocking restores the stored trust, nothing was lost.
        await store.unblock(fp(1));
        expect(store.classify(devA, fp(1)).trust, PeerTrust.trusted);
        expect(store.contacts.single.trust, PeerTrust.trusted);
        expect(store.blockedFingerprints, isEmpty);
      });

      test('a block outlives remove(deviceId)', () async {
        await pin(devA, 1);
        await store.block(fp(1));
        await store.remove(devA);
        expect(store.contacts, isEmpty);
        expect(store.classify(devA, fp(1)).trust, PeerTrust.blocked);
        expect(store.classifyFingerprint(fp(1)).trust, PeerTrust.blocked);
      });

      test('a fingerprint pinned for device A is not trusted when device B shows it', () async {
        await pin(devA, 1, trust: PeerTrust.trusted);
        final i = store.classify(devB, fp(1));
        expect(i.trust, PeerTrust.unknown);
        expect(i.keyChanged, isFalse);
      });

      test(
        'fingerprints compare case-insensitively and are stored uppercase',
        () async {
          await store.pin(
            deviceId: devA,
            fingerprint: fp(1).toLowerCase(),
            alias: 'x',
            trust: PeerTrust.trusted,
          );
          expect(store.contacts.single.fingerprint, fp(1));
          expect(
            store.classify(devA, fp(1).toLowerCase()).trust,
            PeerTrust.trusted,
          );
          expect(store.classify(devA, fp(1)).keyChanged, isFalse);
          final mixed =
              fp(1).substring(0, 20).toLowerCase() + fp(1).substring(20);
          expect(store.classify(devA, mixed).keyChanged, isFalse);
          expect(store.classifyFingerprint(mixed).trust, PeerTrust.trusted);
          await store.block(fp(7).toLowerCase());
          expect(store.blockedFingerprints, [fp(7)]);
          expect(store.classify(devB, fp(7)).trust, PeerTrust.blocked);
          // Re-pinning in another case is the same key, not a change.
          await store.pin(
            deviceId: devA,
            fingerprint: mixed,
            alias: 'x',
            trust: PeerTrust.trusted,
          );
          expect(store.contacts, hasLength(1));
        },
      );
    });

    group('pin', () {
      test('pins a new contact: alias, trust, pinnedAt, no pair key', () async {
        await pin(devA, 1, alias: 'Ravi', trust: PeerTrust.known);
        final c = store.contacts.single;
        expect(c.deviceId, devA);
        expect(c.fingerprint, fp(1));
        expect(c.alias, 'Ravi');
        expect(c.trust, PeerTrust.known);
        expect(c.pinnedAt, DateTime.utc(2026, 11, 3, 12));
        expect(c.hasPairKey, isFalse);
      });

      test('a different fingerprint without replace throws KeyChangedException and changes nothing', () async {
        await pin(devA, 1, trust: PeerTrust.trusted);
        await changes.settle();
        final before = changes.count;
        Object? caught;
        try {
          await pin(devA, 2, alias: 'Attacker', trust: PeerTrust.trusted);
        } on Object catch (e) {
          caught = e;
        }
        expect(caught, isA<KeyChangedException>());
        expect((caught! as KeyChangedException).deviceId, devA);
        expect('$caught', contains(devA));
        expect('$caught', isNot(contains(fp(1))));
        expect('$caught', isNot(contains(fp(2))));
        expect(store.contacts.single.fingerprint, fp(1));
        expect(store.contacts.single.alias, 'Ravi');
        expect(store.classify(devA, fp(1)).trust, PeerTrust.trusted);
        expect(store.classify(devA, fp(2)).keyChanged, isTrue);
        expect(
          await changes.settle(),
          before,
          reason: 'no event for a refusal',
        );
      });

      test(
        'replace: true replaces, emits once, and takes the new trust',
        () async {
          await pin(devA, 1, trust: PeerTrust.trusted);
          await store.setPairKey(devA, true);
          await changes.settle();
          final before = changes.count;
          clock.t = DateTime.utc(2027, 1, 2);
          await pin(devA, 2, alias: 'Ravi (new phone)', replace: true);
          expect(await changes.settle(), before + 1);
          final c = store.contacts.single;
          expect(c.fingerprint, fp(2));
          expect(c.alias, 'Ravi (new phone)');
          expect(
            c.trust,
            PeerTrust.known,
            reason: 'an explicit replace is not an upgrade',
          );
          expect(c.pinnedAt, DateTime.utc(2027, 1, 2));
          expect(
            c.hasPairKey,
            isFalse,
            reason: 'K_pair belonged to the old key',
          );
          expect(store.classify(devA, fp(2)).keyChanged, isFalse);
          final old = store.classify(devA, fp(1));
          expect(
            old.keyChanged,
            isTrue,
            reason: 'the old key is now the odd one',
          );
          expect(old.pinnedFingerprint, fp(2));
          expect(store.classifyFingerprint(fp(1)).trust, PeerTrust.unknown);
        },
      );

      test('pinning the same key again is not a change of key', () async {
        await pin(devA, 1);
        await pin(devA, 1);
        await pin(devA, 1, replace: true);
        expect(store.contacts, hasLength(1));
      });

      test('trust rules for the same fingerprint', () async {
        await pin(devA, 1, trust: PeerTrust.trusted);
        // known never demotes trusted...
        await pin(devA, 1, trust: PeerTrust.known);
        expect(store.contacts.single.trust, PeerTrust.trusted);
        // ...but trusted upgrades known...
        await pin(devB, 2, trust: PeerTrust.known);
        await pin(devB, 2, trust: PeerTrust.trusted);
        expect(store.classify(devB, fp(2)).trust, PeerTrust.trusted);
        // ...and only replace: true demotes.
        await pin(devA, 1, trust: PeerTrust.known, replace: true);
        expect(store.classify(devA, fp(1)).trust, PeerTrust.known);
      });

      test('re-pin updates the alias, keeps trust and pinnedAt', () async {
        await pin(devA, 1, alias: 'Old', trust: PeerTrust.trusted);
        clock.t = DateTime.utc(2030);
        await pin(devA, 1, alias: 'New', trust: PeerTrust.known);
        final c = store.contacts.single;
        expect(c.alias, 'New');
        expect(c.trust, PeerTrust.trusted);
        expect(c.pinnedAt, DateTime.utc(2026, 11, 3, 12));
      });

      test('pin with an unusable trust level is an error', () async {
        for (final t in [PeerTrust.unknown, PeerTrust.blocked]) {
          await expectLater(pin(devA, 1, trust: t), throwsArgumentError);
        }
        expect(store.contacts, isEmpty);
      });

      test('malformed fingerprints are refused and change nothing', () async {
        final bad = [
          '',
          'abc',
          fp(1).substring(1),
          '${fp(1)}0',
          '${fp(1).substring(2)}GG',
          ' ${fp(1).substring(1)}',
          '${fp(1).substring(1)}\n',
          '\uFB00' * 32, // upper-cases to 64 F's: must not be accepted
          '0x${fp(1).substring(2)}',
        ];
        for (final b in bad) {
          await expectLater(
            store.pin(
              deviceId: devA,
              fingerprint: b,
              alias: 'x',
              trust: PeerTrust.known,
            ),
            throwsArgumentError,
            reason: b,
          );
          await expectLater(store.block(b), throwsArgumentError, reason: b);
          await expectLater(store.unblock(b), throwsArgumentError, reason: b);
        }
        expect(store.contacts, isEmpty);
        expect(store.blockedFingerprints, isEmpty);
        expect(await changes.settle(), 0);
      });

      test('device ids: 1 to 128 characters, no control characters', () async {
        for (final bad in ['', 'x' * 129, 'a\u0000b', 'a\nb', 'a\u202Eb']) {
          await expectLater(
            store.pin(
              deviceId: bad,
              fingerprint: fp(1),
              alias: 'x',
              trust: PeerTrust.known,
            ),
            throwsArgumentError,
            reason: bad.length.toString(),
          );
        }
        await pin('x' * 128, 1);
        expect(store.contacts, hasLength(1));
      });

      test(
        'the same fingerprint cannot be pinned under two device ids',
        () async {
          await pin(devA, 1, trust: PeerTrust.trusted);
          await expectLater(
            pin(devB, 1),
            throwsA(isA<FingerprintInUseException>()),
          );
          await pin(devB, 2);
          await expectLater(
            pin(devB, 1, replace: true),
            throwsA(isA<FingerprintInUseException>()),
          );
          expect(store.classify(devB, fp(2)).trust, PeerTrust.known);
          expect(store.classify(devA, fp(1)).trust, PeerTrust.trusted);
        },
      );

      test('two racing pins for one device: the first wins, the second is a key change', () async {
        final results = await Future.wait([
          pin(devA, 1).then<Object?>((_) => null, onError: (Object e) => e),
          pin(devA, 2).then<Object?>((_) => null, onError: (Object e) => e),
        ]);
        expect(results[0], isNull);
        expect(results[1], isA<KeyChangedException>());
        expect(store.contacts.single.fingerprint, fp(1));
      });

      test('100 rapid pins all land', () async {
        await Future.wait([
          for (var i = 1; i <= 100; i++)
            pin(
              'dev-$i',
              i,
              alias: 'Device $i',
              trust: i.isEven ? PeerTrust.trusted : PeerTrust.known,
            ),
        ]);
        expect(store.contacts, hasLength(100));
        for (var i = 1; i <= 100; i++) {
          final info = store.classify('dev-$i', fp(i));
          expect(info.trust, i.isEven ? PeerTrust.trusted : PeerTrust.known);
          expect(info.alias, 'Device $i');
        }
        expect(await changes.settle(), 100);
      });
    });

    group('alias', () {
      test(
        'is sanitised: control characters, bidi overrides, 64 characters',
        () async {
          await pin(
            devA,
            1,
            alias: '  Ra\u0000vi\u202E\n\u200B-Lap\u0007top  ',
          );
          expect(store.contacts.single.alias, 'Ravi-Laptop');
          await pin(devB, 2, alias: 'x' * 200);
          expect(store.classify(devB, fp(2)).alias, 'x' * 64);
        },
      );

      test('an empty alias falls back to the start of the device id; an existing alias is kept', () async {
        await pin(devA, 1, alias: '\u0001 ');
        expect(store.contacts.single.alias, devA.substring(0, 8));
        await pin(devA, 1, alias: 'Named');
        await pin(devA, 1, alias: '   ');
        expect(store.contacts.single.alias, 'Named');
      });
    });

    group('setTrust and setPairKey', () {
      test('promote and demote explicitly', () async {
        await pin(devA, 1);
        await store.setTrust(devA, PeerTrust.trusted);
        expect(store.classify(devA, fp(1)).trust, PeerTrust.trusted);
        await store.setTrust(devA, PeerTrust.known);
        expect(store.classify(devA, fp(1)).trust, PeerTrust.known);
        await expectLater(
          store.setTrust('nobody', PeerTrust.known),
          throwsStateError,
        );
        await expectLater(
          store.setTrust(devA, PeerTrust.blocked),
          throwsArgumentError,
        );
        await expectLater(
          store.setTrust(devA, PeerTrust.unknown),
          throwsArgumentError,
        );
      });

      test('the pair-key flag is reported by classify and contacts', () async {
        await pin(devA, 1, trust: PeerTrust.trusted);
        await store.setPairKey(devA, true);
        expect(store.classify(devA, fp(1)).hasPairKey, isTrue);
        expect(store.classifyFingerprint(fp(1)).hasPairKey, isTrue);
        expect(store.contacts.single.hasPairKey, isTrue);
        await pin(devA, 1, alias: 'again');
        expect(
          store.contacts.single.hasPairKey,
          isTrue,
          reason: 'a re-pin keeps it',
        );
        await store.setPairKey(devA, false);
        expect(store.contacts.single.hasPairKey, isFalse);
        await expectLater(store.setPairKey('nobody', true), throwsStateError);
      });
    });

    group('remove and block', () {
      test('remove forgets the contact; unknown ids are a no-op', () async {
        await pin(devA, 1, trust: PeerTrust.trusted);
        await store.remove(devA);
        expect(store.contacts, isEmpty);
        expect(store.classify(devA, fp(1)).trust, PeerTrust.unknown);
        await store.remove(devA);
        await store.remove('never-existed');
      });

      test(
        'removal then re-pin of a new key is the way out of KEY_CHANGED',
        () async {
          await pin(devA, 1, trust: PeerTrust.trusted);
          expect(store.classify(devA, fp(2)).keyChanged, isTrue);
          await store.remove(devA);
          expect(store.classify(devA, fp(2)).keyChanged, isFalse);
          await pin(devA, 2);
          expect(store.classify(devA, fp(2)).trust, PeerTrust.known);
        },
      );

      test('contacts is an unmodifiable snapshot', () async {
        await pin(devA, 1);
        final snap = store.contacts;
        expect(() => snap.add(snap.first), throwsUnsupportedError);
        await pin(devB, 2);
        expect(snap, hasLength(1));
        expect(store.contacts, hasLength(2));
      });
    });

    group('changes stream', () {
      test(
        'fires once per real mutation and never for no-ops or refusals',
        () async {
          Future<int> after(Future<void> Function() action) async {
            final before = await changes.settle();
            try {
              await action();
            } on Object {
              // refusals are part of the scenario
            }
            return (await changes.settle()) - before;
          }

          expect(await after(() => pin(devA, 1)), 1, reason: 'new contact');
          expect(await after(() => pin(devA, 1)), 0, reason: 'identical pin');
          expect(await after(() => pin(devA, 1, alias: 'Renamed')), 1);
          expect(
            await after(() => pin(devA, 2)),
            0,
            reason: 'refused key change',
          );
          expect(await after(() => pin(devA, 2, replace: true)), 1);
          expect(await after(() => store.setTrust(devA, PeerTrust.trusted)), 1);
          expect(await after(() => store.setTrust(devA, PeerTrust.trusted)), 0);
          expect(await after(() => store.setPairKey(devA, true)), 1);
          expect(await after(() => store.setPairKey(devA, true)), 0);
          expect(await after(() => store.block(fp(9))), 1);
          expect(await after(() => store.block(fp(9))), 0);
          expect(await after(() => store.unblock(fp(9))), 1);
          expect(await after(() => store.unblock(fp(9))), 0);
          expect(await after(() => store.remove(devA)), 1);
          expect(await after(() => store.remove(devA)), 0);
          expect(await after(() => pin(devA, 1, trust: PeerTrust.blocked)), 0);
          expect(await after(() => store.block('bad')), 0);
        },
      );

      test('listeners see the new state when the event arrives', () async {
        PeerTrust? seen;
        final sub = store.changes.listen(
          (_) => seen = store.classify(devA, fp(1)).trust,
        );
        await pin(devA, 1, trust: PeerTrust.trusted);
        await pumpEventQueue();
        expect(seen, PeerTrust.trusted);
        await sub.cancel();
      });

      test(
        'after close() mutations still work and nothing is emitted',
        () async {
          final c = ChangeCounter(store.changes);
          await store.close();
          await pin(devA, 1);
          await pumpEventQueue();
          expect(store.contacts, hasLength(1));
          expect(c.count, 0);
          await store.close();
        },
      );
    });

    test('no fingerprint, alias or device id reaches a log record', () async {
      final logs = captureLogs();
      await pin(devA, 1, alias: 'SENTINEL-ALIAS', trust: PeerTrust.trusted);
      try {
        await pin(devA, 2, alias: 'SENTINEL-ALIAS-2');
      } on KeyChangedException {
        // expected
      }
      await pin(devA, 2, alias: 'SENTINEL-ALIAS-2', replace: true);
      await store.block(fp(3));
      await store.unblock(fp(3));
      await store.remove(devA);
      final text = flatten(logs);
      expect(text, isNot(contains('SENTINEL')));
      expect(RegExp(r'[0-9A-Fa-f]{17,}').hasMatch(text), isFalse);
      for (final n in [1, 2, 3]) {
        expect(text, isNot(contains(fp(n))));
      }
    });
  });
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('ls_trust_'));
  tearDown(() => root.deleteSync(recursive: true));

  semantics('FileTrustStore', (clock, {int? max}) async {
    final dir = Directory.systemTemp.createTempSync('ls_trust_sem_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final registry = max == null
        ? DeviceRegistry(dir)
        : DeviceRegistry(dir, maxContacts: max);
    final s = FileTrustStore(registry, clock: clock);
    await s.load();
    return s;
  });

  semantics('InMemoryTrustStore', (clock, {int? max}) async {
    return InMemoryTrustStore(
      clock: clock,
      maxContacts: max ?? DeviceRegistry.defaultMaxContacts,
    );
  });

  group('FileTrustStore on disk', () {
    late Directory dir;
    late File file;

    Future<FileTrustStore> open({Clock? clock, int? max}) =>
        FileTrustStore.open(
          dir,
          clock: clock ?? FixedClock(DateTime.utc(2026, 11, 3, 12)),
          maxContacts: max ?? DeviceRegistry.defaultMaxContacts,
        );

    setUp(() {
      dir = Directory('${root.path}/state');
      file = File('${dir.path}/contacts.json');
    });

    test(
      'using the store before load() is a programming error, not "unknown"',
      () async {
        final s = FileTrustStore(DeviceRegistry(dir));
        expect(() => s.classify(devA, fp(1)), throwsStateError);
        expect(() => s.classifyFingerprint(fp(1)), throwsStateError);
        expect(() => s.contacts, throwsStateError);
        await expectLater(
          s.pin(
            deviceId: devA,
            fingerprint: fp(1),
            alias: 'x',
            trust: PeerTrust.known,
          ),
          throwsStateError,
        );
        await expectLater(s.block(fp(1)), throwsStateError);
        expect(file.existsSync(), isFalse);
      },
    );

    test(
      'contacts, trust, pair-key flag and blocks survive a restart',
      () async {
        final s = await open();
        await s.pin(
          deviceId: devA,
          fingerprint: fp(1),
          alias: 'Ravi',
          trust: PeerTrust.trusted,
        );
        await s.setPairKey(devA, true);
        await s.pin(
          deviceId: devB,
          fingerprint: fp(2).toLowerCase(),
          alias: 'Meera',
          trust: PeerTrust.known,
        );
        await s.block(fp(9));

        final s2 = await open();
        expect(s2.contacts.map((c) => c.deviceId), [devA, devB]);
        final a = s2.classify(devA, fp(1));
        expect(a.trust, PeerTrust.trusted);
        expect(a.hasPairKey, isTrue);
        expect(a.alias, 'Ravi');
        expect(s2.classify(devB, fp(2)).trust, PeerTrust.known);
        expect(s2.classify(devB, fp(3)).keyChanged, isTrue);
        expect(s2.classify('anyone', fp(9)).trust, PeerTrust.blocked);
        expect(s2.contacts.first.pinnedAt, DateTime.utc(2026, 11, 3, 12));
      },
    );

    test('the file holds uppercase fingerprints only', () async {
      final s = await open();
      await s.pin(
        deviceId: devA,
        fingerprint: fp(1).toLowerCase(),
        alias: 'x',
        trust: PeerTrust.known,
      );
      await s.block(fp(2).toLowerCase());
      final text = file.readAsStringSync();
      expect(text, contains(fp(1)));
      expect(text, contains(fp(2)));
      expect(text, isNot(contains(fp(1).toLowerCase())));
      expect(text, isNot(contains(fp(2).toLowerCase())));
    });

    test('a refused key change leaves the file byte-identical', () async {
      final s = await open();
      await s.pin(
        deviceId: devA,
        fingerprint: fp(1),
        alias: 'x',
        trust: PeerTrust.trusted,
      );
      final before = file.readAsBytesSync();
      final writes = s.registry.writeCount;
      await expectLater(
        s.pin(
          deviceId: devA,
          fingerprint: fp(2),
          alias: 'x',
          trust: PeerTrust.trusted,
        ),
        throwsA(isA<KeyChangedException>()),
      );
      await s.pin(
        deviceId: devA,
        fingerprint: fp(1),
        alias: 'x',
        trust: PeerTrust.known,
      );
      expect(file.readAsBytesSync(), before);
      expect(s.registry.writeCount, writes);
    });

    test('100 rapid pins keep contacts.json valid JSON', () async {
      final s = await open();
      final futures = [
        for (var i = 1; i <= 100; i++)
          s.pin(
            deviceId: 'dev-$i',
            fingerprint: fp(i),
            alias: 'n$i',
            trust: PeerTrust.known,
          ),
      ];
      for (var i = 0; i < 10; i++) {
        if (file.existsSync()) {
          expect(() => jsonDecode(file.readAsStringSync()), returnsNormally);
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await Future.wait(futures);
      final j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(j['v'], 1);
      expect(j['contacts'], hasLength(100));
      final s2 = await open();
      expect(s2.contacts, hasLength(100));
      expect(s2.classify('dev-77', fp(77)).trust, PeerTrust.known);
    });

    test('unknown members written by later increments survive pins and trust changes', () async {
      dir.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'v': 1,
          'contacts': [
            {
              'deviceId': devA,
              'fingerprint': fp(1),
              'alias': 'Ravi',
              'trust': 'known',
              'pinnedAt': '2026-11-03T12:30:00.000Z',
              'kPairRef': 'kpair/$devA',
              'peerAdvKey': 'AAAA',
            },
          ],
        }),
      );
      final s = await open();
      await s.pin(
        deviceId: devB,
        fingerprint: fp(2),
        alias: 'B',
        trust: PeerTrust.known,
      );
      await s.setTrust(devA, PeerTrust.trusted);
      await s.pin(
        deviceId: devA,
        fingerprint: fp(1),
        alias: 'Ravi 2',
        trust: PeerTrust.known,
      );
      final j = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final a =
          (j['contacts']! as List<Object?>).first! as Map<String, Object?>;
      expect(a['kPairRef'], 'kpair/$devA');
      expect(a['peerAdvKey'], 'AAAA');
      expect(a['trust'], 'trusted');
      expect(a['alias'], 'Ravi 2');
    });

    test(
      'a corrupt contacts file opens as an empty store with a backup',
      () async {
        dir.createSync(recursive: true);
        file.writeAsStringSync('{ not json');
        final s = await open();
        expect(s.contacts, isEmpty);
        expect(s.classify(devA, fp(1)).trust, PeerTrust.unknown);
        expect(File('${file.path}.corrupt-1').existsSync(), isTrue);
        await s.pin(
          deviceId: devA,
          fingerprint: fp(1),
          alias: 'x',
          trust: PeerTrust.known,
        );
        expect((await open()).contacts, hasLength(1));
      },
    );

    test(
      'cap: the 2001st contact is refused; replacing one is not growth',
      () async {
        final s = await open(max: 3);
        for (var i = 1; i <= 3; i++) {
          await s.pin(
            deviceId: 'd$i',
            fingerprint: fp(i),
            alias: 'n',
            trust: PeerTrust.known,
          );
        }
        final events = ChangeCounter(s.changes);
        await expectLater(
          s.pin(
            deviceId: 'd4',
            fingerprint: fp(4),
            alias: 'n',
            trust: PeerTrust.known,
          ),
          throwsA(isA<RegistryFullException>()),
        );
        await s.pin(
          deviceId: 'd1',
          fingerprint: fp(11),
          alias: 'n',
          trust: PeerTrust.known,
          replace: true,
        );
        expect(s.contacts, hasLength(3));
        expect(await events.settle(), 1);
        await events.cancel();
        await s.close();
      },
    );

    test('the default cap is 2000', () {
      expect(DeviceRegistry.defaultMaxContacts, 2000);
    });
  });

  group('sanitizeAlias is what the store applies', () {
    test('matches the registry helper', () {
      expect(sanitizeAlias('a\u0000b'), 'ab');
      expect(kMaxAliasLength, 64);
    });
  });
}

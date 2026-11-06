// CredentialStore (docs/plans/inc3.md D3, D6, D7): the device identity is
// created once, reloaded identically, and NEVER silently regenerated. A missing
// or mismatching key, or unreadable metadata, is IdentityLost; only the explicit
// createNewIdentity replaces an identity.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:libreshare_core/src/clock.dart';
import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/storage/credential_store.dart';
import 'package:libreshare_core/src/storage/file_secret_store.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

const String deviceA = '5b0f7d8e-3c1a-4f2b-9d6e-1a2b3c4d5e6f';
const String deviceB = '0f6c2a9e-7b1d-4c3e-8a5f-9e8d7c6b5a43';

String hexUpper(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

/// Deterministic fake of P1's generateIdentity: fixed bytes derived from [seed].
({DeviceIdentity identity, Uint8List privateKeyPem}) fakeIdentity(
  String deviceId,
  int seed,
) {
  final der = Uint8List.fromList(
    List<int>.generate(140, (i) => (seed * 31 + i * 7) % 256),
  );
  final b64 = base64.encode(der);
  final lines = <String>[
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  final pem =
      '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n';
  final key = Uint8List.fromList(
    utf8.encode(
      '-----BEGIN PRIVATE KEY-----\nSENTINELKEY$seed${'Q' * 40}\n-----END PRIVATE KEY-----\n',
    ),
  );
  return (
    identity: DeviceIdentity(
      deviceId: deviceId,
      fingerprint: hexUpper(sha256.convert(der).bytes),
      certDer: der,
      certPem: pem,
    ),
    privateKeyPem: key,
  );
}

/// Counts calls; every call yields a different identity.
class FakeGenerator {
  int calls = 0;
  int _seed = 0;
  ({DeviceIdentity identity, Uint8List privateKeyPem}) call(String deviceId) {
    calls++;
    return fakeIdentity(deviceId, ++_seed);
  }
}

/// A SecretStore that can be told to fail.
class FlakySecretStore implements SecretStore {
  FlakySecretStore(this.inner);
  final SecretStore inner;
  final Set<String> failPuts = {};
  final Set<String> failGets = {};
  final List<String> putLog = [];

  @override
  Future<Uint8List?> get(String name) async {
    if (failGets.contains(name)) {
      throw const SecretStoreException('injected read failure');
    }
    return inner.get(name);
  }

  @override
  Future<void> put(String name, Uint8List value) async {
    putLog.add(name);
    if (failPuts.contains(name)) {
      throw const SecretStoreException('injected write failure');
    }
    return inner.put(name, value);
  }

  @override
  Future<void> delete(String name) => inner.delete(name);
}

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

void main() {
  late Directory root;
  late Directory support;
  late InMemorySecretStore secrets;
  late FakeGenerator gen;
  late FixedClock clock;

  CredentialStore make({
    SecretStore? store,
    KeyMatchVerifier? verify,
    Directory? dir,
  }) => CredentialStore(
    directory: dir ?? support,
    secrets: store ?? secrets,
    clock: clock,
    verifyKeyMatchesCertificate: verify,
  );

  File identityFile() => File('${support.path}/identity.json');

  setUp(() {
    root = Directory.systemTemp.createTempSync('ls_cred_');
    support = Directory('${root.path}/support');
    secrets = InMemorySecretStore();
    gen = FakeGenerator();
    clock = FixedClock(DateTime.utc(2026, 11, 3, 12));
  });
  tearDown(() => root.deleteSync(recursive: true));

  group('first run and reload', () {
    test('first run generates once and persists', () async {
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(gen.calls, 1);
      expect(s.created, isTrue);
      expect(s.identity.deviceId, deviceA);
      expect(s.identity.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(s.createdAt, DateTime.utc(2026, 11, 3, 12));
      expect(identityFile().existsSync(), isTrue);
      expect(await secrets.get('identity.key'), s.privateKeyPem);
      expect(secrets.names, ['identity.key'], reason: 'staging copy removed');
    });

    test('a later run (new instance) reloads the same identity', () async {
      final first = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      final second = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(gen.calls, 1, reason: 'no second generation');
      expect(second.created, isFalse);
      expect(second.identity.fingerprint, first.identity.fingerprint);
      expect(second.identity.deviceId, first.identity.deviceId);
      expect(second.identity.certDer, first.identity.certDer);
      expect(second.identity.certPem, first.identity.certPem);
      expect(second.privateKeyPem, first.privateKeyPem);
      expect(second.createdAt, first.createdAt);
    });

    test('loads are idempotent and never rewrite the files', () async {
      final store = make();
      await store.loadOrCreate(generate: gen.call, deviceId: deviceA);
      final before = identityFile().readAsBytesSync();
      final modified = identityFile().lastModifiedSync();
      for (var i = 0; i < 5; i++) {
        await store.loadOrCreate(generate: gen.call, deviceId: deviceB);
      }
      expect(gen.calls, 1);
      expect(identityFile().readAsBytesSync(), before);
      expect(identityFile().lastModifiedSync(), modified);
    });

    test('the stored device id wins over the one passed later', () async {
      await make().loadOrCreate(generate: gen.call, deviceId: deviceA);
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceB,
      );
      expect(s.identity.deviceId, deviceA);
    });

    test('load() returns null on a fresh store and creates nothing', () async {
      expect(await make().load(), isNull);
      expect(identityFile().existsSync(), isFalse);
      expect(secrets.length, 0);
      expect(gen.calls, 0);
    });

    test('load() returns the identity once it exists', () async {
      final made = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      final got = await make().load();
      expect(got!.identity.fingerprint, made.identity.fingerprint);
    });

    test('concurrent first runs generate exactly one identity', () async {
      final store = make();
      final all = await Future.wait([
        for (var i = 0; i < 6; i++)
          store.loadOrCreate(generate: gen.call, deviceId: deviceA),
      ]);
      expect(gen.calls, 1);
      expect(all.map((s) => s.identity.fingerprint).toSet(), hasLength(1));
      expect(all.where((s) => s.created), hasLength(1));
    });

    test('identity.json is plain JSON and holds no private key', () async {
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      final text = identityFile().readAsStringSync();
      final j = jsonDecode(text) as Map<String, Object?>;
      expect(j['v'], 1);
      expect(j['deviceId'], deviceA);
      expect(j['fingerprint'], s.identity.fingerprint);
      expect(j['certPem'], s.identity.certPem);
      expect(j['createdAt'], '2026-11-03T12:00:00.000Z');
      expect(text, isNot(contains('PRIVATE')));
      expect(text, isNot(contains('SENTINELKEY')));
    });

    test('the age helper drives the "certificate is old" warning', () async {
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(s.age(DateTime.utc(2026, 11, 3, 12)), Duration.zero);
      expect(
        s.age(DateTime.utc(2036, 11, 3, 12)).inDays,
        greaterThan(3650 - 5),
      );
      expect(
        s.age(DateTime.utc(2026, 11, 1)),
        Duration.zero,
        reason: 'a clock that went backwards never reports a negative age',
      );
    });

    test('works with the real FileSecretStore (0600 key file)', () async {
      final fileSecrets = FileSecretStore(Directory('${root.path}/secrets'));
      final a = await make(store: fileSecrets)
          .loadOrCreate(generate: gen.call, deviceId: deviceA);
      final b = await make(
        store: FileSecretStore(Directory('${root.path}/secrets')),
      ).loadOrCreate(generate: gen.call, deviceId: deviceA);
      expect(b.identity.fingerprint, a.identity.fingerprint);
      expect(b.privateKeyPem, a.privateKeyPem);
      expect(gen.calls, 1);
      if (!Platform.isWindows) {
        for (final f in Directory('${root.path}/secrets').listSync()) {
          expect(FileStat.statSync(f.path).mode & 0x1FF, 384);
        }
      }
    });

    test('a stale identity.json.tmp from a crash is ignored', () async {
      await make().loadOrCreate(generate: gen.call, deviceId: deviceA);
      File('${support.path}/identity.json.tmp').writeAsStringSync('{"v":');
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(gen.calls, 1);
      expect(s.identity.deviceId, deviceA);
    });

    test('a crash before the first commit looks like a first run', () async {
      // Killed after the staging write, before identity.json existed.
      await secrets.put('identity.key.next', Uint8List.fromList([1, 2, 3]));
      File('${support.path}/identity.json.tmp')
        ..createSync(recursive: true)
        ..writeAsStringSync('{"v":1');
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(s.created, isTrue);
      expect(gen.calls, 1);
      expect(secrets.names, ['identity.key']);
    });
  });

  group('IdentityLost: never a silent regeneration', () {
    late StoredIdentity original;
    late Uint8List jsonBefore;

    setUp(() async {
      original = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      jsonBefore = identityFile().readAsBytesSync();
    });

    Future<IdentityLostException> loadExpectingLost([
      CredentialStore? s,
    ]) async {
      final calls = gen.calls;
      Object? caught;
      try {
        await (s ?? make()).loadOrCreate(generate: gen.call, deviceId: deviceA);
      } on Object catch (e) {
        caught = e;
      }
      expect(caught, isA<IdentityLostException>());
      expect(gen.calls, calls, reason: 'must not generate a replacement');
      return caught! as IdentityLostException;
    }

    Future<void> expectRecoverableOnlyExplicitly() async {
      // Still lost on the next start: nothing was "fixed" behind our back.
      await loadExpectingLost();
      final fresh = await make().createNewIdentity(generate: gen.call);
      expect(fresh.identity.fingerprint, isNot(original.identity.fingerprint));
      expect(fresh.identity.deviceId, deviceA);
      final again = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(again.identity.fingerprint, fresh.identity.fingerprint);
    }

    test('key deleted -> keyMissing', () async {
      await secrets.delete('identity.key');
      final e = await loadExpectingLost();
      expect(e.reason, IdentityLostReason.keyMissing);
      expect(identityFile().readAsBytesSync(), jsonBefore);
      expect(
        await secrets.get('identity.key'),
        isNull,
        reason: 'not recreated',
      );
      await expectRecoverableOnlyExplicitly();
    });

    test('key replaced by a different key -> keyMismatch', () async {
      final other = fakeIdentity(deviceA, 999).privateKeyPem;
      await secrets.put('identity.key', other);
      final e = await loadExpectingLost();
      expect(e.reason, IdentityLostReason.keyMismatch);
      expect(await secrets.get('identity.key'), other, reason: 'left alone');
      expect(identityFile().readAsBytesSync(), jsonBefore);
      await expectRecoverableOnlyExplicitly();
    });

    test('key store unreadable -> keyUnreadable', () async {
      final flaky = FlakySecretStore(secrets)..failGets.add('identity.key');
      final e = await loadExpectingLost(make(store: flaky));
      expect(e.reason, IdentityLostReason.keyUnreadable);
      expect(identityFile().readAsBytesSync(), jsonBefore);
    });

    test('the key verifier saying no -> keyMismatch', () async {
      final e = await loadExpectingLost(make(verify: (identity, key) => false));
      expect(e.reason, IdentityLostReason.keyMismatch);
    });

    test('the key verifier throwing -> keyMismatch', () async {
      final e = await loadExpectingLost(
        make(verify: (identity, key) => throw const FormatException('x')),
      );
      expect(e.reason, IdentityLostReason.keyMismatch);
    });

    test('the key verifier saying yes loads normally', () async {
      DeviceIdentity? seen;
      final s = await make(
        verify: (identity, key) {
          seen = identity;
          return true;
        },
      ).loadOrCreate(generate: gen.call, deviceId: deviceA);
      expect(s.identity.fingerprint, original.identity.fingerprint);
      expect(seen!.fingerprint, original.identity.fingerprint);
    });

    test(
      'identity.json deleted while the key remains -> metadataMissing',
      () async {
        identityFile().deleteSync();
        final e = await loadExpectingLost();
        expect(e.reason, IdentityLostReason.metadataMissing);
        expect(identityFile().existsSync(), isFalse);
        expect(await secrets.get('identity.key'), original.privateKeyPem);
        // Explicit creation needs the device id because there is none to reuse.
        await expectLater(
          make().createNewIdentity(generate: gen.call),
          throwsArgumentError,
        );
        final fresh = await make().createNewIdentity(
          generate: gen.call,
          deviceId: deviceB,
        );
        expect(fresh.identity.deviceId, deviceB);
      },
    );

    final corruptions = <String, void Function(File f)>{
      'garbage': (f) => f.writeAsStringSync('this is not json'),
      'empty': (f) => f.writeAsStringSync(''),
      'truncated': (f) {
        final b = f.readAsBytesSync();
        f.writeAsBytesSync(b.sublist(0, b.length ~/ 2));
      },
      'a JSON array': (f) => f.writeAsStringSync('[]'),
      'wrong member types': (f) => f.writeAsStringSync(
        '{"v":1,"deviceId":5,"fingerprint":[],"certPem":1}',
      ),
      'newer schema version': (f) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        j['v'] = 2;
        f.writeAsStringSync(jsonEncode(j));
      },
      'fingerprint that is not the hash of the certificate': (f) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        j['fingerprint'] = 'A' * 64;
        f.writeAsStringSync(jsonEncode(j));
      },
      'certificate swapped for another one': (f) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        j['certPem'] = fakeIdentity(deviceA, 4242).identity.certPem;
        f.writeAsStringSync(jsonEncode(j));
      },
      'certificate that is not PEM': (f) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        j['certPem'] = 'hello';
        f.writeAsStringSync(jsonEncode(j));
      },
      'missing key digest': (f) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        j.remove('keySha256');
        f.writeAsStringSync(jsonEncode(j));
      },
      'empty device id': (f) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
        j['deviceId'] = '';
        f.writeAsStringSync(jsonEncode(j));
      },
    };
    corruptions.forEach((label, damage) {
      test(
        'identity.json corrupt ($label) -> metadataCorrupt, not regeneration',
        () async {
          damage(identityFile());
          final damaged = identityFile().readAsBytesSync();
          final e = await loadExpectingLost();
          expect(e.reason, IdentityLostReason.metadataCorrupt);
          expect(
            identityFile().readAsBytesSync(),
            damaged,
            reason: 'kept as is',
          );
          expect(await secrets.get('identity.key'), original.privateKeyPem);
          // load() reports it too instead of pretending there is no identity.
          await expectLater(
            make().load(),
            throwsA(isA<IdentityLostException>()),
          );
        },
      );
    });

    test('identity.json replaced by a directory -> metadataCorrupt', () async {
      identityFile().deleteSync();
      Directory(identityFile().path).createSync();
      final e = await loadExpectingLost();
      expect(e.reason, IdentityLostReason.metadataCorrupt);
    });

    test('the five outcomes are distinct', () {
      expect(IdentityLostReason.values.toSet(), hasLength(5));
      expect(
        IdentityLostReason.values.map((r) => r.name),
        containsAll([
          'metadataMissing',
          'metadataCorrupt',
          'keyMissing',
          'keyUnreadable',
          'keyMismatch',
        ]),
      );
    });

    test('exception text carries a short fingerprint at most', () async {
      await secrets.delete('identity.key');
      final e = await loadExpectingLost();
      final text = e.toString();
      expect(e.shortFingerprint, shortFp(original.identity.fingerprint));
      expect(text, contains(shortFp(original.identity.fingerprint)));
      expect(text, isNot(contains(original.identity.fingerprint)));
      expect(text, isNot(contains('SENTINELKEY')));
    });
  });

  group('explicit replacement (D7)', () {
    test(
      'createNewIdentity replaces key and certificate, same device id',
      () async {
        final a = await make().loadOrCreate(
          generate: gen.call,
          deviceId: deviceA,
        );
        clock.t = DateTime.utc(2027, 1, 1);
        final b = await make().createNewIdentity(generate: gen.call);
        expect(gen.calls, 2);
        expect(b.created, isTrue);
        expect(b.identity.deviceId, deviceA);
        expect(b.identity.fingerprint, isNot(a.identity.fingerprint));
        expect(b.createdAt, DateTime.utc(2027, 1, 1));
        expect(await secrets.get('identity.key'), b.privateKeyPem);
        expect(secrets.names, ['identity.key']);
        final c = await make().loadOrCreate(
          generate: gen.call,
          deviceId: deviceA,
        );
        expect(c.identity.fingerprint, b.identity.fingerprint);
        expect(c.privateKeyPem, b.privateKeyPem);
      },
    );

    test('createNewIdentity can start a different device id', () async {
      await make().loadOrCreate(generate: gen.call, deviceId: deviceA);
      final b = await make().createNewIdentity(
        generate: gen.call,
        deviceId: deviceB,
      );
      expect(b.identity.deviceId, deviceB);
    });

    test('createNewIdentity on a fresh store just creates', () async {
      final s = await make().createNewIdentity(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(s.identity.deviceId, deviceA);
      expect(gen.calls, 1);
    });

    test('a generator failure changes nothing', () async {
      final a = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      await expectLater(
        make().createNewIdentity(
          generate: (id) => throw const FormatException('boom'),
        ),
        throwsFormatException,
      );
      final still = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(still.identity.fingerprint, a.identity.fingerprint);
    });

    test(
      'rotation interrupted before the key was staged keeps the old identity',
      () async {
        final a = await make().loadOrCreate(
          generate: gen.call,
          deviceId: deviceA,
        );
        final flaky = FlakySecretStore(secrets)
          ..failPuts.add('identity.key.next');
        await expectLater(
          make(store: flaky).createNewIdentity(generate: gen.call),
          throwsA(isA<SecretStoreException>()),
        );
        final still = await make().loadOrCreate(
          generate: gen.call,
          deviceId: deviceA,
        );
        expect(still.identity.fingerprint, a.identity.fingerprint);
        expect(still.privateKeyPem, a.privateKeyPem);
      },
    );

    test('rotation interrupted after the commit is completed by the next load', () async {
      await make().loadOrCreate(generate: gen.call, deviceId: deviceA);
      final flaky = FlakySecretStore(secrets)..failPuts.add('identity.key');
      await expectLater(
        make(store: flaky).createNewIdentity(generate: gen.call),
        throwsA(isA<SecretStoreException>()),
      );
      // Crash window: identity.json already names the new key, which is staged.
      expect(flaky.putLog, ['identity.key.next', 'identity.key']);
      final calls = gen.calls;
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(gen.calls, calls, reason: 'completing is not regenerating');
      expect(await secrets.get('identity.key'), s.privateKeyPem);
      expect(secrets.names, ['identity.key'], reason: 'staging copy gone');
      expect(
        s.identity.fingerprint,
        fakeIdentity(deviceA, 2).identity.fingerprint,
      );
    });

    test('an old staged key left behind is cleaned up on load', () async {
      final a = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      await secrets.put('identity.key.next', Uint8List.fromList([5, 5, 5]));
      final s = await make().loadOrCreate(
        generate: gen.call,
        deviceId: deviceA,
      );
      expect(s.identity.fingerprint, a.identity.fingerprint);
      expect(secrets.names, ['identity.key']);
    });
  });

  group('generator output is validated before anything is persisted', () {
    Future<void> expectRefused(
      ({DeviceIdentity identity, Uint8List privateKeyPem}) Function(String) g,
    ) async {
      await expectLater(
        make().loadOrCreate(generate: g, deviceId: deviceA),
        throwsStateError,
      );
      expect(identityFile().existsSync(), isFalse);
      expect(secrets.length, 0);
    }

    test('fingerprint that is not the hash of certDer', () async {
      await expectRefused((id) {
        final g = fakeIdentity(id, 1);
        return (
          identity: DeviceIdentity(
            deviceId: id,
            fingerprint: 'B' * 64,
            certDer: g.identity.certDer,
            certPem: g.identity.certPem,
          ),
          privateKeyPem: g.privateKeyPem,
        );
      });
    });

    test('lowercase fingerprint', () async {
      await expectRefused((id) {
        final g = fakeIdentity(id, 1);
        return (
          identity: DeviceIdentity(
            deviceId: id,
            fingerprint: g.identity.fingerprint.toLowerCase(),
            certDer: g.identity.certDer,
            certPem: g.identity.certPem,
          ),
          privateKeyPem: g.privateKeyPem,
        );
      });
    });

    test('PEM that is not the DER', () async {
      await expectRefused((id) {
        final g = fakeIdentity(id, 1);
        return (
          identity: DeviceIdentity(
            deviceId: id,
            fingerprint: g.identity.fingerprint,
            certDer: g.identity.certDer,
            certPem: fakeIdentity(id, 2).identity.certPem,
          ),
          privateKeyPem: g.privateKeyPem,
        );
      });
    });

    test('another device id than requested', () async {
      await expectRefused((id) => fakeIdentity(deviceB, 1));
    });

    test('empty private key', () async {
      await expectRefused((id) {
        final g = fakeIdentity(id, 1);
        return (identity: g.identity, privateKeyPem: Uint8List(0));
      });
    });

    test('key that fails the verifier', () async {
      await expectLater(
        make(verify: (i, k) => false)
            .loadOrCreate(generate: gen.call, deviceId: deviceA),
        throwsStateError,
      );
      expect(identityFile().existsSync(), isFalse);
    });
  });

  group('no secret in logs or messages', () {
    test('create, load, loss and rotation leak nothing', () async {
      final logs = captureLogs();
      final messages = <String>[];
      final store = make();
      final a = await store.loadOrCreate(generate: gen.call, deviceId: deviceA);
      await make().loadOrCreate(generate: gen.call, deviceId: deviceA);
      await secrets.delete('identity.key');
      try {
        await make().loadOrCreate(generate: gen.call, deviceId: deviceA);
      } on IdentityLostException catch (e) {
        messages.add('$e');
      }
      await make().createNewIdentity(generate: gen.call);
      identityFile().writeAsStringSync('garbage');
      try {
        await make().load();
      } on IdentityLostException catch (e) {
        messages.add('$e');
      }
      try {
        await make().createNewIdentity(
          generate: (id) => fakeIdentity('x', 1),
          deviceId: deviceA,
        );
      } on StateError catch (e) {
        messages.add('$e');
      }

      final all = '${flatten(logs)}\n${messages.join('\n')}';
      expect(all, isNot(contains('SENTINELKEY')));
      expect(all, isNot(contains('PRIVATE KEY')));
      expect(all, isNot(contains(base64.encode(a.privateKeyPem))));
      expect(all, isNot(contains(a.identity.fingerprint)));
      expect(
        RegExp(r'[0-9A-Fa-f]{17,}').hasMatch(all),
        isFalse,
        reason: 'at most 16 hex characters of a fingerprint may appear',
      );
      expect(logs, isNotEmpty, reason: 'creation and loss are worth a line');
    });
  });
}

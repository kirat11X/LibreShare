// P6a - SecurityWiring: the persistent device identity, trust store and PIN guard an engine runs on.
//
// Spec: docs/plans/inc3.md D3 (created once, never silently regenerated: a missing key with a present
// certificate is IdentityLost), D6 (key file 0600), D7 (explicit rotation only), D5 (PIN policy);
// docs/plans/inc3.md section 4.1 table row `unit/{credential_store,...}` (create once / reload gives the
// same fingerprint; 0600 on POSIX); P2 trust store persistence.
//
// SPEC-GAP: when an identity already exists, the `deviceId` argument of `open` is ignored and the
// stored one wins (CredentialStore.loadOrCreate semantics); `open` does not throw for the mismatch.
// SPEC-GAP: a corrupt `contacts.json` opens as an empty trust store (P2: backup `.corrupt`, no crash).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/p6a_support.dart';

bool _contains(List<int> haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Files below [dir] whose bytes contain [needle].
List<File> filesContaining(Directory dir, List<int> needle) => [
  for (final e in dir.listSync(recursive: true, followLinks: false))
    if (e is File && _contains(e.readAsBytesSync(), needle)) e,
];

String fakeFp(int n) => n.toRadixString(16).padLeft(64, 'A').toUpperCase();

void main() {
  late Directory tmp;
  final open = <SecurityWiring>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ls_p6a_wiring_');
  });
  tearDown(() async {
    for (final w in open) {
      await w.close();
    }
    open.clear();
    tmp.deleteSync(recursive: true);
  });

  Future<SecurityWiring> openIn(
    Directory dir, {
    String? deviceId,
    PinPolicy pinPolicy = const PinPolicy.off(),
    String? pin,
    ConsentPolicy consent = const ConsentPolicy(),
    bool allowInsecurePeers = false,
  }) async {
    final w = await SecurityWiring.open(
      directory: dir,
      deviceId: deviceId ?? newDeviceId(),
      pinPolicy: pinPolicy,
      pin: pin,
      consent: consent,
      allowInsecurePeers: allowInsecurePeers,
    );
    open.add(w);
    return w;
  }

  Directory dirNamed(String n) => Directory(p.join(tmp.path, n));

  // D3: create once, reload gives the same identity.
  group('identity is created once and reloaded', () {
    test(
      'first open creates a secure configuration around a fresh identity',
      () async {
        final id = newDeviceId();
        final w = await openIn(dirNamed('a'), deviceId: id);
        expect(w.identity.identity.deviceId, id);
        expect(
          w.identity.identity.fingerprint,
          matches(RegExp(r'^[0-9A-F]{64}$')),
        );
        expect(w.config.isSecure, isTrue);
        expect(w.config.identity, same(w.identity));
        expect(w.config.trust, same(w.trust));
        expect(w.trust.contacts, isEmpty);
        // The identity can sign: proves the private key is really there.
        expect(w.identity.sign(SigDomain.auth, [1, 2, 3]), hasLength(64));
      },
    );

    test('second open of the same directory gives the same device id, certificate and fingerprint', () async {
      final dir = dirNamed('a');
      final first = await openIn(dir, deviceId: newDeviceId());
      final fp = first.identity.identity.fingerprint;
      final der = Uint8List.fromList(first.identity.identity.certDer);
      final id = first.identity.identity.deviceId;
      await first.close();

      final second = await openIn(dir, deviceId: newDeviceId());
      expect(second.identity.identity.fingerprint, fp);
      expect(second.identity.identity.certDer, der);
      expect(
        second.identity.identity.deviceId,
        id,
        reason: 'the stored device id wins over the argument',
      );
    });

    test(
      'two different directories are two different identities (twin)',
      () async {
        final a = await openIn(dirNamed('a'));
        final b = await openIn(dirNamed('b'));
        expect(
          a.identity.identity.fingerprint,
          isNot(b.identity.identity.fingerprint),
        );
        expect(
          a.identity.identity.deviceId,
          isNot(b.identity.identity.deviceId),
        );
      },
    );

    test(
      'a directory that does not exist yet is created (including parents)',
      () async {
        final w = await openIn(Directory(p.join(tmp.path, 'x', 'y', 'z')));
        expect(Directory(p.join(tmp.path, 'x', 'y', 'z')).existsSync(), isTrue);
        expect(w.identity.identity.fingerprint, isNotEmpty);
      },
    );
  });

  // D3: never silently regenerate.
  group('IdentityLost: a missing key is never papered over', () {
    test('certificate present, private key deleted: open throws IdentityLostException, and keeps throwing', () async {
      final dir = dirNamed('a');
      final w = await openIn(dir);
      final key = Uint8List.fromList(w.identity.privateKeyPem());
      await w.close();

      final keyFiles = filesContaining(dir, utf8.encode('PRIVATE KEY'));
      expect(
        keyFiles,
        isNotEmpty,
        reason: 'twin: the harness found the key file',
      );
      for (final f in keyFiles) {
        f.deleteSync();
      }
      expect(filesContaining(dir, key.sublist(0, 30)), isEmpty);
      final before = {
        for (final e in dir.listSync(recursive: true))
          if (e is File) e.path: e.readAsBytesSync(),
      };

      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          SecurityWiring.open(directory: dir, deviceId: newDeviceId()),
          throwsA(isA<IdentityLostException>()),
          reason: 'attempt $attempt',
        );
      }
      final after = {
        for (final e in dir.listSync(recursive: true))
          if (e is File) e.path: e.readAsBytesSync(),
      };
      expect(
        after.keys.toSet(),
        before.keys.toSet(),
        reason: 'no file created or removed',
      );
      for (final k in before.keys) {
        expect(after[k], before[k], reason: 'unchanged: $k');
      }
      expect(
        filesContaining(dir, utf8.encode('PRIVATE KEY')),
        isEmpty,
        reason: 'no replacement key was written',
      );
    });

    test(
      'key present, certificate metadata deleted: also IdentityLost',
      () async {
        final dir = dirNamed('a');
        final w = await openIn(dir);
        await w.close();
        final meta = File(p.join(dir.path, 'identity.json'));
        expect(
          meta.existsSync(),
          isTrue,
          reason:
              'identity.json is where CredentialStore keeps the certificate',
        );
        meta.deleteSync();
        await expectLater(
          SecurityWiring.open(directory: dir, deviceId: newDeviceId()),
          throwsA(isA<IdentityLostException>()),
        );
      },
    );

    test(
      'a corrupt identity.json is IdentityLost, not a new identity',
      () async {
        final dir = dirNamed('a');
        final w = await openIn(dir);
        await w.close();
        File(p.join(dir.path, 'identity.json')).writeAsStringSync('{ not json');
        await expectLater(
          SecurityWiring.open(directory: dir, deviceId: newDeviceId()),
          throwsA(isA<IdentityLostException>()),
        );
      },
    );
  });

  // D6: the only secret on disk is the private key; it is 0600.
  group('key file permissions (POSIX)', () {
    test('every file holding the private key is mode 0600 and not group/world accessible', () async {
      final dir = dirNamed('a');
      final w = await openIn(dir);
      final keyBody = pemBody(w.identity.privateKeyPem());
      final holders = filesContaining(dir, utf8.encode('PRIVATE KEY'));
      expect(
        holders,
        isNotEmpty,
        reason: 'twin: the key is stored somewhere under the directory',
      );
      for (final f in holders) {
        final mode = f.statSync().mode & 0x1ff;
        expect(
          mode & 0x3f,
          0,
          reason:
              '${p.basename(f.path)} is accessible to group/other (${mode.toRadixString(8)})',
        );
        expect(mode & 0x180, 0x180, reason: 'owner read/write');
        expect(f.statSync().mode & 0x1ff, 0x180, reason: '0600');
        expect(
          f.parent.statSync().mode & 0x3f,
          0,
          reason: 'its directory is private too',
        );
      }
      // The certificate metadata is public by nature and must not carry the key.
      final meta = File(p.join(dir.path, 'identity.json')).readAsStringSync();
      expect(meta, isNot(contains('PRIVATE KEY')));
      expect(meta, isNot(contains(keyBody)));
    }, skip: Platform.isWindows ? 'POSIX modes' : null);
  });

  // P2 trust store is persistent in the wiring.
  group('the trust store survives a restart', () {
    test('known, trusted and blocked entries are all still there after close and open', () async {
      final dir = dirNamed('a');
      final w = await openIn(dir);
      final k = newDeviceId();
      final t = newDeviceId();
      await w.trust.pin(
        deviceId: k,
        fingerprint: fakeFp(1),
        alias: 'Known',
        trust: PeerTrust.known,
      );
      await w.trust.pin(
        deviceId: t,
        fingerprint: fakeFp(2),
        alias: 'Trusted',
        trust: PeerTrust.trusted,
      );
      await w.trust.block(fakeFp(3));
      await w.close();

      final again = await openIn(dir);
      final byId = {for (final c in again.trust.contacts) c.deviceId: c};
      expect(byId.keys, containsAll([k, t]));
      expect(byId[k]!.trust, PeerTrust.known);
      expect(byId[k]!.fingerprint, fakeFp(1));
      expect(byId[k]!.alias, 'Known');
      expect(byId[t]!.trust, PeerTrust.trusted);
      expect(
        again.trust.classifyFingerprint(fakeFp(3)).trust,
        PeerTrust.blocked,
      );
      expect(again.trust.classify(k, fakeFp(1)).trust, PeerTrust.known);
      expect(
        again.trust.classify(k, fakeFp(9)).keyChanged,
        isTrue,
        reason: 'the pin is enforced after the restart',
      );
    });

    test('a removed contact stays removed after the restart (twin of the persistence check)', () async {
      final dir = dirNamed('a');
      final w = await openIn(dir);
      final k = newDeviceId();
      await w.trust.pin(
        deviceId: k,
        fingerprint: fakeFp(1),
        alias: 'Known',
        trust: PeerTrust.known,
      );
      await w.trust.remove(k);
      await w.close();
      final again = await openIn(dir);
      expect(again.trust.contacts, isEmpty);
    });

    test('a corrupt contacts file opens as an empty trust store instead of crashing', () async {
      final dir = dirNamed('a');
      final w = await openIn(dir);
      await w.trust.pin(
        deviceId: newDeviceId(),
        fingerprint: fakeFp(1),
        alias: 'K',
        trust: PeerTrust.known,
      );
      await w.close();
      final contacts = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => p.basename(f.path) == 'contacts.json')
          .toList();
      expect(
        contacts,
        hasLength(1),
        reason: 'contacts.json lives under the identity directory',
      );
      contacts.single.writeAsStringSync('}{ garbage');
      final again = await openIn(dir);
      expect(again.trust.contacts, isEmpty);
      expect(
        again.identity.identity.fingerprint,
        w.identity.identity.fingerprint,
        reason: 'the identity is independent of the contact list',
      );
    });
  });

  // D5: PIN policy and the guard the engine hands to the receiver.
  group('PIN policy', () {
    test('off by default: the guard enforces nothing and has no PIN', () async {
      final w = await openIn(dirNamed('a'));
      expect(w.pinGuard.enforced, isFalse);
      expect(w.pinGuard.currentPin, isNull);
      expect(w.config.pin.enabled, isFalse);
      expect(w.config.allowInsecurePeers, isFalse);
    });

    test(
      'fixed policy with a PIN: the guard enforces exactly that PIN',
      () async {
        final w = await openIn(
          dirNamed('a'),
          pinPolicy: const PinPolicy(mode: PinMode.fixed),
          pin: '424242',
        );
        expect(w.pinGuard.enforced, isTrue);
        expect(w.pinGuard.currentPin, '424242');
        expect(w.config.pin.mode, PinMode.fixed);
        expect(
          () => w.pinGuard.check(
            remoteAddress: '127.0.0.1',
            pin: null,
            exempt: false,
          ),
          throwsA(
            isA<LsException>().having(
              (e) => e.code,
              'code',
              LsErrorCode.pinRequired,
            ),
          ),
        );
        expect(
          () => w.pinGuard.check(
            remoteAddress: '127.0.0.1',
            pin: '000000',
            exempt: false,
          ),
          throwsA(
            isA<LsException>().having(
              (e) => e.code,
              'code',
              LsErrorCode.pinInvalid,
            ),
          ),
        );
        w.pinGuard.check(
          remoteAddress: '127.0.0.1',
          pin: '424242',
          exempt: false,
        );
        w.pinGuard.check(remoteAddress: '127.0.0.1', pin: null, exempt: true);
      },
    );

    test('window policy without a PIN generates a six digit PIN', () async {
      final w = await openIn(
        dirNamed('a'),
        pinPolicy: const PinPolicy(mode: PinMode.window),
      );
      expect(w.pinGuard.currentPin, matches(RegExp(r'^\d{6}$')));
    });

    test(
      'a malformed fixed PIN is refused and the message does not contain it',
      () async {
        try {
          await SecurityWiring.open(
            directory: dirNamed('a'),
            deviceId: newDeviceId(),
            pinPolicy: const PinPolicy(mode: PinMode.fixed),
            pin: '12ab9',
          );
          fail('a PIN that is not six digits must be refused');
        } on Object catch (e) {
          expect(e.toString(), isNot(contains('12ab9')));
        }
      },
    );

    test(
      'consent and allowInsecurePeers pass through to the configuration',
      () async {
        final w = await openIn(
          dirNamed('a'),
          consent: const ConsentPolicy(
            autoAcceptTrusted: true,
            maxPendingPerIp: 1,
          ),
          allowInsecurePeers: true,
        );
        expect(w.config.consent.autoAcceptTrusted, isTrue);
        expect(w.config.consent.maxPendingPerIp, 1);
        expect(w.config.allowInsecurePeers, isTrue);
      },
    );
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/cert_factory.dart';
import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart';
import 'package:libreshare_core/src/security/key_identity.dart';
import 'package:test/test.dart';

final BigInt rfcD = BigInt.parse(
  'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721',
  radix: 16,
);
final DateTime t0 = DateTime.utc(2026, 11, 4, 12);

/// Strings that must never appear in an exception message or `toString` for the key [d].
List<String> secretsOf(BigInt d, Uint8List keyPem) {
  final raw = bigIntToBytes(d, 32);
  final pemBody = utf8
      .decode(keyPem)
      .split('\n')
      .where((l) => l.isNotEmpty && !l.startsWith('-----'))
      .join();
  return [
    hexOf(raw),
    hexOf(raw).toUpperCase(),
    b64urlEncode(raw),
    base64.encode(raw),
    pemBody.substring(0, 24),
    pemBody,
    hexOf(keyPem),
  ];
}

void expectNoSecret(Object error, List<String> secrets) {
  final text = '$error';
  for (final s in secrets) {
    expect(text.contains(s), isFalse, reason: 'leaked ${s.length}-char secret');
  }
}

Matcher problem(KeyIdentityProblem p) =>
    throwsA(isA<KeyIdentityException>().having((e) => e.problem, 'problem', p));

void main() {
  late GeneratedIdentity a;
  late GeneratedIdentity b;
  setUpAll(() {
    a = generateIdentity(deviceId: 'device-a', now: t0);
    b = generateIdentity(deviceId: 'device-b', now: t0);
  });

  group('construction', () {
    test(
      'fromGenerated exposes the identity and recomputes the fingerprint',
      () {
        final k = KeyIdentity.fromGenerated(a);
        expect(k.identity.deviceId, 'device-a');
        expect(k.identity.certDer, a.identity.certDer);
        expect(k.identity.certPem, a.identity.certPem);
        expect(k.identity.fingerprint, fingerprintHex(a.identity.certDer));
        expect(k, isA<IdentityProvider>());
      },
    );

    test('built from DER only, from PEM only, and from both (consistent)', () {
      final fromDer = KeyIdentity(
        deviceId: 'device-a',
        certDer: a.identity.certDer,
        privateKeyPem: a.privateKeyPem,
      );
      final fromPem = KeyIdentity(
        deviceId: 'device-a',
        certPem: a.identity.certPem,
        privateKeyPem: a.privateKeyPem,
      );
      final both = KeyIdentity(
        deviceId: 'device-a',
        certDer: a.identity.certDer,
        certPem: a.identity.certPem,
        privateKeyPem: a.privateKeyPem,
      );
      for (final k in [fromDer, fromPem, both]) {
        expect(k.identity.fingerprint, a.identity.fingerprint);
        expect(k.identity.certDer, a.identity.certDer);
        expect(k.identity.certPem, a.identity.certPem);
      }
    });

    test(
      'the stored fingerprint of an old record is irrelevant: it is recomputed',
      () {
        // The constructor has no fingerprint parameter at all; the value always
        // derives from the certificate bytes.
        final k = KeyIdentity.fromGenerated(b);
        expect(k.identity.fingerprint, isNot(a.identity.fingerprint));
        expect(k.identity.fingerprint, fingerprintHex(b.identity.certDer));
      },
    );

    test('needs a certificate in some form', () {
      expect(
        () => KeyIdentity(deviceId: 'device-a', privateKeyPem: a.privateKeyPem),
        throwsArgumentError,
      );
    });

    test('PEM and DER that disagree are refused', () {
      expect(
        () => KeyIdentity(
          deviceId: 'device-a',
          certDer: a.identity.certDer,
          certPem: b.identity.certPem,
          privateKeyPem: a.privateKeyPem,
        ),
        problem(KeyIdentityProblem.badCertificate),
      );
    });

    test(
      'certificate of one key with the private key of another is refused',
      () {
        expect(
          () => KeyIdentity(
            deviceId: 'device-a',
            certDer: a.identity.certDer,
            privateKeyPem: b.privateKeyPem,
          ),
          problem(KeyIdentityProblem.keyMismatch),
        );
      },
    );

    test('deviceId must equal the certificate CN', () {
      expect(
        () => KeyIdentity(
          deviceId: 'someone-else',
          certDer: a.identity.certDer,
          privateKeyPem: a.privateKeyPem,
        ),
        problem(KeyIdentityProblem.deviceIdMismatch),
      );
    });

    test('hostile or broken certificates are refused', () {
      final ca = buildCertificateDer(
        signerKey: rfcD,
        subjectPublicPoint: p256PublicPoint(rfcD),
        subjectCn: 'device-a',
        notBefore: t0,
        notAfter: t0.add(const Duration(days: 30)),
        serial: BigInt.one,
        ca: true,
      );
      final good = identityFromScalar(
        deviceId: 'device-a',
        privateScalar: rfcD,
        now: t0,
        serial: BigInt.two,
      );
      final badSig = Uint8List.fromList(good.identity.certDer)
        ..[good.identity.certDer.length - 3] ^= 1;
      for (final der in [
        ca,
        badSig,
        Uint8List(0),
        Uint8List.fromList([1, 2, 3]),
        Uint8List(5000),
      ]) {
        expect(
          () => KeyIdentity(
            deviceId: 'device-a',
            certDer: der,
            privateKeyPem: good.privateKeyPem,
          ),
          problem(KeyIdentityProblem.badCertificate),
        );
      }
    });

    test('broken private keys are refused', () {
      for (final pem in [
        Uint8List(0),
        Uint8List.fromList(
          utf8.encode(
            '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n',
          ),
        ),
        a.identity.certDer, // a certificate is not a key
        Uint8List.fromList(utf8.encode(a.identity.certPem)),
      ]) {
        expect(
          () => KeyIdentity(
            deviceId: 'device-a',
            certDer: a.identity.certDer,
            privateKeyPem: pem,
          ),
          problem(KeyIdentityProblem.badPrivateKey),
        );
      }
    });
  });

  group('sign', () {
    test('64 raw bytes r||s that verify over domain + NUL + message', () {
      final k = KeyIdentity.fromGenerated(a);
      final cert = parseCertificate(a.identity.certDer);
      final sig = k.sign('LSP1-AUTH-v1', utf8.encode('hello'));
      expect(sig.length, 64);
      expect(
        p256VerifyRaw(cert.publicPoint, [
          ...utf8.encode('LSP1-AUTH-v1'),
          0,
          ...utf8.encode('hello'),
        ], sig),
        isTrue,
      );
    });

    test('signed bytes are exactly domain, one NUL, message', () {
      final k = KeyIdentity.fromGenerated(
        identityFromScalar(
          deviceId: 'rfc',
          privateScalar: rfcD,
          now: t0,
          serial: BigInt.one,
        ),
      );
      final expected = p256SignRaw(rfcD, [
        ...'LSP1-BYE'.codeUnits,
        0,
        ...'payload'.codeUnits,
      ]);
      expect(k.sign(SigDomain.bye, 'payload'.codeUnits), expected);
    });

    test('is deterministic (RFC 6979)', () {
      final k = KeyIdentity.fromGenerated(a);
      expect(
        k.sign(SigDomain.auth, [1, 2, 3]),
        k.sign(SigDomain.auth, [1, 2, 3]),
      );
    });

    test('domain separation at the primitive level', () {
      final k = KeyIdentity.fromGenerated(a);
      final cert = parseCertificate(a.identity.certDer);
      final sig = k.sign(SigDomain.bye, [9, 9, 9]);
      Uint8List input(String d) =>
          Uint8List.fromList([...utf8.encode(d), 0, 9, 9, 9]);
      expect(
        p256VerifyRaw(cert.publicPoint, input(SigDomain.bye), sig),
        isTrue,
      );
      expect(
        p256VerifyRaw(cert.publicPoint, input(SigDomain.auth), sig),
        isFalse,
      );
      // a domain that is a prefix of another cannot be confused either
      final s2 = k.sign('LSP1', [0x41]);
      expect(
        p256VerifyRaw(cert.publicPoint, [...'LSP1'.codeUnits, 0, 0x41], s2),
        isTrue,
      );
      expect(
        p256VerifyRaw(cert.publicPoint, [...'LSP1A'.codeUnits, 0, 0x41], s2),
        isFalse,
      );
    });

    test('rejects an empty domain and a domain containing NUL', () {
      final k = KeyIdentity.fromGenerated(a);
      expect(() => k.sign('', [1]), throwsArgumentError);
      expect(() => k.sign('A\u0000B', [1]), throwsArgumentError);
    });

    test('different keys give different signatures', () {
      final sa = KeyIdentity.fromGenerated(a).sign(SigDomain.auth, [1]);
      final sb = KeyIdentity.fromGenerated(b).sign(SigDomain.auth, [1]);
      expect(sa, isNot(sb));
    });
  });

  group('privateKeyPem and diagnostics', () {
    test('returns the PKCS#8 PEM as an independent copy', () {
      final k = KeyIdentity.fromGenerated(a);
      final pem = k.privateKeyPem();
      expect(pem, a.privateKeyPem);
      pem[30] ^= 0xFF; // caller scribbles on its copy
      expect(k.privateKeyPem(), a.privateKeyPem);
      expect(k.sign(SigDomain.auth, [1]).length, 64);
    });

    test('constructor copies its inputs too', () {
      final pem = Uint8List.fromList(a.privateKeyPem);
      final k = KeyIdentity(
        deviceId: 'device-a',
        certDer: a.identity.certDer,
        privateKeyPem: pem,
      );
      pem.fillRange(0, pem.length, 0);
      expect(k.privateKeyPem(), a.privateKeyPem);
    });

    test('toString shows the device id and a short fingerprint only', () {
      final k = KeyIdentity.fromGenerated(a);
      final s = k.toString();
      final d = decodePkcs8PrivateKeyPem(a.privateKeyPem);
      expectNoSecret(s, secretsOf(d, a.privateKeyPem));
      expect(s, contains('device-a'));
      expect(s, contains(shortFp(a.identity.fingerprint)));
      expect(s.contains(a.identity.fingerprint), isFalse);
    });

    test('no key material in any failure path message', () {
      final d = decodePkcs8PrivateKeyPem(a.privateKeyPem);
      final secrets = secretsOf(d, a.privateKeyPem);
      final dB = decodePkcs8PrivateKeyPem(b.privateKeyPem);
      final secretsB = secretsOf(dB, b.privateKeyPem);
      final attempts = <void Function()>[
        () => KeyIdentity(
          deviceId: 'device-a',
          certDer: a.identity.certDer,
          privateKeyPem: b.privateKeyPem,
        ),
        () => KeyIdentity(
          deviceId: 'nope',
          certDer: a.identity.certDer,
          privateKeyPem: a.privateKeyPem,
        ),
        () => KeyIdentity(
          deviceId: 'device-a',
          certDer: a.identity.certDer,
          privateKeyPem: Uint8List.fromList(
            utf8.encode(utf8.decode(a.privateKeyPem).replaceFirst('M', 'N')),
          ),
        ),
        () => KeyIdentity(
          deviceId: 'device-a',
          certDer: Uint8List(10),
          privateKeyPem: a.privateKeyPem,
        ),
      ];
      var thrown = 0;
      for (final f in attempts) {
        try {
          f();
        } on Object catch (e) {
          thrown++;
          expectNoSecret(e, secrets);
          expectNoSecret(e, secretsB);
          if (e is KeyIdentityException) {
            expectNoSecret(e.message, secrets);
            expectNoSecret(e.message, secretsB);
          }
        }
      }
      expect(thrown, attempts.length);
    });
  });
}

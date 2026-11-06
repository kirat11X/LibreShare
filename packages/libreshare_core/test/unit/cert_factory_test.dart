import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/cert_factory.dart';
import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart';
import 'package:libreshare_core/src/security/der.dart';
import 'package:test/test.dart';

/// RFC 6979 appendix A.2.5 key (a public test key, never used for anything real).
final BigInt rfcD = BigInt.parse(
  'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721',
  radix: 16,
);
const rfcUx =
    '60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6';
const rfcUy =
    '7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299';
// ECDSA/SHA-256 over "sample" with that key (RFC 6979 A.2.5; also reproduced by
// `openssl dgst -sha256 -sign ... -sigopt nonce-type:1`).
const rfcR = 'efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716';
const rfcS = 'f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8';

final DateTime t0 = DateTime.utc(2026, 11, 4, 12, 30, 45, 678);

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

bool _hasOpenssl() {
  try {
    return Process.runSync('openssl', ['version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

final bool hasOpenssl = _hasOpenssl();
final Object skipNoOpenssl = hasOpenssl ? false : 'openssl missing';

/// A certificate for the RFC key with knobs for negative cases.
Uint8List mk({
  Uint8List? point,
  String cn = 'device-0001',
  String? issuerCn,
  DateTime? notBefore,
  DateTime? notAfter,
  BigInt? serial,
  bool ca = false,
  bool bc = true,
  bool ku = true,
  bool eku = true,
  int kuByte = 0x80,
  int kuUnused = 7,
  List<Uint8List> extra = const [],
  Uint8List? spki,
  bool version = true,
  String? sigOid,
  String? outerSigOid,
}) => buildCertificateDer(
  signerKey: rfcD,
  subjectPublicPoint: point ?? p256PublicPoint(rfcD),
  subjectCn: cn,
  issuerCn: issuerCn,
  notBefore: notBefore ?? DateTime.utc(2026, 11, 3, 12),
  notAfter: notAfter ?? DateTime.utc(2036, 11, 1, 12),
  serial: serial ?? BigInt.from(0x1234567),
  ca: ca,
  includeBasicConstraints: bc,
  includeKeyUsage: ku,
  includeExtKeyUsage: eku,
  keyUsageByte: kuByte,
  keyUsageUnused: kuUnused,
  extraExtensions: extra,
  spkiOverride: spki,
  includeVersion: version,
  signatureOid: sigOid ?? oidEcdsaWithSha256,
  outerSignatureOid: outerSigOid,
);

Uint8List spkiFor({
  required String keyAlg,
  required String? paramsOid,
  required List<int> point,
}) => derSequence([
  derSequence([derOid(keyAlg), if (paramsOid != null) derOid(paramsOid)]),
  derBitString(point),
]);

Matcher get badCert => throwsA(isA<CertificateFormatException>());

void main() {
  group('P-256 helpers', () {
    test('constants agree with the curve implementation in pointycastle', () {
      expect(p256ConstantsAgreeWithImplementation(), isTrue);
    });

    test('RFC 6979 A.2.5: public key from the private scalar', () {
      final pt = p256PublicPoint(rfcD);
      expect(pt.length, 65);
      expect(pt[0], 4);
      expect(hexOf(pt.sublist(1, 33)), rfcUx);
      expect(hexOf(pt.sublist(33)), rfcUy);
    });

    test('RFC 6979 A.2.5: deterministic ECDSA-SHA256 known answer', () {
      final sig = p256SignRaw(rfcD, 'sample'.codeUnits);
      expect(sig.length, 64);
      expect(hexOf(sig.sublist(0, 32)), rfcR);
      expect(hexOf(sig.sublist(32)), rfcS);
      // deterministic: identical on repeat
      expect(p256SignRaw(rfcD, 'sample'.codeUnits), sig);
    });

    test('verify accepts the known answer and rejects tampering', () {
      final pt = p256PublicPoint(rfcD);
      final sig = p256SignRaw(rfcD, 'sample'.codeUnits);
      expect(p256VerifyRaw(pt, 'sample'.codeUnits, sig), isTrue);
      expect(p256VerifyRaw(pt, 'sample!'.codeUnits, sig), isFalse);
      final bad = Uint8List.fromList(sig)..[10] ^= 1;
      expect(p256VerifyRaw(pt, 'sample'.codeUnits, bad), isFalse);
      final other = p256PublicPoint(generateP256Scalar());
      expect(p256VerifyRaw(other, 'sample'.codeUnits, sig), isFalse);
    });

    test(
      'verify accepts the high-s twin (no malleability rule is imposed)',
      () {
        final pt = p256PublicPoint(rfcD);
        final sig = p256SignRaw(rfcD, 'sample'.codeUnits);
        final s = bigIntFromBytes(sig.sublist(32));
        final twin = Uint8List.fromList([
          ...sig.sublist(0, 32),
          ...bigIntToBytes(kP256Order - s, 32),
        ]);
        expect(p256VerifyRaw(pt, 'sample'.codeUnits, twin), isTrue);
      },
    );

    test(
      'verify rejects r or s of 0, >= n, and wrong lengths without throwing',
      () {
        final pt = p256PublicPoint(rfcD);
        final good = p256SignRaw(rfcD, 'sample'.codeUnits);
        final r = good.sublist(0, 32);
        final s = good.sublist(32);
        final zero = Uint8List(32);
        final n = bigIntToBytes(kP256Order, 32);
        final nPlus = bigIntToBytes(kP256Order + BigInt.one, 32);
        final ff = Uint8List.fromList(List.filled(32, 0xff));
        final cases = <String, List<int>>{
          'r=0': [...zero, ...s],
          's=0': [...r, ...zero],
          'r=n': [...n, ...s],
          's=n': [...r, ...n],
          'r=n+1': [...nPlus, ...s],
          's=n+1': [...r, ...nPlus],
          'r=2^256-1': [...ff, ...s],
          's=2^256-1': [...r, ...ff],
          'both zero': Uint8List(64),
          'empty': const <int>[],
          '63 bytes': good.sublist(0, 63),
          '65 bytes': [...good, 0],
          '32 bytes': r,
          'DER-ish 72 bytes': Uint8List(72),
        };
        cases.forEach((name, sig) {
          expect(
            p256VerifyRaw(pt, 'sample'.codeUnits, sig),
            isFalse,
            reason: name,
          );
        });
      },
    );

    test('verify returns false for invalid public points', () {
      final sig = p256SignRaw(rfcD, 'sample'.codeUnits);
      final good = p256PublicPoint(rfcD);
      expect(p256VerifyRaw(Uint8List(0), 'sample'.codeUnits, sig), isFalse);
      expect(p256VerifyRaw(Uint8List(65), 'sample'.codeUnits, sig), isFalse);
      expect(
        p256VerifyRaw(good.sublist(0, 64), 'sample'.codeUnits, sig),
        isFalse,
      );
    });

    test('isValidP256Point: the generator and random keys are valid', () {
      expect(isValidP256Point(p256PublicPoint(BigInt.one)), isTrue);
      for (var i = 0; i < 5; i++) {
        expect(isValidP256Point(p256PublicPoint(generateP256Scalar())), isTrue);
      }
    });

    test(
      'isValidP256Point rejects off-curve, malformed and special points',
      () {
        final good = p256PublicPoint(rfcD);
        final offCurve = Uint8List.fromList(good)..[64] ^= 1;
        expect(isValidP256Point(offCurve), isFalse);
        expect(isValidP256Point(Uint8List(65)), isFalse); // 0x00 prefix
        expect(isValidP256Point(Uint8List.fromList([0])), isFalse); // infinity
        expect(isValidP256Point(good.sublist(0, 33)), isFalse);
        expect(
          isValidP256Point(Uint8List.fromList([2, ...good.sublist(1, 33)])),
          isFalse,
          reason: 'compressed form is not accepted',
        );
        expect(isValidP256Point(Uint8List.fromList([...good, 0])), isFalse);
        // x >= p
        final big = Uint8List.fromList([
          4,
          ...bigIntToBytes(kP256Prime + BigInt.one, 32),
          ...good.sublist(33),
        ]);
        expect(isValidP256Point(big), isFalse);
        // the group order as x or y is not a coordinate of any valid point here
        expect(
          isValidP256Point(
            Uint8List.fromList([
              4,
              ...bigIntToBytes(kP256Order, 32),
              ...bigIntToBytes(kP256Order, 32),
            ]),
          ),
          isFalse,
        );
      },
    );

    test('generateP256Scalar is in [1, n-1] and differs per call', () {
      final a = generateP256Scalar();
      final b = generateP256Scalar();
      expect(a, isNot(b));
      for (final v in [a, b]) {
        expect(v > BigInt.zero && v < kP256Order, isTrue);
      }
    });
  });

  group('PEM', () {
    test('round trip with 64-column lines', () {
      final data = Uint8List.fromList(List.generate(300, (i) => i & 0xFF));
      final pem = pemEncode(data, 'CERTIFICATE');
      expect(pem, startsWith('-----BEGIN CERTIFICATE-----\n'));
      expect(pem, endsWith('-----END CERTIFICATE-----\n'));
      for (final line in pem.split('\n')) {
        expect(line.length, lessThanOrEqualTo(64));
      }
      expect(pemDecode(pem, 'CERTIFICATE'), data);
    });

    test('accepts CRLF line endings', () {
      final data = Uint8List.fromList(List.generate(100, (i) => i));
      final pem = pemEncode(data, 'CERTIFICATE').replaceAll('\n', '\r\n');
      expect(pemDecode(pem, 'CERTIFICATE'), data);
    });

    test('rejects wrong label, missing footer, garbage, trailing data', () {
      final data = Uint8List.fromList(List.generate(50, (i) => i));
      final pem = pemEncode(data, 'CERTIFICATE');
      expect(() => pemDecode(pem, 'PRIVATE KEY'), throwsFormatException);
      expect(
        () => pemDecode(
          pem.replaceAll('-----END CERTIFICATE-----', ''),
          'CERTIFICATE',
        ),
        throwsFormatException,
      );
      expect(() => pemDecode('not pem', 'CERTIFICATE'), throwsFormatException);
      expect(() => pemDecode('', 'CERTIFICATE'), throwsFormatException);
      expect(() => pemDecode('$pem$pem', 'CERTIFICATE'), throwsFormatException);
      expect(
        () => pemDecode('${pem}junk', 'CERTIFICATE'),
        throwsFormatException,
      );
      expect(
        () => pemDecode(
          '-----BEGIN CERTIFICATE-----\n@@@@\n-----END CERTIFICATE-----\n',
          'CERTIFICATE',
        ),
        throwsFormatException,
      );
    });

    test('rejects absurdly large input', () {
      final huge = pemEncode(Uint8List(100000), 'CERTIFICATE');
      expect(() => pemDecode(huge, 'CERTIFICATE'), throwsFormatException);
    });
  });

  group('PKCS#8 private key', () {
    test(
      'encode then decode gives the same scalar; PEM label is PRIVATE KEY',
      () {
        final pem = encodePkcs8PrivateKeyPem(rfcD);
        final text = utf8.decode(pem);
        expect(text, startsWith('-----BEGIN PRIVATE KEY-----\n'));
        expect(decodePkcs8PrivateKeyPem(pem), rfcD);
      },
    );

    test(
      'structure is PrivateKeyInfo{0, {ecPublicKey, prime256v1}, ECPrivateKey}',
      () {
        final der = pemDecode(
          utf8.decode(encodePkcs8PrivateKeyPem(rfcD)),
          'PRIVATE KEY',
        );
        final top = derParseSingle(der).reader();
        expect(top.expect(DerTag.integer).asInteger(), BigInt.zero);
        final alg = top.expect(DerTag.sequence).reader();
        expect(alg.read().asOid(), oidEcPublicKey);
        expect(alg.read().asOid(), oidPrime256v1);
        alg.finish();
        final inner = derParseSingle(top.expect(DerTag.octetString).content)
            .reader();
        expect(inner.expect(DerTag.integer).asInteger(), BigInt.one);
        expect(
          inner.expect(DerTag.octetString).content,
          bigIntToBytes(rfcD, 32),
        );
      },
    );

    test('small scalars keep the fixed 32-byte width', () {
      final pem = encodePkcs8PrivateKeyPem(BigInt.from(5));
      expect(decodePkcs8PrivateKeyPem(pem), BigInt.from(5));
    });

    test('rejects 0, n, and values above n on encode', () {
      for (final bad in [BigInt.zero, kP256Order, kP256Order + BigInt.one]) {
        expect(() => encodePkcs8PrivateKeyPem(bad), throwsArgumentError);
      }
    });

    Uint8List pkcs8({
      BigInt? version,
      String curve = oidPrime256v1,
      String keyAlg = oidEcPublicKey,
      List<int>? d,
      List<Uint8List> ecExtra = const [],
      List<int> trailing = const [],
      int ecVersion = 1,
    }) {
      final ecKey = derSequence([
        derInteger(BigInt.from(ecVersion)),
        derOctetString(d ?? bigIntToBytes(rfcD, 32)),
        ...ecExtra,
      ]);
      final info = derSequence([
        derInteger(version ?? BigInt.zero),
        derSequence([derOid(keyAlg), derOid(curve)]),
        derOctetString(ecKey),
      ]);
      return Uint8List.fromList(
        utf8.encode(pemEncode([...info, ...trailing], 'PRIVATE KEY')),
      );
    }

    test(
      'decoder accepts the optional embedded public key when it matches',
      () {
        final pub = derExplicit(1, derBitString(p256PublicPoint(rfcD)));
        expect(decodePkcs8PrivateKeyPem(pkcs8(ecExtra: [pub])), rfcD);
      },
    );

    test(
      'decoder rejects malformed or foreign keys with KeyFormatException',
      () {
        final pubOther = derExplicit(
          1,
          derBitString(p256PublicPoint(BigInt.from(7))),
        );
        final cases = <String, Uint8List>{
          'wrong curve (P-384 OID)': pkcs8(curve: '1.3.132.0.34'),
          'RSA algorithm': pkcs8(keyAlg: '1.2.840.113549.1.1.1'),
          'version 1 PrivateKeyInfo': pkcs8(version: BigInt.one),
          'd = 0': pkcs8(d: Uint8List(32)),
          'd = n': pkcs8(d: bigIntToBytes(kP256Order, 32)),
          'd = 2^256-1': pkcs8(d: List.filled(32, 0xff)),
          'short d': pkcs8(d: List.filled(31, 1)),
          'long d': pkcs8(d: List.filled(33, 1)),
          'ECPrivateKey version 2': pkcs8(ecVersion: 2),
          'embedded public key mismatch': pkcs8(ecExtra: [pubOther]),
          'trailing bytes in DER': pkcs8(trailing: [0]),
          'empty': Uint8List(0),
          'garbage': Uint8List.fromList(utf8.encode('hello')),
          'certificate label': Uint8List.fromList(
            utf8.encode(pemEncode(mk(), 'CERTIFICATE')),
          ),
          'SEC1 label': Uint8List.fromList(
            utf8.encode(pemEncode(Uint8List(40), 'EC PRIVATE KEY')),
          ),
        };
        cases.forEach((name, pem) {
          expect(
            () => decodePkcs8PrivateKeyPem(pem),
            throwsA(isA<KeyFormatException>()),
            reason: name,
          );
        });
      },
    );

    test('exception text never contains key material', () {
      final secretHex = hexOf(bigIntToBytes(rfcD, 32));
      final secretB64 = b64urlEncode(bigIntToBytes(rfcD, 32));
      final pemBody = utf8
          .decode(pkcs8(curve: '1.3.132.0.34'))
          .split('\n')
          .where((l) => !l.startsWith('-----') && l.isNotEmpty)
          .join();
      for (final pem in [
        pkcs8(curve: '1.3.132.0.34'),
        pkcs8(d: bigIntToBytes(kP256Order, 32)),
        pkcs8(ecVersion: 2),
      ]) {
        try {
          decodePkcs8PrivateKeyPem(pem);
          fail('must throw');
        } on KeyFormatException catch (e) {
          final text = '${e.toString()} ${e.message}'.toLowerCase();
          expect(text, isNot(contains(secretHex)));
          expect(text, isNot(contains(secretB64.toLowerCase())));
          expect(text, isNot(contains(pemBody.toLowerCase().substring(0, 20))));
        }
      }
    });
  });

  group('generateIdentity (profile D2)', () {
    late GeneratedIdentity g;
    late ParsedCertificate cert;
    setUpAll(() {
      g = generateIdentity(deviceId: 'dev-profile-0001', now: t0);
      cert = parseCertificate(g.identity.certDer, verifySelfSignature: true);
    });

    test('identity fields: id, uppercase fingerprint, PEM matches DER', () {
      expect(g.identity.deviceId, 'dev-profile-0001');
      expect(g.identity.fingerprint, matches(RegExp(r'^[0-9A-F]{64}$')));
      expect(g.identity.fingerprint, fingerprintHex(g.identity.certDer));
      expect(pemDecode(g.identity.certPem, 'CERTIFICATE'), g.identity.certDer);
      expect(g.identity.certDer.length, lessThan(kMaxCertDerBytes));
    });

    test(
      'subject = issuer = CN=deviceId (self-signed), v3, ecdsa-with-SHA256',
      () {
        expect(cert.subjectCn, 'dev-profile-0001');
        expect(cert.isSelfIssued, isTrue);
        expect(cert.version, 3);
        expect(cert.signatureOid, oidEcdsaWithSha256);
        expect(cert.selfSignatureValid(), isTrue);
      },
    );

    test('validity: notBefore = now - 24h, notAfter = now + 3650 days (second precision)', () {
      final floor = DateTime.utc(2026, 11, 4, 12, 30, 45);
      expect(cert.notBefore, floor.subtract(const Duration(hours: 24)));
      expect(cert.notAfter, floor.add(const Duration(days: 3650)));
    });

    test('serial is positive with at most 127 significant bits and differs per identity', () {
      expect(cert.serialNumber > BigInt.zero, isTrue);
      expect(cert.serialNumber.bitLength, lessThanOrEqualTo(127));
      final serials = <BigInt>{};
      for (var i = 0; i < 20; i++) {
        serials.add(
          parseCertificate(
            generateIdentity(deviceId: 'x$i', now: t0).identity.certDer,
          ).serialNumber,
        );
      }
      expect(serials.length, 20);
    });

    test('extensions: BasicConstraints CA:false critical, KeyUsage digitalSignature critical, EKU serverAuth, no SAN', () {
      final tbs = derParseSingle(g.identity.certDer).reader().read().reader();
      tbs.expect(DerTag.explicit(0));
      for (var i = 0; i < 6; i++) {
        tbs.read(); // serial, sigAlg, issuer, validity, subject, spki
      }
      final exts = tbs
          .expect(DerTag.explicit(3))
          .reader()
          .expect(DerTag.sequence)
          .reader();
      final seen = <String, ({bool critical, Uint8List value})>{};
      while (!exts.atEnd) {
        final e = exts.expect(DerTag.sequence).reader();
        final oid = e.expect(DerTag.oid).asOid();
        final crit = e.readOptional(DerTag.boolean)?.asBoolean() ?? false;
        seen[oid] = (
          critical: crit,
          value: e.expect(DerTag.octetString).content,
        );
      }
      expect(seen.keys.toSet(), {
        oidBasicConstraints,
        oidKeyUsage,
        oidExtKeyUsage,
      });
      expect(seen[oidBasicConstraints]!.critical, isTrue);
      expect(
        hexOf(seen[oidBasicConstraints]!.value),
        '3000',
      ); // CA:false = empty SEQUENCE
      expect(seen[oidKeyUsage]!.critical, isTrue);
      expect(
        hexOf(seen[oidKeyUsage]!.value),
        '03020780',
      ); // digitalSignature only
      expect(seen[oidExtKeyUsage]!.critical, isFalse);
      expect(hexOf(seen[oidExtKeyUsage]!.value), '300a06082b06010505070301');
      expect(cert.hasSubjectAltName, isFalse);
      expect(cert.extendedKeyUsage, [oidServerAuth]);
    });

    test('public key is an uncompressed on-curve P-256 point with the SPKI the profile names', () {
      expect(cert.publicPoint.length, 65);
      expect(isValidP256Point(cert.publicPoint), isTrue);
      final spki = derParseSingle(cert.spkiDer).reader();
      final alg = spki.expect(DerTag.sequence).reader();
      expect(alg.read().asOid(), oidEcPublicKey);
      expect(alg.read().asOid(), oidPrime256v1);
    });

    test('private key PEM is PKCS#8 and matches the certificate key', () {
      final text = utf8.decode(g.privateKeyPem);
      expect(text, startsWith('-----BEGIN PRIVATE KEY-----\n'));
      final d = decodePkcs8PrivateKeyPem(g.privateKeyPem);
      expect(p256PublicPoint(d), cert.publicPoint);
    });

    test('two identities differ in key, certificate and fingerprint', () {
      final a = generateIdentity(deviceId: 'same', now: t0);
      final b = generateIdentity(deviceId: 'same', now: t0);
      expect(a.identity.fingerprint, isNot(b.identity.fingerprint));
      expect(a.privateKeyPem, isNot(equals(b.privateKeyPem)));
    });

    test('now defaults to the wall clock', () {
      final before = DateTime.now().toUtc();
      final c = parseCertificate(
        generateIdentity(deviceId: 'clock').identity.certDer,
      );
      final after = DateTime.now().toUtc();
      expect(
        c.notBefore.isAfter(
          before.subtract(const Duration(hours: 24, seconds: 2)),
        ),
        isTrue,
      );
      expect(
        c.notBefore.isBefore(
          after
              .subtract(const Duration(hours: 24))
              .add(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    });

    test('deviceId validation', () {
      for (final bad in [
        '',
        'a' * 65,
        'tab\there',
        'nl\nx',
        '\u0000x',
        'bell\u0007',
      ]) {
        expect(
          () => generateIdentity(deviceId: bad),
          throwsArgumentError,
          reason: bad.codeUnits.toString(),
        );
      }
      expect(generateIdentity(deviceId: 'a' * 64).identity.deviceId.length, 64);
      expect(
        generateIdentity(deviceId: 'héllo-ü').identity.deviceId,
        'héllo-ü',
      );
    });

    test(
      'positional adapter is assignable to the IdentityGenerator shape of P2',
      () {
        final ({DeviceIdentity identity, Uint8List privateKeyPem}) Function(
          String,
        )
        gen = generateIdentityFor;
        expect(gen('adapter').identity.deviceId, 'adapter');
      },
    );

    test('identityFromScalar is fully deterministic (RFC 6979 signature)', () {
      final a = identityFromScalar(
        deviceId: 'vec',
        privateScalar: rfcD,
        now: DateTime.utc(2026, 11, 4, 12),
        serial: BigInt.from(0x0102030405),
      );
      final b = identityFromScalar(
        deviceId: 'vec',
        privateScalar: rfcD,
        now: DateTime.utc(2026, 11, 4, 12),
        serial: BigInt.from(0x0102030405),
      );
      expect(a.identity.certDer, b.identity.certDer);
      expect(a.identity.fingerprint, b.identity.fingerprint);
    });
  });

  group('parseCertificate', () {
    test('exposes subject, validity, serial, key and fingerprint', () {
      final der = mk();
      final c = parseCertificate(der, verifySelfSignature: true);
      expect(c.subjectCn, 'device-0001');
      expect(c.notBefore, DateTime.utc(2026, 11, 3, 12));
      expect(c.notAfter, DateTime.utc(2036, 11, 1, 12));
      expect(c.serialNumber, BigInt.from(0x1234567));
      expect(hexOf(c.publicPoint.sublist(1, 33)), rfcUx);
      expect(c.fingerprint, fingerprintHex(der));
      expect(c.der, der);
    });

    test('expiry is not enforced (pins ignore it)', () {
      final c = parseCertificate(
        mk(
          notBefore: DateTime.utc(2001, 1, 1),
          notAfter: DateTime.utc(2002, 1, 1),
        ),
      );
      expect(c.notAfter.year, 2002);
    });

    test('rejects oversize input (> 2 KiB), even if well-formed', () {
      Uint8List padded(int pad) => mk(
        extra: [
          derExtension(
            oid: '1.2.3.4.5',
            critical: false,
            value: derOctetString(Uint8List(pad)),
          ),
        ],
      );
      // largest padding that still fits under the cap (binary search: each
      // candidate costs one signature)
      var lo = 0;
      var hi = 3000;
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        if (padded(mid).length <= kMaxCertDerBytes) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      final pad = lo;
      final fits = padded(pad);
      final tooBig = padded(pad + 1);
      expect(fits.length, lessThanOrEqualTo(kMaxCertDerBytes));
      expect(tooBig.length, greaterThan(kMaxCertDerBytes));
      expect(parseCertificate(fits).subjectCn, 'device-0001');
      expect(() => parseCertificate(tooBig), badCert);
      expect(() => parseCertificate(padded(2200)), badCert);
    });

    test('rejects empty input, trailing garbage and every truncation', () {
      final der = mk();
      expect(() => parseCertificate(Uint8List(0)), badCert);
      expect(() => parseCertificate(Uint8List.fromList([...der, 0])), badCert);
      expect(
        () => parseCertificate(Uint8List.fromList([...der, ...der])),
        badCert,
      );
      for (var n = 0; n < der.length; n++) {
        expect(
          () => parseCertificate(Uint8List.sublistView(der, 0, n)),
          badCert,
          reason: 'truncated to $n',
        );
      }
    });

    test('rejects a CA certificate (CA:true), critical or not', () {
      expect(() => parseCertificate(mk(ca: true)), badCert);
    });

    test('rejects a non-P-256 key: P-384 OID, RSA, off-curve, compressed, infinity', () {
      final good = p256PublicPoint(rfcD);
      final cases = <String, Uint8List>{
        'P-384 curve OID': spkiFor(
          keyAlg: oidEcPublicKey,
          paramsOid: '1.3.132.0.34',
          point: [4, ...Uint8List(96)],
        ),
        'RSA': derSequence([
          derSequence([derOid('1.2.840.113549.1.1.1'), derNull()]),
          derBitString([0x30, 0x03, 0x02, 0x01, 0x01]),
        ]),
        'ed25519-like OID': derSequence([
          derSequence([derOid('1.3.101.112')]),
          derBitString(Uint8List(32)),
        ]),
        'off-curve point': spkiFor(
          keyAlg: oidEcPublicKey,
          paramsOid: oidPrime256v1,
          point: Uint8List.fromList(good)..[40] ^= 0x55,
        ),
        'compressed point': spkiFor(
          keyAlg: oidEcPublicKey,
          paramsOid: oidPrime256v1,
          point: [2, ...good.sublist(1, 33)],
        ),
        'point at infinity': spkiFor(
          keyAlg: oidEcPublicKey,
          paramsOid: oidPrime256v1,
          point: const [0],
        ),
        'explicit-params style (extra element)': derSequence([
          derSequence([
            derOid(oidEcPublicKey),
            derOid(oidPrime256v1),
            derNull(),
          ]),
          derBitString(good),
        ]),
        'bit string with padding': derSequence([
          derSequence([derOid(oidEcPublicKey), derOid(oidPrime256v1)]),
          derBitString(good, unusedBits: 1),
        ]),
      };
      cases.forEach((name, spki) {
        expect(() => parseCertificate(mk(spki: spki)), badCert, reason: name);
      });
    });

    test('rejects X.509 v1 (no version field)', () {
      expect(() => parseCertificate(mk(version: false)), badCert);
    });

    test('rejects other signature algorithms and mismatched inner/outer algorithms', () {
      expect(
        () => parseCertificate(
          mk(sigOid: '1.2.840.10045.4.3.3', outerSigOid: '1.2.840.10045.4.3.3'),
        ),
        badCert,
      );
      expect(
        () => parseCertificate(mk(outerSigOid: '1.2.840.10045.4.3.3')),
        badCert,
      );
    });

    test('rejects an issuer different from the subject (not self-issued)', () {
      expect(() => parseCertificate(mk(issuerCn: 'someone-else')), badCert);
    });

    test('rejects notAfter before notBefore, serial 0 and serial longer than 20 bytes', () {
      expect(
        () => parseCertificate(
          mk(notBefore: DateTime.utc(2030), notAfter: DateTime.utc(2029)),
        ),
        badCert,
      );
      expect(() => parseCertificate(mk(serial: BigInt.zero)), badCert);
      expect(() => parseCertificate(mk(serial: BigInt.one << 170)), badCert);
      expect(
        parseCertificate(mk(serial: BigInt.one << 150)).serialNumber,
        BigInt.one << 150,
      );
    });

    test('extensions: unknown critical rejected, unknown non-critical ignored, duplicates rejected', () {
      expect(
        () => parseCertificate(
          mk(
            extra: [
              derExtension(oid: '1.2.3.4', critical: true, value: derNull()),
            ],
          ),
        ),
        badCert,
      );
      expect(
        parseCertificate(
          mk(
            extra: [
              derExtension(oid: '1.2.3.4', critical: false, value: derNull()),
            ],
          ),
        ).subjectCn,
        'device-0001',
      );
      expect(
        () => parseCertificate(
          mk(
            extra: [
              derExtension(
                oid: oidBasicConstraints,
                critical: true,
                value: derSequence(const []),
              ),
            ],
          ),
        ),
        badCert,
      );
    });

    test('KeyUsage must allow digitalSignature and must not allow certificate signing', () {
      expect(
        () => parseCertificate(mk(kuByte: 0x40, kuUnused: 6)),
        badCert,
      ); // nonRepudiation only
      expect(
        () => parseCertificate(mk(kuByte: 0x84, kuUnused: 2)),
        badCert,
      ); // + keyCertSign
      expect(parseCertificate(mk(ku: false)).subjectCn, 'device-0001');
    });

    test('a SAN is reported but allowed', () {
      final san = derExtension(
        oid: oidSubjectAltName,
        critical: false,
        value: derSequence([
          derTlv(0x87, const [127, 0, 0, 1]),
        ]),
      );
      expect(parseCertificate(mk(extra: [san])).hasSubjectAltName, isTrue);
    });

    test('subject CN is null unless the subject is exactly one valid CN', () {
      expect(parseCertificate(mk(cn: 'ok')).subjectCn, 'ok');
      expect(parseCertificate(mk(cn: 'a' * 65)).subjectCn, isNull);
      expect(parseCertificate(mk(cn: 'bad\u0001ctl')).subjectCn, isNull);
      expect(parseCertificate(mk(cn: '')).subjectCn, isNull);
    });

    test('tampered signature: accepted by default, refused with verifySelfSignature', () {
      final der = mk();
      final bad = Uint8List.fromList(der)..[der.length - 3] ^= 1;
      expect(parseCertificate(bad).subjectCn, 'device-0001');
      expect(parseCertificate(bad).selfSignatureValid(), isFalse);
      expect(() => parseCertificate(bad, verifySelfSignature: true), badCert);
      expect(
        parseCertificate(der, verifySelfSignature: true).selfSignatureValid(),
        isTrue,
      );
    });

    test(
      'a certificate signed by a different key fails the self-signature check',
      () {
        final other = buildCertificateDer(
          signerKey: BigInt.from(99),
          subjectPublicPoint: p256PublicPoint(rfcD),
          subjectCn: 'x',
          notBefore: DateTime.utc(2026),
          notAfter: DateTime.utc(2030),
          serial: BigInt.one,
        );
        expect(parseCertificate(other).selfSignatureValid(), isFalse);
        expect(
          () => parseCertificate(other, verifySelfSignature: true),
          badCert,
        );
      },
    );

    test('exceptions never carry certificate bytes', () {
      final der = mk(ca: true);
      final derHex = hexOf(der);
      final b64 = base64.encode(der);
      try {
        parseCertificate(der);
        fail('must throw');
      } on CertificateFormatException catch (e) {
        final t = '${e.toString()} ${e.message}'.toLowerCase();
        expect(t, isNot(contains(derHex.substring(20, 60))));
        expect(t, isNot(contains(b64.substring(20, 40).toLowerCase())));
      }
    });

    test(
      '10,000 mutated certificates only ever throw CertificateFormatException',
      () {
        final rnd = Random(0xCE87);
        final der = generateIdentity(
          deviceId: 'fuzz-seed',
          now: t0,
        ).identity.certDer;
        var accepted = 0;
        for (var i = 0; i < 10000; i++) {
          var m = Uint8List.fromList(der);
          final flips = 1 + rnd.nextInt(3);
          for (var k = 0; k < flips; k++) {
            m[rnd.nextInt(m.length)] = rnd.nextInt(256);
          }
          switch (rnd.nextInt(4)) {
            case 0:
              m = Uint8List.sublistView(m, 0, rnd.nextInt(m.length));
            case 1:
              m = Uint8List.fromList([...m, rnd.nextInt(256)]);
            default:
              break;
          }
          try {
            parseCertificate(m);
            accepted++;
          } on CertificateFormatException {
            // expected
          }
        }
        // most single-byte mutations are rejected, but a few (e.g. in the serial or
        // signature value) legitimately remain well-formed
        expect(accepted, lessThan(2500));
      },
    );
  });

  group('openssl oracle', () {
    late Directory tmp;
    late GeneratedIdentity g;
    late String certPath;
    late String keyPath;

    setUpAll(() {
      if (!hasOpenssl) return;
      tmp = Directory.systemTemp.createTempSync('ls_cert_oracle');
      g = generateIdentity(deviceId: 'oracle-device', now: t0);
      certPath = '${tmp.path}/cert.pem';
      keyPath = '${tmp.path}/key.pem';
      File(certPath).writeAsStringSync(g.identity.certPem);
      File(keyPath).writeAsBytesSync(g.privateKeyPem);
    });
    tearDownAll(() {
      if (hasOpenssl && tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    String run(List<String> args) {
      final r = Process.runSync('openssl', args);
      expect(r.exitCode, 0, reason: 'openssl ${args.join(' ')}\n${r.stderr}');
      return '${r.stdout}';
    }

    test(
      'openssl x509 -text parses the certificate and shows the profile',
      skip: skipNoOpenssl,
      () {
        final text = run(['x509', '-in', certPath, '-noout', '-text']);
        expect(text, contains('Version: 3 (0x2)'));
        expect(text, contains('Signature Algorithm: ecdsa-with-SHA256'));
        expect(text, contains('Issuer: CN=oracle-device'));
        expect(text, contains('Subject: CN=oracle-device'));
        expect(text, contains('Public-Key: (256 bit)'));
        expect(text, contains('prime256v1'));
        expect(text, contains('CA:FALSE'));
        expect(text, contains('Digital Signature'));
        expect(text, contains('TLS Web Server Authentication'));
        expect(text, isNot(contains('Subject Alternative Name')));
        expect(text, contains('critical'));
        expect(text, contains('Nov  3 12:30:45 2026 GMT'));
        expect(text, contains('Nov  1 12:30:45 2036 GMT'));
      },
    );

    test('openssl SHA-256 fingerprint equals ours', skip: skipNoOpenssl, () {
      final out = run([
        'x509',
        '-in',
        certPath,
        '-noout',
        '-fingerprint',
        '-sha256',
      ]);
      final theirs = out.trim().split('=').last.replaceAll(':', '');
      expect(theirs, g.identity.fingerprint);
    });

    test(
      'openssl verifies the self-signature and the certificate as its own trust anchor',
      skip: skipNoOpenssl,
      () {
        final r = Process.runSync('openssl', [
          'verify',
          '-no-CAfile',
          '-no-CApath',
          '-check_ss_sig',
          '-trusted',
          certPath,
          certPath,
        ]);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect('${r.stdout}', contains('OK'));
      },
    );

    test(
      'openssl accepts the private key and its public key equals the certificate key',
      skip: skipNoOpenssl,
      () {
        run(['pkey', '-in', keyPath, '-noout', '-check']);
        final fromKey = run(['pkey', '-in', keyPath, '-pubout']);
        final fromCert = run(['x509', '-in', certPath, '-noout', '-pubkey']);
        expect(fromKey.trim(), fromCert.trim());
        final text = run(['pkey', '-in', keyPath, '-noout', '-text']);
        expect(text, contains('prime256v1'));
      },
    );

    test(
      'our deterministic signature verifies in openssl',
      skip: skipNoOpenssl,
      () {
        final d = decodePkcs8PrivateKeyPem(g.privateKeyPem);
        final msg = Uint8List.fromList(
          utf8.encode('libreshare oracle message'),
        );
        final raw = p256SignRaw(d, msg);
        // raw r||s -> DER for openssl
        final der = derSequence([
          derInteger(bigIntFromBytes(raw.sublist(0, 32))),
          derInteger(bigIntFromBytes(raw.sublist(32))),
        ]);
        File('${tmp.path}/msg.bin').writeAsBytesSync(msg);
        File('${tmp.path}/sig.der').writeAsBytesSync(der);
        final pub = run(['pkey', '-in', keyPath, '-pubout']);
        File('${tmp.path}/pub.pem').writeAsStringSync(pub);
        final r = Process.runSync('openssl', [
          'dgst',
          '-sha256',
          '-verify',
          '${tmp.path}/pub.pem',
          '-signature',
          '${tmp.path}/sig.der',
          '${tmp.path}/msg.bin',
        ]);
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect('${r.stdout}', contains('Verified OK'));
      },
    );
  });
}

/// Pure-Dart device identity: P-256 key generation, deterministic ECDSA, the self-signed X.509
/// certificate profile of docs/plans/inc3.md D2, a strict certificate parser for attacker-supplied
/// certificates, PKCS#8/PEM codecs, and the P-256 primitives the other security modules share.
///
/// Certificate profile (D2): X.509 v3, self-signed ECDSA P-256 / `ecdsa-with-SHA256`, issuer =
/// subject = `CN=<deviceId>`, notBefore = now - 24 h, notAfter = now + 3650 days, serial = 127
/// random bits, BasicConstraints CA:false (critical), KeyUsage digitalSignature (critical), EKU
/// serverAuth, no SAN (peers connect by IP; pinning replaces name checks).
///
/// Nothing here logs. Exceptions carry fixed phrases only, never certificate or key bytes.
///
/// Side-channel note: pointycastle's BigInt scalar multiplication is not constant time. That is
/// acceptable for a LAN tool whose adversary does not run code on the same machine, and is listed
/// as a known limitation in docs/test-reports/inc3-spikes.md.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pointycastle/export.dart' as pc;

import 'contracts.dart';
import 'crypto_primitives.dart';
import 'der.dart';

/// Certificate size cap for anything parsed from the network (docs/plans/inc3.md D9).
const int kMaxCertDerBytes = 2048;

// Object identifiers used by the profile.
const String oidEcPublicKey = '1.2.840.10045.2.1';
const String oidPrime256v1 = '1.2.840.10045.3.1.7';
const String oidEcdsaWithSha256 = '1.2.840.10045.4.3.2';
const String oidCommonName = '2.5.4.3';
const String oidSubjectAltName = '2.5.29.17';
const String oidKeyUsage = '2.5.29.15';
const String oidBasicConstraints = '2.5.29.19';
const String oidExtKeyUsage = '2.5.29.37';
const String oidServerAuth = '1.3.6.1.5.5.7.3.1';

// ------------------------------------------------------------------ errors

/// A certificate is malformed, outside the accepted profile, or too large. The message is a fixed
/// phrase and never contains certificate bytes.
class CertificateFormatException implements Exception {
  const CertificateFormatException(this.message);
  final String message;
  @override
  String toString() => 'CertificateFormatException: $message';
}

/// A private-key PEM is malformed or not a P-256 key. The message is a fixed phrase and never
/// contains key bytes.
class KeyFormatException implements Exception {
  const KeyFormatException(this.message);
  final String message;
  @override
  String toString() => 'KeyFormatException: $message';
}

// ------------------------------------------------------------------ P-256

/// secp256r1 group order n.
final BigInt kP256Order = BigInt.parse(
  'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
  radix: 16,
);

/// secp256r1 field prime p.
final BigInt kP256Prime = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);

/// secp256r1 curve constant b (a = p - 3).
final BigInt kP256B = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);

final pc.ECDomainParameters _domain = pc.ECDomainParameters('secp256r1');

/// Test hook: true when the constants above agree with pointycastle's own curve definition.
@visibleForTesting
bool p256ConstantsAgreeWithImplementation() {
  final g = _domain.G;
  final gx = g.x!.toBigInteger()!;
  final gy = g.y!.toBigInteger()!;
  return _domain.n == kP256Order &&
      _domain.curve.fieldSize == 256 &&
      _domain.curve.b!.toBigInteger() == kP256B &&
      _domain.curve.a!.toBigInteger() == kP256Prime - BigInt.from(3) &&
      _onCurve(gx, gy);
}

bool _onCurve(BigInt x, BigInt y) {
  if (x.isNegative || y.isNegative || x >= kP256Prime || y >= kP256Prime) {
    return false;
  }
  final lhs = (y * y) % kP256Prime;
  final rhs = (x * x * x - BigInt.from(3) * x + kP256B) % kP256Prime; // a = -3
  return lhs == rhs;
}

/// Uniform private scalar in `[1, n-1]` from the OS CSPRNG (rejection sampling).
BigInt generateP256Scalar() {
  while (true) {
    final d = bigIntFromBytes(secureRandomBytes(32));
    if (d > BigInt.zero && d < kP256Order) return d;
  }
}

/// Uncompressed SEC1 public point (`04 || X || Y`, 65 bytes) for private scalar [d].
Uint8List p256PublicPoint(BigInt d) {
  if (d <= BigInt.zero || d >= kP256Order) {
    throw ArgumentError.value('out of range', 'd');
  }
  final q = _domain.G * d;
  return Uint8List.fromList(q!.getEncoded(false));
}

/// True for a 65-byte uncompressed point with coordinates below p that lies on P-256. (The
/// cofactor is 1, so on-curve implies in the prime-order group.) Compressed forms, the point at
/// infinity and anything off the curve are refused.
bool isValidP256Point(List<int> point) {
  if (point.length != 65 || point[0] != 4) return false;
  final x = bigIntFromBytes(point.sublist(1, 33));
  final y = bigIntFromBytes(point.sublist(33, 65));
  return _onCurve(x, y);
}

/// Deterministic ECDSA (RFC 6979) over SHA-256([message]) with private scalar [d]; returns raw
/// `r || s` (64 bytes). Needs no randomness at signing time.
Uint8List p256SignRaw(BigInt d, List<int> message) {
  final signer =
      pc.ECDSASigner(pc.SHA256Digest(), pc.HMac(pc.SHA256Digest(), 64))..init(
        true,
        pc.PrivateKeyParameter<pc.ECPrivateKey>(pc.ECPrivateKey(d, _domain)),
      );
  final sig =
      signer.generateSignature(Uint8List.fromList(message)) as pc.ECSignature;
  return Uint8List.fromList([
    ...bigIntToBytes(sig.r, 32),
    ...bigIntToBytes(sig.s, 32),
  ]);
}

bool _verifyRs(List<int> point, List<int> message, BigInt r, BigInt s) {
  try {
    if (r < BigInt.one || r >= kP256Order) return false;
    if (s < BigInt.one || s >= kP256Order) return false;
    if (!isValidP256Point(point)) return false;
    final q = _domain.curve.createPoint(
      bigIntFromBytes(point.sublist(1, 33)),
      bigIntFromBytes(point.sublist(33, 65)),
    );
    final verifier = pc.ECDSASigner(pc.SHA256Digest())
      ..init(
        false,
        pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(q, _domain)),
      );
    return verifier.verifySignature(
      Uint8List.fromList(message),
      pc.ECSignature(r, s),
    );
  } catch (_) {
    return false;
  }
}

/// ECDSA/SHA-256 verification of raw `r || s` ([signature], exactly 64 bytes) over [message] with
/// the uncompressed [point]. Returns false for wrong lengths, r or s outside `[1, n-1]`, invalid or
/// off-curve points. Never throws. High-s signatures are accepted (no malleability rule: every
/// signed text carries a nonce).
bool p256VerifyRaw(List<int> point, List<int> message, List<int> signature) {
  if (signature.length != 64) return false;
  return _verifyRs(
    point,
    message,
    bigIntFromBytes(signature.sublist(0, 32)),
    bigIntFromBytes(signature.sublist(32)),
  );
}

// ------------------------------------------------------------------ PEM

const int _kMaxPemChars = 16 * 1024;
final RegExp _b64Body = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

/// RFC 7468 PEM with 64-column lines and a trailing newline.
String pemEncode(List<int> der, String label) {
  final body = base64.encode(der);
  final lines = <String>[
    for (var i = 0; i < body.length; i += 64)
      body.substring(i, i + 64 > body.length ? body.length : i + 64),
  ];
  return '-----BEGIN $label-----\n${lines.map((l) => '$l\n').join()}-----END $label-----\n';
}

/// Strict single-block PEM decoder: exact [label], nothing before or after the block (one
/// trailing newline allowed), base64 alphabet only, input capped at 16 KiB. Throws
/// [FormatException] with a fixed message.
Uint8List pemDecode(String pem, String label) {
  const bad = FormatException('invalid PEM');
  if (pem.length > _kMaxPemChars) throw bad;
  final text = pem.replaceAll('\r\n', '\n');
  final begin = '-----BEGIN $label-----\n';
  final end = '-----END $label-----';
  if (!text.startsWith(begin)) throw bad;
  final endAt = text.indexOf(end, begin.length);
  if (endAt < 0) throw bad;
  final tail = text.substring(endAt + end.length);
  if (tail != '' && tail != '\n') throw bad;
  final body = text.substring(begin.length, endAt).replaceAll('\n', '');
  if (!_b64Body.hasMatch(body)) throw bad;
  try {
    return base64.decode(body);
  } on FormatException {
    throw bad;
  }
}

// ------------------------------------------------------------------ PKCS#8

/// PKCS#8 `PrivateKeyInfo` (RFC 5958) wrapping an RFC 5915 `ECPrivateKey` with the public key
/// included, PEM label `PRIVATE KEY`; the form `SecurityContext.usePrivateKeyBytes` accepts.
Uint8List encodePkcs8PrivateKeyPem(BigInt d) {
  if (d <= BigInt.zero || d >= kP256Order) {
    throw ArgumentError.value('out of range', 'd');
  }
  final ecKey = derSequence([
    derInteger(BigInt.one),
    derOctetString(bigIntToBytes(d, 32)),
    derExplicit(1, derBitString(p256PublicPoint(d))),
  ]);
  final info = derSequence([
    derInteger(BigInt.zero),
    derSequence([derOid(oidEcPublicKey), derOid(oidPrime256v1)]),
    derOctetString(ecKey),
  ]);
  return Uint8List.fromList(utf8.encode(pemEncode(info, 'PRIVATE KEY')));
}

/// Parses a PKCS#8 P-256 private key PEM and returns the scalar. Strict: only the P-256
/// `id-ecPublicKey` algorithm, fixed 32-byte scalar in `[1, n-1]`, an optional embedded public key
/// must match, no trailing data. Throws [KeyFormatException] with a fixed message.
BigInt decodePkcs8PrivateKeyPem(List<int> pem) {
  const bad = KeyFormatException('malformed private key');
  try {
    final text = utf8.decode(pem);
    final der = pemDecode(text, 'PRIVATE KEY');
    final info = derParseSingle(Uint8List.fromList(der), maxBytes: 512);
    if (info.tag != DerTag.sequence) throw bad;
    final r = info.reader();
    if (r.expect(DerTag.integer).asInteger() != BigInt.zero) throw bad;
    final alg = r.expect(DerTag.sequence).reader();
    if (alg.expect(DerTag.oid).asOid() != oidEcPublicKey) throw bad;
    if (alg.expect(DerTag.oid).asOid() != oidPrime256v1) throw bad;
    alg.finish();
    final inner = derParseSingle(r.expect(DerTag.octetString).content);
    r.finish();
    if (inner.tag != DerTag.sequence) throw bad;
    final k = inner.reader();
    if (k.expect(DerTag.integer).asInteger() != BigInt.one) throw bad;
    final dBytes = k.expect(DerTag.octetString).content;
    if (dBytes.length != 32) throw bad;
    final d = bigIntFromBytes(dBytes);
    if (d <= BigInt.zero || d >= kP256Order) throw bad;
    final params = k.readOptional(DerTag.explicit(0));
    if (params != null) {
      final p = params.reader();
      if (p.expect(DerTag.oid).asOid() != oidPrime256v1) throw bad;
      p.finish();
    }
    final pub = k.readOptional(DerTag.explicit(1));
    if (pub != null) {
      final p = pub.reader();
      final bits = p.expect(DerTag.bitString).asBitString();
      p.finish();
      if (bits.unusedBits != 0 ||
          !constantTimeEquals(bits.bytes, p256PublicPoint(d))) {
        throw bad;
      }
    }
    k.finish();
    return d;
  } on KeyFormatException {
    rethrow;
  } catch (_) {
    throw bad;
  }
}

// ------------------------------------------------------------------ building

/// DER `Extension ::= SEQUENCE { extnID, critical DEFAULT FALSE, extnValue OCTET STRING }`.
/// [value] is the already-encoded extension value.
@visibleForTesting
Uint8List derExtension({
  required String oid,
  required bool critical,
  required List<int> value,
}) => derSequence([
  derOid(oid),
  if (critical) derBoolean(true),
  derOctetString(value),
]);

Uint8List _name(String cn) => derSequence([
  derSet([
    derSequence([derOid(oidCommonName), derUtf8String(cn)]),
  ]),
]);

/// Builds and signs a self-signed certificate. The defaults are exactly the D2 profile; the other
/// knobs exist so tests can produce hostile variants (CA:true, foreign keys, unknown extensions).
@visibleForTesting
Uint8List buildCertificateDer({
  required BigInt signerKey,
  required Uint8List subjectPublicPoint,
  required String subjectCn,
  String? issuerCn,
  required DateTime notBefore,
  required DateTime notAfter,
  required BigInt serial,
  bool ca = false,
  bool includeBasicConstraints = true,
  bool includeKeyUsage = true,
  bool includeExtKeyUsage = true,
  int keyUsageByte = 0x80,
  int keyUsageUnused = 7,
  List<Uint8List> extraExtensions = const [],
  Uint8List? spkiOverride,
  bool includeVersion = true,
  String signatureOid = oidEcdsaWithSha256,
  String? outerSignatureOid,
}) {
  final spki =
      spkiOverride ??
      derSequence([
        derSequence([derOid(oidEcPublicKey), derOid(oidPrime256v1)]),
        derBitString(subjectPublicPoint),
      ]);
  final extensions = <Uint8List>[
    if (includeBasicConstraints)
      derExtension(
        oid: oidBasicConstraints,
        critical: true,
        value: derSequence(ca ? [derBoolean(true)] : const []),
      ),
    if (includeKeyUsage)
      derExtension(
        oid: oidKeyUsage,
        critical: true,
        value: derBitString([keyUsageByte], unusedBits: keyUsageUnused),
      ),
    if (includeExtKeyUsage)
      derExtension(
        oid: oidExtKeyUsage,
        critical: false,
        value: derSequence([derOid(oidServerAuth)]),
      ),
    ...extraExtensions,
  ];
  final tbs = derSequence([
    if (includeVersion) derExplicit(0, derInteger(BigInt.two)),
    derInteger(serial),
    derSequence([derOid(signatureOid)]),
    _name(issuerCn ?? subjectCn),
    derSequence([derTime(notBefore), derTime(notAfter)]),
    _name(subjectCn),
    spki,
    if (extensions.isNotEmpty) derExplicit(3, derSequence(extensions)),
  ]);
  final raw = p256SignRaw(signerKey, tbs);
  final sigDer = derSequence([
    derInteger(bigIntFromBytes(raw.sublist(0, 32))),
    derInteger(bigIntFromBytes(raw.sublist(32))),
  ]);
  return derSequence([
    tbs,
    derSequence([derOid(outerSignatureOid ?? signatureOid)]),
    derBitString(sigDer),
  ]);
}

/// Result of [generateIdentity]: the public identity and the PKCS#8 PEM of its private key.
typedef GeneratedIdentity = ({
  DeviceIdentity identity,
  Uint8List privateKeyPem,
});

void _checkDeviceId(String id) {
  final runes = id.runes.toList();
  final badChar = runes.any((c) => c < 0x20 || (c >= 0x7f && c <= 0x9f));
  if (runes.isEmpty || runes.length > 64 || badChar) {
    throw ArgumentError.value(
      'length ${runes.length}',
      'deviceId',
      'must be 1..64 printable characters',
    );
  }
}

BigInt _randomSerial() {
  while (true) {
    final b = secureRandomBytes(16);
    b[0] &= 0x7F; // 127 random bits, always positive
    final v = bigIntFromBytes(b);
    if (v > BigInt.zero) return v;
  }
}

/// Deterministic identity from a fixed key, serial and clock: for test vectors only. Production
/// code uses [generateIdentity].
@visibleForTesting
GeneratedIdentity identityFromScalar({
  required String deviceId,
  required BigInt privateScalar,
  required DateTime now,
  required BigInt serial,
}) {
  _checkDeviceId(deviceId);
  final u = now.toUtc();
  final base = DateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second);
  final der = buildCertificateDer(
    signerKey: privateScalar,
    subjectPublicPoint: p256PublicPoint(privateScalar),
    subjectCn: deviceId,
    notBefore: base.subtract(const Duration(hours: 24)),
    notAfter: base.add(const Duration(days: 3650)),
    serial: serial,
  );
  return (
    identity: DeviceIdentity(
      deviceId: deviceId,
      fingerprint: fingerprintHex(der),
      certDer: der,
      certPem: pemEncode(der, 'CERTIFICATE'),
    ),
    privateKeyPem: encodePkcs8PrivateKeyPem(privateScalar),
  );
}

/// Creates a fresh identity: new P-256 key, self-signed certificate per the D2 profile.
/// [now] is the issue time (defaults to the wall clock). The caller stores the key in a
/// `SecretStore`; it is never logged.
GeneratedIdentity generateIdentity({required String deviceId, DateTime? now}) =>
    identityFromScalar(
      deviceId: deviceId,
      privateScalar: generateP256Scalar(),
      now: now ?? DateTime.now().toUtc(),
      serial: _randomSerial(),
    );

/// Positional adapter of [generateIdentity] with the `IdentityGenerator` shape
/// (`GeneratedIdentity Function(String deviceId)`) the credential store expects.
GeneratedIdentity generateIdentityFor(String deviceId) =>
    generateIdentity(deviceId: deviceId);

// ------------------------------------------------------------------ parsing

/// A certificate that passed the strict profile checks of [parseCertificate].
final class ParsedCertificate {
  ParsedCertificate._({
    required this.der,
    required this.tbsBytes,
    required this.serialNumber,
    required this.subjectCn,
    required this.notBefore,
    required this.notAfter,
    required this.spkiDer,
    required this.publicPoint,
    required this.extendedKeyUsage,
    required this.hasSubjectAltName,
    required this.signatureOid,
    required (BigInt, BigInt) rs,
  }) : _signature = rs;

  /// The complete DER certificate (a private copy of the input).
  final Uint8List der;

  /// The signed `TBSCertificate` bytes.
  final Uint8List tbsBytes;
  final BigInt serialNumber;

  /// The subject CN when the subject is exactly one valid CN (1..64 printable characters);
  /// otherwise null.
  final String? subjectCn;
  final DateTime notBefore;
  final DateTime notAfter;

  /// The complete `SubjectPublicKeyInfo` TLV.
  final Uint8List spkiDer;

  /// Uncompressed P-256 point (`04 || X || Y`), validated to be on the curve.
  final Uint8List publicPoint;
  final List<String> extendedKeyUsage;
  final bool hasSubjectAltName;
  final String signatureOid;
  final (BigInt, BigInt) _signature;

  /// Always 3: version 1 certificates are rejected.
  int get version => 3;

  /// Always true: certificates whose issuer differs from the subject are rejected.
  bool get isSelfIssued => true;

  /// Uppercase hex SHA-256 of [der] (LSP-1 section 0.2).
  String get fingerprint => fingerprintHex(der);

  /// Verifies the certificate's own signature with its own key (about 10 ms; not run by default).
  bool selfSignatureValid() =>
      _verifyRs(publicPoint, tbsBytes, _signature.$1, _signature.$2);
}

CertificateFormatException _reject(String why) =>
    CertificateFormatException(why);

String? _cnOf(DerElement name) {
  final rdns = name.reader();
  String? cn;
  var count = 0;
  var attrs = 0;
  while (!rdns.atEnd) {
    final rdn = rdns.expect(DerTag.set).reader();
    if (rdn.atEnd) throw _reject('empty name component');
    count++;
    while (!rdn.atEnd) {
      final atv = rdn.expect(DerTag.sequence).reader();
      final oid = atv.expect(DerTag.oid).asOid();
      final value = atv.read();
      atv.finish();
      attrs++;
      if (oid == oidCommonName &&
          (value.tag == DerTag.utf8String ||
              value.tag == DerTag.printableString)) {
        try {
          cn = value.asString();
        } on DerException {
          cn = null;
        }
      }
    }
  }
  if (count != 1 || attrs != 1 || cn == null) return null;
  final runes = cn.runes.toList();
  if (runes.isEmpty ||
      runes.length > 64 ||
      runes.any((c) => c < 0x20 || (c >= 0x7f && c <= 0x9f))) {
    return null;
  }
  return cn;
}

/// Strictly parses a peer-supplied DER certificate: at most [kMaxCertDerBytes], canonical DER, no
/// trailing bytes, v3, `ecdsa-with-SHA256`, issuer == subject, a P-256 key that lies on the curve,
/// extensions limited to what RFC 5280 allows (no unknown critical extension, no duplicates), no
/// CA:true, KeyUsage (if present) with digitalSignature and without keyCertSign. Expiry is not
/// checked (pins ignore it). With [verifySelfSignature] the certificate's own signature is also
/// verified (about 10 ms).
///
/// Throws only [CertificateFormatException], whatever the input.
ParsedCertificate parseCertificate(
  Uint8List der, {
  bool verifySelfSignature = false,
}) {
  if (der.isEmpty || der.length > kMaxCertDerBytes) {
    throw _reject('certificate size out of range');
  }
  try {
    final parsed = _parse(Uint8List.fromList(der));
    if (verifySelfSignature && !parsed.selfSignatureValid()) {
      throw _reject('self-signature invalid');
    }
    return parsed;
  } on CertificateFormatException {
    rethrow;
  } on DerException {
    throw _reject('malformed certificate');
  } catch (_) {
    // Trust boundary: whatever a hostile input provokes, the caller sees one exception type.
    throw _reject('malformed certificate');
  }
}

ParsedCertificate _parse(Uint8List der) {
  final root = derParseSingle(der, maxBytes: kMaxCertDerBytes);
  if (root.tag != DerTag.sequence) throw _reject('not a certificate');
  final top = root.reader();
  final tbsEl = top.expect(DerTag.sequence);
  final outerAlg = top.expect(DerTag.sequence);
  final sigBits = top.expect(DerTag.bitString).asBitString();
  top.finish();

  final tbs = tbsEl.reader();
  final versionEl = tbs.readOptional(DerTag.explicit(0));
  if (versionEl == null) throw _reject('only v3 certificates are accepted');
  final vr = versionEl.reader();
  final version = vr.expect(DerTag.integer).asInteger();
  vr.finish();
  if (version != BigInt.two) throw _reject('only v3 certificates are accepted');

  final serialEl = tbs.expect(DerTag.integer);
  final serial = serialEl.asInteger();
  if (serial == BigInt.zero || serialEl.content.length > 20) {
    throw _reject('bad serial number');
  }

  final innerAlg = tbs.expect(DerTag.sequence);
  final algReader = innerAlg.reader();
  final sigOid = algReader.expect(DerTag.oid).asOid();
  algReader.finish();
  if (sigOid != oidEcdsaWithSha256) {
    throw _reject('unsupported signature algorithm');
  }
  if (!constantTimeEquals(innerAlg.encoded, outerAlg.encoded)) {
    throw _reject('signature algorithm mismatch');
  }

  final issuer = tbs.expect(DerTag.sequence);
  final validity = tbs.expect(DerTag.sequence).reader();
  final notBefore = validity.read().asTime();
  final notAfter = validity.read().asTime();
  validity.finish();
  if (notAfter.isBefore(notBefore)) throw _reject('bad validity');
  final subject = tbs.expect(DerTag.sequence);
  final subjectCn = _cnOf(subject);
  _cnOf(issuer); // structural check of the issuer name
  if (!constantTimeEquals(issuer.encoded, subject.encoded)) {
    throw _reject('certificate is not self-issued');
  }

  final spkiEl = tbs.expect(DerTag.sequence);
  final spki = spkiEl.reader();
  final keyAlg = spki.expect(DerTag.sequence).reader();
  if (keyAlg.expect(DerTag.oid).asOid() != oidEcPublicKey) {
    throw _reject('not an EC key');
  }
  if (keyAlg.expect(DerTag.oid).asOid() != oidPrime256v1) {
    throw _reject('not a P-256 key');
  }
  keyAlg.finish();
  final keyBits = spki.expect(DerTag.bitString).asBitString();
  spki.finish();
  if (keyBits.unusedBits != 0 || !isValidP256Point(keyBits.bytes)) {
    throw _reject('invalid public key');
  }
  final point = Uint8List.fromList(keyBits.bytes);

  var hasSan = false;
  final eku = <String>[];
  final extEl = tbs.readOptional(DerTag.explicit(3));
  if (extEl != null) {
    final outer = extEl.reader();
    final seq = outer.expect(DerTag.sequence).reader();
    outer.finish();
    if (seq.atEnd) throw _reject('empty extensions');
    final seen = <String>{};
    while (!seq.atEnd) {
      final e = seq.expect(DerTag.sequence).reader();
      final oid = e.expect(DerTag.oid).asOid();
      var critical = false;
      if (e.peekTag() == DerTag.boolean) {
        critical = e.read().asBoolean();
        if (!critical) throw _reject('non-DER extension flag');
      }
      final value = e.expect(DerTag.octetString).content;
      e.finish();
      if (!seen.add(oid)) throw _reject('duplicate extension');
      switch (oid) {
        case oidBasicConstraints:
          final bc = derParseSingle(Uint8List.fromList(value));
          if (bc.tag != DerTag.sequence) throw _reject('bad basic constraints');
          final r = bc.reader();
          var ca = false;
          if (r.peekTag() == DerTag.boolean) {
            ca = r.read().asBoolean();
            if (!ca) throw _reject('non-DER basic constraints');
          }
          if (r.peekTag() == DerTag.integer) {
            r.read().asInteger();
            if (!ca) throw _reject('bad basic constraints');
          }
          r.finish();
          if (ca) throw _reject('CA certificates are not accepted');
        case oidKeyUsage:
          final bits = derParseSingle(Uint8List.fromList(value)).asBitString();
          if (bits.bytes.isEmpty ||
              bits.bytes[0] & 0x80 == 0 ||
              bits.bytes[0] & 0x04 != 0) {
            throw _reject('key usage not acceptable');
          }
        case oidExtKeyUsage:
          final seqEl = derParseSingle(Uint8List.fromList(value));
          if (seqEl.tag != DerTag.sequence) {
            throw _reject('bad extended key usage');
          }
          final r = seqEl.reader();
          if (r.atEnd) throw _reject('bad extended key usage');
          while (!r.atEnd) {
            eku.add(r.expect(DerTag.oid).asOid());
          }
        case oidSubjectAltName:
          final san = derParseSingle(Uint8List.fromList(value));
          if (san.tag != DerTag.sequence) throw _reject('bad subject alt name');
          hasSan = true;
        default:
          if (critical) throw _reject('unknown critical extension');
      }
    }
  }
  tbs.finish();

  final outerOid = outerAlg.reader();
  if (outerOid.expect(DerTag.oid).asOid() != oidEcdsaWithSha256) {
    throw _reject('unsupported signature algorithm');
  }
  outerOid.finish();
  if (sigBits.unusedBits != 0) throw _reject('bad signature encoding');
  final sig = derParseSingle(Uint8List.fromList(sigBits.bytes), maxBytes: 80);
  if (sig.tag != DerTag.sequence) throw _reject('bad signature encoding');
  final sr = sig.reader();
  final r = sr.expect(DerTag.integer).asInteger();
  final s = sr.expect(DerTag.integer).asInteger();
  sr.finish();

  return ParsedCertificate._(
    der: der,
    tbsBytes: tbsEl.encoded,
    serialNumber: serial,
    subjectCn: subjectCn,
    notBefore: notBefore,
    notAfter: notAfter,
    spkiDer: spkiEl.encoded,
    publicPoint: point,
    extendedKeyUsage: List.unmodifiable(eku),
    hasSubjectAltName: hasSan,
    signatureOid: sigOid,
    rs: (r, s),
  );
}

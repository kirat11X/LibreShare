// BIP-340 Schnorr signatures over secp256k1 using pointycastle primitives.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

import '../security/crypto_primitives.dart';

final ECCurve_secp256k1 _secp256k1 = ECCurve_secp256k1();

/// Field prime p = 2^256 - 2^32 - 977
final BigInt _p = BigInt.parse(
  'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
  radix: 16,
);

/// Curve group order n
final BigInt _n = _secp256k1.n;

/// Base generator point G
final ECPoint _generatorG = _secp256k1.G;

/// Computes BIP-340 tagged SHA-256 hash: SHA256(SHA256(tag) || SHA256(tag) || msg).
Uint8List bip340TaggedHash(String tag, List<int> msg) {
  final tagHash = crypto.sha256.convert(utf8.encode(tag)).bytes;
  final bb = BytesBuilder(copy: false);
  bb.add(tagHash);
  bb.add(tagHash);
  bb.add(msg);
  return Uint8List.fromList(crypto.sha256.convert(bb.takeBytes()).bytes);
}

/// Parses big-endian bytes into a [BigInt].
BigInt bytesToBigInt(List<int> bytes) {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return BigInt.parse(hex, radix: 16);
}

/// Returns true if [pt] has an even y-coordinate.
bool hasEvenY(ECPoint pt) {
  final y = pt.y?.toBigInteger();
  if (y == null) return false;
  return (y % BigInt.two) == BigInt.zero;
}

/// Derives the 32-byte BIP-340 x-only public key from a private key [sk].
Uint8List getBip340PublicKey(BigInt sk) {
  if (sk <= BigInt.zero || sk >= _n) {
    throw ArgumentError('Secret key out of range [1, n-1]');
  }
  final P = _generatorG * sk;
  if (P == null || P.isInfinity) {
    throw ArgumentError('Invalid secret key');
  }
  return bigIntToBytes(P.x!.toBigInteger()!, 32);
}

/// Signs a 32-byte [message] using private key [sk] and optional [auxRand] per BIP-340.
///
/// Returns 64-byte Schnorr signature (32-byte R.x || 32-byte s).
Uint8List signBip340({
  required BigInt sk,
  required Uint8List message,
  Uint8List? auxRand,
}) {
  if (sk <= BigInt.zero || sk >= _n) {
    throw ArgumentError('Secret key out of range [1, n-1]');
  }
  if (message.length != 32) {
    throw ArgumentError('Message must be exactly 32 bytes');
  }

  final P = _generatorG * sk;
  if (P == null || P.isInfinity) {
    throw ArgumentError('Invalid secret key');
  }

  var d = sk;
  if (!hasEvenY(P)) {
    d = _n - d;
  }

  final aux = auxRand ?? Uint8List(32);
  final t = Uint8List(32);
  final skBytes = bigIntToBytes(d, 32);
  final auxHash = bip340TaggedHash('BIP0340/aux', aux);
  for (var i = 0; i < 32; i++) {
    t[i] = skBytes[i] ^ auxHash[i];
  }

  final pxBytes = bigIntToBytes(P.x!.toBigInteger()!, 32);
  final nonceBytes = BytesBuilder(copy: false);
  nonceBytes.add(t);
  nonceBytes.add(pxBytes);
  nonceBytes.add(message);

  final rand = bip340TaggedHash('BIP0340/nonce', nonceBytes.takeBytes());
  final kPrime = bytesToBigInt(rand) % _n;
  if (kPrime == BigInt.zero) {
    throw StateError('Derived kPrime is zero');
  }

  final R = _generatorG * kPrime;
  if (R == null || R.isInfinity) {
    throw StateError('Derived R point is infinity');
  }

  var k = kPrime;
  if (!hasEvenY(R)) {
    k = _n - k;
  }

  final rxBytes = bigIntToBytes(R.x!.toBigInteger()!, 32);
  final chalBytes = BytesBuilder(copy: false);
  chalBytes.add(rxBytes);
  chalBytes.add(pxBytes);
  chalBytes.add(message);

  final e =
      bytesToBigInt(
        bip340TaggedHash('BIP0340/challenge', chalBytes.takeBytes()),
      ) %
      _n;
  final s = (k + e * d) % _n;

  final sig = Uint8List(64);
  sig.setRange(0, 32, rxBytes);
  sig.setRange(32, 64, bigIntToBytes(s, 32));
  return sig;
}

/// Verifies a 64-byte BIP-340 Schnorr [sig] against 32-byte [pubKeyBytes] and [message].
bool verifyBip340({
  required Uint8List pubKeyBytes,
  required Uint8List message,
  required Uint8List sig,
}) {
  if (pubKeyBytes.length != 32 || sig.length != 64 || message.length != 32) {
    return false;
  }

  final px = bytesToBigInt(pubKeyBytes);
  if (px >= _p) return false;

  // lift_x: y^2 = x^3 + 7 mod p
  final ySquared = (px.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
  // p = 3 mod 4, so sqrt(y^2) = (y^2)^((p+1)/4) mod p
  final exp = (_p + BigInt.one) ~/ BigInt.from(4);
  var y = ySquared.modPow(exp, _p);
  if ((y.modPow(BigInt.two, _p)) != ySquared) {
    return false; // Point not on curve
  }
  if ((y % BigInt.two) != BigInt.zero) {
    y = _p - y;
  }

  final P = _secp256k1.curve.createPoint(px, y);

  final rx = bytesToBigInt(sig.sublist(0, 32));
  final s = bytesToBigInt(sig.sublist(32, 64));
  if (rx >= _p || s >= _n) return false;

  final chalBytes = BytesBuilder(copy: false);
  chalBytes.add(sig.sublist(0, 32));
  chalBytes.add(pubKeyBytes);
  chalBytes.add(message);

  final e =
      bytesToBigInt(
        bip340TaggedHash('BIP0340/challenge', chalBytes.takeBytes()),
      ) %
      _n;

  // R = s*G - e*P = s*G + (n - e)*P
  final sG = _generatorG * s;
  final negEP = P * (_n - e);
  if (sG == null || negEP == null) return false;

  final R = sG + negEP;
  if (R == null || R.isInfinity || !hasEvenY(R) || R.x!.toBigInteger() != rx) {
    return false;
  }

  return true;
}

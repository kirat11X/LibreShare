// Proof for mutant M91: BIP-340 verify must reject R with odd y.
// Build a signature whose nonce point R = kG has ODD y; everything else is a correct Schnorr
// signature (s = k + e*d), so only the even-y rule rejects it.
import 'dart:typed_data';

import 'package:libreshare_core/src/rendezvous/bip340.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

Uint8List _b32(BigInt v) {
  final h = v.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList([for (var i = 0; i < 32; i++) int.parse(h.substring(i * 2, i * 2 + 2), radix: 16)]);
}

void main() {
  final curve = ECCurve_secp256k1();
  final n = curve.n;
  final msg = Uint8List.fromList(List.generate(32, (i) => i));

  test('odd-y R is rejected; even-y R accepted (positive control)', () {
    var d = BigInt.from(0xC0FFEE);
    if (!hasEvenY((curve.G * d)!)) d = n - d;
    final pk = _b32((curve.G * d)!.x!.toBigInteger()!);
    var sawOdd = false, sawEven = false;
    for (var kk = 1; kk < 40 && !(sawOdd && sawEven); kk++) {
      final k = BigInt.from(kk * 7919);
      final R = (curve.G * k)!;
      final rx = _b32(R.x!.toBigInteger()!);
      final e = bytesToBigInt(bip340TaggedHash('BIP0340/challenge', [...rx, ...pk, ...msg])) % n;
      final s = (k + e * d) % n;
      final ok = verifyBip340(pubKeyBytes: pk, message: msg, sig: Uint8List.fromList([...rx, ..._b32(s)]));
      if (hasEvenY(R)) { sawEven = true; expect(ok, isTrue); } else { sawOdd = true; expect(ok, isFalse); }
    }
    expect(sawOdd && sawEven, isTrue);
  });
}

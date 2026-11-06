import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/contracts.dart';
import 'package:libreshare_core/src/security/crypto_primitives.dart';
import 'package:test/test.dart';

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

/// A [Random] that replays scripted bytes for `nextInt(256)`.
class _ScriptedRandom implements Random {
  _ScriptedRandom(this.bytes);
  final List<int> bytes;
  int used = 0;

  @override
  int nextInt(int max) {
    expect(max, 256, reason: 'randomIntBelow must draw single bytes');
    return bytes[used++];
  }

  @override
  bool nextBool() => throw UnimplementedError();
  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  group('sha256', () {
    test('sha256Hex known answer is lowercase', () {
      expect(
        sha256Hex('abc'.codeUnits),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('sha256Bytes is the 32 raw digest bytes', () {
      final d = sha256Bytes('abc'.codeUnits);
      expect(d, isA<Uint8List>());
      expect(d.length, 32);
      expect(toHex(d), sha256Hex('abc'.codeUnits));
    });

    test('fingerprintHex is uppercase hex SHA-256, 64 chars', () {
      final fp = fingerprintHex('abc'.codeUnits);
      expect(fp.length, 64);
      expect(
        fp,
        'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
      );
      expect(fp, matches(RegExp(r'^[0-9A-F]{64}$')));
    });
  });

  group('hmacSha256 (RFC 4231)', () {
    test('test case 1', () {
      expect(
        toHex(hmacSha256(List.filled(20, 0x0b), 'Hi There'.codeUnits)),
        'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7',
      );
    });
    test('test case 2', () {
      expect(
        toHex(
          hmacSha256(
            'Jefe'.codeUnits,
            'what do ya want for nothing?'.codeUnits,
          ),
        ),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843',
      );
    });
    test('test case 6 (key longer than block size)', () {
      expect(
        toHex(
          hmacSha256(
            List.filled(131, 0xaa),
            'Test Using Larger Than Block-Size Key - Hash Key First'.codeUnits,
          ),
        ),
        '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54',
      );
    });
  });

  group('hkdfSha256 (RFC 5869)', () {
    test('A.1 basic test case', () {
      expect(
        toHex(
          hkdfSha256(
            ikm: List.filled(22, 0x0b),
            salt: hex('000102030405060708090a0b0c'),
            info: hex('f0f1f2f3f4f5f6f7f8f9'),
            length: 42,
          ),
        ),
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('A.2 longer inputs/outputs', () {
      expect(
        toHex(
          hkdfSha256(
            ikm: List.generate(80, (i) => i),
            salt: List.generate(80, (i) => 0x60 + i),
            info: List.generate(80, (i) => 0xb0 + i),
            length: 82,
          ),
        ),
        'b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c'
        '59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71'
        'cc30c58179ec3e87c14c01d5c1f3434f1d87',
      );
    });

    test('A.3 zero-length salt and info', () {
      expect(
        toHex(
          hkdfSha256(
            ikm: List.filled(22, 0x0b),
            salt: const [],
            info: const [],
            length: 42,
          ),
        ),
        '8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d'
        '9d201395faa4b61a96c8',
      );
    });

    test('maximum length 255*32 works, one more byte is refused', () {
      final okm = hkdfSha256(ikm: [1], salt: [2], info: [3], length: 255 * 32);
      expect(okm.length, 8160);
      expect(
        () => hkdfSha256(ikm: [1], salt: [2], info: [3], length: 8161),
        throwsArgumentError,
      );
    });

    test('length must be positive', () {
      expect(
        () => hkdfSha256(ikm: [1], salt: [2], info: [3], length: 0),
        throwsArgumentError,
      );
      expect(
        () => hkdfSha256(ikm: [1], salt: [2], info: [3], length: -1),
        throwsArgumentError,
      );
    });

    test('shorter output is a prefix of the longer one', () {
      final a = hkdfSha256(ikm: [9], salt: [8], info: [7], length: 16);
      final b = hkdfSha256(ikm: [9], salt: [8], info: [7], length: 64);
      expect(b.sublist(0, 16), a);
    });
  });

  group('constantTimeEquals', () {
    test('equal content is true, including empty', () {
      expect(constantTimeEquals(const [], const []), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(
        constantTimeEquals(Uint8List.fromList([0, 255]), [0, 255]),
        isTrue,
      );
    });

    test('a difference at any position is false', () {
      final a = List<int>.generate(40, (i) => i);
      for (var i = 0; i < a.length; i++) {
        final b = [...a]..[i] ^= 0x01;
        expect(constantTimeEquals(a, b), isFalse, reason: 'position $i');
        expect(constantTimeEquals(b, a), isFalse, reason: 'position $i');
      }
    });

    test('different lengths are false, even when one is a prefix', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
      expect(constantTimeEquals(const [], [0]), isFalse);
      expect(constantTimeEquals([0], const []), isFalse);
      // zero padding must not make different lengths equal
      expect(constantTimeEquals([1, 0, 0], [1]), isFalse);
      expect(constantTimeEquals([1], [1, 0, 0]), isFalse);
    });
  });

  group('secureRandomBytes', () {
    test('returns exactly n bytes', () {
      for (final n in [0, 1, 15, 16, 32, 1000]) {
        expect(secureRandomBytes(n).length, n);
      }
    });
    test('negative length is refused', () {
      expect(() => secureRandomBytes(-1), throwsArgumentError);
    });
    test('two draws differ and are not all zero', () {
      final a = secureRandomBytes(32);
      final b = secureRandomBytes(32);
      expect(a, isNot(equals(b)));
      expect(a.any((x) => x != 0), isTrue);
    });
    test('every bit position takes both values in 2000 bytes', () {
      final bytes = secureRandomBytes(2000);
      var or = 0;
      var and = 0xFF;
      for (final x in bytes) {
        or |= x;
        and &= x;
      }
      expect(or, 0xFF);
      expect(and, 0);
    });
  });

  group('base64url', () {
    test('encode has no padding and uses the url alphabet', () {
      expect(b64urlEncode(const []), '');
      expect(b64urlEncode('f'.codeUnits), 'Zg');
      expect(b64urlEncode('fo'.codeUnits), 'Zm8');
      expect(b64urlEncode('foo'.codeUnits), 'Zm9v');
      expect(b64urlEncode([0xfb, 0xff, 0xfe]), '-__-');
    });

    test('round trip for every length 0..70', () {
      final rnd = Random(1);
      for (var n = 0; n <= 70; n++) {
        final data = Uint8List.fromList(
          List.generate(n, (_) => rnd.nextInt(256)),
        );
        final s = b64urlEncode(data);
        expect(s.contains('='), isFalse);
        expect(b64urlDecode(s), data, reason: 'length $n');
      }
    });

    test('decode of the empty string is empty', () {
      expect(b64urlDecode(''), isEmpty);
    });

    test('rejects padding', () {
      expect(() => b64urlDecode('Zg=='), throwsFormatException);
      expect(() => b64urlDecode('Zm8='), throwsFormatException);
    });

    test('rejects the standard alphabet and other characters', () {
      for (final bad in [
        '+/+/',
        'Zm9v ',
        ' Zm9v',
        'Zm\n9v',
        'Zm9v\n',
        'Zm9é',
        'Zm9v\u0000',
        'Zm.v',
        'Zm9v!',
      ]) {
        expect(
          () => b64urlDecode(bad),
          throwsFormatException,
          reason: 'input: ${bad.codeUnits}',
        );
      }
    });

    test('rejects lengths that are 1 mod 4', () {
      expect(() => b64urlDecode('Z'), throwsFormatException);
      expect(() => b64urlDecode('Zm9vY'), throwsFormatException);
    });

    test('rejects non-canonical encodings (non-zero trailing bits)', () {
      // 'Zg' is canonical for 'f'; 'Zh' decodes to the same byte with
      // stray low bits set.
      expect(b64urlDecode('Zg'), [0x66]);
      expect(() => b64urlDecode('Zh'), throwsFormatException);
      // 'Zm8' canonical; 'Zm9' has stray bits.
      expect(() => b64urlDecode('Zm9'), throwsFormatException);
    });

    test('FormatException text never echoes the input', () {
      const secret = 'SECRETSECRET+';
      try {
        b64urlDecode(secret);
        fail('should have thrown');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains('SECRET')));
      }
    });
  });

  group('randomIntBelow', () {
    test('stays inside [0, max) and hits both ends', () {
      final seen = <int>{};
      for (var i = 0; i < 2000; i++) {
        final v = randomIntBelow(10);
        expect(v, inInclusiveRange(0, 9));
        seen.add(v);
      }
      expect(seen.length, 10);
    });

    test('max 1 is always 0', () {
      expect(randomIntBelow(1), 0);
    });

    test('rejects non-positive and absurd bounds', () {
      expect(() => randomIntBelow(0), throwsArgumentError);
      expect(() => randomIntBelow(-5), throwsArgumentError);
      expect(() => randomIntBelow((1 << 32) + 1), throwsArgumentError);
    });

    test('rejection sampling: values in the biased tail are redrawn', () {
      // For max=10 the largest accepted 32-bit draw is 2^32 - 7 (the tail of
      // 6 values would make 0..5 more likely).
      final rnd = _ScriptedRandom([
        0xFF, 0xFF, 0xFF, 0xFF, // 4294967295 -> in the tail, redraw
        0xFF, 0xFF, 0xFF, 0xFA, // 4294967290 -> in the tail (>= limit), redraw
        0x00, 0x00, 0x00, 0x07, // 7 -> accepted
      ]);
      expect(randomIntBelow(10, random: rnd), 7);
      expect(rnd.used, 12);
    });

    test('rejection sampling: the last accepted value is not redrawn', () {
      final rnd = _ScriptedRandom([0xFF, 0xFF, 0xFF, 0xF9]); // 2^32 - 7
      expect(randomIntBelow(10, random: rnd), (0xFFFFFFF9) % 10);
      expect(rnd.used, 4);
    });

    test('roughly uniform over 6-digit PIN digits (chi-square, seeded)', () {
      final rnd = Random(42);
      final counts = List<int>.filled(10, 0);
      const n = 20000;
      for (var i = 0; i < n; i++) {
        counts[randomIntBelow(10, random: rnd)]++;
      }
      final expected = n / 10;
      var chi = 0.0;
      for (final c in counts) {
        chi += (c - expected) * (c - expected) / expected;
      }
      // df = 9, p = 0.001 critical value is 27.88.
      expect(chi, lessThan(27.88));
    });
  });

  group('domainSeparate', () {
    test('is label, one NUL, message', () {
      expect(
        toHex(domainSeparate('LSP1-BYE', [1, 2, 3])),
        '${toHex('LSP1-BYE'.codeUnits)}00010203',
      );
      expect(toHex(domainSeparate('X', const [])), '5800');
    });
    test('rejects an empty label and a label containing NUL', () {
      expect(() => domainSeparate('', [1]), throwsArgumentError);
      expect(() => domainSeparate('A\u0000B', [1]), throwsArgumentError);
    });
    test('a longer label can never spell a shorter label plus message', () {
      // "A" NUL "B..." and "AB" NUL "..." differ, because the NUL position differs.
      expect(
        domainSeparate('A', 'B\u0000X'.codeUnits),
        isNot(domainSeparate('AB', 'X'.codeUnits)),
      );
    });
  });

  // Known-answer vectors of docs/protocol/test-vectors-inc3.md section 5. Computed independently
  // with Python hashlib/hmac and the `cryptography` HKDF; the constructions are LSP-1 section 5.3.
  group('pairing known-answer vectors (HMAC and K_pair)', () {
    const fpA =
        'F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD';
    const fpB =
        'AE91A910C4E3D642640BD9CCFCBD18A6BB2ACF0091BEFFF1D7BD56C437F99EFF';
    final secret = List<int>.generate(32, (i) => 0x40 + i);
    final nA = List<int>.generate(16, (i) => 0x60 + i);
    final nB = List<int>.generate(16, (i) => 0x70 + i);

    test('invite secret S encodes to 43 base64url characters', () {
      expect(
        b64urlEncode(secret),
        'QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8',
      );
    });

    test('PAIR-REQ mac = HMAC(S, label NUL fpB fpA nB)', () {
      final mac = hmacSha256(
        secret,
        domainSeparate(SigDomain.pairRequest, [
          ...fpB.codeUnits,
          ...fpA.codeUnits,
          ...nB,
        ]),
      );
      expect(
        toHex(mac),
        'a4af9b3626dec060bc129302b38429c5e2a95278529ea944b9a710503fe18b67',
      );
      expect(b64urlEncode(mac), 'pK-bNibewGC8EpMCs4QpxeKpUnhSnqlEuacQUD_hi2c');
    });

    test('PAIR-ACK mac = HMAC(S, label NUL fpA fpB nA nB)', () {
      final mac = hmacSha256(
        secret,
        domainSeparate(SigDomain.pairAck, [
          ...fpA.codeUnits,
          ...fpB.codeUnits,
          ...nA,
          ...nB,
        ]),
      );
      expect(
        toHex(mac),
        'da859a48862641fdf686a481a241f055d1bfa7cf419db45ad1a111a16b6134af',
      );
      expect(b64urlEncode(mac), '2oWaSIYmQf32hqSBokHwVdG_p89BnbRa0aERoWthNK8');
    });

    test(
      'K_pair = HKDF(S, salt nA||nB, info "LSP-R1 pair"||min(fp)||max(fp), 32)',
      () {
        final lo = fpA.compareTo(fpB) <= 0 ? fpA : fpB;
        final hi = fpA.compareTo(fpB) <= 0 ? fpB : fpA;
        final k = hkdfSha256(
          ikm: secret,
          salt: [...nA, ...nB],
          info: [
            ...SigDomain.pairInfo.codeUnits,
            ...lo.codeUnits,
            ...hi.codeUnits,
          ],
          length: 32,
        );
        expect(
          toHex(k),
          '03e8c2507e0048b521fad8c05766fb7a5d218c723f91f161d1c4ec58d52af0ff',
        );
        expect(b64urlEncode(k), 'A-jCUH4ASLUh-tjAV2b7el0hjHI_kfFh0cTsWNUq8P8');
      },
    );
  });
}

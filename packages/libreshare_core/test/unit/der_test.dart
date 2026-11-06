import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/der.dart';
import 'package:test/test.dart';

Uint8List hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

String timeStr(Uint8List enc) {
  final e = derParseSingle(enc);
  return '0x${e.tag.toRadixString(16)} ${String.fromCharCodes(e.content)}';
}

void main() {
  group('writer', () {
    test('definite lengths use the shortest form', () {
      expect(toHex(derTlv(0x04, Uint8List(0))), '0400');
      expect(toHex(derTlv(0x04, Uint8List(127)).sublist(0, 2)), '047f');
      expect(toHex(derTlv(0x04, Uint8List(128)).sublist(0, 3)), '048180');
      expect(toHex(derTlv(0x04, Uint8List(255)).sublist(0, 3)), '0481ff');
      expect(toHex(derTlv(0x04, Uint8List(256)).sublist(0, 4)), '04820100');
      expect(toHex(derTlv(0x04, Uint8List(65536)).sublist(0, 5)), '0483010000');
    });

    test('INTEGER known encodings (minimal, non-negative)', () {
      expect(toHex(derInteger(BigInt.zero)), '020100');
      expect(toHex(derInteger(BigInt.from(127))), '02017f');
      expect(toHex(derInteger(BigInt.from(128))), '02020080');
      expect(toHex(derInteger(BigInt.from(256))), '02020100');
      expect(toHex(derInteger(BigInt.from(0x7fffffff))), '02047fffffff');
      expect(
        toHex(derInteger(BigInt.parse('ff' * 16, radix: 16))),
        '021100${'ff' * 16}',
      );
      expect(() => derInteger(BigInt.from(-1)), throwsArgumentError);
    });

    test('BOOLEAN and NULL', () {
      expect(toHex(derBoolean(true)), '0101ff');
      expect(toHex(derBoolean(false)), '010100');
      expect(toHex(derNull()), '0500');
    });

    test('OID known encodings', () {
      expect(toHex(derOid('1.2.840.10045.2.1')), '06072a8648ce3d0201');
      expect(toHex(derOid('1.2.840.10045.3.1.7')), '06082a8648ce3d030107');
      expect(toHex(derOid('1.2.840.10045.4.3.2')), '06082a8648ce3d040302');
      expect(toHex(derOid('2.5.4.3')), '0603550403');
      expect(toHex(derOid('2.5.29.19')), '0603551d13');
      expect(toHex(derOid('1.3.6.1.5.5.7.3.1')), '06082b06010505070301');
      // an arc needing a multi-byte base-128 value
      expect(toHex(derOid('2.999.3')), '0603883703');
    });

    test('OID rejects malformed dotted text', () {
      for (final bad in [
        '',
        '1',
        '3.1',
        '1.40',
        '1.2.',
        '1..2',
        'a.b',
        '-1.2',
      ]) {
        expect(() => derOid(bad), throwsArgumentError, reason: bad);
      }
    });

    test('BIT STRING and OCTET STRING', () {
      expect(toHex(derBitString([0x80], unusedBits: 7)), '03020780');
      expect(toHex(derBitString([1, 2, 3])), '030400010203');
      expect(toHex(derOctetString([1, 2])), '04020102');
      expect(() => derBitString([1], unusedBits: 8), throwsArgumentError);
      expect(() => derBitString(const [], unusedBits: 1), throwsArgumentError);
    });

    test('strings and explicit tags', () {
      expect(toHex(derUtf8String('ab')), '0c026162');
      expect(toHex(derExplicit(0, derInteger(BigInt.two))), 'a003020102');
      expect(toHex(derExplicit(3, derSequence(const []))), 'a3023000');
    });

    test('time: UTCTime up to 2049, GeneralizedTime from 2050', () {
      expect(
        timeStr(derTime(DateTime.utc(2026, 11, 4, 13, 5, 9))),
        '0x17 261104130509Z',
      );
      expect(
        timeStr(derTime(DateTime.utc(2049, 12, 31, 23, 59, 59))),
        '0x17 491231235959Z',
      );
      expect(
        timeStr(derTime(DateTime.utc(2050, 1, 1))),
        '0x18 20500101000000Z',
      );
      expect(timeStr(derTime(DateTime.utc(1999, 1, 1))), '0x17 990101000000Z');
      expect(
        timeStr(derTime(DateTime.utc(1949, 1, 1))),
        '0x18 19490101000000Z',
      );
    });
  });

  group('reader: accepts well-formed DER', () {
    test('sequence of mixed elements round-trips through the writer', () {
      final enc = derSequence([
        derInteger(BigInt.from(300)),
        derOid('1.2.840.10045.2.1'),
        derBoolean(true),
        derOctetString([9, 8, 7]),
        derBitString([0xAA, 0xBB]),
        derUtf8String('héllo'),
        derTime(DateTime.utc(2030, 2, 3, 4, 5, 6)),
        derNull(),
      ]);
      final root = derParseSingle(enc);
      expect(root.tag, DerTag.sequence);
      final r = root.reader();
      expect(r.read().asInteger(), BigInt.from(300));
      expect(r.read().asOid(), '1.2.840.10045.2.1');
      expect(r.read().asBoolean(), isTrue);
      expect(r.read().asOctetString(), [9, 8, 7]);
      final bits = r.read().asBitString();
      expect(bits.bytes, [0xAA, 0xBB]);
      expect(bits.unusedBits, 0);
      expect(r.read().asString(), 'héllo');
      expect(r.read().asTime(), DateTime.utc(2030, 2, 3, 4, 5, 6));
      r.read().expectNull();
      r.finish();
      expect(root.encoded, enc);
    });

    test('long-form lengths parse', () {
      for (final n in [128, 255, 256, 1000, 70000]) {
        final enc = derTlv(0x04, Uint8List(n));
        final e = derParseSingle(enc, maxBytes: 100000);
        expect(e.content.length, n);
      }
    });

    test('OID arcs decode back to dotted text', () {
      for (final oid in [
        '0.0',
        '1.2.840.113549.1.1.11',
        '2.5.29.37',
        '2.999.3',
        '1.3.6.1.4.1.311.60.2.1.3',
      ]) {
        expect(derParseSingle(derOid(oid)).asOid(), oid);
      }
    });

    test('INTEGER decodes 0, 127, 128, big values', () {
      for (final v in [
        BigInt.zero,
        BigInt.from(127),
        BigInt.from(128),
        BigInt.from(255),
        BigInt.from(256),
        BigInt.parse('7f${'ff' * 15}', radix: 16),
        BigInt.parse('ff' * 32, radix: 16),
      ]) {
        expect(derParseSingle(derInteger(v)).asInteger(), v);
      }
    });

    test('readOptional / peekTag walk optional members', () {
      final enc = derSequence([
        derExplicit(0, derInteger(BigInt.two)),
        derInteger(BigInt.one),
      ]);
      final r = derParseSingle(enc).reader();
      expect(r.peekTag(), 0xa0);
      expect(r.readOptional(0xa1), isNull);
      expect(r.readOptional(0xa0), isNotNull);
      expect(r.peekTag(), DerTag.integer);
      r.expect(DerTag.integer);
      expect(r.atEnd, isTrue);
      expect(r.peekTag(), isNull);
    });
  });

  group('reader: rejects non-strict or hostile input', () {
    void rejects(String name, String hexBytes, {int maxBytes = 4096}) {
      test(name, () {
        expect(
          () => derParseSingle(hex(hexBytes), maxBytes: maxBytes),
          throwsA(isA<DerException>()),
        );
      });
    }

    rejects('empty input', '');
    rejects('indefinite length (0x80)', '30800000');
    rejects('reserved length byte 0xff', '04ff00');
    rejects('long form for a value below 128', '04810500000000 00');
    rejects('long form with a leading zero length byte', '0482008000');
    rejects('length wider than 4 bytes', '048500000000010000');
    rejects('length beyond the available bytes', '040500');
    rejects('declared length 2^31 with 3 bytes present', '048480000000000000');
    rejects('truncated header (tag only)', '30');
    rejects('truncated long length', '0482');
    rejects('trailing garbage after one element', '0400ff');
    rejects('two elements where one is required', '04000400');
    rejects('high tag number form (0x1f)', '1f2000');
    rejects('end-of-contents tag 0', '0000');

    test('size cap applies before parsing', () {
      expect(
        () => derParseSingle(derTlv(0x04, Uint8List(100)), maxBytes: 50),
        throwsA(isA<DerException>()),
      );
    });

    void badInt(String name, String hexBytes) {
      test('INTEGER $name', () {
        expect(
          () => derParseSingle(hex(hexBytes)).asInteger(),
          throwsA(isA<DerException>()),
        );
      });
    }

    badInt('empty', '0200');
    badInt('redundant leading zero', '0202 0001');
    badInt('negative (high bit set)', '0201 80');
    badInt('negative 0xff', '0201 ff');

    test('wrong tag for the accessor', () {
      expect(
        () => derParseSingle(hex('0401 00')).asInteger(),
        throwsA(isA<DerException>()),
      );
      expect(
        () => derParseSingle(hex('0201 00')).asOctetString(),
        throwsA(isA<DerException>()),
      );
    });

    test('BOOLEAN must be 0x00 or 0xff and one byte', () {
      for (final bad in ['0101 01', '0101 fe', '0100', '0102 ffff']) {
        expect(
          () => derParseSingle(hex(bad)).asBoolean(),
          throwsA(isA<DerException>()),
          reason: bad,
        );
      }
    });

    test('BIT STRING: bad unused-bit counts and non-zero padding', () {
      for (final bad in [
        '0300', // empty
        '0301 08', // 8 unused bits
        '0301 01', // 1 unused bit with no data
        '0302 07 81', // padding bit set
      ]) {
        expect(
          () => derParseSingle(hex(bad)).asBitString(),
          throwsA(isA<DerException>()),
          reason: bad,
        );
      }
    });

    test('OID: empty, non-minimal, truncated, oversized arc', () {
      for (final bad in [
        '0600',
        '0603 55 80 03', // arc with leading 0x80
        '0602 55 83', // continuation bit on the last byte
        '0608 55 ffffffffff7f 01', // 6-byte arc
      ]) {
        expect(
          () => derParseSingle(hex(bad)).asOid(),
          throwsA(isA<DerException>()),
          reason: bad,
        );
      }
    });

    test('strings: invalid UTF-8 and bad PrintableString', () {
      expect(
        () => derParseSingle(hex('0c02 c328')).asString(),
        throwsA(isA<DerException>()),
      );
      expect(
        () => derParseSingle(hex('1302 612a')).asString(), // '*' not printable
        throwsA(isA<DerException>()),
      );
      expect(derParseSingle(hex('1303 616263')).asString(), 'abc');
      expect(
        () => derParseSingle(hex('0402 6162')).asString(),
        throwsA(isA<DerException>()),
      );
    });

    test('time: malformed forms are refused', () {
      String t(int tag, String s) => toHex(derTlv(tag, s.codeUnits));
      for (final bad in [
        t(0x17, '2611041305Z'), // no seconds
        t(0x17, '261104130509+0100'), // offset
        t(0x17, '261304130509Z'), // month 13
        t(0x17, '261132130509Z'), // day 32
        t(0x17, '260230130509Z'), // 30 February
        t(0x17, '261104250509Z'), // hour 25
        t(0x17, '261104136009Z'), // minute 60
        t(0x17, '2611041305 9Z'), // space
        t(0x18, '20261104130509Z'), // Generalized below 2050 must be UTCTime
        t(0x18, '20500101000000.5Z'), // fraction
        t(0x17, '26110413050aZ'), // letter instead of a digit
      ]) {
        expect(
          () => derParseSingle(hex(bad)).asTime(),
          throwsA(isA<DerException>()),
          reason: bad,
        );
      }
      // UTCTime year pivot: 49 -> 2049, 50 -> 1950
      expect(
        derParseSingle(derTlv(0x17, '490101000000Z'.codeUnits)).asTime().year,
        2049,
      );
      expect(
        derParseSingle(derTlv(0x17, '500101000000Z'.codeUnits)).asTime().year,
        1950,
      );
    });

    test('NULL must be empty', () {
      expect(
        () => derParseSingle(hex('0501 00')).expectNull(),
        throwsA(isA<DerException>()),
      );
    });

    test('reader.expect with the wrong tag and reading past the end', () {
      final enc = derSequence([derInteger(BigInt.one)]);
      expect(
        () => derParseSingle(enc).reader().expect(DerTag.octetString),
        throwsA(isA<DerException>()),
      );
      final r = derParseSingle(enc).reader()..read();
      expect(() => r.read(), throwsA(isA<DerException>()));
    });

    test('finish() refuses leftover members', () {
      final r = derParseSingle(
        derSequence([derInteger(BigInt.one), derInteger(BigInt.two)]),
      ).reader();
      r.read();
      expect(() => r.finish(), throwsA(isA<DerException>()));
    });

    test('children of a primitive element are refused', () {
      expect(
        () => derParseSingle(hex('0401 00')).reader(),
        throwsA(isA<DerException>()),
      );
    });

    test('nesting deeper than the cap is refused (stack-bomb)', () {
      var enc = derInteger(BigInt.one);
      for (var i = 0; i < 40; i++) {
        enc = derSequence([enc]);
      }
      var e = derParseSingle(enc, maxBytes: 100000);
      expect(() {
        for (var i = 0; i < 40; i++) {
          e = e.reader().read();
        }
      }, throwsA(isA<DerException>()));
    });

    test('exception text never contains input bytes', () {
      try {
        derParseSingle(hex('0482 0080 deadbeefcafe'));
        fail('should throw');
      } on DerException catch (e) {
        expect(e.toString().toLowerCase(), isNot(contains('deadbeef')));
      }
    });
  });

  group('fuzz', () {
    test('random and mutated inputs only ever throw DerException', () {
      final rnd = Random(0xDE12);
      final seed = derSequence([
        derExplicit(0, derInteger(BigInt.two)),
        derInteger(BigInt.parse('7f${'ab' * 15}', radix: 16)),
        derSequence([derOid('1.2.840.10045.4.3.2')]),
        derSequence([
          derSet([
            derSequence([derOid('2.5.4.3'), derUtf8String('device')]),
          ]),
        ]),
        derSequence([
          derTime(DateTime.utc(2026, 1, 1)),
          derTime(DateTime.utc(2036, 1, 1)),
        ]),
        derBitString(List.generate(65, (i) => i)),
      ]);

      void walk(DerElement e, int depth) {
        if (e.isConstructed && depth < 12) {
          final r = e.reader();
          while (!r.atEnd) {
            walk(r.read(), depth + 1);
          }
        } else {
          for (final f in <void Function()>[
            e.asInteger,
            e.asBoolean,
            e.asOid,
            e.asBitString,
            e.asString,
            e.asTime,
            e.asOctetString,
          ]) {
            try {
              f();
            } on DerException {
              // expected
            }
          }
        }
      }

      for (var i = 0; i < 20000; i++) {
        Uint8List input;
        if (i % 4 == 0) {
          input = Uint8List.fromList(
            List.generate(rnd.nextInt(80), (_) => rnd.nextInt(256)),
          );
        } else {
          input = Uint8List.fromList(seed);
          final flips = 1 + rnd.nextInt(4);
          for (var k = 0; k < flips; k++) {
            input[rnd.nextInt(input.length)] = rnd.nextInt(256);
          }
          if (rnd.nextBool()) {
            input = Uint8List.sublistView(input, 0, rnd.nextInt(input.length));
          }
        }
        try {
          walk(derParseSingle(input), 0);
        } on DerException {
          // expected
        }
      }
    });
  });
}

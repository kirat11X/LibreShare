import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/sas.dart';
import 'package:test/test.dart';

// Vectors computed independently with Python hashlib; also published in
// docs/protocol/test-vectors-inc3.md.
const fpS = 'AE91A910C4E3D642640BD9CCFCBD18A6BB2ACF0091BEFFF1D7BD56C437F99EFF';
const fpR = 'F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD';
const fpM = '0ABECAEB9C5DD717D0F2184B2B615F1D497EDACFE6A3FC459E298E4D2818FCDB';

Uint8List bytes16(int from) =>
    Uint8List.fromList(List.generate(16, (i) => from + i));

final ns = bytes16(0x00);
final nr = bytes16(0x10);

void main() {
  group('sasCommit', () {
    test('known_answer_vectors', () {
      expect(
        sasCommit(
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpR,
        ),
        'xVsm4yPtHTjhd4VytGITnQbYj6JcNg9e9N07JsZVscs',
      );
      expect(
        sasCommit(
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpM,
        ),
        'l7DGyZO5eoGq8RPyF3MDvTfy1LN_4YESPyFCht7WJu4',
      );
    });

    test('is 43 base64url characters (SHA-256, no padding)', () {
      final c = sasCommit(
        ns: ns,
        senderFingerprint: fpS,
        receiverFingerprintSeenBySender: fpR,
      );
      expect(c.length, 43);
      expect(c, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    });

    test('fingerprint case does not matter', () {
      expect(
        sasCommit(
          ns: ns,
          senderFingerprint: fpS.toLowerCase(),
          receiverFingerprintSeenBySender: fpR.toLowerCase(),
        ),
        sasCommit(
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpR,
        ),
      );
    });

    test('any_input_change_changes_commit (every nonce bit, every fingerprint char)', () {
      final base = sasCommit(
        ns: ns,
        senderFingerprint: fpS,
        receiverFingerprintSeenBySender: fpR,
      );
      final seen = <String>{base};
      for (var i = 0; i < 16; i++) {
        for (var bit = 0; bit < 8; bit++) {
          final n = Uint8List.fromList(ns)..[i] ^= 1 << bit;
          seen.add(
            sasCommit(
              ns: n,
              senderFingerprint: fpS,
              receiverFingerprintSeenBySender: fpR,
            ),
          );
        }
      }
      expect(
        seen.length,
        1 + 128,
        reason: 'each nonce bit flip gives a new commit',
      );
      String flip(String fp, int i) =>
          fp.replaceRange(i, i + 1, fp[i] == '0' ? '1' : '0');
      for (var i = 0; i < 64; i += 7) {
        expect(
          sasCommit(
            ns: ns,
            senderFingerprint: flip(fpS, i),
            receiverFingerprintSeenBySender: fpR,
          ),
          isNot(base),
        );
        expect(
          sasCommit(
            ns: ns,
            senderFingerprint: fpS,
            receiverFingerprintSeenBySender: flip(fpR, i),
          ),
          isNot(base),
        );
      }
    });

    test('roles are not interchangeable (sender and receiver fingerprints swapped)', () {
      expect(
        sasCommit(
          ns: ns,
          senderFingerprint: fpR,
          receiverFingerprintSeenBySender: fpS,
        ),
        isNot(
          sasCommit(
            ns: ns,
            senderFingerprint: fpS,
            receiverFingerprintSeenBySender: fpR,
          ),
        ),
      );
    });

    test('nonce_length_enforced', () {
      for (final len in [0, 1, 15, 17, 32]) {
        expect(
          () => sasCommit(
            ns: Uint8List(len),
            senderFingerprint: fpS,
            receiverFingerprintSeenBySender: fpR,
          ),
          throwsArgumentError,
          reason: 'length $len',
        );
      }
    });

    test('fingerprints must be 64 hex characters', () {
      for (final bad in [
        '',
        'abc',
        fpS.substring(1),
        '${fpS}0',
        'G${fpS.substring(1)}',
        ' $fpS',
      ]) {
        expect(
          () => sasCommit(
            ns: ns,
            senderFingerprint: bad,
            receiverFingerprintSeenBySender: fpR,
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  group('sasCommitMatches', () {
    final commit = sasCommit(
      ns: ns,
      senderFingerprint: fpS,
      receiverFingerprintSeenBySender: fpR,
    );

    test('true for the honest reveal', () {
      expect(
        sasCommitMatches(
          commit: commit,
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpR,
        ),
        isTrue,
      );
    });

    test('reveal_with_wrong_nonce_rejected', () {
      expect(
        sasCommitMatches(
          commit: commit,
          ns: bytes16(0x01),
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpR,
        ),
        isFalse,
      );
    });

    test('a different receiver fingerprint (relaying MITM) does not match', () {
      expect(
        sasCommitMatches(
          commit: commit,
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpM,
        ),
        isFalse,
      );
      expect(
        sasCommitMatches(
          commit: commit,
          ns: ns,
          senderFingerprint: fpM,
          receiverFingerprintSeenBySender: fpR,
        ),
        isFalse,
      );
    });

    test('malformed attacker input returns false and never throws', () {
      final bad = <String, ({String commit, List<int> ns, String s, String r})>{
        'short nonce': (commit: commit, ns: Uint8List(15), s: fpS, r: fpR),
        'long nonce': (commit: commit, ns: Uint8List(17), s: fpS, r: fpR),
        'empty commit': (commit: '', ns: ns, s: fpS, r: fpR),
        'padded commit': (commit: '$commit=', ns: ns, s: fpS, r: fpR),
        'short commit': (commit: commit.substring(1), ns: ns, s: fpS, r: fpR),
        'non-canonical commit': (
          commit: '${commit.substring(0, 42)}${commit[42] == 'A' ? 'B' : 'A'}',
          ns: ns,
          s: fpS,
          r: fpR,
        ),
        'standard alphabet commit': (
          commit: '+${commit.substring(1)}',
          ns: ns,
          s: fpS,
          r: fpR,
        ),
        'bad sender fp': (commit: commit, ns: ns, s: 'zz', r: fpR),
        'bad receiver fp': (commit: commit, ns: ns, s: fpS, r: ''),
      };
      bad.forEach((name, c) {
        expect(
          sasCommitMatches(
            commit: c.commit,
            ns: c.ns,
            senderFingerprint: c.s,
            receiverFingerprintSeenBySender: c.r,
          ),
          isFalse,
          reason: name,
        );
      });
    });
  });

  group('sasCode', () {
    String code(Uint8List n1, Uint8List n2, String a, String b) =>
        sasCode(ns: n1, nr: n2, fingerprintA: a, fingerprintB: b);

    test('known_answer_vectors', () {
      expect(code(ns, nr, fpS, fpR), '060044');
      expect(code(ns, nr, fpS, fpM), '078646');
      expect(
        code(ns, Uint8List.fromList(List.filled(15, 0xA0) + [0x60]), fpS, fpR),
        '002408',
      );
      expect(
        code(ns, Uint8List.fromList(List.filled(15, 0xB0) + [0x09]), fpS, fpR),
        '090751',
      );
    });

    test('both_sides_compute_same_code', () {
      // sender view: A = own, B = peer; receiver view: swapped
      expect(code(ns, nr, fpS, fpR), code(ns, nr, fpR, fpS));
    });

    test('fingerprint_order_does_not_matter (min/max by text)', () {
      final rnd = Random(3);
      for (var i = 0; i < 50; i++) {
        final a = List.generate(
          64,
          (_) => '0123456789ABCDEF'[rnd.nextInt(16)],
        ).join();
        final b = List.generate(
          64,
          (_) => '0123456789ABCDEF'[rnd.nextInt(16)],
        ).join();
        expect(code(ns, nr, a, b), code(ns, nr, b, a));
      }
    });

    test('fingerprint case does not matter', () {
      expect(
        code(ns, nr, fpS.toLowerCase(), fpR.toLowerCase()),
        code(ns, nr, fpS, fpR),
      );
    });

    test('leading_zeros_kept: always exactly six digits', () {
      expect(code(ns, nr, fpS, fpR).startsWith('0'), isTrue);
      final rnd = Random(11);
      var zeroLeading = 0;
      for (var i = 0; i < 3000; i++) {
        final n1 = Uint8List.fromList(
          List.generate(16, (_) => rnd.nextInt(256)),
        );
        final n2 = Uint8List.fromList(
          List.generate(16, (_) => rnd.nextInt(256)),
        );
        final c = code(n1, n2, fpS, fpR);
        expect(c, matches(RegExp(r'^[0-9]{6}$')));
        if (c.startsWith('0')) zeroLeading++;
      }
      // about 10% of codes start with 0
      expect(zeroLeading, inInclusiveRange(200, 400));
    });

    test('any_input_change_changes_code (nonces and fingerprints)', () {
      final base = code(ns, nr, fpS, fpR);
      for (var i = 0; i < 16; i++) {
        final n1 = Uint8List.fromList(ns)..[i] ^= 0x01;
        final n2 = Uint8List.fromList(nr)..[i] ^= 0x80;
        expect(code(n1, nr, fpS, fpR), isNot(base), reason: 'Ns byte $i');
        expect(code(ns, n2, fpS, fpR), isNot(base), reason: 'Nr byte $i');
      }
      for (var i = 0; i < 64; i += 5) {
        String flip(String fp) =>
            fp.replaceRange(i, i + 1, fp[i] == '0' ? '1' : '0');
        expect(
          code(ns, nr, flip(fpS), fpR),
          isNot(base),
          reason: 'fpS char $i',
        );
        expect(
          code(ns, nr, fpS, flip(fpR)),
          isNot(base),
          reason: 'fpR char $i',
        );
      }
    });

    test('Ns and Nr are not interchangeable', () {
      expect(code(nr, ns, fpS, fpR), isNot(code(ns, nr, fpS, fpR)));
    });

    test('nonce_length_enforced', () {
      for (final len in [0, 8, 15, 17]) {
        expect(
          () => code(Uint8List(len), nr, fpS, fpR),
          throwsArgumentError,
          reason: 'Ns $len',
        );
        expect(
          () => code(ns, Uint8List(len), fpS, fpR),
          throwsArgumentError,
          reason: 'Nr $len',
        );
      }
    });

    test('fingerprints must be 64 hex characters', () {
      expect(() => code(ns, nr, 'xyz', fpR), throwsArgumentError);
      expect(() => code(ns, nr, fpS, ''), throwsArgumentError);
      expect(() => code(ns, nr, fpS, fpR.substring(2)), throwsArgumentError);
    });

    test('20,000 samples are roughly uniform (chi-square, seeded)', () {
      final rnd = Random(2026);
      const n = 20000;
      final byFirst = List<int>.filled(10, 0);
      final byHundredth = List<int>.filled(100, 0);
      for (var i = 0; i < n; i++) {
        final n1 = Uint8List.fromList(
          List.generate(16, (_) => rnd.nextInt(256)),
        );
        final n2 = Uint8List.fromList(
          List.generate(16, (_) => rnd.nextInt(256)),
        );
        final v = int.parse(code(n1, n2, fpS, fpR));
        byFirst[v ~/ 100000]++;
        byHundredth[v ~/ 10000]++;
      }
      double chi(List<int> counts) {
        final e = n / counts.length;
        return counts.fold(0.0, (s, c) => s + (c - e) * (c - e) / e);
      }

      expect(chi(byFirst), lessThan(27.88)); // df 9, p = 0.001
      expect(chi(byHundredth), lessThan(148.2)); // df 99, p = 0.001
    });
  });

  group('sasCodeDisplay', () {
    test('groups digits 3+3', () {
      expect(sasCodeDisplay('482913'), '482 913');
      expect(sasCodeDisplay('060044'), '060 044');
    });
    test('rejects anything that is not six digits', () {
      for (final bad in ['', '12345', '1234567', '12a456', ' 48291']) {
        expect(() => sasCodeDisplay(bad), throwsArgumentError, reason: bad);
      }
    });
  });
}

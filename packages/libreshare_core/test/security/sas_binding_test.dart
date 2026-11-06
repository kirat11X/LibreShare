// SAS binding properties of the crypto primitives (docs/plans/inc3.md section 4.1, finding 2 and
// D4). The receiver-side state-machine cases of the plan's sas_binding_test list
// (receiver_cannot_accept_before_reveal, no_reveal_within_30s_fails_TIMEOUT,
// commit_present_means_no_auto_accept) belong to the receiver package and are added there.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/security/crypto_primitives.dart';
import 'package:libreshare_core/src/security/sas.dart';
import 'package:test/test.dart';

String randomFp(Random rnd) =>
    fingerprintHex(List.generate(32, (_) => rnd.nextInt(256)));
Uint8List randomNonce(Random rnd) =>
    Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));

/// The build spec section 5 formula that Increment 3 replaces:
/// int(SHA-256("LSP1-SAS" || min(fpA,fpB) || max(fpA,fpB))[0..4]) mod 10^6.
int plainHashSas(String a, String b) {
  final lo = a.compareTo(b) <= 0 ? a : b;
  final hi = a.compareTo(b) <= 0 ? b : a;
  final h = sha256Bytes(utf8.encode('LSP1-SAS$lo$hi'));
  return ((h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3]) % 1000000;
}

void main() {
  test('relaying_mitm_detected_by_commit_mismatch_without_user_input', () {
    final rnd = Random(1);
    final fpSender = randomFp(rnd);
    final fpReal = randomFp(rnd);
    final fpMitm = randomFp(rnd);
    final ns = randomNonce(rnd);
    // The sender talks TLS to the MITM, so it commits to the MITM's fingerprint.
    final commit = sasCommit(
      ns: ns,
      senderFingerprint: fpSender,
      receiverFingerprintSeenBySender: fpMitm,
    );
    // The MITM relays commit and, later, the reveal to the real receiver, which recomputes the
    // commit with its OWN fingerprint: no digit is compared by a human and it already fails.
    expect(
      sasCommitMatches(
        commit: commit,
        ns: ns,
        senderFingerprint: fpSender,
        receiverFingerprintSeenBySender: fpReal,
      ),
      isFalse,
    );
    // Control: with no MITM the receiver's own fingerprint is what the sender saw.
    final honest = sasCommit(
      ns: ns,
      senderFingerprint: fpSender,
      receiverFingerprintSeenBySender: fpReal,
    );
    expect(
      sasCommitMatches(
        commit: honest,
        ns: ns,
        senderFingerprint: fpSender,
        receiverFingerprintSeenBySender: fpReal,
      ),
      isTrue,
    );
  });

  test('commit_binds_Ns: no other nonce opens the same commitment', () {
    final rnd = Random(2);
    final fpS = randomFp(rnd);
    final fpR = randomFp(rnd);
    final ns = randomNonce(rnd);
    final commit = sasCommit(
      ns: ns,
      senderFingerprint: fpS,
      receiverFingerprintSeenBySender: fpR,
    );
    for (var i = 0; i < 2000; i++) {
      final other = randomNonce(rnd);
      expect(
        sasCommitMatches(
          commit: commit,
          ns: other,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: fpR,
        ),
        isFalse,
      );
    }
  });

  test('commit_binds_both_fingerprints', () {
    final rnd = Random(3);
    final fpS = randomFp(rnd);
    final fpR = randomFp(rnd);
    final ns = randomNonce(rnd);
    final commit = sasCommit(
      ns: ns,
      senderFingerprint: fpS,
      receiverFingerprintSeenBySender: fpR,
    );
    for (var i = 0; i < 500; i++) {
      expect(
        sasCommitMatches(
          commit: commit,
          ns: ns,
          senderFingerprint: randomFp(rnd),
          receiverFingerprintSeenBySender: fpR,
        ),
        isFalse,
      );
      expect(
        sasCommitMatches(
          commit: commit,
          ns: ns,
          senderFingerprint: fpS,
          receiverFingerprintSeenBySender: randomFp(rnd),
        ),
        isFalse,
      );
    }
  });

  test(
    'code depends on both nonces and both fingerprints (grind resistance)',
    () {
      final rnd = Random(4);
      final fpA = randomFp(rnd);
      final fpB = randomFp(rnd);
      final ns = randomNonce(rnd);
      final nr = randomNonce(rnd);
      final base = sasCode(
        ns: ns,
        nr: nr,
        fingerprintA: fpA,
        fingerprintB: fpB,
      );
      var same = 0;
      const trials = 400;
      for (var i = 0; i < trials; i++) {
        final changes = [
          sasCode(
            ns: randomNonce(rnd),
            nr: nr,
            fingerprintA: fpA,
            fingerprintB: fpB,
          ),
          sasCode(
            ns: ns,
            nr: randomNonce(rnd),
            fingerprintA: fpA,
            fingerprintB: fpB,
          ),
          sasCode(
            ns: ns,
            nr: nr,
            fingerprintA: randomFp(rnd),
            fingerprintB: fpB,
          ),
          sasCode(
            ns: ns,
            nr: nr,
            fingerprintA: fpA,
            fingerprintB: randomFp(rnd),
          ),
        ];
        for (final c in changes) {
          if (c == base) same++;
        }
      }
      // A random replacement matches with probability 1e-6; 1600 draws almost surely give 0.
      expect(same, lessThanOrEqualTo(1));
    },
  );

  test('impersonating_mitm_gets_different_codes_on_each_side (seeded)', () {
    // M impersonates the receiver towards A (identity M1) and the sender towards B (identity M2).
    final rnd = Random(5);
    var equal = 0;
    const trials = 500;
    for (var i = 0; i < trials; i++) {
      final fpA = randomFp(rnd);
      final fpB = randomFp(rnd);
      final fpM1 = randomFp(rnd);
      final fpM2 = randomFp(rnd);
      final nsA = randomNonce(rnd); // honest A's committed nonce
      final nrM = randomNonce(rnd); // M's reply nonce towards A
      final nsM = randomNonce(rnd); // M's committed nonce towards B
      final nrB = randomNonce(rnd); // B's reply nonce
      final onA = sasCode(
        ns: nsA,
        nr: nrM,
        fingerprintA: fpA,
        fingerprintB: fpM1,
      );
      final onB = sasCode(
        ns: nsM,
        nr: nrB,
        fingerprintA: fpM2,
        fingerprintB: fpB,
      );
      if (onA == onB) equal++;
    }
    expect(equal, 0);
  });

  test('plain_hash_sas_is_grindable_but_commit_reveal_is_not', () {
    final rnd = Random(6);

    // --- the spec's original formula: the attacker grinds throw-away certificate fingerprints.
    // Honest A (fpA) and honest B (fpB). M must present M1 to A and M2 to B with equal codes.
    final fpA = randomFp(rnd);
    final fpB = randomFp(rnd);
    final candidatesM1 = <int, String>{};
    for (var i = 0; i < 4000; i++) {
      final fp = randomFp(rnd);
      candidatesM1[plainHashSas(fpA, fp)] = fp;
    }
    String? fpM2;
    String? fpM1;
    var tries = 0;
    while (fpM1 == null && tries < 40000) {
      tries++;
      final cand = randomFp(rnd);
      final hit = candidatesM1[plainHashSas(cand, fpB)];
      if (hit != null) {
        fpM2 = cand;
        fpM1 = hit;
      }
    }
    expect(
      fpM1,
      isNotNull,
      reason: 'with ~4000 + a few hundred hashes the old SAS is matched',
    );
    expect(plainHashSas(fpA, fpM1!), plainHashSas(fpM2!, fpB));
    expect(tries, lessThan(40000));

    // --- commit-then-reveal: the same attacker budget (even more) does not help, because
    // fpM1 is fixed by the TLS handshake before the commit and Ns is unknown until the reveal,
    // while Nr towards B is chosen by B after M's own commit.
    var attackerWins = 0;
    const trials = 10000;
    for (var i = 0; i < trials; i++) {
      final a = randomFp(rnd);
      final b = randomFp(rnd);
      final m1 = randomFp(rnd);
      final m2 = randomFp(rnd);
      final nsA = randomNonce(rnd);
      final nrFromM = randomNonce(
        rnd,
      ); // chosen before Ns is revealed: independent of it
      final nsFromM = randomNonce(rnd); // committed before Nr is known
      final nrFromB = randomNonce(rnd);
      final onA = sasCode(
        ns: nsA,
        nr: nrFromM,
        fingerprintA: a,
        fingerprintB: m1,
      );
      final onB = sasCode(
        ns: nsFromM,
        nr: nrFromB,
        fingerprintA: m2,
        fingerprintB: b,
      );
      if (onA == onB) attackerWins++;
    }
    expect(
      attackerWins / trials,
      lessThanOrEqualTo(1e-4),
      reason: 'success rate must stay at the 1e-6 guessing level',
    );
  });
}

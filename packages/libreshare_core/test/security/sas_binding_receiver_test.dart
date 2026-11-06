// SAS commit/reveal, receiver half (Increment 3, work package P4).
// (The primitives and the sender half are P1's `sas_binding_test.dart`; this file asserts what
// FileReceiver does with them.)
//
// Sources: LSP-1 5.1 (commit/reveal flow, rules, deadlines), 4.3.4 `POST /sessions/{sid}/sas`,
// 6 (state machine), docs/plans/inc3.md D4 and section 4.1 `security/sas_binding_test`
// (`relaying_mitm_detected_by_commit_mismatch_without_user_input`,
// `impersonating_mitm_gets_different_codes_on_each_side`, `receiver_cannot_accept_before_reveal`,
// `no_reveal_within_30s_fails_TIMEOUT`, `commit_present_means_no_auto_accept`).
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p4_fake_time.dart';
import '../helpers/p4_support.dart';

void main() {
  final tx = p4Identity(kTxId);
  late P4Rig rig;

  tearDown(() => rig.dispose());

  FileReceiver rx() => rig.receiver;

  IncomingSessionInfo infoFor(String sid) {
    final i = rx().incomingInfo(sid);
    expect(i, isNotNull, reason: 'incomingInfo must describe a live session');
    return i!;
  }

  /// Opens a first-contact session with a commitment; returns it with the sender's nonce state.
  Future<(SessionStatus, SasSender)> firstContact({
    KeyIdentity? sender,
    String? receiverFpSeenBySender,
  }) async {
    final s = sender ?? tx;
    final sas = SasSender(s, receiverFpSeenBySender ?? rig.rxFp);
    final st = await rig.open(s, commit: sas.commit);
    expect(st.sas, isNotNull, reason: 'a SAS challenge must be returned');
    return (st, sas);
  }

  Future<SessionStatus> reveal(
    String sid,
    SasSender sas, {
    AuthenticatedPeer? peer,
    String? nonce,
  }) => Future.sync(
    () => rx().revealSas(
      sid,
      nonce: nonce ?? sas.nonceB64,
      peer: peer ?? peerOf(sas.sender),
    ),
  );

  // LSP-1 5.1: the 202 carries `sas.nonce` = Nr (22 b64url = 16 bytes), chosen by the receiver
  // after the commitment; Accept stays disabled; every PENDING SessionStatus repeats the same Nr.
  group('202 with the receiver nonce', () {
    test('PENDING with sas.nonce of 16 bytes and no tokens', () async {
      rig = P4Rig();
      final (st, _) = await firstContact();
      expect(st.status, TransferStatus.pending);
      expect(st.acceptedFiles, isEmpty);
      expect(st.sas, isNotNull);
      expect(st.sas!.nonce, hasLength(22));
      expect(b64urlDecode(st.sas!.nonce), hasLength(16));
    });

    test('Nr is fresh per session and differs from the sender nonce', () async {
      rig = P4Rig();
      final (a, sasA) = await firstContact();
      final (b, _) = await firstContact();
      expect(a.sas!.nonce, isNot(b.sas!.nonce));
      expect(a.sas!.nonce, isNot(sasA.nonceB64));
    });

    test('Nr never changes while PENDING (poll, reveal response)', () async {
      rig = P4Rig();
      final (st, sas) = await firstContact();
      final polled = await rx().getSession(st.sessionId);
      expect(polled.status, TransferStatus.pending);
      expect(polled.sas!.nonce, st.sas!.nonce);
      final revealed = await reveal(st.sessionId, sas);
      expect(revealed.status, TransferStatus.pending);
      expect(revealed.sas!.nonce, st.sas!.nonce);
      expect((await rx().getSession(st.sessionId)).sas!.nonce, st.sas!.nonce);
    });

    test(
      'a session WITHOUT a commitment has no sas member (positive twin)',
      () async {
        rig = P4Rig();
        final st = await rig.open(tx);
        expect(st.status, TransferStatus.pending);
        expect(st.sas, isNull);
      },
    );

    test('a malformed commitment is 400 and creates nothing', () async {
      // LSP-1 4.3.4 step 5 (shape): sasCommit must be 43 base64url characters. The HTTP layer
      // checks it too; the handler must not trust that.
      rig = P4Rig();
      for (final bad in ['', 'short', 'A' * 44, '!' * 43, '${'A' * 42}=']) {
        await expectLs(rig.open(tx, commit: bad), LsErrorCode.badRequest);
      }
      expect(rx().pendingSessionIds, isEmpty);
    });
  });

  // LSP-1 5.1: "The receiver cannot enable Accept before the code exists; otherwise a sender
  // that never reveals would bypass the SAS."
  group('Accept needs the code (receiver_cannot_accept_before_reveal)', () {
    test(
      'accept before the reveal is refused (409) and the session stays PENDING',
      () async {
        rig = P4Rig();
        final (st, sas) = await firstContact();
        for (var i = 0; i < 3; i++) {
          await expectLs(rx().accept(st.sessionId), LsErrorCode.wrongState);
        }
        final polled = await rx().getSession(st.sessionId);
        expect(polled.status, TransferStatus.pending);
        expect(polled.acceptedFiles, isEmpty);
        expect(infoFor(st.sessionId).sasCode, isNull);
        expect(rig.eventsOf<SasReady>(), isEmpty);
        // twin: after the reveal the very same accept works
        await reveal(st.sessionId, sas);
        final ok = await rx().accept(st.sessionId);
        expect(ok.status, TransferStatus.inProgress);
        expect(ok.acceptedFiles.keys, ['f0']);
      },
    );

    test('a sender that never reveals gets no tokens however often the user taps Accept', () async {
      rig = P4Rig();
      final (st, _) = await firstContact();
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          rx()
              .accept(st.sessionId)
              .then<Object?>((s) => s, onError: (Object e) => e),
      ]);
      expect(results.whereType<SessionStatus>(), isEmpty);
      expect(results.whereType<LsException>(), hasLength(5));
      expect(
        (await rx().getSession(st.sessionId)).status,
        TransferStatus.pending,
      );
    });

    test('chunks cannot be uploaded before Accept (no usable token, no data on disk)', () async {
      rig = P4Rig();
      final (st, _) = await firstContact();
      Object? caught;
      try {
        await rx().putChunk(
          st.sessionId,
          'f0',
          0,
          Stream.value(<int>[1, 2, 3, 4, 5]),
          token: 'anything',
        );
      } on LsException catch (e) {
        caught = e;
      }
      expect(
        caught,
        anyOf(isLs(LsErrorCode.tokenInvalid), isLs(LsErrorCode.wrongState)),
      );
      expect(rig.dl.listSync(recursive: true), isEmpty);
    });
  });

  // LSP-1 5.1 + 4.3.4 /sas: Match -> 200 PENDING; the receiver derives the code and emits
  // SasReady(outgoing: false).
  group('reveal accepted', () {
    test(
      'code equals the sender-side computation; SasReady(outgoing:false) once',
      () async {
        rig = P4Rig();
        final (st, sas) = await firstContact();
        expect(rig.eventsOf<SasReady>(), isEmpty);
        await reveal(st.sessionId, sas);
        final ev = rig.eventsOf<SasReady>().single;
        expect(ev.sessionId, st.sessionId);
        expect(ev.outgoing, isFalse);
        expect(ev.code, matches(RegExp(r'^[0-9]{6}$')));
        expect(ev.code, sas.codeWith(st.sas!.nonce, rig.rxFp));
        final info = infoFor(st.sessionId);
        expect(info.sasRequired, isTrue);
        expect(info.sasCode, ev.code);
      },
    );

    test(
      'the code does not depend on the order of the two fingerprints',
      () async {
        rig = P4Rig();
        final (st, sas) = await firstContact();
        await reveal(st.sessionId, sas);
        final nr = b64urlDecode(st.sas!.nonce);
        final swapped = sasCode(
          ns: sas.ns,
          nr: nr,
          fingerprintA: rig.rxFp,
          fingerprintB: fpOf(tx),
        );
        expect(rig.eventsOf<SasReady>().single.code, swapped);
      },
    );

    test('a second reveal is 409 and does not emit a second code', () async {
      rig = P4Rig();
      final (st, sas) = await firstContact();
      await reveal(st.sessionId, sas);
      await expectLs(reveal(st.sessionId, sas), LsErrorCode.wrongState);
      expect(rig.eventsOf<SasReady>(), hasLength(1));
      expect(
        (await rx().getSession(st.sessionId)).status,
        TransferStatus.pending,
      );
    });

    test('two sessions get independent codes', () async {
      rig = P4Rig();
      final (a, sasA) = await firstContact();
      final (b, sasB) = await firstContact();
      await reveal(a.sessionId, sasA);
      await reveal(b.sessionId, sasB);
      final codes = rig.eventsOf<SasReady>().toList();
      expect(codes, hasLength(2));
      expect(codes[0].sessionId, a.sessionId);
      expect(codes[1].sessionId, b.sessionId);
      expect(codes[0].code, sasA.codeWith(a.sas!.nonce, rig.rxFp));
      expect(codes[1].code, sasB.codeWith(b.sas!.nonce, rig.rxFp));
    });
  });

  // LSP-1 4.3.4 /sas: "Mismatch -> 401 AUTH_INVALID and the session becomes FAILED(PROTOCOL_ERROR):
  // a relaying man-in-the-middle fails here without any human comparison."
  group('commit mismatch (relaying_mitm_detected_by_commit_mismatch_without_user_input)', () {
    test('sender saw a MITM certificate (fpR\' != our fingerprint): 401 + FAILED(PROTOCOL_ERROR)', () async {
      rig = P4Rig();
      final mitm = p4Identity('mitm-id');
      // The honest sender committed to the fingerprint it saw in the handshake: the MITM's.
      final (st, sas) = await firstContact(receiverFpSeenBySender: fpOf(mitm));
      await expectLs(reveal(st.sessionId, sas), LsErrorCode.authInvalid);
      final polled = await rx().getSession(st.sessionId);
      expect(polled.status, TransferStatus.failed);
      expect(polled.failureReason, FailureReason.protocolError);
      final fin = rig.eventsOf<SessionFinished>().single;
      expect(fin.reason, 'PROTOCOL_ERROR');
      expect(fin.success, isFalse);
      expect(
        rig.eventsOf<SasReady>(),
        isEmpty,
        reason: 'no code is ever derived',
      );
      expect(rig.trust.contacts, isEmpty);
    });

    test(
      'a revealed nonce that differs in one bit: 401 + FAILED(PROTOCOL_ERROR)',
      () async {
        rig = P4Rig();
        final (st, sas) = await firstContact();
        final flipped = List<int>.of(sas.ns)..[0] ^= 1;
        await expectLs(
          reveal(st.sessionId, sas, nonce: b64urlEncode(flipped)),
          LsErrorCode.authInvalid,
        );
        expect(
          (await rx().getSession(st.sessionId)).failureReason,
          FailureReason.protocolError,
        );
      },
    );

    test(
      'after the failure even the correct reveal is 409 and Accept is 409',
      () async {
        rig = P4Rig();
        final (st, sas) = await firstContact();
        await expectLs(
          reveal(
            st.sessionId,
            sas,
            nonce: b64urlEncode(List<int>.filled(16, 7)),
          ),
          LsErrorCode.authInvalid,
        );
        await expectLs(reveal(st.sessionId, sas), LsErrorCode.wrongState);
        await expectLs(rx().accept(st.sessionId), LsErrorCode.wrongState);
        expect(rig.eventsOf<SasReady>(), isEmpty);
      },
    );

    test('a commitment replayed by another device does not verify (it binds the sender fingerprint)', () async {
      rig = P4Rig();
      final attacker = p4Identity('attacker-id');
      final honest = SasSender(tx, rig.rxFp);
      // The attacker captured the honest commit (and later even learns Ns) and presents it
      // as its own, under its own valid proof.
      final st = await rig.open(attacker, commit: honest.commit);
      await expectLs(
        Future.sync(
          () => rx().revealSas(
            st.sessionId,
            nonce: honest.nonceB64,
            peer: peerOf(attacker),
          ),
        ),
        LsErrorCode.authInvalid,
      );
      expect(
        (await rx().getSession(st.sessionId)).failureReason,
        FailureReason.protocolError,
      );
    });

    test('positive twin: the honest sender of the same Ns verifies', () async {
      rig = P4Rig();
      final (st, sas) = await firstContact();
      final r = await reveal(st.sessionId, sas);
      expect(r.status, TransferStatus.pending);
    });

    test('the code a MITM with its OWN identity shows differs from what the honest sender shows (impersonating_mitm_gets_different_codes_on_each_side)', () async {
      rig = P4Rig();
      final mitm = p4Identity('mitm-id');
      // MITM -> receiver: its own identity and its own Ns'. S -> MITM: S thinks the receiver is M.
      final mitmToReceiver = SasSender(mitm, rig.rxFp);
      final st = await rig.open(mitm, commit: mitmToReceiver.commit);
      await reveal(st.sessionId, mitmToReceiver);
      final shownOnReceiver = rig.eventsOf<SasReady>().single.code;
      // What the honest sender computes: its own Ns, a nonce the MITM relayed, fpS and fpM.
      final honest = SasSender(tx, fpOf(mitm));
      final honestCode = honest.codeWith(st.sas!.nonce, fpOf(mitm));
      expect(shownOnReceiver, isNot(honestCode));
    });
  });

  // 4.3.4 /sas: the proof must name the session's sender; a body that is not a 22-char nonce
  // is 400; unknown sid 404; cancelled 410; session without commitment 409.
  group('reveal preconditions', () {
    test('proof of another device is 401 and does NOT kill the session', () async {
      // SPEC-GAP: LSP-1 makes only a commitment mismatch fatal. Killing the session on a
      // foreign proof would let anyone who learns a sid abort a pending prompt.
      rig = P4Rig();
      final (st, sas) = await firstContact();
      final other = p4Identity('other-id');
      await expectLs(
        reveal(st.sessionId, sas, peer: peerOf(other)),
        LsErrorCode.authInvalid,
      );
      expect(
        (await rx().getSession(st.sessionId)).status,
        TransferStatus.pending,
      );
      final ok = await reveal(st.sessionId, sas);
      expect(ok.status, TransferStatus.pending);
    });

    test(
      'no proof (peer == null) is 401 and does not kill the session',
      () async {
        rig = P4Rig();
        final (st, sas) = await firstContact();
        await expectLs(
          Future.sync(
            () => rx().revealSas(st.sessionId, nonce: sas.nonceB64, peer: null),
          ),
          LsErrorCode.authInvalid,
        );
        expect(
          (await rx().getSession(st.sessionId)).status,
          TransferStatus.pending,
        );
      },
    );

    test('a nonce that is not 22 base64url characters of 16 bytes is 400, session untouched', () async {
      rig = P4Rig();
      final (st, sas) = await firstContact();
      for (final bad in [
        '',
        'AAAA',
        'A' * 23,
        '${'A' * 21}!',
        '${'A' * 21}=',
      ]) {
        await expectLs(
          reveal(st.sessionId, sas, nonce: bad),
          LsErrorCode.badRequest,
        );
      }
      expect(
        (await rx().getSession(st.sessionId)).status,
        TransferStatus.pending,
      );
      await reveal(st.sessionId, sas);
    });

    test('unknown session id is 404', () async {
      rig = P4Rig();
      final sas = SasSender(tx, rig.rxFp);
      await expectLs(
        Future.sync(
          () => rx().revealSas(
            'no-such-session',
            nonce: sas.nonceB64,
            peer: peerOf(tx),
          ),
        ),
        LsErrorCode.notFound,
      );
    });

    test(
      'a session created WITHOUT a commitment answers 409 WRONG_STATE',
      () async {
        rig = P4Rig();
        final st = await rig.open(tx);
        final sas = SasSender(tx, rig.rxFp);
        await expectLs(reveal(st.sessionId, sas), LsErrorCode.wrongState);
        expect(
          (await rx().getSession(st.sessionId)).status,
          TransferStatus.pending,
        );
      },
    );

    test('a cancelled session answers 410 CANCELLED', () async {
      rig = P4Rig();
      final (st, sas) = await firstContact();
      await rx().cancel(st.sessionId);
      await expectLs(reveal(st.sessionId, sas), LsErrorCode.cancelled);
    });

    test('an accepted (IN_PROGRESS) session answers 409', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.known);
      final st = await rig.open(tx);
      await rx().accept(st.sessionId);
      await expectLs(
        reveal(st.sessionId, SasSender(tx, rig.rxFp)),
        LsErrorCode.wrongState,
      );
    });
  });

  // LSP-1 5.1 deadlines: reveal within 30 s of the 202 (kSasRevealTimeout) else FAILED(TIMEOUT);
  // the 120 s consent deadline runs from session creation and covers the reveal too.
  group('deadlines (virtual time, default constants)', () {
    test('no reveal within 30 s -> FAILED(TIMEOUT); the late reveal is 409; nothing pinned', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        final (st, sas) = await firstContact();
        await t.advance(const Duration(seconds: 29));
        expect(
          (await rx().getSession(st.sessionId)).status,
          TransferStatus.pending,
        );
        await t.advance(const Duration(seconds: 1, milliseconds: 1));
        final polled = await rx().getSession(st.sessionId);
        expect(polled.status, TransferStatus.failed);
        expect(polled.failureReason, FailureReason.timeout);
        expect(rig.eventsOf<SessionFinished>().single.reason, 'TIMEOUT');
        await expectLs(reveal(st.sessionId, sas), LsErrorCode.wrongState);
        await expectLs(rx().accept(st.sessionId), LsErrorCode.wrongState);
        expect(rig.eventsOf<SasReady>(), isEmpty);
        expect(rig.trust.contacts, isEmpty);
      });
    });

    test('a reveal at 29 s is still accepted (positive twin)', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        final (st, sas) = await firstContact();
        await t.advance(const Duration(seconds: 29));
        final ok = await reveal(st.sessionId, sas);
        expect(ok.status, TransferStatus.pending);
        expect(rig.eventsOf<SasReady>(), hasLength(1));
      });
    });

    test('after a good reveal the 30 s deadline is gone; the 120 s consent deadline still fires', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        final (st, sas) = await firstContact();
        await t.advance(const Duration(seconds: 10));
        await reveal(st.sessionId, sas);
        await t.advance(const Duration(seconds: 100)); // t = 110 s
        expect(
          (await rx().getSession(st.sessionId)).status,
          TransferStatus.pending,
        );
        await t.advance(
          const Duration(seconds: 10, milliseconds: 5),
        ); // t > 120 s
        final polled = await rx().getSession(st.sessionId);
        expect(polled.status, TransferStatus.failed);
        expect(polled.failureReason, FailureReason.timeout);
        await expectLs(rx().accept(st.sessionId), LsErrorCode.wrongState);
      });
    });

    test('Accept between the reveal and 120 s works (positive twin)', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        final (st, sas) = await firstContact();
        await reveal(st.sessionId, sas);
        await t.advance(const Duration(seconds: 60));
        final ok = await rx().accept(st.sessionId);
        expect(ok.status, TransferStatus.inProgress);
        await t.advance(const Duration(seconds: 300));
        expect(
          (await rx().getSession(st.sessionId)).status,
          TransferStatus.inProgress,
        );
      });
    });
  });

  // LSP-1 5.1 rule 3 / plan section 4.1 `commit_present_means_no_auto_accept`.
  group('commit_present_means_no_auto_accept', () {
    test(
      'trusted contact + autoAcceptTrusted + commit -> 202 with SAS pending',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
        await rig.pinContact(tx, PeerTrust.trusted);
        final (st, sas) = await firstContact();
        expect(st.status, TransferStatus.pending);
        expect(st.sas, isNotNull);
        await expectLs(rx().accept(st.sessionId), LsErrorCode.wrongState);
        await reveal(st.sessionId, sas);
        expect(
          (await rx().accept(st.sessionId)).status,
          TransferStatus.inProgress,
        );
      },
    );

    test(
      'twin: the same contact without a commitment IS auto-accepted',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
        await rig.pinContact(tx, PeerTrust.trusted);
        final st = await rig.open(tx);
        expect(st.status, TransferStatus.inProgress);
        expect(st.sas, isNull);
      },
    );
  });

  // Cancel in the middle of the flow must leave nothing behind.
  test(
    'cancel during the SAS flow ends the session; reveal is then 410',
    () async {
      rig = P4Rig();
      final (st, sas) = await firstContact();
      await reveal(st.sessionId, sas);
      await rx().cancel(st.sessionId);
      final polled = await rx().getSession(st.sessionId);
      expect(polled.failureReason, FailureReason.cancelled);
      expect(rig.trust.contacts, isEmpty);
      await expectLs(reveal(st.sessionId, sas), LsErrorCode.cancelled);
    },
  );
}

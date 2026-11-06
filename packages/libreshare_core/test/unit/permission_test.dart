// Consent for incoming sessions in the secure profile (Increment 3, work package P4).
//
// Sources: LSP-1 4.3.4 "Outcomes" (202 PENDING vs 200 IN_PROGRESS on auto-accept; a request with
// `sasCommit` is never auto-accepted), 5 "Consent" row (non-trusted senders always prompt;
// trusted auto-accept is opt-in; 120 s -> FAILED(TIMEOUT)), 5.1 (pinning after the users
// accepted), 6 (state machine), docs/plans/inc3.md D4 and section 4 row `unit/permission_test`.
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

  // LSP-1 4.3.4 Outcomes + 5.1: auto-accept only for a PROVEN, PINNED-TRUSTED sender whose
  // request has NO sasCommit, and only when ConsentPolicy.autoAcceptTrusted is on (default off).
  // Table: trust x commit x policy.
  group('auto-accept matrix', () {
    for (final trust in [null, PeerTrust.known, PeerTrust.trusted]) {
      for (final withCommit in [false, true]) {
        for (final policyOn in [false, true]) {
          final expectAuto =
              trust == PeerTrust.trusted && !withCommit && policyOn;
          final name =
              'trust=${trust?.name ?? 'unknown'} commit=$withCommit '
              'autoAcceptTrusted=$policyOn -> '
              '${expectAuto ? 'auto-accepted (200)' : 'prompt (202)'}';
          test(name, () async {
            rig = P4Rig(consent: ConsentPolicy(autoAcceptTrusted: policyOn));
            if (trust != null) await rig.pinContact(tx, trust);
            final commit = withCommit ? SasSender(tx, rig.rxFp).commit : null;
            final st = await rig.open(tx, commit: commit);
            if (expectAuto) {
              expect(st.status, TransferStatus.inProgress);
              expect(st.acceptedFiles.keys, ['f0']);
              expect(st.acceptedFiles['f0']!.token, isNotEmpty);
              expect(rx().pendingSessionIds, isEmpty);
            } else {
              expect(st.status, TransferStatus.pending);
              expect(st.acceptedFiles, isEmpty);
              expect(rx().pendingSessionIds, [st.sessionId]);
            }
            expect(rig.eventsOf<SessionCreated>(), hasLength(1));
          });
        }
      }
    }

    test(
      'auto-accept does not touch the contact (no pin, no ContactChanged)',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
        await rig.pinContact(tx, PeerTrust.trusted, alias: 'Alice');
        final before = rig.trust.contacts.single;
        await rig.open(tx);
        expect(rig.eventsOf<ContactChanged>(), isEmpty);
        expect(rig.trust.contacts.single.trust, PeerTrust.trusted);
        expect(rig.trust.contacts.single.alias, before.alias);
      },
    );

    test(
      'a proof is required: no proof is 401, never an auto-accept',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
        await rig.pinContact(tx, PeerTrust.trusted);
        // The attacker copies the trusted contact's deviceId and fingerprint into the body
        // but cannot produce its proof.
        await expectLs(
          rx().createAuthenticatedSession(
            p4Request(tx),
            remoteAddress: '192.0.2.10',
            peer: null,
          ),
          LsErrorCode.authInvalid,
        );
        expect(rx().pendingSessionIds, isEmpty);
        expect(rx().activeSessionCount, 0);
      },
    );

    test(
      'a valid proof of ANOTHER key claiming the trusted contact is 401',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
        await rig.pinContact(tx, PeerTrust.trusted);
        final attacker = p4Identity('attacker-id');
        final req = p4Request(tx); // claims tx-id and tx's fingerprint
        await expectLs(
          rx().createAuthenticatedSession(
            req,
            remoteAddress: '192.0.2.10',
            peer: peerOf(attacker),
          ),
          LsErrorCode.authInvalid,
        );
        expect(rx().activeSessionCount, 0);
      },
    );

    // SPEC-GAP: LSP-1 says a sasCommit is never auto-accepted "whatever the sender's trust
    // level"; it does not mention the operator flag `--auto-accept` (FileReceiver.autoAccept).
    // The safer reading: the human comparison always happens when a commitment is present.
    test('operator autoAccept flag does not bypass a SAS commitment', () async {
      rig = P4Rig(autoAccept: true);
      final st = await rig.open(tx, commit: SasSender(tx, rig.rxFp).commit);
      expect(st.status, TransferStatus.pending);
      expect(st.acceptedFiles, isEmpty);
    });

    test('operator autoAccept flag keeps working without a commitment (Inc 1 semantics)', () async {
      // SPEC-GAP: the flag is "accept everything from a proven sender" in the secure profile.
      rig = P4Rig(autoAccept: true);
      final st = await rig.open(tx);
      expect(st.status, TransferStatus.inProgress);
    });
  });

  // LSP-1 4.3.4 step 9: blocked -> 403 BLOCKED before any prompt (plan section 4).
  group('blocked sender', () {
    test('403 BLOCKED, no SessionCreated, nothing pending', () async {
      rig = P4Rig();
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
      expect(rig.eventsOf<SessionCreated>(), isEmpty);
      expect(rx().pendingSessionIds, isEmpty);
    });

    test('un-blocking restores the normal prompt (positive twin)', () async {
      rig = P4Rig();
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
      await rig.trust.unblock(fpOf(tx));
      expect((await rig.open(tx)).status, TransferStatus.pending);
    });
  });

  // LSP-1 6: PENDING --reject--> FAILED(REJECTED). The sender sees it on its next poll.
  group('reject', () {
    test('reject gives FAILED(REJECTED) on poll, SessionFinished(REJECTED), session gone from pending', () async {
      rig = P4Rig();
      final st = await rig.open(tx);
      await rx().reject(st.sessionId);
      final polled = await rx().getSession(st.sessionId);
      expect(polled.status, TransferStatus.failed);
      expect(polled.failureReason, FailureReason.rejected);
      final fin = rig.eventsOf<SessionFinished>().single;
      expect(fin.success, isFalse);
      expect(fin.reason, 'REJECTED');
      expect(rx().pendingSessionIds, isEmpty);
    });

    test('a long-poller is woken by the reject', () async {
      rig = P4Rig();
      final st = await rig.open(tx);
      final poll = rx().getSession(
        st.sessionId,
        wait: const Duration(seconds: 20),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await rx().reject(st.sessionId);
      final r = await poll.timeout(const Duration(seconds: 5));
      expect(r.failureReason, FailureReason.rejected);
    });

    test(
      'reject before the SAS code exists is allowed; the reveal then is 409',
      () async {
        rig = P4Rig();
        final sas = SasSender(tx, rig.rxFp);
        final st = await rig.open(tx, commit: sas.commit);
        await rx().reject(st.sessionId);
        expect(
          (await rx().getSession(st.sessionId)).failureReason,
          FailureReason.rejected,
        );
        await expectLs(
          Future.sync(
            () => rx().revealSas(
              st.sessionId,
              nonce: sas.nonceB64,
              peer: peerOf(tx),
            ),
          ),
          LsErrorCode.wrongState,
        );
        expect(rig.eventsOf<SasReady>(), isEmpty);
      },
    );

    test('reject twice and accept-after-reject are 409', () async {
      rig = P4Rig();
      final st = await rig.open(tx);
      await rx().reject(st.sessionId);
      await expectLs(rx().reject(st.sessionId), LsErrorCode.wrongState);
      await expectLs(rx().accept(st.sessionId), LsErrorCode.wrongState);
    });

    test('a rejected first contact is NOT pinned', () async {
      rig = P4Rig();
      final sas = SasSender(tx, rig.rxFp);
      final st = await rig.open(tx, commit: sas.commit);
      await rx().revealSas(st.sessionId, nonce: sas.nonceB64, peer: peerOf(tx));
      await rx().reject(st.sessionId);
      expect(rig.trust.contacts, isEmpty);
      expect(rig.trust.classify(kTxId, fpOf(tx)).trust, PeerTrust.unknown);
      expect(rig.eventsOf<ContactChanged>(), isEmpty);
    });
  });

  // LSP-1 4.1 (permission timeout 120 s, `kPermissionTimeout`) and 6: FAILED(TIMEOUT); accepting
  // afterwards is a 409; accept and timeout racing: exactly one wins.
  group('consent timeout (virtual time, default constants)', () {
    test(
      '120 s of silence -> FAILED(TIMEOUT); 119 s is still PENDING',
      () async {
        final clock = ManualClock();
        await withFakeTime(clock, (t) async {
          rig = P4Rig(clock: clock);
          final st = await rig.open(tx);
          await t.advance(const Duration(seconds: 119));
          expect(
            (await rx().getSession(st.sessionId)).status,
            TransferStatus.pending,
          );
          expect(rig.eventsOf<SessionFinished>(), isEmpty);
          await t.advance(const Duration(seconds: 1, milliseconds: 1));
          final polled = await rx().getSession(st.sessionId);
          expect(polled.status, TransferStatus.failed);
          expect(polled.failureReason, FailureReason.timeout);
          final fin = rig.eventsOf<SessionFinished>().single;
          expect(fin.success, isFalse);
          expect(fin.reason, 'TIMEOUT');
          expect(rx().pendingSessionIds, isEmpty);
        });
      },
    );

    test('accept after the timeout is 409 and starts nothing', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        final st = await rig.open(tx);
        await t.advance(const Duration(seconds: 121));
        await expectLs(rx().accept(st.sessionId), LsErrorCode.wrongState);
        final polled = await rx().getSession(st.sessionId);
        expect(polled.status, TransferStatus.failed);
        expect(polled.acceptedFiles, isEmpty);
      });
    });

    test('accepting in time disarms the timeout (positive twin)', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        final st = await rig.open(tx);
        await t.advance(const Duration(seconds: 100));
        await rx().accept(st.sessionId);
        await t.advance(const Duration(seconds: 200));
        final polled = await rx().getSession(st.sessionId);
        expect(polled.status, TransferStatus.inProgress);
        expect(rig.eventsOf<SessionFinished>(), isEmpty);
      });
    });

    test('a timed-out first contact is not pinned', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        final sas = SasSender(tx, rig.rxFp);
        final st = await rig.open(tx, commit: sas.commit);
        await rx().revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        );
        await t.advance(const Duration(seconds: 121));
        expect(
          (await rx().getSession(st.sessionId)).failureReason,
          FailureReason.timeout,
        );
        expect(rig.trust.contacts, isEmpty);
      });
    });

    // Exactly one wins: whichever order the scheduler takes, the end state must be consistent
    // with the answer the caller of accept() got, and SessionFinished fires at most once.
    for (final lead in [const Duration(milliseconds: 1), Duration.zero]) {
      test(
        'accept racing the 120 s timeout (accept issued ${lead.inMilliseconds} ms before it fires): exactly one wins',
        () async {
          final clock = ManualClock();
          await withFakeTime(clock, (t) async {
            rig = P4Rig(clock: clock);
            final st = await rig.open(tx);
            await t.advance(kPermissionTimeout - lead);
            Object? acceptError;
            SessionStatus? accepted;
            final acceptDone = rx()
                .accept(st.sessionId)
                .then<void>(
                  (s) => accepted = s,
                  onError: (Object e) => acceptError = e,
                );
            await t.advance(lead + const Duration(milliseconds: 5));
            await acceptDone;
            final end = await rx().getSession(st.sessionId);
            if (accepted != null) {
              expect(acceptError, isNull);
              expect(accepted!.status, TransferStatus.inProgress);
              expect(end.status, TransferStatus.inProgress);
              expect(rig.eventsOf<SessionFinished>(), isEmpty);
            } else {
              expect(acceptError, isLs(LsErrorCode.wrongState));
              expect(end.status, TransferStatus.failed);
              expect(end.failureReason, FailureReason.timeout);
              expect(rig.eventsOf<SessionFinished>(), hasLength(1));
            }
          });
        },
      );
    }

    test('accept racing the timeout leaves no session that is both accepted and timed out', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        for (var i = 0; i < 4; i++) {
          final st = await rig.open(tx, remote: '198.51.100.$i');
          expect(st.status, TransferStatus.pending);
        }
        final ids = rx().pendingSessionIds.toList();
        await t.advance(kPermissionTimeout - const Duration(milliseconds: 2));
        final results = <String, bool>{};
        final futures = [
          for (final id in ids)
            rx()
                .accept(id)
                .then<void>(
                  (_) => results[id] = true,
                  onError: (Object _) => results[id] = false,
                ),
        ];
        await t.advance(const Duration(milliseconds: 10));
        await Future.wait(futures);
        for (final id in ids) {
          final end = await rx().getSession(id);
          expect(
            end.status == TransferStatus.inProgress,
            results[id],
            reason: 'accept() outcome must match the final state',
          );
        }
      });
    });
  });

  // LSP-1 5.1 "After the users accepted, 'Trust this device' pins the fingerprint (TOFU)" and
  // seams item 5: the receiver pins the sender as `known` when the user accepts a SAS-confirmed
  // session, and emits ContactChanged.
  group('pinning on accept', () {
    test('Accept of a SAS-confirmed first contact pins it as known (+ ContactChanged)', () async {
      rig = P4Rig();
      final sas = SasSender(tx, rig.rxFp);
      final st = await rig.open(tx, commit: sas.commit);
      await rx().revealSas(st.sessionId, nonce: sas.nonceB64, peer: peerOf(tx));
      expect(
        rig.trust.contacts,
        isEmpty,
        reason: 'no pin before the user accepts',
      );
      final accepted = await rx().accept(st.sessionId);
      expect(accepted.status, TransferStatus.inProgress);
      final c = rig.trust.contacts.single;
      expect(c.deviceId, kTxId);
      expect(c.fingerprint, fpOf(tx));
      expect(c.trust, PeerTrust.known);
      expect(c.alias, 'Sender');
      expect(rig.eventsOf<ContactChanged>().map((e) => e.deviceId), [kTxId]);
      // the next session from the pinned key is classified known (no SAS needed any more)
      expect(rig.trust.classify(kTxId, fpOf(tx)).trust, PeerTrust.known);
    });

    // SPEC-GAP: LSP-1 pins only "after the users accepted" a SAS flow. A first contact whose
    // sender had a pin for us (so it sent no commitment) has no human comparison; the safer
    // reading does not turn an unverified key into a contact.
    test(
      'Accept of an unknown sender WITHOUT a SAS flow does not pin',
      () async {
        rig = P4Rig();
        final st = await rig.open(tx);
        await rx().accept(st.sessionId);
        expect(rig.trust.contacts, isEmpty);
        expect(rig.eventsOf<ContactChanged>(), isEmpty);
      },
    );

    test(
      'Accept never lowers trust: a trusted contact stays trusted',
      () async {
        rig = P4Rig();
        await rig.pinContact(tx, PeerTrust.trusted);
        final sas = SasSender(tx, rig.rxFp);
        final st = await rig.open(tx, commit: sas.commit);
        await rx().revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        );
        await rx().accept(st.sessionId);
        expect(rig.trust.contacts.single.trust, PeerTrust.trusted);
      },
    );

    test('Accept of a known contact (no commit) changes nothing', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.known);
      final st = await rig.open(tx);
      await rx().accept(st.sessionId);
      expect(rig.trust.contacts.single.trust, PeerTrust.known);
      expect(rig.eventsOf<ContactChanged>(), isEmpty);
    });

    test('a SAS code of one session does not unlock Accept of another; the other stays unpinned', () async {
      rig = P4Rig();
      final other = p4Identity('other-id');
      final sasA = SasSender(tx, rig.rxFp);
      final sessionA = await rig.open(tx, commit: sasA.commit);
      await rx().revealSas(
        sessionA.sessionId,
        nonce: sasA.nonceB64,
        peer: peerOf(tx),
      );
      // session B from a different device has a commitment but no reveal: Accept is refused
      final sasB = SasSender(other, rig.rxFp);
      final sessionB = await rig.open(other, commit: sasB.commit);
      await expectLs(rx().accept(sessionB.sessionId), LsErrorCode.wrongState);
      expect(
        rig.trust.classify(other.identity.deviceId, fpOf(other)).trust,
        PeerTrust.unknown,
      );
    });
  });

  // The "repeated rejects offer a block" row of the plan says "event only": the receiver may
  // suggest a block but must never block by itself.
  // SPEC-GAP: no event type for the offer exists in model/events.dart and the threshold is not
  // specified, so the offer itself is not asserted here (see docs/plans/inc3-p4-tests.md).
  group('repeated rejects never block automatically', () {
    test(
      'after 6 rejects the same device is still prompted, not refused',
      () async {
        rig = P4Rig(
          consent: const ConsentPolicy(
            maxPendingPerIp: 20,
            maxPendingTotal: 20,
          ),
        );
        for (var i = 0; i < 6; i++) {
          final st = await rig.open(tx);
          await rx().reject(st.sessionId);
        }
        expect(rig.trust.blockedFingerprints, isEmpty);
        expect(rig.trust.contacts, isEmpty);
        final again = await rig.open(tx);
        expect(again.status, TransferStatus.pending);
      },
    );

    test('harness twin: an explicit block does refuse', () async {
      rig = P4Rig();
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
    });
  });

  // seams: `incomingInfo(sid)` => IncomingSessionInfo for the consent prompt.
  group('incomingInfo', () {
    test('unknown session -> null', () {
      rig = P4Rig();
      expect(rx().incomingInfo('does-not-exist'), isNull);
    });

    test('first contact with a commitment: sasRequired, no code yet', () async {
      rig = P4Rig();
      final st = await rig.open(tx, commit: SasSender(tx, rig.rxFp).commit);
      final info = infoFor(st.sessionId);
      expect(info.sessionId, st.sessionId);
      expect(info.peer!.fingerprint, fpOf(tx));
      expect(info.peer!.deviceId, kTxId);
      expect(info.trust, PeerTrust.unknown);
      expect(info.keyChanged, isFalse);
      expect(info.sasRequired, isTrue);
      expect(info.sasCode, isNull);
    });

    test('known sender without commitment: no SAS', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.known);
      final st = await rig.open(tx);
      final info = infoFor(st.sessionId);
      expect(info.trust, PeerTrust.known);
      expect(info.sasRequired, isFalse);
      expect(info.sasCode, isNull);
    });

    test('trusted contact with autoAccept off still shows a prompt with trust=trusted', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.trusted);
      final st = await rig.open(tx);
      expect(st.status, TransferStatus.pending);
      expect(infoFor(st.sessionId).trust, PeerTrust.trusted);
    });

    test(
      'unknown sender without commitment: trust unknown, no SAS required',
      () async {
        rig = P4Rig();
        final st = await rig.open(tx);
        final info = infoFor(st.sessionId);
        expect(info.trust, PeerTrust.unknown);
        expect(info.sasRequired, isFalse);
      },
    );
  });
}

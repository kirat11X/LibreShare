// BlockSuggested: "repeated rejects offer a block" (Increment 3, work package P4).
//
// Rule (orchestrator decision 2026-11-05, plan section 4 row `repeated_rejects_offer_block`):
// when the user REJECTS a session from a sender whose authenticated fingerprint has now been
// rejected 3 times within 10 minutes, the receiver emits exactly one
// BlockSuggested(rejectCount: 3) and resets that fingerprint's counter. The receiver never
// blocks by itself: TrustStore unchanged, the next session is prompted as usual. Timeouts,
// cancels by the sender and accepted sessions do not count.
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

  /// Opens a session from [sender] and rejects it (the user's Reject action).
  Future<void> rejectOne(
    KeyIdentity sender, {
    String remote = '192.0.2.10',
  }) async {
    final st = await rig.open(sender, remote: remote);
    expect(st.status, TransferStatus.pending);
    await rx().reject(st.sessionId);
  }

  List<BlockSuggested> suggestions() => rig.eventsOf<BlockSuggested>().toList();

  group('threshold of 3', () {
    test(
      '2 rejects: no event; the 3rd: exactly one with the right fields',
      () async {
        rig = P4Rig();
        await rejectOne(tx);
        await rejectOne(tx);
        expect(suggestions(), isEmpty);
        await rejectOne(tx);
        final ev = suggestions().single;
        expect(ev.deviceId, kTxId);
        expect(ev.fingerprint, fpOf(tx));
        expect(ev.alias, 'Sender');
        expect(ev.rejectCount, 3);
      },
    );

    test(
      'a SAS first contact rejected before the code exists counts too',
      () async {
        rig = P4Rig();
        await rejectOne(tx);
        await rejectOne(tx);
        final st = await rig.open(tx, commit: SasSender(tx, rig.rxFp).commit);
        await rx().reject(st.sessionId);
        expect(suggestions(), hasLength(1));
      },
    );

    test('4th and 5th rejects: nothing; the 6th: the next event (counter was reset)', () async {
      rig = P4Rig();
      for (var i = 1; i <= 6; i++) {
        await rejectOne(tx);
        final expected = i >= 6 ? 2 : (i >= 3 ? 1 : 0);
        expect(suggestions(), hasLength(expected), reason: 'after reject $i');
      }
      expect(suggestions().map((e) => e.rejectCount), [3, 3]);
    });

    test('a second reject of the SAME session (409) does not count', () async {
      rig = P4Rig();
      final first = await rig.open(tx);
      await rx().reject(first.sessionId);
      await expectLs(rx().reject(first.sessionId), LsErrorCode.wrongState);
      await rejectOne(tx);
      expect(suggestions(), isEmpty, reason: 'only 2 distinct rejects so far');
      await rejectOne(tx);
      expect(suggestions(), hasLength(1));
    });
  });

  group('never blocks by itself', () {
    test(
      'after the event: TrustStore unchanged and the next session is prompted',
      () async {
        rig = P4Rig();
        for (var i = 0; i < 3; i++) {
          await rejectOne(tx);
        }
        expect(suggestions(), hasLength(1));
        expect(rig.trust.blockedFingerprints, isEmpty);
        expect(rig.trust.contacts, isEmpty);
        expect(rig.trust.classify(kTxId, fpOf(tx)).trust, PeerTrust.unknown);
        final next = await rig.open(tx);
        expect(next.status, TransferStatus.pending);
        expect(rig.eventsOf<ContactChanged>(), isEmpty);
      },
    );

    test('a pinned contact stays pinned at the same level', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.known, alias: 'Alice');
      for (var i = 0; i < 3; i++) {
        await rejectOne(tx);
      }
      expect(
        suggestions().single.alias,
        'Sender',
        reason: 'alias as the sender presented it',
      );
      final c = rig.trust.contacts.single;
      expect(c.trust, PeerTrust.known);
      expect(c.alias, 'Alice');
      expect(rig.trust.blockedFingerprints, isEmpty);
    });

    test('harness twin: an explicit block does refuse afterwards', () async {
      rig = P4Rig();
      for (var i = 0; i < 3; i++) {
        await rejectOne(tx);
      }
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
    });
  });

  group('who counts', () {
    test('rejects of different fingerprints do not aggregate', () async {
      rig = P4Rig();
      final a = p4Identity('sender-a');
      final b = p4Identity('sender-b');
      final c = p4Identity('sender-c');
      for (var i = 0; i < 2; i++) {
        await rejectOne(a);
        await rejectOne(b);
        await rejectOne(c);
      }
      expect(suggestions(), isEmpty);
      await rejectOne(b);
      final ev = suggestions().single;
      expect(ev.fingerprint, fpOf(b));
      expect(ev.deviceId, 'sender-b');
    });

    test('a trusted and a known contact count like anybody else', () async {
      rig = P4Rig();
      final known = p4Identity('known-id');
      await rig.pinContact(tx, PeerTrust.trusted);
      await rig.pinContact(known, PeerTrust.known);
      for (var i = 0; i < 3; i++) {
        await rejectOne(tx);
        await rejectOne(known);
      }
      final fps = suggestions().map((e) => e.fingerprint).toSet();
      expect(fps, {fpOf(tx), fpOf(known)});
      expect(suggestions(), hasLength(2));
    });

    test(
      'plaintext-profile senders (no fingerprint) never produce the event',
      () async {
        rig = P4Rig(secure: false);
        final req = p4Request(
          tx,
          info: infoOf(tx, fingerprint: '', version: kProtocolVersion),
        );
        for (var i = 0; i < 7; i++) {
          final st = await rx().createSession(req, remoteAddress: '192.0.2.10');
          await rx().reject(st.sessionId);
        }
        expect(suggestions(), isEmpty);
      },
    );

    test(
      'a blocked fingerprint never reaches the prompt: no reject, no event',
      () async {
        rig = P4Rig();
        await rig.trust.block(fpOf(tx));
        for (var i = 0; i < 5; i++) {
          await expectLs(rig.open(tx), LsErrorCode.blocked);
        }
        expect(suggestions(), isEmpty);
        // twin: lifted, three rejects do produce it
        await rig.trust.unblock(fpOf(tx));
        for (var i = 0; i < 3; i++) {
          await rejectOne(tx);
        }
        expect(suggestions(), hasLength(1));
      },
    );
  });

  // The window is 10 minutes of the injected clock. Counted at the time of the reject.
  group('10 minute window (boundary +-1 ms)', () {
    test('third reject 1 ms inside the window of the first: event', () async {
      rig = P4Rig();
      await rejectOne(tx);
      await rejectOne(tx);
      rig.clock.jumpWallClock(
        const Duration(minutes: 10) - const Duration(milliseconds: 1),
      );
      await rejectOne(tx);
      expect(suggestions(), hasLength(1));
    });

    test(
      'third reject 1 ms outside the window of the first two: no event',
      () async {
        rig = P4Rig();
        await rejectOne(tx);
        await rejectOne(tx);
        rig.clock.jumpWallClock(
          const Duration(minutes: 10) + const Duration(milliseconds: 1),
        );
        await rejectOne(tx);
        expect(suggestions(), isEmpty);
      },
    );

    test('rolling: only the oldest falls out, the next reject then completes a triple', () async {
      rig = P4Rig();
      await rejectOne(tx); // t = 0
      rig.clock.jumpWallClock(const Duration(minutes: 6));
      await rejectOne(tx); // t = 6 min
      rig.clock.jumpWallClock(
        const Duration(minutes: 6),
      ); // t = 12 min: first is out
      await rejectOne(tx); // 2 in window
      expect(suggestions(), isEmpty);
      rig.clock.jumpWallClock(const Duration(minutes: 1));
      await rejectOne(tx); // 6, 12, 13 min: three in window
      expect(suggestions(), hasLength(1));
    });

    test('after the event the old rejects are not reused: two more inside the window are not enough', () async {
      rig = P4Rig();
      for (var i = 0; i < 3; i++) {
        await rejectOne(tx);
      }
      rig.clock.jumpWallClock(const Duration(minutes: 1));
      await rejectOne(tx);
      await rejectOne(tx);
      expect(suggestions(), hasLength(1));
    });
  });

  group('what does not count', () {
    test('an accepted session neither counts nor resets the counter', () async {
      rig = P4Rig();
      await rejectOne(tx);
      await rejectOne(tx);
      final ok = await rig.open(tx);
      await rx().accept(ok.sessionId);
      expect(suggestions(), isEmpty, reason: 'an accept is not a reject');
      await rejectOne(tx);
      expect(
        suggestions(),
        hasLength(1),
        reason: 'the two earlier rejects still stand',
      );
    });

    test('accepts alone never produce it', () async {
      rig = P4Rig();
      for (var i = 0; i < 6; i++) {
        final st = await rig.open(tx);
        await rx().accept(st.sessionId);
      }
      expect(suggestions(), isEmpty);
    });

    test('sender cancels neither count nor reset', () async {
      rig = P4Rig();
      await rejectOne(tx);
      await rejectOne(tx);
      for (var i = 0; i < 3; i++) {
        final st = await rig.open(tx);
        await rx().cancel(st.sessionId);
      }
      expect(suggestions(), isEmpty);
      await rejectOne(tx);
      expect(suggestions(), hasLength(1));
    });

    test('consent timeouts neither count nor reset', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        await rejectOne(tx);
        await rejectOne(tx);
        for (var i = 0; i < 3; i++) {
          final st = await rig.open(tx);
          await t.advance(const Duration(seconds: 121));
          expect(
            (await rx().getSession(st.sessionId)).failureReason,
            FailureReason.timeout,
          );
        }
        expect(
          suggestions(),
          isEmpty,
          reason: 'three timeouts are not three rejects',
        );
        await rejectOne(tx);
        expect(suggestions(), hasLength(1));
      });
    });

    test('a SAS reveal timeout and a commit mismatch do not count', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock);
        for (var i = 0; i < 3; i++) {
          await rig.open(tx, commit: SasSender(tx, rig.rxFp).commit);
          await t.advance(const Duration(seconds: 31));
        }
        final bad = SasSender(tx, fpOf(p4Identity('mitm-id')));
        final st = await rig.open(tx, commit: bad.commit);
        await expectLs(
          rx().revealSas(st.sessionId, nonce: bad.nonceB64, peer: peerOf(tx)),
          LsErrorCode.authInvalid,
        );
        expect(suggestions(), isEmpty);
      });
    });
  });

  group('event content and logs', () {
    test('BlockSuggested carries exactly the listed members', () async {
      rig = P4Rig();
      for (var i = 0; i < 3; i++) {
        await rejectOne(tx);
      }
      final ev = suggestions().single;
      expect(ev.deviceId, isNotEmpty);
      expect(ev.fingerprint, hasLength(64));
      expect(ev.alias, isNotEmpty);
      expect(ev.rejectCount, 3);
      // nothing else to leak: no session id, token or address in the event's own text
      expect(ev.toString(), isNot(contains('192.0.2.10')));
    });

    test('nothing is logged in full-fingerprint form', () async {
      final logs = LogCapture()..start();
      addTearDown(logs.stop);
      rig = P4Rig();
      for (var i = 0; i < 6; i++) {
        await rejectOne(tx);
      }
      expect(suggestions(), hasLength(2));
      expect(p4Leaks(logs.text, sentinels: {'fingerprint': fpOf(tx)}), isEmpty);
    });
  });
}

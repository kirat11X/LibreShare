// Key change, receiver half (Increment 3, work package P4).
// (The sender half, `sender_refuses_receiver_key_change_with_PeerKeyChanged`, is P5's.)
//
// Sources: LSP-1 4.3.4 step 9 ("a known deviceId whose pinned fingerprint differs from the proven
// one -> 403 KEY_CHANGED (never auto-accepted, even for a trusted contact)"), 4.3.5 (KEY_CHANGED
// 403), 5.1 ("A pin mismatch (KEY_CHANGED) is never overridden by a SAS"), docs/plans/inc3.md D7
// and section 4.1 `security/key_change_test`
// (`receiver_answers_KEY_CHANGED_403_to_known_deviceId_with_new_key`,
// `key_change_emits_event_and_never_auto_accepts_even_for_trusted`,
// `explicit_removal_then_sas_restores_flow`).
import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p4_support.dart';

void main() {
  final tx = p4Identity(kTxId);
  late P4Rig rig;
  late KeyIdentity newKey;

  setUp(() {
    newKey = freshIdentity(
      kTxId,
    ); // same deviceId, different key and certificate
  });
  tearDown(() => rig.dispose());

  void noTrace() {
    expect(rig.receiver.pendingSessionIds, isEmpty);
    expect(rig.receiver.activeSessionCount, 0);
    expect(rig.eventsOf<SessionCreated>(), isEmpty);
  }

  group('known deviceId with a new key -> 403 KEY_CHANGED', () {
    for (final level in [PeerTrust.known, PeerTrust.trusted]) {
      test(
        '${level.name} contact: refused, PeerKeyChanged emitted once with both fingerprints',
        () async {
          rig = P4Rig();
          await rig.pinContact(tx, level);
          await expectLs(rig.open(newKey), LsErrorCode.keyChanged);
          final ev = rig.eventsOf<PeerKeyChanged>().single;
          expect(ev.deviceId, kTxId);
          expect(ev.pinnedFingerprint, fpOf(tx));
          expect(ev.presentedFingerprint, fpOf(newKey));
          noTrace();
        },
      );
    }

    test('positive twin: the pinned key itself is served', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.known);
      final st = await rig.open(tx);
      expect(st.status, TransferStatus.pending);
      expect(rig.eventsOf<PeerKeyChanged>(), isEmpty);
    });

    test('a different deviceId with a new key is simply a stranger (no KEY_CHANGED)', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.trusted);
      final stranger = freshIdentity('another-device');
      final st = await rig.open(stranger);
      expect(st.status, TransferStatus.pending);
      expect(rig.eventsOf<PeerKeyChanged>(), isEmpty);
    });

    test('the error text carries no fingerprint', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.known);
      final e = await expectLs(rig.open(newKey), LsErrorCode.keyChanged);
      for (final fp in [fpOf(tx), fpOf(newKey)]) {
        expect(e.message, isNot(contains(fp)));
        expect(e.message, isNot(contains(shortFp(fp))));
      }
      expect(e.retryable, isFalse);
      expect(e.httpStatus, 403);
    });
  });

  // "never auto-accepted even for a trusted contact": every route to an auto-accept is closed.
  group('key_change_emits_event_and_never_auto_accepts_even_for_trusted', () {
    test('trusted + autoAcceptTrusted: refused (the same contact with its pinned key IS auto-accepted)', () async {
      rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
      await rig.pinContact(tx, PeerTrust.trusted);
      // harness twin first: with the pinned key auto-accept happens
      final ok = await rig.open(tx);
      expect(ok.status, TransferStatus.inProgress);
      rig.events.clear();
      await expectLs(rig.open(newKey), LsErrorCode.keyChanged);
      expect(rig.eventsOf<PeerKeyChanged>(), hasLength(1));
      expect(rig.eventsOf<SessionCreated>(), isEmpty);
    });

    test('operator autoAccept flag: refused', () async {
      rig = P4Rig(autoAccept: true);
      await rig.pinContact(tx, PeerTrust.known);
      await expectLs(rig.open(newKey), LsErrorCode.keyChanged);
      expect(rig.receiver.activeSessionCount, 0);
    });

    test(
      'with a SAS commitment: still refused, no SAS state, no pending session',
      () async {
        rig = P4Rig();
        await rig.pinContact(tx, PeerTrust.known);
        final sas = SasSender(newKey, rig.rxFp);
        await expectLs(
          rig.open(newKey, commit: sas.commit),
          LsErrorCode.keyChanged,
        );
        noTrace();
        expect(rig.eventsOf<SasReady>(), isEmpty);
      },
    );

    test('with a correct PIN: still refused, PIN not consumed', () async {
      final pv = RecordingPinVerifier();
      rig = P4Rig(
        pinVerifier: pv,
        pin: const PinPolicy(mode: PinMode.fixed),
      );
      await rig.pinContact(tx, PeerTrust.known);
      await expectLs(rig.open(newKey, pin: '123456'), LsErrorCode.keyChanged);
      expect(pv.consumed, 0);
      expect(pv.checks, isEmpty);
    });
  });

  // The pin is never replaced by a request: refusal has no side effect on the trust store.
  group('never replaced, never downgraded', () {
    test('ten attempts later the pin, trust level and classification are unchanged', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.trusted, alias: 'Alice');
      for (var i = 0; i < 10; i++) {
        await expectLs(rig.open(newKey), LsErrorCode.keyChanged);
      }
      final c = rig.trust.contacts.single;
      expect(c.fingerprint, fpOf(tx));
      expect(c.trust, PeerTrust.trusted);
      expect(c.alias, 'Alice');
      final info = rig.trust.classify(kTxId, fpOf(newKey));
      expect(info.keyChanged, isTrue);
      expect(info.pinnedFingerprint, fpOf(tx));
      expect(rig.trust.classify(kTxId, fpOf(tx)).trust, PeerTrust.trusted);
      expect(rig.eventsOf<ContactChanged>(), isEmpty);
    });

    test(
      'the old key keeps working after refused attempts of the new key',
      () async {
        rig = P4Rig();
        await rig.pinContact(tx, PeerTrust.known);
        await expectLs(rig.open(newKey), LsErrorCode.keyChanged);
        expect((await rig.open(tx)).status, TransferStatus.pending);
      },
    );

    test(
      'a SAS-confirmed accept of the OLD key does not touch the pin either',
      () async {
        rig = P4Rig();
        await rig.pinContact(tx, PeerTrust.known);
        final sas = SasSender(tx, rig.rxFp);
        final st = await rig.open(tx, commit: sas.commit);
        await rig.receiver.revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        );
        await rig.receiver.accept(st.sessionId);
        expect(rig.trust.contacts.single.fingerprint, fpOf(tx));
      },
    );
  });

  // plan section 4.1: after the user removes the contact explicitly, the SAS flow works again
  // and pins the NEW key (that is the only way a key is replaced).
  group('explicit_removal_then_sas_restores_flow', () {
    test('remove contact -> first contact with the new key -> reveal -> accept pins the new key', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.trusted);
      await expectLs(rig.open(newKey), LsErrorCode.keyChanged);

      await rig.trust.remove(kTxId);
      final sas = SasSender(newKey, rig.rxFp);
      final st = await rig.open(newKey, commit: sas.commit);
      expect(st.status, TransferStatus.pending);
      await rig.receiver.revealSas(
        st.sessionId,
        nonce: sas.nonceB64,
        peer: peerOf(newKey),
      );
      await rig.receiver.accept(st.sessionId);

      final c = rig.trust.contacts.single;
      expect(c.deviceId, kTxId);
      expect(c.fingerprint, fpOf(newKey));
      expect(
        c.trust,
        PeerTrust.known,
        reason: 'a removed trusted contact starts again as known',
      );
      // and now the OLD key is the one that is refused
      await expectLs(rig.open(tx), LsErrorCode.keyChanged);
    });

    test('removal alone (no SAS) does not auto-accept the new key', () async {
      rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
      await rig.pinContact(tx, PeerTrust.trusted);
      await rig.trust.remove(kTxId);
      final st = await rig.open(newKey);
      expect(st.status, TransferStatus.pending);
    });
  });

  // A pinned device cannot be impersonated by a certificate with the same CN either: the proof
  // names the key, the body names the device (LSP-1 4.3.4 step 8 comes first).
  test('a clone claiming the pinned deviceId with its OWN key but another CN in its certificate is 401', () async {
    rig = P4Rig();
    await rig.pinContact(tx, PeerTrust.trusted);
    final evil = p4Identity('evil-id');
    final req = p4Request(evil, info: infoOf(evil, deviceId: kTxId));
    await expectLs(
      rig.receiver.createAuthenticatedSession(
        req,
        remoteAddress: '192.0.2.10',
        peer: peerOf(evil),
      ),
      LsErrorCode.authInvalid,
    );
    expect(rig.eventsOf<PeerKeyChanged>(), isEmpty);
  });
}

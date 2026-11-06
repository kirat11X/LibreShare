// Verifying-tester review of P4 (FileReceiver secure behaviour, SAS, pairing), 2026-11-05.
//
// Groups named "[RED]" document a defect found in the delivered code: they FAIL until the coder
// fixes it and must not be edited to pass. Every other group closes a gap that a mutation of the
// delivered code left green (they pass today and must stay green).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/manual_clock.dart';
import '../helpers/p4_fake_time.dart';
import '../helpers/p4_support.dart';
import '../helpers/p4v_support.dart';

Future<Object> outcome(Future<SessionStatus> f) async {
  try {
    return await f;
  } on LsException catch (e) {
    return e;
  }
}

class _Party {
  _Party(this.deviceId, this.clock, {InMemoryTrustStore? trustStore})
    : id = p4Identity('rv-$deviceId', deviceId: deviceId),
      trust = trustStore ?? InMemoryTrustStore(clock: clock),
      secrets = InMemorySecretStore() {
    service = PairingService(
      identity: id,
      trust: trust,
      secrets: secrets,
      self: () => card,
      clock: clock,
      onEvent: events.add,
    );
  }

  final String deviceId;
  final ManualClock clock;
  final KeyIdentity id;
  final TrustStore trust;
  final InMemorySecretStore secrets;
  final List<LsEvent> events = [];
  late final PairingService service;

  String get fp => id.identity.fingerprint;
  AuthenticatedPeer get peer => peerOf(id);
  DeviceInfo get card => DeviceInfo(
    deviceId: deviceId,
    alias: 'Alias $deviceId',
    platform: 'linux',
    fingerprint: fp,
    version: kProtocolVersionSecure,
  );
}

void main() {
  final tx = p4Identity(kTxId);
  late P4Rig rig;
  tearDown(() => rig.dispose());

  // ------------------------------------------------------------------ [RED] one-time PIN
  group('[RED] one-time PIN is consumed atomically (LSP-1 5.2, check-to-registration race)', () {
    test('two concurrent POST /sessions with the same one-time PIN: exactly one is authorised', () async {
      final guard = PinGuard(
        policy: const PinPolicy(mode: PinMode.window, oneTime: true),
        pin: '123456',
      );
      rig = P4Rig(pin: guard.policy, pinVerifier: guard);
      final a = p4Identity('rv-pin-a');
      final b = p4Identity('rv-pin-b');
      final results = await Future.wait([
        outcome(rig.open(a, pin: '123456', remote: '192.0.2.1')),
        outcome(rig.open(b, pin: '123456', remote: '192.0.2.2')),
      ]);
      final ok = results.whereType<SessionStatus>().length;
      final refused = results
          .whereType<LsException>()
          .where((e) => e.code == LsErrorCode.pinInvalid)
          .length;
      expect(ok, 1, reason: 'a one-time PIN authorises one session');
      expect(refused, 1, reason: 'the second one gets PIN_INVALID');
      expect(rig.receiver.pendingSessionIds, hasLength(1));
    });

    test('positive twin: sequential use of a one-time PIN is refused the second time', () async {
      final guard = PinGuard(
        policy: const PinPolicy(mode: PinMode.window, oneTime: true),
        pin: '123456',
      );
      rig = P4Rig(pin: guard.policy, pinVerifier: guard);
      await rig.open(p4Identity('rv-pin-a'), pin: '123456');
      await expectLs(
        rig.open(p4Identity('rv-pin-b'), pin: '123456', remote: '192.0.2.2'),
        LsErrorCode.pinInvalid,
      );
    });
  });

  // ------------------------------------------------------------------ concurrency of caps
  group('pending caps hold under concurrency', () {
    test(
      'six concurrent requests from one IP: exactly 3 pending, 3 x 429',
      () async {
        rig = P4Rig();
        final ids = [for (var i = 0; i < 6; i++) p4Identity('rv-cap-$i')];
        final results = await Future.wait([
          for (final k in ids) outcome(rig.open(k)),
        ]);
        expect(results.whereType<SessionStatus>(), hasLength(3));
        expect(
          results.whereType<LsException>().where(
            (e) => e.code == LsErrorCode.rateLimited,
          ),
          hasLength(3),
        );
        expect(rig.receiver.pendingSessionIds, hasLength(3));
      },
    );

    test(
      'ten concurrent requests from ten IPs: exactly 8 pending, 2 x 429',
      () async {
        rig = P4Rig();
        final results = await Future.wait([
          for (var i = 0; i < 10; i++)
            outcome(rig.open(p4Identity('rv-cap-$i'), remote: '198.51.100.$i')),
        ]);
        expect(results.whereType<SessionStatus>(), hasLength(8));
        expect(rig.receiver.pendingSessionIds, hasLength(8));
      },
    );
  });

  // ------------------------------------------------------------------ slot release
  group('pending slots are released on every exit path', () {
    test('consent timeout (120 s) frees the per-IP slot', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(
          clock: clock,
          consent: const ConsentPolicy(maxPendingPerIp: 1),
        );
        await rig.open(tx);
        await expectLs(rig.open(tx), LsErrorCode.rateLimited);
        await t.advance(const Duration(seconds: 121));
        expect((await rig.open(tx)).status, TransferStatus.pending);
      });
    });

    test('SAS reveal timeout (30 s) frees the total slot', () async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(
          clock: clock,
          consent: const ConsentPolicy(maxPendingPerIp: 1, maxPendingTotal: 1),
        );
        await rig.open(tx, commit: SasSender(tx, rig.rxFp).commit);
        await expectLs(
          rig.open(p4Identity('rv-other'), remote: '198.51.100.1'),
          LsErrorCode.rateLimited,
        );
        await t.advance(const Duration(seconds: 31));
        expect(
          (await rig.open(
            p4Identity('rv-other'),
            remote: '198.51.100.1',
          )).status,
          TransferStatus.pending,
        );
      });
    });

    test('a commitment mismatch frees the slot', () async {
      rig = P4Rig(consent: const ConsentPolicy(maxPendingPerIp: 1));
      final sas = SasSender(tx, 'AB' * 32); // sender saw another certificate
      final st = await rig.open(tx, commit: sas.commit);
      await expectLs(
        rig.receiver.revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        ),
        LsErrorCode.authInvalid,
      );
      expect((await rig.open(tx)).status, TransferStatus.pending);
    });

    test(
      'a refused accept (sender blocked meanwhile) frees the slot',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(maxPendingPerIp: 1));
        final st = await rig.open(tx);
        await rig.trust.block(fpOf(tx));
        await expectLs(rig.receiver.accept(st.sessionId), LsErrorCode.blocked);
        await rig.trust.unblock(fpOf(tx));
        expect((await rig.open(tx)).status, TransferStatus.pending);
      },
    );
  });

  // ------------------------------------------------------------------ accept() re-classification
  group('accept() re-checks the trust store (user blocked / re-pinned while the prompt was open)', () {
    test('blocked meanwhile: 403 BLOCKED, session FAILED(REJECTED), no tokens, not a user reject', () async {
      rig = P4Rig();
      final st = await rig.open(tx);
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.receiver.accept(st.sessionId), LsErrorCode.blocked);
      final polled = await rig.receiver.getSession(st.sessionId);
      expect(polled.status, TransferStatus.failed);
      expect(polled.failureReason, FailureReason.rejected);
      expect(polled.acceptedFiles, isEmpty);
      expect(rig.receiver.pendingSessionIds, isEmpty);
      expect(rig.eventsOf<BlockSuggested>(), isEmpty);
    });

    test(
      'blocked meanwhile after a SAS flow: refused and NOT pinned',
      () async {
        rig = P4Rig();
        final sas = SasSender(tx, rig.rxFp);
        final st = await rig.open(tx, commit: sas.commit);
        await rig.receiver.revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        );
        await rig.trust.block(fpOf(tx));
        await expectLs(rig.receiver.accept(st.sessionId), LsErrorCode.blocked);
        expect(rig.trust.classify(kTxId, fpOf(tx)).trust, PeerTrust.blocked);
        expect(rig.eventsOf<ContactChanged>(), isEmpty);
      },
    );

    test('pin replaced meanwhile (explicit "accept the new key"): old session is KEY_CHANGED, not accepted', () async {
      rig = P4Rig();
      await rig.pinContact(tx, PeerTrust.known);
      final st = await rig.open(tx);
      final other = freshIdentity(kTxId);
      await rig.trust.pin(
        deviceId: kTxId,
        fingerprint: fpOf(other),
        alias: 'New key',
        trust: PeerTrust.known,
        replace: true,
      );
      await expectLs(rig.receiver.accept(st.sessionId), LsErrorCode.keyChanged);
      expect(
        (await rig.receiver.getSession(st.sessionId)).status,
        TransferStatus.failed,
      );
    });

    test('accept racing reject in one tick: exactly one wins and the final state agrees', () async {
      rig = P4Rig();
      final st = await rig.open(tx);
      final res = await Future.wait([
        outcome(rig.receiver.accept(st.sessionId)),
        rig.receiver
            .reject(st.sessionId)
            .then<Object>((_) => 'rejected', onError: (Object e) => e),
      ]);
      final okAccept = res[0] is SessionStatus;
      final okReject = res[1] == 'rejected';
      expect(
        okAccept != okReject,
        isTrue,
        reason: 'exactly one succeeds: $res',
      );
      final polled = await rig.receiver.getSession(st.sessionId);
      expect(
        polled.status,
        okAccept ? TransferStatus.inProgress : TransferStatus.failed,
      );
    });
  });

  // ------------------------------------------------------------------ timers
  group('timers are cancelled on every exit path', () {
    Future<void> withRig(
      Future<void> Function(FakeTime t) body, {
      ConsentPolicy consent = const ConsentPolicy(),
    }) async {
      final clock = ManualClock();
      await withFakeTime(clock, (t) async {
        rig = P4Rig(clock: clock, consent: consent);
        await body(t);
      });
    }

    test(
      'pending without commitment: 1 timer; Accept leaves 0',
      () => withRig((t) async {
        final st = await rig.open(tx);
        expect(t.activeTimers, 1);
        await rig.receiver.accept(st.sessionId);
        expect(t.activeTimers, 0);
      }),
    );

    test(
      'pending without commitment: Reject leaves 0',
      () => withRig((t) async {
        final st = await rig.open(tx);
        await rig.receiver.reject(st.sessionId);
        expect(t.activeTimers, 0);
      }),
    );

    test(
      'pending with commitment: 2 timers; a good reveal leaves only the consent timer; Accept leaves 0',
      () => withRig((t) async {
        final sas = SasSender(tx, rig.rxFp);
        final st = await rig.open(tx, commit: sas.commit);
        expect(t.activeTimers, 2);
        await rig.receiver.revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        );
        expect(t.activeTimers, 1, reason: 'the 30 s reveal deadline is gone');
        await rig.receiver.accept(st.sessionId);
        expect(t.activeTimers, 0);
      }),
    );

    test(
      'a commitment mismatch leaves 0 timers',
      () => withRig((t) async {
        final sas = SasSender(tx, 'CD' * 32);
        final st = await rig.open(tx, commit: sas.commit);
        await expectLs(
          rig.receiver.revealSas(
            st.sessionId,
            nonce: sas.nonceB64,
            peer: peerOf(tx),
          ),
          LsErrorCode.authInvalid,
        );
        expect(t.activeTimers, 0);
      }),
    );

    test(
      'reveal timeout and consent timeout leave 0 timers',
      () => withRig((t) async {
        await rig.open(tx, commit: SasSender(tx, rig.rxFp).commit);
        await rig.open(tx);
        await t.advance(const Duration(seconds: 31));
        expect(t.activeTimers, 1, reason: 'the plain session is still waiting');
        await t.advance(const Duration(seconds: 100));
        expect(t.activeTimers, 0);
      }),
    );

    test(
      'dispose() cancels the timers of every pending session',
      () => withRig((t) async {
        await rig.open(tx);
        await rig.open(tx, commit: SasSender(tx, rig.rxFp).commit);
        expect(t.activeTimers, 3);
        rig.receiver.dispose();
        expect(t.activeTimers, 0);
      }),
    );

    test(
      'Accept refused because the sender was blocked leaves 0 timers',
      () => withRig((t) async {
        final st = await rig.open(tx);
        await rig.trust.block(fpOf(tx));
        await expectLs(rig.receiver.accept(st.sessionId), LsErrorCode.blocked);
        expect(t.activeTimers, 0);
      }),
    );
  });

  group('[RED, low] a listener that accepts synchronously inside SessionCreated leaves no timer', () {
    test(
      'no 120 s timer is armed on a session that is already IN_PROGRESS',
      () async {
        final clock = ManualClock();
        await withFakeTime(clock, (t) async {
          final tmp = Directory.systemTemp.createTempSync('ls_p4v_');
          addTearDown(() => tmp.deleteSync(recursive: true));
          final trust = InMemoryTrustStore(clock: clock);
          late final FileReceiver rx;
          rx = p4vReceiver(
            downloadDir: tmp,
            trust: trust,
            clock: clock,
            onEvent: (e) {
              if (e is SessionCreated) unawaited(rx.accept(e.sessionId));
            },
          );
          addTearDown(rx.dispose);
          rig = P4Rig(); // only for tearDown symmetry
          final st = await rx.createAuthenticatedSession(
            p4Request(tx),
            remoteAddress: '192.0.2.10',
            peer: peerOf(tx),
          );
          await t.pump();
          expect(
            (await rx.getSession(st.sessionId)).status,
            TransferStatus.inProgress,
          );
          expect(t.activeTimers, 0);
        });
      },
    );
  });

  // ------------------------------------------------------------------ SAS
  group('SAS: reveal bound to its own session', () {
    test('the nonce of session 1 revealed on session 2 of the same sender: 401 + FAILED(PROTOCOL_ERROR) for session 2 only', () async {
      rig = P4Rig();
      final s1 = SasSender(
        tx,
        rig.rxFp,
        ns: List<int>.generate(16, (i) => i + 1),
      );
      final s2 = SasSender(
        tx,
        rig.rxFp,
        ns: List<int>.generate(16, (i) => i + 101),
      );
      final a = await rig.open(tx, commit: s1.commit);
      final b = await rig.open(tx, commit: s2.commit);
      await expectLs(
        rig.receiver.revealSas(
          b.sessionId,
          nonce: s1.nonceB64,
          peer: peerOf(tx),
        ),
        LsErrorCode.authInvalid,
      );
      expect(
        (await rig.receiver.getSession(b.sessionId)).failureReason,
        FailureReason.protocolError,
      );
      final still = await rig.receiver.getSession(a.sessionId);
      expect(still.status, TransferStatus.pending);
      await rig.receiver.revealSas(
        a.sessionId,
        nonce: s1.nonceB64,
        peer: peerOf(tx),
      );
      expect(rig.eventsOf<SasReady>(), hasLength(1));
    });

    test('reveal after the user rejected is 409 and emits no code', () async {
      rig = P4Rig();
      final sas = SasSender(tx, rig.rxFp);
      final st = await rig.open(tx, commit: sas.commit);
      await rig.receiver.reject(st.sessionId);
      await expectLs(
        rig.receiver.revealSas(
          st.sessionId,
          nonce: sas.nonceB64,
          peer: peerOf(tx),
        ),
        LsErrorCode.wrongState,
      );
      expect(rig.eventsOf<SasReady>(), isEmpty);
    });

    test('a wrong-nonce reveal makes Accept impossible afterwards (409), nothing pinned', () async {
      rig = P4Rig();
      final sas = SasSender(tx, 'EF' * 32);
      final st = await rig.open(tx, commit: sas.commit);
      await outcome(
        rig.receiver
            .revealSas(st.sessionId, nonce: sas.nonceB64, peer: peerOf(tx))
            .then((_) => throw StateError('must not succeed')),
      );
      await expectLs(rig.receiver.accept(st.sessionId), LsErrorCode.wrongState);
      expect(rig.trust.classify(kTxId, fpOf(tx)).trust, PeerTrust.unknown);
    });

    test('a code exists only after the reveal: incomingInfo shows no code before, the right one after', () async {
      rig = P4Rig();
      final sas = SasSender(tx, rig.rxFp);
      final st = await rig.open(tx, commit: sas.commit);
      expect(rig.receiver.incomingInfo(st.sessionId)!.sasCode, isNull);
      final after = await rig.receiver.revealSas(
        st.sessionId,
        nonce: sas.nonceB64,
        peer: peerOf(tx),
      );
      expect(
        rig.receiver.incomingInfo(st.sessionId)!.sasCode,
        sas.codeWith(after.sas!.nonce, rig.rxFp),
      );
    });
  });

  // ------------------------------------------------------------------ plaintext profile
  group('plaintext profile ignores everything secure', () {
    test('a hostile sasCommit in a plaintext request is ignored: 200 IN_PROGRESS, no sas member, reveal is 404', () async {
      rig = P4Rig(secure: false, autoAccept: true);
      final st = await rig.receiver.createSession(
        p4Request(tx, commit: 'A' * 43),
        remoteAddress: '192.0.2.10',
      );
      expect(st.status, TransferStatus.inProgress);
      expect(st.sas, isNull);
      await expectLs(
        rig.receiver.revealSas(st.sessionId, nonce: 'A' * 22, peer: peerOf(tx)),
        LsErrorCode.notFound,
      );
    });

    test('plaintext createSession on a SECURE receiver is refused (401), nothing created', () async {
      rig = P4Rig();
      await expectLs(
        rig.receiver.createSession(p4Request(tx), remoteAddress: '192.0.2.10'),
        LsErrorCode.authInvalid,
      );
      expect(rig.receiver.activeSessionCount, 0);
    });
  });

  // ------------------------------------------------------------------ download-folder probe
  group('download folder probe', () {
    List<String> probes(Directory d) => d
        .listSync(followLinks: false)
        .map((e) => e.path.split('/').last)
        .where((n) => n.startsWith('.lsprobe'))
        .toList();

    test(
      'no .lsprobe file is left after success, 429, 507 or a blocked sender',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(maxPendingPerIp: 1));
        await rig.open(tx);
        await expectLs(rig.open(tx), LsErrorCode.rateLimited);
        rig.free = 1;
        await expectLs(
          rig.open(tx, remote: '198.51.100.1'),
          LsErrorCode.insufficientStorage,
        );
        rig.free = null;
        await rig.trust.block(fpOf(tx));
        await expectLs(
          rig.open(tx, remote: '198.51.100.2'),
          LsErrorCode.blocked,
        );
        expect(probes(rig.dl), isEmpty);
      },
    );

    test('a symlinked download folder works and the probe leaves nothing in the target', () async {
      final base = Directory.systemTemp.createTempSync('ls_p4v_link_');
      addTearDown(() => base.deleteSync(recursive: true));
      final real = Directory('${base.path}/real')..createSync();
      final link = Link('${base.path}/link')..createSync(real.path);
      rig = P4Rig(downloadDir: Directory(link.path));
      expect((await rig.open(tx)).status, TransferStatus.pending);
      expect(probes(real), isEmpty);
      expect(
        real.listSync(),
        isEmpty,
        reason: 'nothing but the probe was created, and it is gone',
      );
    });

    test(
      'a dangling symlink as download folder is 507, not an internal error',
      () async {
        final base = Directory.systemTemp.createTempSync('ls_p4v_dangling_');
        addTearDown(() => base.deleteSync(recursive: true));
        Link('${base.path}/link').createSync('${base.path}/missing');
        rig = P4Rig(downloadDir: Directory('${base.path}/link'));
        await expectLs(rig.open(tx), LsErrorCode.insufficientStorage);
      },
    );

    test('a user file that looks like a probe is never touched', () async {
      rig = P4Rig(consent: const ConsentPolicy(maxPendingTotal: 100));
      final mine = File('${rig.dl.path}/.lsprobe-0');
      mine.writeAsStringSync('mine');
      for (var i = 0; i < 20; i++) {
        await rig.open(tx, remote: '198.51.100.$i');
      }
      expect(mine.readAsStringSync(), 'mine');
    });
  });

  // ------------------------------------------------------------------ pairing
  group('pairing: what an attacker without S sees', () {
    late ManualClock clock;
    late _Party a;
    late _Party b;
    setUp(() {
      clock = ManualClock();
      a = _Party('rv-a-id', clock);
      b = _Party('rv-b-id', clock);
      rig = P4Rig(); // tearDown symmetry
    });

    PairRequest wrongMac(PairInvite invite) {
      final scan = b.service.startScan(
        inviteSecretB64: invite.secretB64,
        inviter: a.card,
      );
      return PairRequest(
        sender: b.card,
        nonce: scan.request.nonce,
        mac: b64urlEncode(Uint8List(32)),
      );
    }

    test('a BLOCKED scanner with a wrong MAC gets 401 AUTH_INVALID, not 403 BLOCKED', () async {
      final invite = a.service.createInvite();
      await (a.trust as InMemoryTrustStore).block(b.fp);
      await expectLs(
        a.service.handlePair(wrongMac(invite), peer: b.peer),
        LsErrorCode.authInvalid,
      );
      expect(a.service.hasActiveInvite, isTrue);
    });

    test('a scanner with a changed key and a wrong MAC gets 401 and no PeerKeyChanged event', () async {
      final invite = a.service.createInvite();
      await a.trust.pin(
        deviceId: b.deviceId,
        fingerprint: 'AB' * 32,
        alias: 'old',
        trust: PeerTrust.known,
      );
      await expectLs(
        a.service.handlePair(wrongMac(invite), peer: b.peer),
        LsErrorCode.authInvalid,
      );
      expect(a.events.whereType<PeerKeyChanged>(), isEmpty);
    });

    test('a holder of S with a valid MAC whose body names ANOTHER fingerprint than its proof is 401', () async {
      final c = _Party('rv-c-id', clock);
      final invite = a.service.createInvite();
      final nonce = Uint8List.fromList(List<int>.generate(16, (i) => i + 9));
      final mac = pairRequestMac(
        secret: invite.secret,
        scannerFingerprint: c.fp,
        inviterFingerprint: a.fp,
        scannerNonce: nonce,
      );
      final lying = PairRequest(
        sender: DeviceInfo(
          deviceId: c.deviceId,
          alias: 'Bob (a lie)',
          platform: 'linux',
          fingerprint: b.fp, // the body claims B, the proof is C's
          version: kProtocolVersionSecure,
        ),
        nonce: b64urlEncode(nonce),
        mac: b64urlEncode(mac),
      );
      await expectLs(
        a.service.handlePair(lying, peer: c.peer),
        LsErrorCode.authInvalid,
      );
      expect(a.service.pendingPrompt, isNull);
      expect(a.service.hasActiveInvite, isTrue);
    });

    test('with no invite every request is 404, whatever it carries', () async {
      final invite = a.service.createInvite();
      final good = b.service
          .startScan(inviteSecretB64: invite.secretB64, inviter: a.card)
          .request;
      final fresh = _Party('rv-a2-id', clock);
      await expectLs(
        fresh.service.handlePair(good, peer: b.peer),
        LsErrorCode.notFound,
      );
    });

    test('a new invite created while a request is held does not get spent by the old request', () async {
      final first = a.service.createInvite();
      final sc = b.service.startScan(
        inviteSecretB64: first.secretB64,
        inviter: a.card,
      );
      final held = a.service.handlePair(sc.request, peer: b.peer);
      await pumpEventQueue();
      a.service.createInvite();
      a.service.decide(accept: true);
      final res = await held;
      expect(res.accepted, isTrue);
      expect(
        a.service.hasActiveInvite,
        isTrue,
        reason: 'the newer invite is untouched',
      );
    });
  });

  group('[RED, low] pairing leaves no half-done contact', () {
    test(
      'if recording the pair key fails, the answer and the stored state agree',
      () async {
        final clock = ManualClock();
        final a = _Party(
          'rv-a-id',
          clock,
          trustStore: FailingSetPairKeyTrust(clock: clock),
        );
        final b = _Party('rv-b-id', clock);
        rig = P4Rig();
        final invite = a.service.createInvite();
        final sc = b.service.startScan(
          inviteSecretB64: invite.secretB64,
          inviter: a.card,
        );
        final held = a.service.handlePair(sc.request, peer: b.peer);
        await pumpEventQueue();
        a.service.decide(accept: true);
        PairResponse? res;
        try {
          res = await held;
        } on Object {
          // an exception is acceptable only if nothing is left behind (checked below)
        }
        final contact =
            a.trust.classify(b.deviceId, b.fp).trust != PeerTrust.unknown;
        final kpair = await a.secrets.get('kpair/${b.deviceId}');
        final answeredAccepted = res?.accepted ?? false;
        expect(
          contact,
          answeredAccepted,
          reason: 'inviter pinned the scanner but told it "declined" (or the reverse)',
        );
        expect(
          kpair != null,
          answeredAccepted,
          reason: 'K_pair stored without a completed pairing (or missing after success)',
        );
      },
    );
  });

  group('pairing: a refused pin rolls the stored K_pair back', () {
    Future<PairResponse> pairWith(_Party a, _Party b) async {
      final invite = a.service.createInvite();
      final sc = b.service.startScan(
        inviteSecretB64: invite.secretB64,
        inviter: a.card,
      );
      final held = a.service.handlePair(sc.request, peer: b.peer);
      await pumpEventQueue();
      a.service.decide(accept: true);
      return held;
    }

    test('fingerprint already pinned for another device: accepted:false, no kpair, no contact', () async {
      final clock = ManualClock();
      final a = _Party('rv-a-id', clock);
      final b = _Party('rv-b-id', clock);
      rig = P4Rig();
      await a.trust.pin(
        deviceId: 'someone-else',
        fingerprint: b.fp,
        alias: 'other',
        trust: PeerTrust.known,
      );
      final res = await pairWith(a, b);
      expect(res.accepted, isFalse);
      expect(a.secrets.names, isEmpty, reason: 'K_pair must not stay behind');
      expect(a.trust.classify(b.deviceId, b.fp).trust, PeerTrust.unknown);
      expect(a.events.whereType<ContactChanged>(), isEmpty);
    });

    test('contact list full: accepted:false, no kpair', () async {
      final clock = ManualClock();
      final a = _Party(
        'rv-a-id',
        clock,
        trustStore: InMemoryTrustStore(clock: clock, maxContacts: 1),
      );
      final b = _Party('rv-b-id', clock);
      rig = P4Rig();
      await a.trust.pin(
        deviceId: 'filler',
        fingerprint: 'CD' * 32,
        alias: 'filler',
        trust: PeerTrust.known,
      );
      final res = await pairWith(a, b);
      expect(res.accepted, isFalse);
      expect(a.secrets.names, isEmpty);
    });
  });

  group('static guards (timing safety cannot be observed by a unit test)', () {
    String src(String rel) => File(rel).readAsStringSync();
    setUp(() => rig = P4Rig());

    test('pairing MACs and SAS commitments are compared with constantTimeEquals only', () {
      final pairing = src('lib/src/security/pairing_service.dart');
      expect(
        RegExp(r'constantTimeEquals\(expected, mac\)')
            .allMatches(pairing)
            .length,
        2,
        reason: 'request MAC (inviter) and ack MAC (scanner)',
      );
      expect(pairing, isNot(contains('expected == mac')));
      expect(pairing, isNot(contains('mac == expected')));
      expect(
        src('lib/src/security/sas.dart'),
        contains('constantTimeEquals(expected, given)'),
      );
      final rx = src('lib/src/transfer/file_receiver.dart');
      expect(rx, contains('_tokenEquals(token, f.token)'));
      expect(rx, isNot(contains('token == f.token')));
    });
  });
}

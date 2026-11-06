// FileReceiver as SecureTransferHandler: the LSP-1 4.3.4 secure-profile check order from
// "shape/consistency" on (Increment 3, work package P4).
//
// Order under test (LSP-1 4.3.4 "Secure-profile order [I3]"): 7 consistency (400) -> 8 sender
// match (401 AUTH_INVALID) -> 9 trust (403 BLOCKED / 403 KEY_CHANGED) -> 10 PIN -> 11 storage
// (507) -> 12 pending caps (429) -> 13 busy (409). Gate, rate limit, body size and the proof
// itself belong to the HTTP layer (P3) and are not tested here.
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p4_support.dart';

void main() {
  final tx = p4Identity(kTxId);
  late P4Rig rig;

  tearDown(() => rig.dispose());

  void noSessionCreated() {
    expect(rig.receiver.pendingSessionIds, isEmpty);
    expect(rig.receiver.activeSessionCount, 0);
    expect(rig.eventsOf<SessionCreated>(), isEmpty);
  }

  // LSP-1 4.3.4 step 8: `sender.fingerprint` empty or different from the fingerprint the proof
  // names -> 401 AUTH_INVALID. The receiver additionally compares the deviceId with the proof's
  // certificate CN (seams doc, data-flow item 2).
  group('sender match (step 8)', () {
    test(
      'positive twin: sender fields equal to the proof -> PENDING',
      () async {
        rig = P4Rig();
        final st = await rig.open(tx);
        expect(st.status, TransferStatus.pending);
        expect(rig.receiver.pendingSessionIds, [st.sessionId]);
      },
    );

    test(
      'no proof at all (peer == null) on a secure receiver is 401',
      () async {
        rig = P4Rig();
        await expectLs(
          rig.receiver.createAuthenticatedSession(
            p4Request(tx),
            remoteAddress: '192.0.2.10',
            peer: null,
          ),
          LsErrorCode.authInvalid,
        );
        noSessionCreated();
      },
    );

    test('empty sender.fingerprint is 401', () async {
      rig = P4Rig();
      final req = p4Request(tx, info: infoOf(tx, fingerprint: ''));
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          req,
          remoteAddress: '192.0.2.10',
          peer: peerOf(tx),
        ),
        LsErrorCode.authInvalid,
      );
      noSessionCreated();
    });

    test(
      'sender.fingerprint of ANOTHER device (impersonation) is 401',
      () async {
        rig = P4Rig();
        final victim = p4Identity('victim-id');
        // The attacker holds a valid proof for its own key but claims the victim's fingerprint.
        final req = p4Request(tx, info: infoOf(tx, fingerprint: fpOf(victim)));
        await expectLs(
          rig.receiver.createAuthenticatedSession(
            req,
            remoteAddress: '192.0.2.10',
            peer: peerOf(tx),
          ),
          LsErrorCode.authInvalid,
        );
        noSessionCreated();
      },
    );

    test(
      'sender.deviceId different from the proof certificate CN is 401',
      () async {
        rig = P4Rig();
        final req = p4Request(tx, info: infoOf(tx, deviceId: 'someone-else'));
        await expectLs(
          rig.receiver.createAuthenticatedSession(
            req,
            remoteAddress: '192.0.2.10',
            peer: peerOf(tx),
          ),
          LsErrorCode.authInvalid,
        );
        noSessionCreated();
      },
    );

    // SPEC-GAP: AuthenticatedPeer.deviceId is nullable ("null if the certificate carries none we
    // accept"). LSP-1 does not say what a receiver does then; the safer reading is to refuse.
    test('proof without a usable deviceId (CN) is 401', () async {
      rig = P4Rig();
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          p4Request(tx),
          remoteAddress: '192.0.2.10',
          peer: peerOf(tx, noCn: true),
        ),
        LsErrorCode.authInvalid,
      );
      noSessionCreated();
    });

    // SPEC-GAP: the unauthenticated entry point on a secure receiver. LSP-1 only says the
    // secure-profile server calls the authenticated one; a secure receiver must not be a way
    // around the proof, so the safer reading refuses.
    test('createSession (no proof) on a secure receiver is 401', () async {
      rig = P4Rig();
      await expectLs(
        rig.receiver.createSession(p4Request(tx), remoteAddress: '192.0.2.10'),
        LsErrorCode.authInvalid,
      );
      noSessionCreated();
    });
  });

  // LSP-1 0.3: the plaintext profile IS the LSP/1.0 wire. Nothing of the secure machinery may
  // change its behaviour.
  group('plaintext profile stays Inc 1/2 behaviour', () {
    test(
      'no proof, empty fingerprint, no trust store: PENDING as before',
      () async {
        rig = P4Rig(secure: false);
        const legacy = DeviceInfo(
          deviceId: 'legacy-id',
          alias: 'Legacy',
          platform: 'linux',
        );
        final req = SessionRequest(
          sender: legacy,
          files: p4Request(tx).files,
          totalSize: 5,
          chunkSize: p4ChunkSize,
        );
        final st = await rig.receiver.createAuthenticatedSession(
          req,
          remoteAddress: '192.0.2.10',
          peer: null,
        );
        expect(st.status, TransferStatus.pending);
        expect(st.sas, isNull);
      },
    );

    test('auto-accept still starts the session at once', () async {
      rig = P4Rig(secure: false, autoAccept: true);
      final st = await rig.receiver.createSession(
        p4Request(tx),
        remoteAddress: '192.0.2.10',
      );
      expect(st.status, TransferStatus.inProgress);
      expect(st.acceptedFiles.keys, ['f0']);
    });

    test('/sas and /pair do not exist (404), incomingInfo is empty', () async {
      rig = P4Rig(secure: false);
      await expectLs(
        Future.sync(
          () => rig.receiver.revealSas(
            'x',
            nonce: 'AAAAAAAAAAAAAAAAAAAAAA',
            peer: null,
          ),
        ),
        LsErrorCode.notFound,
      );
      await expectLs(
        Future.sync(
          () => rig.receiver.pair(
            PairRequest(
              sender: infoOf(tx),
              nonce: 'AAAAAAAAAAAAAAAAAAAAAA',
              mac: 'A' * 43,
            ),
            remoteAddress: '192.0.2.10',
            peer: peerOf(tx),
          ),
        ),
        LsErrorCode.notFound,
      );
      expect(rig.receiver.incomingInfo('x'), isNull);
    });
  });

  // LSP-1 4.3.4 step 9 and 4.3.1: a blocked fingerprint is refused before anything else that is
  // trust related; the refusal never creates a session or a prompt.
  group('trust (step 9)', () {
    test('blocked fingerprint -> 403 BLOCKED, no session, no prompt', () async {
      rig = P4Rig();
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
      noSessionCreated();
    });

    test('blocked beats a trusted pin of the same fingerprint', () async {
      rig = P4Rig(consent: const ConsentPolicy(autoAcceptTrusted: true));
      await rig.pinContact(tx, PeerTrust.trusted);
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
      noSessionCreated();
    });

    test(
      'blocked is refused even with the operator auto-accept flag',
      () async {
        rig = P4Rig(autoAccept: true);
        await rig.trust.block(fpOf(tx));
        await expectLs(rig.open(tx), LsErrorCode.blocked);
        noSessionCreated();
      },
    );

    test(
      'blocking one device does not refuse another (positive twin)',
      () async {
        rig = P4Rig();
        await rig.trust.block(fpOf(p4Identity('other-id')));
        expect((await rig.open(tx)).status, TransferStatus.pending);
      },
    );

    test('error messages never carry a fingerprint', () async {
      rig = P4Rig();
      await rig.trust.block(fpOf(tx));
      final e = await expectLs(rig.open(tx), LsErrorCode.blocked);
      expect(e.message, isNot(contains(shortFp(fpOf(tx)))));
      expect(e.message, isNot(contains(fpOf(tx))));
    });
  });

  // The check ORDER. Each test sets up two failures at once and asserts which one wins. A
  // positive twin (only the later failure) proves the later check is reachable in the same rig.
  group('check order: which error wins', () {
    late RecordingPinVerifier pv;

    void newRig({
      ConsentPolicy consent = const ConsentPolicy(),
      bool pinFails = false,
    }) {
      pv = RecordingPinVerifier(
        failWith: pinFails
            ? LsException(LsErrorCode.pinRequired, 'PIN required')
            : null,
      );
      rig = P4Rig(
        pinVerifier: pv,
        consent: consent,
        pin: const PinPolicy(mode: PinMode.fixed),
      );
    }

    test('consistency (400) beats sender mismatch (401)', () async {
      newRig();
      final bad = p4Request(
        tx,
        info: infoOf(tx, fingerprint: fpOf(p4Identity('victim-id'))),
        chunkSize: 1000,
      );
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          bad,
          remoteAddress: '192.0.2.10',
          peer: peerOf(tx),
        ),
        LsErrorCode.badRequest,
      );
      // twin: fix the chunk size and the mismatch is what remains
      final fixed = p4Request(
        tx,
        info: infoOf(tx, fingerprint: fpOf(p4Identity('victim-id'))),
      );
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          fixed,
          remoteAddress: '192.0.2.10',
          peer: peerOf(tx),
        ),
        LsErrorCode.authInvalid,
      );
    });

    test('AUTH_INVALID beats blocked, PIN, storage, caps and busy', () async {
      newRig(pinFails: true);
      await rig.trust.block(fpOf(tx));
      rig.free = 0;
      rig.receiver.acceptingSessions = false;
      final req = p4Request(tx, info: infoOf(tx, fingerprint: ''));
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          req,
          remoteAddress: '192.0.2.10',
          peer: peerOf(tx),
        ),
        LsErrorCode.authInvalid,
      );
      expect(pv.checks, isEmpty, reason: 'PIN must not be consulted yet');
      // twin: with a proper sender block, the next failure down the list shows up
      await expectLs(rig.open(tx), LsErrorCode.blocked);
    });

    test('AUTH_INVALID beats key-changed', () async {
      newRig();
      final newKey = freshIdentity(kTxId);
      await rig.pinContact(tx, PeerTrust.trusted);
      final req = p4Request(newKey, info: infoOf(newKey, fingerprint: ''));
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          req,
          remoteAddress: '192.0.2.10',
          peer: peerOf(newKey),
        ),
        LsErrorCode.authInvalid,
      );
      expect(rig.eventsOf<PeerKeyChanged>(), isEmpty);
    });

    test('blocked beats PIN (verifier never consulted)', () async {
      newRig(pinFails: true);
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
      expect(pv.checks, isEmpty);
      // twin: unblocked, the PIN failure is what the sender sees
      await rig.trust.unblock(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.pinRequired);
      expect(pv.checks, hasLength(1));
    });

    test('key-changed beats PIN (verifier never consulted)', () async {
      newRig(pinFails: true);
      await rig.pinContact(tx, PeerTrust.known);
      final newKey = freshIdentity(kTxId);
      await expectLs(rig.open(newKey), LsErrorCode.keyChanged);
      expect(pv.checks, isEmpty);
      // twin: the pinned key itself reaches the PIN check
      await expectLs(rig.open(tx), LsErrorCode.pinRequired);
      expect(pv.checks, hasLength(1));
    });

    test('blocked beats key-changed', () async {
      newRig();
      await rig.pinContact(tx, PeerTrust.known);
      final newKey = freshIdentity(kTxId);
      await rig.trust.block(fpOf(newKey));
      await expectLs(rig.open(newKey), LsErrorCode.blocked);
    });

    test('PIN beats storage (507)', () async {
      newRig(pinFails: true);
      rig.free = 0;
      await expectLs(rig.open(tx), LsErrorCode.pinRequired);
      // twin: once the PIN passes, the storage check is what refuses
      pv.failWith = null;
      await expectLs(rig.open(tx), LsErrorCode.insufficientStorage);
    });

    test('storage (507) beats the pending caps (429)', () async {
      newRig(consent: const ConsentPolicy(maxPendingPerIp: 1));
      expect((await rig.open(tx)).status, TransferStatus.pending);
      rig.free = 0;
      await expectLs(rig.open(tx), LsErrorCode.insufficientStorage);
      rig.free = null;
      await expectLs(rig.open(tx), LsErrorCode.rateLimited);
    });

    test('pending caps (429) beat busy (409)', () async {
      newRig(consent: const ConsentPolicy(maxPendingPerIp: 1));
      expect((await rig.open(tx)).status, TransferStatus.pending);
      rig.receiver.acceptingSessions = false;
      await expectLs(rig.open(tx), LsErrorCode.rateLimited);
      // twin: from another address (no cap hit) the receiver is busy
      await expectLs(rig.open(tx, remote: '198.51.100.7'), LsErrorCode.busy);
    });

    test('consistency (400) beats busy (409), PIN beats busy', () async {
      newRig();
      rig.receiver.acceptingSessions = false;
      final bad = p4Request(tx, chunkSize: 1000);
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          bad,
          remoteAddress: '192.0.2.10',
          peer: peerOf(tx),
        ),
        LsErrorCode.badRequest,
      );
      pv.failWith = LsException(LsErrorCode.pinInvalid, 'PIN invalid');
      await expectLs(rig.open(tx), LsErrorCode.pinInvalid);
      pv.failWith = null;
      await expectLs(rig.open(tx), LsErrorCode.busy);
    });

    test('busy last: a closed Receive window still answers 409 after every check passes', () async {
      newRig();
      rig.receiver.acceptingSessions = false;
      await expectLs(rig.open(tx), LsErrorCode.busy);
      noSessionCreated();
      rig.receiver.acceptingSessions = true;
      expect((await rig.open(tx)).status, TransferStatus.pending);
    });
  });

  // LSP-1 4.3.4 step 10 and 5.2, contracts.dart PinVerifier: the receiver asks the verifier
  // (exempt = trusted contact AND the policy exempts contacts), propagates its error unchanged
  // and consumes the PIN only for a session that was authorised.
  group('PIN integration (step 10)', () {
    test('check gets the remote address, the PIN of the request and exempt=false for a stranger', () async {
      final pv = RecordingPinVerifier();
      rig = P4Rig(
        pinVerifier: pv,
        pin: const PinPolicy(mode: PinMode.fixed),
      );
      await rig.open(tx, pin: '123456', remote: '203.0.113.9');
      expect(pv.checks, hasLength(1));
      expect(pv.checks.single.remoteAddress, '203.0.113.9');
      expect(pv.checks.single.pin, '123456');
      expect(pv.checks.single.exempt, isFalse);
    });

    test('trusted contact is exempt; known contact is not', () async {
      final pv = RecordingPinVerifier();
      rig = P4Rig(
        pinVerifier: pv,
        pin: const PinPolicy(mode: PinMode.fixed),
      );
      final knownDev = p4Identity('known-id');
      await rig.pinContact(tx, PeerTrust.trusted);
      await rig.pinContact(knownDev, PeerTrust.known);
      await rig.open(tx);
      await rig.open(knownDev);
      expect(pv.checks.map((c) => c.exempt), [true, false]);
    });

    test(
      'trusted is NOT exempt when the policy turns the exemption off',
      () async {
        final pv = RecordingPinVerifier();
        rig = P4Rig(
          pinVerifier: pv,
          pin: const PinPolicy(mode: PinMode.fixed, exemptContacts: false),
        );
        await rig.pinContact(tx, PeerTrust.trusted);
        await rig.open(tx);
        expect(pv.checks.single.exempt, isFalse);
      },
    );

    for (final code in [
      LsErrorCode.pinRequired,
      LsErrorCode.pinInvalid,
      LsErrorCode.blocked,
    ]) {
      test(
        '${code.wire} from the verifier reaches the sender unchanged; no session; no consume',
        () async {
          final pv = RecordingPinVerifier(
            failWith: LsException(code, 'fixed text'),
          );
          rig = P4Rig(
            pinVerifier: pv,
            pin: const PinPolicy(mode: PinMode.fixed),
          );
          await expectLs(rig.open(tx, pin: '000000'), code);
          noSessionCreated();
          expect(pv.consumed, 0);
        },
      );
    }

    test(
      'an authorised session that needed the PIN consumes it exactly once',
      () async {
        // SPEC-GAP: "authorised" is read as "passed every check and was created" (the safer
        // reading: consuming only at Accept would let one PIN open several prompts).
        final pv = RecordingPinVerifier();
        rig = P4Rig(
          pinVerifier: pv,
          pin: const PinPolicy(mode: PinMode.fixed),
        );
        await rig.open(tx, pin: '123456');
        expect(pv.consumed, 1);
      },
    );

    test('no consume when the PIN was not needed (exempt contact)', () async {
      final pv = RecordingPinVerifier();
      rig = P4Rig(
        pinVerifier: pv,
        pin: const PinPolicy(mode: PinMode.fixed),
      );
      await rig.pinContact(tx, PeerTrust.trusted);
      await rig.open(tx);
      expect(pv.consumed, 0);
    });

    test('no consume when the PIN is not enforced', () async {
      final pv = RecordingPinVerifier(enforced: false);
      rig = P4Rig(pinVerifier: pv);
      await rig.open(tx);
      expect(pv.consumed, 0);
    });

    test(
      'no consume when a later check refuses the session (507, 429, 409)',
      () async {
        final pv = RecordingPinVerifier();
        rig = P4Rig(
          pinVerifier: pv,
          pin: const PinPolicy(mode: PinMode.fixed),
          consent: const ConsentPolicy(maxPendingPerIp: 1),
        );
        rig.free = 0;
        await expectLs(
          rig.open(tx, pin: '123456'),
          LsErrorCode.insufficientStorage,
        );
        rig.free = null;
        expect(pv.consumed, 0);
        await rig.open(tx, pin: '123456');
        expect(pv.consumed, 1); // the one that was created
        await expectLs(rig.open(tx, pin: '123456'), LsErrorCode.rateLimited);
        rig.receiver.acceptingSessions = false;
        await expectLs(
          rig.open(tx, pin: '123456', remote: '198.51.100.7'),
          LsErrorCode.busy,
        );
        expect(pv.consumed, 1, reason: 'refused sessions must not burn a PIN');
      },
    );

    test(
      'no PinVerifier configured: requests with and without pin both pass',
      () async {
        rig = P4Rig();
        expect((await rig.open(tx)).status, TransferStatus.pending);
        expect(
          (await rig.open(tx, pin: '123456')).status,
          TransferStatus.pending,
        );
      },
    );
  });

  // LSP-1 4.3.4 step 11 (507 below totalSize + 64 MiB) is unchanged by the secure profile.
  group('storage (step 11)', () {
    test('free space below total + margin is 507, equal is fine', () async {
      rig = P4Rig();
      const margin = 64 * 1024 * 1024;
      rig.free = 5 + margin - 1;
      await expectLs(rig.open(tx), LsErrorCode.insufficientStorage);
      noSessionCreated();
      rig.free = 5 + margin;
      expect((await rig.open(tx)).status, TransferStatus.pending);
    });
  });

  // LSP-1 4.3.4 step 12: at most 3 pending prompts per IP and 8 in total (ConsentPolicy).
  group('pending caps (step 12)', () {
    test(
      'fourth pending prompt from one IP is 429, other IPs unaffected',
      () async {
        rig = P4Rig();
        for (var i = 0; i < 3; i++) {
          expect((await rig.open(tx)).status, TransferStatus.pending);
        }
        final e = await expectLs(rig.open(tx), LsErrorCode.rateLimited);
        expect(e.retryable, isTrue);
        expect(rig.receiver.pendingSessionIds, hasLength(3));
        expect(
          (await rig.open(tx, remote: '198.51.100.7')).status,
          TransferStatus.pending,
        );
      },
    );

    test(
      'ninth pending prompt overall is 429 although its IP is fresh',
      () async {
        rig = P4Rig();
        for (var ip = 1; ip <= 3; ip++) {
          final n = ip == 3 ? 2 : 3;
          for (var i = 0; i < n; i++) {
            await rig.open(tx, remote: '198.51.100.$ip');
          }
        }
        expect(rig.receiver.pendingSessionIds, hasLength(8));
        await expectLs(
          rig.open(tx, remote: '198.51.100.99'),
          LsErrorCode.rateLimited,
        );
        expect(rig.receiver.pendingSessionIds, hasLength(8));
      },
    );

    test('limits come from ConsentPolicy, not from constants', () async {
      rig = P4Rig(
        consent: const ConsentPolicy(maxPendingPerIp: 1, maxPendingTotal: 2),
      );
      await rig.open(tx);
      await expectLs(rig.open(tx), LsErrorCode.rateLimited);
      await rig.open(tx, remote: '198.51.100.1');
      await expectLs(
        rig.open(tx, remote: '198.51.100.2'),
        LsErrorCode.rateLimited,
      );
    });

    test('a rejected session frees its slot', () async {
      rig = P4Rig(consent: const ConsentPolicy(maxPendingPerIp: 1));
      final first = await rig.open(tx);
      await expectLs(rig.open(tx), LsErrorCode.rateLimited);
      await rig.receiver.reject(first.sessionId);
      expect((await rig.open(tx)).status, TransferStatus.pending);
    });

    test(
      'an accepted session is no longer pending and frees its slot',
      () async {
        rig = P4Rig(consent: const ConsentPolicy(maxPendingPerIp: 1));
        final first = await rig.open(tx);
        await rig.receiver.accept(first.sessionId);
        expect((await rig.open(tx)).status, TransferStatus.pending);
      },
    );

    test('a cancelled session frees its slot', () async {
      rig = P4Rig(consent: const ConsentPolicy(maxPendingPerIp: 1));
      final first = await rig.open(tx);
      await rig.receiver.cancel(first.sessionId);
      expect((await rig.open(tx)).status, TransferStatus.pending);
    });
  });

  // Extra: a refused request leaves no trace on disk.
  test(
    'refused requests create no file or directory in the download folder',
    () async {
      rig = P4Rig();
      await rig.trust.block(fpOf(tx));
      await expectLs(rig.open(tx), LsErrorCode.blocked);
      await expectLs(
        rig.receiver.createAuthenticatedSession(
          p4Request(tx),
          remoteAddress: '192.0.2.10',
          peer: null,
        ),
        LsErrorCode.authInvalid,
      );
      expect(rig.dl.listSync(recursive: true), isEmpty);
      expect(Directory(rig.dl.path).existsSync(), isTrue);
    },
  );

  // The handler never throws anything but LsException at its boundary, whatever the input.
  test('hostile request shapes only ever produce LsException', () async {
    rig = P4Rig();
    final shapes = <SessionRequest>[
      p4Request(tx, commit: ''),
      p4Request(tx, commit: 'short'),
      p4Request(tx, commit: 'A' * 44),
      p4Request(tx, commit: '!' * 43),
      p4Request(tx, pin: '\u0000' * 100),
    ];
    for (final s in shapes) {
      try {
        await rig.receiver.createAuthenticatedSession(
          s,
          remoteAddress: '192.0.2.10',
          peer: peerOf(tx),
        );
      } on LsException {
        // refused: fine
      }
    }
  });
}

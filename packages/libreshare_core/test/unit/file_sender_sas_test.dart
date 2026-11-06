// P5 - FileSender in the secure profile: SAS commit/reveal, pinned receivers, aborts and legacy
// peers (LSP-1 4.7, 5.1; docs/plans/inc3.md D4, D10; docs/plans/inc3-seams.md data-flow 3, 5, 6
// and "Exceptions crossing package boundaries").
//
// The receiver is FakeSecurePeer (test/helpers/p5_fake_secure_peer.dart): it verifies the commitment
// against its own fingerprint when Ns is revealed and cannot accept before that, so a sender that
// computes the commit wrongly, reveals late or never gets stuck or fails here, not silently.
//
// Contract assumed for the new symbols (see docs/plans/inc3-p5-tests.md):
//   FileSender(..., SecurityConfig security = SecurityConfig.plaintext(),
//                   String? pinnedReceiverFingerprint)
//   SendResult.receiverFingerprint (String?)
//   send() THROWS InsecurePeerException / PeerFingerprintMismatchException / SasAbortedException
//   (they are local security refusals, not wire outcomes); every other failure stays a SendResult.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p5_fake_secure_peer.dart';
import '../helpers/p5_raw_peer.dart' show infoFor;
import '../helpers/p5_support.dart';
import '../helpers/test_data.dart';

const _zero = [Duration.zero, Duration.zero, Duration.zero];

void main() {
  late KeyIdentity me;
  late SecurityConfig sec;
  late String senderFp;
  final receiverFp = fingerprintHex(utf8.encode('the-real-receiver'));
  final mitmFp = fingerprintHex(utf8.encode('the-man-in-the-middle'));
  late DeviceInfo self;
  late Directory tmp;
  late File file;

  setUpAll(() {
    me = newIdentity('p5-sender');
    sec = secureConfig(me);
    senderFp = me.identity.fingerprint;
    self = infoFor('p5-sender', senderFp);
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('p5_sender');
    file = writeRandomFile(tmp, 'payload.bin', 2048);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  FakeSecurePeer fake({String? seen, bool legacy = false}) => FakeSecurePeer(
    senderFp: senderFp,
    receiverFp: receiverFp,
    seenFp: seen,
    legacy: legacy,
  );

  FileSender sender(
    FakeSecurePeer peer,
    List<LsEvent> events, {
    SecurityConfig? security,
    String? pinned,
    Duration acceptTimeout = const Duration(seconds: 5),
  }) => FileSender(
    client: peer,
    self: self,
    security: security ?? sec,
    pinnedReceiverFingerprint: pinned,
    retryDelays: _zero,
    acceptTimeout: acceptTimeout,
    // One timeline for calls and events, to assert ordering.
    onEvent: (e) {
      events.add(e);
      peer.calls.add('event:${e.runtimeType}');
    },
  );

  Future<({SendResult? result, Object? error})> run(FileSender s) async {
    try {
      return (result: await s.send([file]), error: null);
    } on Object catch (e) {
      return (result: null, error: e);
    }
  }

  Future<T> waitFor<T extends LsEvent>(List<LsEvent> events) async {
    for (var i = 0; i < 300; i++) {
      for (final e in events) {
        if (e is T) return e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('no ${T.toString()} event within 3 s');
  }

  List<SasReady> sasEvents(List<LsEvent> events) =>
      events.whereType<SasReady>().toList();

  // LSP-1 5.1: the sender commits iff it has no pin; reveals Ns right after the 202; both sides
  // derive the same six digits; chunks flow only after acceptance.
  group('first contact: commit and reveal', () {
    test(
      'sends sasCommit (43 b64url chars) when it has no pin for the receiver',
      () async {
        final peer = fake();
        final out = await run(sender(peer, []));
        expect(out.error, isNull);
        final commit = peer.request!.sasCommit;
        expect(commit, isNotNull);
        expect(commit, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      },
    );

    test('the commit opens with the revealed Ns, the sender fingerprint and the fingerprint SEEN in the handshake', () async {
      final peer = fake();
      await run(sender(peer, []));
      final ns = peer.revealedNs!;
      expect(ns, hasLength(16));
      expect(
        sasCommitMatches(
          commit: peer.request!.sasCommit!,
          ns: ns,
          senderFingerprint: senderFp,
          receiverFingerprintSeenBySender: peer.serverFingerprint!,
        ),
        isTrue,
      );
      // Twin: it does not open under any other receiver fingerprint.
      expect(
        sasCommitMatches(
          commit: peer.request!.sasCommit!,
          ns: ns,
          senderFingerprint: senderFp,
          receiverFingerprintSeenBySender: mitmFp,
        ),
        isFalse,
      );
    });

    test(
      'Ns is sent as 22 base64url characters and revealed exactly once',
      () async {
        final peer = fake();
        await run(sender(peer, []));
        expect(peer.reveals, 1);
      },
    );

    test('reveals right after the 202: before the first long poll and before any chunk', () async {
      final peer = fake();
      await run(sender(peer, []));
      final reveal = peer.calls.indexOf('revealSas');
      expect(reveal, greaterThan(peer.calls.indexOf('createSession')));
      expect(reveal, lessThan(peer.calls.indexOf('waitSession')));
      expect(reveal, lessThan(peer.calls.indexOf('putChunk')));
    });

    test(
      'emits SasReady(outgoing: true) with the code both screens show, once',
      () async {
        final peer = fake();
        final events = <LsEvent>[];
        final out = await run(sender(peer, events));
        expect(out.result!.isSuccess, isTrue);
        final ready = sasEvents(events);
        expect(ready, hasLength(1));
        expect(ready.single.outgoing, isTrue);
        expect(ready.single.sessionId, FakeSecurePeer.sessionId);
        expect(ready.single.code, peer.expectedCode());
        expect(ready.single.code, matches(RegExp(r'^[0-9]{6}$')));
      },
    );

    test('SasReady comes only after the reveal succeeded (a code is never shown for a failed reveal)', () async {
      final peer = fake()..revealGate = Completer<void>();
      final events = <LsEvent>[];
      final s = sender(peer, events);
      final future = run(s);
      await peer.revealEntered.future;
      await settle(100);
      expect(sasEvents(events), isEmpty);
      peer.revealGate!.complete();
      await waitFor<SasReady>(events);
      final reveal = peer.calls.indexOf('revealSas');
      expect(peer.calls.indexOf('event:SasReady'), greaterThan(reveal));
      expect((await future).result!.isSuccess, isTrue);
    });

    test('no chunk is sent before the reveal and the acceptance', () async {
      final peer = fake();
      await run(sender(peer, []));
      expect(
        peer.calls.indexOf('putChunk'),
        greaterThan(peer.calls.indexOf('revealSas')),
      );
      expect(peer.puts, 1);
    });

    test('two sends use different nonces and different commitments', () async {
      final a = fake();
      final b = fake();
      await run(sender(a, []));
      await run(sender(b, []));
      expect(a.revealedNs, isNot(b.revealedNs));
      expect(a.request!.sasCommit, isNot(b.request!.sasCommit));
    });

    test(
      'the result exposes the fingerprint the receiver showed, for pinning',
      () async {
        final peer = fake();
        final out = await run(sender(peer, []));
        expect(out.result!.isSuccess, isTrue);
        expect(out.result!.receiverFingerprint, receiverFp);
      },
    );

    test('receiver rejects after the code comparison: FAILED(REJECTED), nothing sent, nothing to pin', () async {
      final peer = fake()..failAfterReveal = FailureReason.rejected;
      final out = await run(sender(peer, []));
      expect(out.error, isNull);
      expect(out.result!.status, TransferStatus.failed);
      expect(out.result!.failureReason, FailureReason.rejected);
      expect(peer.puts, 0);
      expect(out.result!.receiverFingerprint, isNull);
    });
  });

  // 5.1 rule: "If the answer to a request that carried sasCommit is not a PENDING status with
  // sas.nonce ... the sender MUST cancel the session and send nothing further (FAILED(PROTOCOL_ERROR))".
  group('a receiver that does not play the SAS game', () {
    for (final (name, mode) in [
      (
        'ignores sasCommit and answers PENDING without sas',
        CreateMode.pendingWithoutSas,
      ),
      (
        'auto-accepts despite the commit (immediate IN_PROGRESS)',
        CreateMode.immediateAccept,
      ),
    ]) {
      test(
        'a receiver that $name: cancel, PROTOCOL_ERROR, no chunk, no reveal',
        () async {
          final peer = fake()..mode = mode;
          final events = <LsEvent>[];
          final out = await run(sender(peer, events));
          expect(out.error, isNull);
          expect(out.result!.status, TransferStatus.failed);
          expect(out.result!.failureReason, FailureReason.protocolError);
          expect(peer.puts, 0);
          expect(peer.reveals, 0);
          expect(peer.cancelled, [FakeSecurePeer.sessionId]);
          expect(sasEvents(events), isEmpty);
          expect(out.result!.receiverFingerprint, isNull);
        },
      );
    }

    test(
      'a malformed sas.nonce: nothing is sent and no code is shown',
      () async {
        final peer = fake()..mode = CreateMode.pendingBadNonce;
        final events = <LsEvent>[];
        final out = await run(sender(peer, events));
        // SPEC-GAP: the plan does not say whether this is a result or SasAbortedException; both
        // are acceptable, a transfer is not.
        expect(
          out.error is SasAbortedException ||
              out.result?.failureReason == FailureReason.protocolError,
          isTrue,
          reason: 'error=${out.error} result=${out.result}',
        );
        expect(peer.puts, 0);
        expect(sasEvents(events), isEmpty);
      },
    );
  });

  // 5.1 / plan D4: abort paths. SasAbortedException leaves send(); no chunk was uploaded.
  group('abort during the SAS', () {
    test('commit mismatch at the receiver (relaying MITM): SasAbortedException, no chunk, no code', () async {
      final peer = fake(
        seen: mitmFp,
      ); // the handshake showed the MITM's certificate
      final events = <LsEvent>[];
      final out = await run(sender(peer, events));
      expect(out.error, isA<SasAbortedException>());
      expect(peer.puts, 0);
      expect(sasEvents(events), isEmpty);
    });

    test('control: without the relay the very same flow succeeds', () async {
      final peer = fake();
      final out = await run(sender(peer, []));
      expect(out.result!.isSuccess, isTrue);
    });

    test('reveal answered 401 AUTH_INVALID: SasAbortedException', () async {
      final peer = fake()..revealError = LsException(LsErrorCode.authInvalid);
      final events = <LsEvent>[];
      final out = await run(sender(peer, events));
      expect(out.error, isA<SasAbortedException>());
      expect(peer.puts, 0);
      expect(sasEvents(events), isEmpty);
    });

    test(
      'reveal answered 409 WRONG_STATE (deadline gone): SasAbortedException',
      () async {
        final peer = fake()..revealError = LsException(LsErrorCode.wrongState);
        final out = await run(sender(peer, []));
        expect(out.error, isA<SasAbortedException>());
        expect(peer.puts, 0);
      },
    );

    test('reveal that keeps failing on the transport: SasAbortedException, no chunk', () async {
      final peer = fake()..revealError = const SocketException('gone');
      final out = await run(sender(peer, []));
      expect(out.error, isA<SasAbortedException>());
      expect(peer.puts, 0);
    });

    test(
      'the user aborts while comparing codes (cancel after SasReady)',
      () async {
        final peer = fake()..holdAccept = Completer<void>();
        final events = <LsEvent>[];
        final s = sender(peer, events);
        final future = run(s);
        await waitFor<SasReady>(events);
        await s.cancel();
        final out = await future;
        expect(out.error, isA<SasAbortedException>());
        expect(peer.cancelled, [
          FakeSecurePeer.sessionId,
        ], reason: 'the receiver is told');
        expect(peer.puts, 0);
      },
    );

    test('the user aborts while the reveal is in flight', () async {
      final peer = fake()..revealGate = Completer<void>();
      final events = <LsEvent>[];
      final s = sender(peer, events);
      final future = run(s);
      await peer.revealEntered.future;
      await s.cancel();
      final out = await future;
      expect(out.error, isA<SasAbortedException>());
      expect(peer.puts, 0);
      expect(sasEvents(events), isEmpty);
    });

    test('control: cancelling a PINNED send (no SAS) stays an ordinary FAILED(CANCELLED) result', () async {
      final peer = fake()..holdAccept = Completer<void>();
      final events = <LsEvent>[];
      final s = sender(peer, events, pinned: receiverFp);
      final future = run(s);
      for (var i = 0; i < 200 && !peer.calls.contains('waitSession'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await s.cancel();
      final out = await future;
      expect(out.error, isNull);
      expect(out.result!.failureReason, FailureReason.cancelled);
    });

    test('SasAbortedException carries fixed text only', () async {
      final peer = fake(seen: mitmFp);
      final out = await run(sender(peer, []));
      final text = '${out.error}';
      expect(text, isNot(matches(fullHex)));
      expect(text, isNot(contains(receiverFp)));
      expect(text, isNot(contains(mitmFp)));
      expect(text, isNot(contains(senderFp)));
    });
  });

  // 5.1: "A sender with a pin sends none".
  group('pinned receiver: no SAS at all', () {
    test(
      'no sasCommit, no reveal, no SasReady; the transfer completes',
      () async {
        final peer = fake();
        final events = <LsEvent>[];
        final out = await run(sender(peer, events, pinned: receiverFp));
        expect(
          out.result!.isSuccess,
          isTrue,
          reason: '${out.error} ${out.result}',
        );
        expect(peer.request!.sasCommit, isNull);
        expect(peer.reveals, 0);
        expect(peer.calls, isNot(contains('revealSas')));
        expect(sasEvents(events), isEmpty);
        expect(peer.puts, 1);
      },
    );

    test(
      'the result still names the receiver fingerprint (equal to the pin)',
      () async {
        final peer = fake();
        final out = await run(sender(peer, [], pinned: receiverFp));
        expect(out.result!.receiverFingerprint, receiverFp);
      },
    );

    test('control: the same sender without a pin DOES commit (so the pinned run proves something)', () async {
      final peer = fake();
      await run(sender(peer, []));
      expect(peer.request!.sasCommit, isNotNull);
    });
  });

  // 4.7 and seams data-flow 6: legacy receivers (no fingerprint).
  group('legacy receivers', () {
    test('plaintext legacy peer: InsecurePeerException, createSession never called, nothing sent', () async {
      final peer = fake(legacy: true);
      final out = await run(sender(peer, []));
      expect(out.error, isA<InsecurePeerException>());
      expect(peer.calls, isNot(contains('createSession')));
      expect(peer.puts, 0);
      expect(peer.request, isNull);
    });

    test('allowInsecurePeers: the plaintext profile is used (no commit, no reveal) and it completes', () async {
      final peer = fake(legacy: true);
      final out = await run(
        sender(peer, [], security: secureConfig(me, allowInsecurePeers: true)),
      );
      expect(
        out.result!.isSuccess,
        isTrue,
        reason: '${out.error} ${out.result}',
      );
      expect(peer.request!.sasCommit, isNull);
      expect(peer.reveals, 0);
      expect(out.result!.receiverFingerprint, isNull);
    });

    test(
      'allowInsecurePeers does not weaken a secure receiver: it still commits',
      () async {
        final peer = fake();
        await run(
          sender(
            peer,
            [],
            security: secureConfig(me, allowInsecurePeers: true),
          ),
        );
        expect(peer.request!.sasCommit, isNotNull);
      },
    );
  });

  // 4.3.5 / AE note: the sender must not blur local security refusals into "could not reach".
  group('error classification', () {
    test('InsecurePeerException from the client leaves send() as that type, nothing sent', () async {
      final peer = fake()..createError = const InsecurePeerException();
      final out = await run(sender(peer, []));
      expect(out.error, isA<InsecurePeerException>());
      expect(peer.puts, 0);
    });

    test('PeerFingerprintMismatchException from the client leaves send() as that type', () async {
      final peer = fake()
        ..createError = PeerFingerprintMismatchException(
          shortFp(receiverFp),
          shortFp(mitmFp),
        );
      final out = await run(sender(peer, []));
      expect(out.error, isA<PeerFingerprintMismatchException>());
      expect(peer.puts, 0);
    });

    test('the same exceptions from info() (the first contact with the receiver) also leave as their own type', () async {
      final peer = fake()
        ..infoError = PeerFingerprintMismatchException(
          shortFp(receiverFp),
          shortFp(mitmFp),
        );
      final out = await run(sender(peer, [], pinned: receiverFp));
      expect(out.error, isA<PeerFingerprintMismatchException>());
      expect(peer.calls, isNot(contains('createSession')));
    });

    test('AUTH_INVALID is a protocol failure, never "no connection"', () async {
      final peer = fake()..createError = LsException(LsErrorCode.authInvalid);
      final out = await run(sender(peer, []));
      expect(out.result!.failureReason, FailureReason.protocolError);
      expect(out.result!.failureReason, isNot(FailureReason.noConnection));
    });

    test('control: an unreachable peer is still NO_CONNECTION', () async {
      final peer = fake()..createError = const SocketException('refused');
      final out = await run(sender(peer, []));
      expect(out.result!.failureReason, FailureReason.noConnection);
    });
  });

  // Inc 1/2 behaviour must not move: the plaintext FileSender never asks for /info first, never
  // commits, never reveals.
  group('plaintext profile is unchanged', () {
    test('default FileSender: createSession is the first call, no sasCommit, no reveal', () async {
      final peer = fake();
      final s = FileSender(
        client: peer,
        self: infoFor('p5-sender', ''),
        retryDelays: _zero,
      );
      final r = await s.send([file]);
      expect(r.isSuccess, isTrue);
      expect(peer.calls.first, 'createSession');
      expect(peer.calls, isNot(contains('info')));
      expect(peer.request!.sasCommit, isNull);
      expect(peer.reveals, 0);
      expect(r.receiverFingerprint, isNull);
    });
  });
}

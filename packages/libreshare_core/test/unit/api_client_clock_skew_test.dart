// P5 - clock skew correction for X-LS-Auth (LSP-1 4.3.6 "Clock", docs/plans/inc3.md D9):
// "The server sets Date on every response, including a 401. A client whose first request is refused
// with 401 AUTH_INVALID reads Date, computes skew = serverDate - localNow and retries ONCE with
// ts = localNow + skew and a fresh nonce; a second refusal is final. The server never widens its
// window."
//
// The wall clock of the TEST is real; the peer is the one with a fake clock (clockOffset), which
// is what makes the situation deterministic: its window check uses serverNow and its Date header
// says serverNow.
import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p5_raw_peer.dart';
import '../helpers/p5_support.dart';

void main() {
  late KeyIdentity me;
  late KeyIdentity srv;
  late SecurityConfig sec;
  late DeviceInfo self;
  final peers = <RawPeer>[];
  final clients = <ApiClient>[];

  setUpAll(() {
    me = newIdentity('p5-skew-me');
    srv = newIdentity('p5-skew-srv');
    sec = secureConfig(me);
    self = infoFor('p5-skew-me', me.identity.fingerprint);
  });

  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    for (final p in peers) {
      await p.close();
    }
    peers.clear();
  });

  /// A peer whose clock is [offset] away from the test's, that enforces the +-120 s window with
  /// P1's verifier and answers 401 AUTH_INVALID (with Date) otherwise.
  Future<({RawTlsPeer peer, ProofChecker checker})> skewedPeer(
    Duration offset, {
    bool sendDate = true,
    RawResponse? alwaysRefuse,
  }) async {
    final checker = ProofChecker(
      srv.identity.fingerprint,
      now: () => DateTime.now().toUtc().add(offset),
    );
    final peer = await RawTlsPeer.start(
      srv,
      clockOffset: offset,
      sendDate: sendDate,
      handler: (r) {
        if (alwaysRefuse != null) return alwaysRefuse;
        final res = checker.check(r);
        if (res is AuthFailed) return RawResponse.error(401, 'AUTH_INVALID');
        if (r.path.endsWith('/sas')) {
          return RawResponse.json(200, statusJson('PENDING', nonce: 'A' * 22));
        }
        if (r.path == '/api/v1/pair') {
          return RawResponse.json(
            200,
            PairResponse(accepted: false, responder: self).toJson(),
          );
        }
        if (r.path == '/api/v1/register') {
          return RawResponse.json(200, self.toJson());
        }
        return RawResponse.json(202, statusJson('PENDING', nonce: 'A' * 22));
      },
    );
    peers.add(peer);
    return (peer: peer, checker: checker);
  }

  ApiClient client(RawTlsPeer p) {
    final c = secureClient(p.port, sec, pin: srv.identity.fingerprint);
    clients.add(c);
    return c;
  }

  Future<Object?> outcome(Future<Object?> f) async {
    try {
      return await f;
    } on Object catch (e) {
      return e;
    }
  }

  int serverNowMs(Duration offset) =>
      DateTime.now().toUtc().add(offset).millisecondsSinceEpoch;

  for (final offset in [
    const Duration(hours: 1),
    const Duration(hours: -1),
    const Duration(days: 2),
  ]) {
    test(
      'a client ${offset.inHours} h away from the server retries once with the corrected clock',
      () async {
        final s = await skewedPeer(offset);
        final st = await client(s.peer).createSession(sampleRequest(self));
        expect(st.status, TransferStatus.pending);
        expect(
          s.peer.requests,
          hasLength(2),
          reason: 'refused once, then accepted',
        );

        final first = proofParts(s.peer.requests[0].header(kAuthHeader)!);
        final second = proofParts(s.peer.requests[1].header(kAuthHeader)!);
        // The first proof used the local clock: far from the server's.
        expect(
          (first.ts - serverNowMs(offset)).abs(),
          greaterThan(const Duration(minutes: 30).inMilliseconds),
        );
        // The retry uses ts = localNow + skew: within a few seconds of the server's clock
        // (Date has whole-second resolution).
        expect(
          (second.ts - serverNowMs(offset)).abs(),
          lessThan(const Duration(seconds: 10).inMilliseconds),
        );
        // A fresh nonce, never the same proof again.
        expect(second.nonce, isNot(first.nonce));
        // Same request: same target and body.
        expect(s.peer.requests[1].target, s.peer.requests[0].target);
        expect(s.peer.requests[1].body, s.peer.requests[0].body);
      },
    );
  }

  test('control: a clock within the window is accepted at the first attempt (no retry)', () async {
    final s = await skewedPeer(const Duration(seconds: 60));
    await client(s.peer).createSession(sampleRequest(self));
    expect(s.peer.requests, hasLength(1));
  });

  test('control: the harness really refuses a stale proof (no Date header, so no correction)', () async {
    final s = await skewedPeer(const Duration(hours: 1), sendDate: false);
    final err = await outcome(
      client(s.peer).createSession(sampleRequest(self)),
    );
    expect(
      err,
      isA<LsException>().having((e) => e.code, 'code', LsErrorCode.authInvalid),
    );
    expect(s.peer.requests.length, lessThanOrEqualTo(2));
  });

  test(
    'a second refusal is final: exactly two attempts, then AUTH_INVALID',
    () async {
      final s = await skewedPeer(
        Duration.zero,
        alwaysRefuse: RawResponse.error(401, 'AUTH_INVALID'),
      );
      final err = await outcome(
        client(s.peer).createSession(sampleRequest(self)),
      );
      expect(
        err,
        isA<LsException>().having(
          (e) => e.code,
          'code',
          LsErrorCode.authInvalid,
        ),
      );
      await settle();
      expect(s.peer.requests, hasLength(2));
      expect(
        proofParts(s.peer.requests[1].header(kAuthHeader)!).nonce,
        isNot(proofParts(s.peer.requests[0].header(kAuthHeader)!).nonce),
      );
    },
  );

  test('only AUTH_INVALID triggers a retry: other 401/403 answers are returned at once', () async {
    for (final (status, code) in [
      (401, 'PIN_REQUIRED'),
      (401, 'PIN_INVALID'),
      (403, 'BLOCKED'),
      (403, 'KEY_CHANGED'),
      (404, 'NOT_FOUND'),
    ]) {
      final s = await skewedPeer(
        Duration.zero,
        alwaysRefuse: RawResponse.error(status, code),
      );
      final err = await outcome(
        client(s.peer).createSession(sampleRequest(self)),
      );
      expect(err, isA<LsException>(), reason: code);
      await settle(30);
      expect(s.peer.requests, hasLength(1), reason: code);
    }
  });

  test(
    'without a usable Date header there is at most one retry and no hang',
    () async {
      final s = await skewedPeer(const Duration(hours: 3), sendDate: false);
      final stopwatch = Stopwatch()..start();
      final err = await outcome(
        client(s.peer).createSession(sampleRequest(self)),
      );
      expect(err, isA<LsException>());
      expect(s.peer.requests.length, lessThanOrEqualTo(2));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    },
  );

  test('an unparsable Date header does not crash the client', () async {
    final s = await skewedPeer(
      Duration.zero,
      alwaysRefuse: RawResponse.error(
        401,
        'AUTH_INVALID',
        headers: {'date': 'not a date'},
      ),
    );
    final err = await outcome(
      client(s.peer).createSession(sampleRequest(self)),
    );
    expect(
      err,
      isA<LsException>().having((e) => e.code, 'code', LsErrorCode.authInvalid),
    );
    expect(s.peer.requests.length, lessThanOrEqualTo(2));
  });

  for (final route in ['register', 'revealSas', 'pair']) {
    test('the correction also applies to $route', () async {
      final s = await skewedPeer(const Duration(hours: -2));
      final c = client(s.peer);
      switch (route) {
        case 'register':
          await c.register(self);
        case 'revealSas':
          await c.revealSas('sess-1', nonce: 'A' * 22);
        default:
          await c.pair(
            PairRequest(sender: self, nonce: 'A' * 22, mac: 'M' * 43),
          );
      }
      expect(s.peer.requests, hasLength(2));
      expect(
        (proofParts(s.peer.requests[1].header(kAuthHeader)!).ts -
                serverNowMs(const Duration(hours: -2)))
            .abs(),
        lessThan(10000),
      );
    });
  }

  test('the retried proof is bound to the same server certificate', () async {
    final s = await skewedPeer(const Duration(hours: 1));
    await client(s.peer).createSession(sampleRequest(self));
    // The second attempt was accepted by the checker (it verifies with the peer's own fingerprint).
    expect(s.checker.nonces.length, 1);
  });
}

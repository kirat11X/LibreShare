// Request-rate limiting of the secure ApiServer. Spec: LSP-1 4.3.4 (secure order: gate -> rate
// limit -> body size -> auth ...), 4.3.5 (RATE_LIMITED 429 + Retry-After), 4.3.1 (Retry-After row),
// 4.3.4 /pair ("the bucket of POST /sessions"). The PIN-failure windows are in pin_test.dart.
//
// The limiter's clock is injected (RateLimiter(clock:)), so refill is exercised without sleeping.
import 'dart:convert';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart';

void main() {
  late P3Rig rig;
  late P3Clock clock;

  setUp(() async {
    clock = P3Clock();
    rig = await P3Rig.start(
      enableRateLimit: true,
      rateLimiter: RateLimiter(clock: clock.now),
    );
  });
  tearDown(() => rig.stop());

  final alice = p3Alice;

  List<int> pairBody() => utf8.encode(
    jsonEncode(
      PairRequest(
        sender: alice.info(),
        nonce: p3Nonce22,
        mac: 'A' * 43,
      ).toJson(),
    ),
  );

  Future<P3Res> pair({String? from}) => rig.request(
    'POST',
    '/pair',
    body: pairBody(),
    headers: {'content-type': 'application/json'},
    signAs: alice,
    from: from,
  );

  void expectRateLimited(P3Res r) {
    expect(r.status, 429, reason: r.text);
    expect(r.header('content-type'), contains('application/json'));
    expect(r.error['code'], 'RATE_LIMITED');
    expect(r.error['retryable'], isTrue);
    final retry = int.tryParse(r.header('retry-after') ?? '');
    expect(retry, isNotNull, reason: 'Retry-After must be whole seconds');
    expect(retry, inInclusiveRange(1, 60));
    expect(r.date, isNotNull);
  }

  group('10 POST /sessions per minute per IP (4.3.4 step "rate limit")', () {
    test('the 11th request in a minute is 429 with Retry-After; the handler saw exactly 10', () async {
      for (var i = 0; i < 10; i++) {
        expect(
          (await rig.postSession(alice)).status,
          202,
          reason: 'request ${i + 1}',
        );
      }
      expectRateLimited(await rig.postSession(alice));
      expect(rig.handler.count('createAuthenticatedSession'), 10);
    });

    test('the bucket refills continuously: 6 s later one more request passes, a second does not', () async {
      for (var i = 0; i < 10; i++) {
        await rig.postSession(alice);
      }
      expectRateLimited(await rig.postSession(alice));
      clock.advance(const Duration(seconds: 6, milliseconds: 100));
      expect((await rig.postSession(alice)).status, 202);
      expectRateLimited(await rig.postSession(alice));
      clock.advance(const Duration(minutes: 1));
      for (var i = 0; i < 10; i++) {
        expect(
          (await rig.postSession(alice)).status,
          202,
          reason: 'full refill, request $i',
        );
      }
    });

    test('the limit is per source IP: another IP has its own bucket', () async {
      for (var i = 0; i < 10; i++) {
        await rig.postSession(alice);
      }
      expectRateLimited(await rig.postSession(alice));
      final other = await rig.postSession(alice, from: '127.0.0.2');
      expect(other.status, 202, reason: other.text);
      expect(
        rig.handler.last('createAuthenticatedSession').remoteAddress,
        '127.0.0.2',
      );
    });

    test('only POST /sessions is limited: GET /info, status polls and chunk PUTs are not', () async {
      for (var i = 0; i < 10; i++) {
        await rig.postSession(alice);
      }
      expectRateLimited(await rig.postSession(alice));
      for (var i = 0; i < 25; i++) {
        expect((await rig.request('GET', '/info')).status, 200);
      }
      expect((await rig.request('GET', '/sessions/s1')).status, 200);
      expect(
        (await rig.request(
          'PUT',
          '/sessions/s1/files/f1/chunks/0',
          body: [1],
          headers: {'authorization': 'Bearer t', kChunkHashHeader: 'a' * 64},
        )).status,
        200,
      );
    });

    test('a 429 does not reach auth or the handler even for a bad proof (limit comes first)', () async {
      for (var i = 0; i < 10; i++) {
        await rig.postSession(alice);
      }
      final r = await rig.request(
        'POST',
        '/sessions',
        body: p3SessionBody(alice),
        headers: {'content-type': 'application/json'},
        authHeader: 'junk',
      );
      expectRateLimited(r);
    });
  });

  group('the limit runs before auth and before the body is read (4.3.4)', () {
    test('requests without a proof use up tokens: 10 x 401, then 429, never a free 401', () async {
      for (var i = 0; i < 10; i++) {
        final r = await rig.request(
          'POST',
          '/sessions',
          body: p3SessionBody(alice),
          headers: {'content-type': 'application/json'},
        );
        expect(r.status, 401, reason: 'request ${i + 1}');
      }
      final r = await rig.request(
        'POST',
        '/sessions',
        body: p3SessionBody(alice),
        headers: {'content-type': 'application/json'},
      );
      expectRateLimited(r);
      expect(rig.handler.calls, isEmpty);
    });

    test('a limited request with an unparsable body is 429, not 400 (body not read first)', () async {
      for (var i = 0; i < 10; i++) {
        await rig.postSession(alice);
      }
      final r = await rig.request(
        'POST',
        '/sessions',
        body: utf8.encode('{not json'),
        headers: {'content-type': 'application/json'},
        signAs: alice,
      );
      expectRateLimited(r);
      // Twin: with a token available the same body is a 400 (so the 429 above was the limiter).
      clock.advance(const Duration(minutes: 1));
      final ok = await rig.request(
        'POST',
        '/sessions',
        body: utf8.encode('{not json'),
        headers: {'content-type': 'application/json'},
        signAs: alice,
      );
      expect(ok.status, 400, reason: ok.text);
    });
  });

  group('POST /pair shares the bucket of POST /sessions (4.3.4 /pair)', () {
    test(
      '6 sessions + 4 pairs use the 10 tokens; the next of either kind is 429',
      () async {
        for (var i = 0; i < 6; i++) {
          expect((await rig.postSession(alice)).status, 202);
        }
        for (var i = 0; i < 4; i++) {
          expect((await pair()).status, 200, reason: 'pair ${i + 1}');
        }
        expectRateLimited(await rig.postSession(alice));
        expectRateLimited(await pair());
        expect(rig.handler.count('pair'), 4);
      },
    );

    test('10 pairs exhaust the bucket for sessions', () async {
      for (var i = 0; i < 10; i++) {
        expect((await pair()).status, 200, reason: 'pair ${i + 1}');
      }
      expectRateLimited(await rig.postSession(alice));
    });
  });

  group('plaintext profile keeps its Inc 1 behaviour', () {
    test(
      'plaintext server: 10 pass, 11th is 429 (twin of the secure test)',
      () async {
        await rig.stop();
        rig = await P3Rig.start(
          secure: false,
          enableRateLimit: true,
          rateLimiter: RateLimiter(clock: clock.now),
        );
        for (var i = 0; i < 10; i++) {
          final r = await rig.request(
            'POST',
            '/sessions',
            body: p3SessionBody(alice),
          );
          expect(r.status, 202, reason: 'request ${i + 1}: ${r.text}');
        }
        expectRateLimited(
          await rig.request('POST', '/sessions', body: p3SessionBody(alice)),
        );
      },
    );
  });
}

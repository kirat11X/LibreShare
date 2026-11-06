// Request-body caps of the secure ApiServer. Spec: LSP-1 0.3 table (POST /sessions body limit),
// 4.1 (kMaxJsonBytes 256 KiB, kMaxSessionJsonBytes 4 MiB), 4.3.4 step 2 and secure-order step 3,
// 4.3.5 (TOO_LARGE 413, RATE_LIMITED 429), docs/plans/inc3.md D11.
//
//  * secure profile: POST /sessions up to 4 MiB; every other route 256 KiB;
//  * a body above 256 KiB needs Content-Length (without one it is cut off at 256 KiB);
//  * at most 2 oversize (> 256 KiB) bodies are read at once; a third gets 429 RATE_LIMITED;
//  * the plaintext profile keeps 256 KiB everywhere and has no concurrency cap.
import 'dart:async';
import 'dart:convert';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart';

const int _k256 = 256 * 1024;
const int _k4M = 4 * 1024 * 1024;
const _json = {'content-type': 'application/json'};

void main() {
  late P3Rig rig;

  setUp(() async => rig = await P3Rig.start());
  tearDown(() => rig.stop());

  final alice = p3Alice;

  Future<P3Res> sessions(
    List<int> body, {
    bool sign = true,
    bool chunked = false,
  }) => rig.request(
    'POST',
    '/sessions',
    body: body,
    headers: _json,
    signAs: sign ? alice : null,
    chunked: chunked,
  );

  void expectTooLarge(P3Res r) {
    expect(r.status, 413, reason: r.text);
    expect(r.error['code'], 'TOO_LARGE');
    expect(r.error['retryable'], isFalse);
  }

  // --------------------------------------------------------------------------------------
  group('POST /sessions limits in the secure profile (0.3, 4.3.4 step 2)', () {
    test(
      'exactly 256 KiB and 256 KiB + 1 are accepted (the cap is 4 MiB here)',
      () async {
        for (final n in [_k256, _k256 + 1, 1024 * 1024]) {
          final r = await sessions(p3SessionBody(alice, length: n));
          expect(r.status, 202, reason: '$n bytes: ${r.text}');
        }
        expect(rig.handler.count('createAuthenticatedSession'), 3);
      },
    );

    test(
      'exactly 4 MiB is accepted (the proof covers the whole body)',
      () async {
        final r = await sessions(p3SessionBody(alice, length: _k4M));
        expect(r.status, 202, reason: r.text);
        expect(rig.handler.count('createAuthenticatedSession'), 1);
      },
    );

    test('4 MiB + 1 is 413 TOO_LARGE and never reaches the handler', () async {
      expectTooLarge(await sessions(p3SessionBody(alice, length: _k4M + 1)));
      expect(rig.handler.calls, isEmpty);
    });

    test('size is checked before auth: 4 MiB + 1 without a proof is 413, 4 MiB without a proof is 401', () async {
      expectTooLarge(
        await sessions(p3SessionBody(alice, length: _k4M + 1), sign: false),
      );
      final r = await sessions(p3SessionBody(alice, length: _k4M), sign: false);
      expect(
        r.status,
        401,
        reason: 'twin: inside the cap the proof is checked next',
      );
      expect(r.error['code'], 'AUTH_INVALID');
    });

    test(
      '10,000 files (about 2 MB of JSON) fit the cap and reach the handler',
      () async {
        final b = p3SessionBody(alice, files: 10000);
        expect(
          b.length,
          greaterThan(_k256),
          reason: 'must be an oversize body to prove the new cap',
        );
        expect(b.length, lessThan(_k4M));
        final r = await sessions(b);
        expect(r.status, 202, reason: r.text);
        expect(
          rig.handler.last('createAuthenticatedSession').request!.files,
          hasLength(10000),
        );
      },
    );

    test('an absurd declared Content-Length is refused without serving it', () async {
      final raw = await P3Raw.tls(rig.port);
      addTearDown(raw.destroy);
      raw.write(
        'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
        'Content-Length: ${100 * 1024 * 1024}\r\n\r\n',
      );
      final head = await raw.waitForHead();
      // 413, or the connection is simply closed: never a served request.
      expect(
        head.isEmpty || head.startsWith('HTTP/1.1 413'),
        isTrue,
        reason: head,
      );
      expect(rig.handler.calls, isEmpty);
    });
  });

  // --------------------------------------------------------------------------------------
  group('other routes keep 256 KiB in the secure profile', () {
    test('POST /register: 256 KiB accepted, + 1 is 413', () async {
      final ok = await rig.request(
        'POST',
        '/register',
        body: p3RegisterBody(alice.info(), length: _k256),
        headers: _json,
        signAs: alice,
      );
      expect(ok.status, 200, reason: ok.text);
      final big = await rig.request(
        'POST',
        '/register',
        body: p3RegisterBody(alice.info(), length: _k256 + 1),
        headers: _json,
        signAs: alice,
      );
      expectTooLarge(big);
      expect(rig.handler.count('register'), 1);
    });

    test('POST /sessions/{sid}/sas: 256 KiB + 1 is 413', () async {
      final pad = jsonEncode({'nonce': p3Nonce22, 'pad': 'x' * _k256});
      final r = await rig.request(
        'POST',
        '/sessions/s1/sas',
        body: utf8.encode(pad),
        headers: _json,
        signAs: alice,
      );
      expectTooLarge(r);
      expect(rig.handler.count('revealSas'), 0);
    });

    test(
      'POST /pair: 256 KiB + 1 is 413 (4.3.4 /pair: body size 256 KiB)',
      () async {
        final map = PairRequest(
          sender: alice.info(),
          nonce: p3Nonce22,
          mac: 'A' * 43,
        ).toJson()..['pad'] = 'x' * (_k256 + 1);
        final r = await rig.request(
          'POST',
          '/pair',
          body: utf8.encode(jsonEncode(map)),
          headers: _json,
          signAs: alice,
        );
        expectTooLarge(r);
        expect(rig.handler.count('pair'), 0);
      },
    );

    test('POST .../complete: 256 KiB + 1 is 413', () async {
      final r = await rig.request(
        'POST',
        '/sessions/s1/files/f1/complete',
        body: utf8.encode(jsonEncode({'sha256': null, 'pad': 'x' * _k256})),
        headers: {..._json, 'authorization': 'Bearer t'},
      );
      expectTooLarge(r);
      expect(rig.handler.count('completeFile'), 0);
    });
  });

  // --------------------------------------------------------------------------------------
  group('Content-Length is required above 256 KiB (secure-order step 3, 4.3.4 step 2)', () {
    test('chunked body <= 256 KiB is accepted (twin)', () async {
      final r = await sessions(
        p3SessionBody(alice, length: _k256),
        chunked: true,
      );
      expect(r.status, 202, reason: r.text);
    });

    test('chunked body of 256 KiB + 1 is cut off: 413', () async {
      expectTooLarge(
        await sessions(p3SessionBody(alice, length: _k256 + 1), chunked: true),
      );
      expect(rig.handler.calls, isEmpty);
    });

    test('chunked 4 MiB body is refused too, valid proof or not', () async {
      expectTooLarge(
        await sessions(p3SessionBody(alice, length: _k4M), chunked: true),
      );
      expectTooLarge(
        await sessions(
          p3SessionBody(alice, length: _k4M),
          sign: false,
          chunked: true,
        ),
      );
      expect(rig.handler.calls, isEmpty);
    });

    test('the same 4 MiB body WITH Content-Length is accepted (it is the missing length that is refused)', () async {
      expect((await sessions(p3SessionBody(alice, length: _k4M))).status, 202);
    });
  });

  // --------------------------------------------------------------------------------------
  group('at most 2 oversize bodies are read at once (secure-order step 3)', () {
    /// Sends the request head for an oversize body (declared [declared] bytes) plus
    /// [sentBytes] bytes of it, then leaves the body hanging.
    Future<P3Raw> hangingOversize({
      int declared = 300 * 1024,
      int sentBytes = 1000,
    }) async {
      final raw = await P3Raw.tls(rig.port);
      raw.write(
        'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
        'Content-Length: $declared\r\n\r\n',
      );
      raw.writeBytes(List.filled(sentBytes, 0x20));
      await raw.socket.flush();
      // give the server time to enter the body read
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return raw;
    }

    test('a third oversize body gets 429 RATE_LIMITED (retryable, Retry-After); a small one is unaffected', () async {
      final a = await hangingOversize();
      final b = await hangingOversize();
      addTearDown(a.destroy);
      addTearDown(b.destroy);

      final third = await sessions(p3SessionBody(alice, length: 300 * 1024));
      expect(third.status, 429, reason: third.text);
      expect(third.error['code'], 'RATE_LIMITED');
      expect(third.error['retryable'], isTrue);
      expect(int.tryParse(third.header('retry-after') ?? ''), isNotNull);

      // A normal-size request is not counted as oversize.
      final small = await sessions(p3SessionBody(alice));
      expect(small.status, 202, reason: small.text);
      expect(rig.handler.count('createAuthenticatedSession'), 1);
    });

    test('with only ONE oversize body in flight the second is served (the cap is 2, not 1)', () async {
      final a = await hangingOversize();
      addTearDown(a.destroy);
      final second = await sessions(p3SessionBody(alice, length: 300 * 1024));
      expect(second.status, 202, reason: second.text);
    });

    test('a slot is released when a body ends: cut-off connection or completed body', () async {
      final a = await hangingOversize();
      final b = await hangingOversize();
      addTearDown(b.destroy);
      expect(
        (await sessions(p3SessionBody(alice, length: 300 * 1024))).status,
        429,
      );
      // connection of A dies mid-body
      a.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final retry = await sessions(p3SessionBody(alice, length: 300 * 1024));
      expect(
        retry.status,
        202,
        reason: 'slot of the aborted body must be free again: ${retry.text}',
      );
    });

    test(
      'a refused 413 oversize request (4 MiB + 1) does not hold a slot',
      () async {
        for (var i = 0; i < 4; i++) {
          expectTooLarge(
            await sessions(p3SessionBody(alice, length: _k4M + 1)),
          );
        }
        final a = await hangingOversize();
        final b = await hangingOversize();
        addTearDown(a.destroy);
        addTearDown(b.destroy);
        expect(
          (await sessions(p3SessionBody(alice, length: 300 * 1024))).status,
          429,
        );
      },
    );

    test(
      'the cap is per server, not per IP (second source address counts too)',
      () async {
        final a = await hangingOversize();
        final b = await hangingOversize();
        addTearDown(a.destroy);
        addTearDown(b.destroy);
        final other = await rig.request(
          'POST',
          '/sessions',
          body: p3SessionBody(alice, length: 300 * 1024),
          headers: _json,
          signAs: alice,
          from: '127.0.0.2',
        );
        expect(other.status, 429, reason: other.text);
      },
    );
  });

  // --------------------------------------------------------------------------------------
  group('plaintext profile is unchanged (Inc 1/2)', () {
    setUp(() async {
      await rig.stop();
      rig = await P3Rig.start(secure: false);
    });

    Future<P3Res> plain(List<int> body, {bool chunked = false}) => rig.request(
      'POST',
      '/sessions',
      body: body,
      headers: _json,
      chunked: chunked,
    );

    test('exactly 256 KiB is accepted, 256 KiB + 1 is 413', () async {
      expect((await plain(p3SessionBody(alice, length: _k256))).status, 202);
      expectTooLarge(await plain(p3SessionBody(alice, length: _k256 + 1)));
    });

    test('a chunked body of 256 KiB + 1 is 413 as before', () async {
      expectTooLarge(
        await plain(p3SessionBody(alice, length: _k256 + 1), chunked: true),
      );
    });

    test(
      'the 4 MiB cap and the oversize concurrency cap do not exist there',
      () async {
        expectTooLarge(await plain(p3SessionBody(alice, length: 1024 * 1024)));
        expectTooLarge(await plain(p3SessionBody(alice, length: _k4M)));
      },
    );
  });
}

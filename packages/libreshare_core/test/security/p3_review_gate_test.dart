// P3 verifying review: Contacts-only gate edge cases, request-smuggling-ish inputs and the oversize
// boundary that the first test set left uncovered (found by mutation checks). Spec: LSP-1 4.3.4
// secure order step 1, 4.3.6 (grammar, gate paragraph), 5.4, 4.3.1 (Content-Length).
//
// [RED] = fails against the P3 code as delivered. Everything else passes today and kills a mutant
// that the first test set let live (the mutant is named in the test).
import 'dart:async';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart';

const _json = {'content-type': 'application/json'};

void main() {
  late P3Rig rig;
  var contacts = true;
  var callbackThrows = false;

  setUp(() async {
    contacts = true;
    callbackThrows = false;
    rig = await P3Rig.start(
      contactsOnly: () {
        if (callbackThrows) throw StateError('settings store unavailable');
        return contacts;
      },
    );
    await p3Pin(rig, p3Alice);
  });
  tearDown(() => rig.stop());

  Future<P3Res> unknownRoute() => rig.request('GET', '/does-not-exist');

  Future<P3Res> sessions(String? header) => rig.request(
    'POST',
    '/sessions',
    body: p3SessionBody(p3Alice),
    headers: _json,
    authHeader: header,
  );

  Future<P3Res> register(String? header) => rig.request(
    'POST',
    '/register',
    body: p3RegisterBody(p3Alice.info()),
    headers: _json,
    authHeader: header,
  );

  String validFor(String method, String path, List<int> body) =>
      rig.proof(p3Alice, method, path, body);

  // ------------------------------------------------------------------------------------------
  group('fail closed (mutant fail-open: a throwing contactsOnly callback treated as "everyone")', () {
    test('a callback that throws keeps strangers out (404 on all three gated routes) and does not 500', () async {
      callbackThrows = true;
      final ref = await unknownRoute();
      for (final r in [
        await rig.request('GET', '/info'),
        await register(null),
        await sessions(null),
        await rig.request('GET', '/info', signAs: p3Mallory),
      ]) {
        expect(r.status, 404, reason: r.text);
        expect(r.bytes, ref.bytes);
      }
      expect(rig.handler.calls, isEmpty);
    });

    test(
      'a callback that throws still serves a contact with a valid proof',
      () async {
        callbackThrows = true;
        final r = await rig.request('GET', '/info', signAs: p3Alice);
        expect(r.status, 200, reason: r.text);
        expect(
          (await sessions(
            validFor('POST', '/sessions', p3SessionBody(p3Alice)),
          )).status,
          202,
        );
      },
    );

    test('the callback recovering is picked up on the next request', () async {
      callbackThrows = true;
      expect((await rig.request('GET', '/info')).status, 404);
      callbackThrows = false;
      contacts = false;
      expect((await rig.request('GET', '/info')).status, 200);
    });
  });

  // ------------------------------------------------------------------------------------------
  group('what counts as a well-formed header at the gate (4.3.6: "absent, malformed or names a non-contact is a stranger")', () {
    List<String> parts(String method, String path, List<int> body) =>
        validFor(method, path, body).split('.');

    test('a header longer than 4096 bytes is a stranger even with a contact certificate (mutant: no length cap)', () async {
      final body = p3SessionBody(p3Alice);
      final p = parts('POST', '/sessions', body);
      final long = [p[0], p[1], p[2], p[3] + 'A' * 4200, p[4]].join('.');
      expect(long.length, greaterThan(4096));
      final ref = await unknownRoute();
      final r = await sessions(long);
      expect(r.status, 404, reason: r.text);
      expect(r.bytes, ref.bytes);
      final r2 = await register(
        [p[0], p[1], p[2], p[3] + 'A' * 4200, p[4]].join('.'),
      );
      expect(r2.status, 404, reason: r2.text);
      expect(rig.handler.calls, isEmpty);
    });

    test('[RED, low] a contact certificate with a malformed ts, nonce or sig is a stranger: 404, not 401 (POST /sessions and /register)', () async {
      final body = p3SessionBody(p3Alice);
      final p = parts('POST', '/sessions', body);
      final ref = await unknownRoute();
      final bent = <String, String>{
        'ts with a leading zero': [
          p[0],
          p[1],
          '0${p[2]}',
          p[3],
          p[4],
        ].join('.'),
        'ts not a number': [p[0], p[1], 'abc', p[3], p[4]].join('.'),
        'nonce too short': [
          p[0],
          p[1],
          p[2],
          p[3].substring(1),
          p[4],
        ].join('.'),
        'sig too short': [p[0], p[1], p[2], p[3], p[4].substring(1)].join('.'),
        'sig empty': [p[0], p[1], p[2], p[3], ''].join('.'),
        'nonce not base64url': [p[0], p[1], p[2], '!' * 22, p[4]].join('.'),
      };
      for (final e in bent.entries) {
        final s = await sessions(e.value);
        expect(s.status, 404, reason: 'POST /sessions, ${e.key}: ${s.text}');
        expect(s.bytes, ref.bytes, reason: e.key);
        final g = await register(e.value);
        expect(g.status, 404, reason: 'POST /register, ${e.key}: ${g.text}');
      }
      expect(rig.handler.calls, isEmpty);
    });

    test('a duplicated X-LS-Auth header is a stranger', () async {
      final raw = await P3Raw.tls(rig.port);
      addTearDown(raw.destroy);
      final h = validFor('GET', '/info', const []);
      raw.write(
        'GET $kApiPrefix/info HTTP/1.1\r\nHost: x\r\nConnection: close\r\n'
        '$kAuthHeader: $h\r\n$kAuthHeader: $h\r\n\r\n',
      );
      await raw.waitForHead();
      expect(raw.statusCode, 404);
    });
  });

  // ------------------------------------------------------------------------------------------
  group('request-target variants cannot dodge the gate (verified by hand: all 404)', () {
    test('GET /info and POST /sessions|/register through odd but legal targets are strangers', () async {
      final targets = [
        'GET //api/v1/info',
        'GET $kApiPrefix/./info',
        'GET $kApiPrefix/x/../info',
        'GET $kApiPrefix/%69nfo',
        'GET $kApiPrefix/info/',
        'GET $kApiPrefix//info',
        'GET http://127.0.0.1$kApiPrefix/info',
        'GET http://evil.example$kApiPrefix/info',
        'get $kApiPrefix/info',
        'HEAD $kApiPrefix/info',
        'POST $kApiPrefix/%73essions',
        'POST //api/v1/sessions',
        'POST $kApiPrefix/sessions/',
        'POST $kApiPrefix/x/../register',
      ];
      for (final t in targets) {
        final raw = await P3Raw.tls(rig.port);
        raw.write(
          '$t HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
        );
        await raw.waitForHead();
        // 404 (envelope of an unknown route) and never a served 200/202 or 401.
        expect(raw.statusCode, 404, reason: t);
        raw.destroy();
      }
      expect(rig.handler.calls, isEmpty);
    });
  });

  // ------------------------------------------------------------------------------------------
  group('Content-Length / Transfer-Encoding games on POST /sessions are never served (dart:io closes the connection)', () {
    setUp(() async {
      contacts = false;
    });

    test('negative, overflowing, hex, signed, duplicated or conflicting lengths reach no handler and get no 2xx', () async {
      final cases = [
        'Content-Length: -5',
        'Content-Length: 99999999999999999999',
        'Content-Length: 18446744073709551626',
        'Content-Length: 9223372036854775807',
        'Content-Length: 4\r\nContent-Length: 5',
        'Content-Length: 4\r\nContent-Length: 4',
        'Content-Length: 0x10',
        'Content-Length: +10',
        'Content-Length: 1e3',
        'Content-Length: 4\r\nTransfer-Encoding: chunked',
        'Transfer-Encoding: chunked\r\nTransfer-Encoding: identity',
        'Transfer-Encoding: xchunked',
        'Content-Length: ',
      ];
      for (final c in cases) {
        final raw = await P3Raw.tls(rig.port);
        raw.write(
          'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\n$c\r\nConnection: close\r\n\r\n{"a":1}',
        );
        await raw.waitForHead(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final s = raw.statusCode;
        expect(s < 200 || s >= 300, isTrue, reason: '[$c] answered $s');
        raw.destroy();
      }
      expect(rig.handler.calls, isEmpty);
    });
  });

  // ------------------------------------------------------------------------------------------
  group('oversize boundary (mutant: ">= 256 KiB" counted as oversize)', () {
    setUp(() async {
      contacts = false;
    });

    Future<P3Raw> hanging() async {
      final raw = await P3Raw.tls(rig.port);
      raw.write(
        'POST $kApiPrefix/sessions HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n'
        'Content-Length: ${300 * 1024}\r\n\r\n',
      );
      raw.writeBytes(List.filled(1024, 0x20));
      await raw.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return raw;
    }

    test('with both slots taken, a body of exactly 256 KiB is served and 256 KiB + 1 is 429', () async {
      final a = await hanging();
      final b = await hanging();
      addTearDown(a.destroy);
      addTearDown(b.destroy);
      final exactly = await rig.postSession(
        p3Alice,
        body: p3SessionBody(p3Alice, length: 256 * 1024),
      );
      expect(exactly.status, 202, reason: exactly.text);
      final plusOne = await rig.postSession(
        p3Alice,
        body: p3SessionBody(p3Alice, length: 256 * 1024 + 1),
      );
      expect(plusOne.status, 429, reason: plusOne.text);
    });
  });
}

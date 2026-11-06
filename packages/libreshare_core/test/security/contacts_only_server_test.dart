// Contacts-only gate of the secure ApiServer. Spec: LSP-1 4.3.2 (note on Contacts-only),
// 4.3.4 (secure order, step 1), 4.3.6 (last paragraph), 5.4; docs/plans/inc3.md section 3 item 7.
//
// A stranger gets the 404 NOT_FOUND envelope of an unknown route, byte for byte: same status, same
// body bytes, same header names. /pair is exempt. The decision is made per request.
import 'dart:convert';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart';

void main() {
  late P3Rig rig;
  var contactsOnly = true;

  setUp(() async {
    contactsOnly = true;
    rig = await P3Rig.start(contactsOnly: () => contactsOnly);
  });
  tearDown(() => rig.stop());

  final alice = p3Alice; // becomes a contact
  final mallory = p3Mallory; // stays a stranger

  /// The three gated requests of 5.4: GET /info, POST /register, POST /sessions.
  Map<String, Future<P3Res> Function(P3Peer? who, {String? header})> gated() {
    Future<P3Res> info(P3Peer? who, {String? header}) =>
        rig.request('GET', '/info', signAs: who, authHeader: header);
    Future<P3Res> register(P3Peer? who, {String? header}) => rig.request(
      'POST',
      '/register',
      body: p3RegisterBody((who ?? alice).info()),
      headers: {'content-type': 'application/json'},
      signAs: who,
      authHeader: header,
    );
    Future<P3Res> sessions(P3Peer? who, {String? header}) => rig.request(
      'POST',
      '/sessions',
      body: p3SessionBody(who ?? alice),
      headers: {'content-type': 'application/json'},
      signAs: who,
      authHeader: header,
    );
    return {
      'GET /info': info,
      'POST /register': register,
      'POST /sessions': sessions,
    };
  }

  Future<P3Res> unknownRoute() => rig.request('GET', '/does-not-exist');

  void expectPlain404(P3Res r, P3Res reference, {String? why}) {
    expect(r.status, 404, reason: why ?? r.text);
    expect(r.error['code'], 'NOT_FOUND', reason: why);
    expect(
      r.bytes,
      reference.bytes,
      reason: '$why: body bytes must equal an unknown route',
    );
    expect(
      r.headerNames,
      reference.headerNames,
      reason: '$why: header names differ',
    );
    expect(
      r.headersWithoutDate,
      reference.headersWithoutDate,
      reason: '$why: header values differ',
    );
  }

  group(
    'stranger (5.4: no X-LS-Auth, or a certificate that is not a contact)',
    () {
      test('GET /info, /register and /sessions: 404 identical to an unknown route, handler untouched', () async {
        final ref = await unknownRoute();
        expect(ref.status, 404);
        for (final e in gated().entries) {
          // no proof at all
          expectPlain404(
            await e.value(null),
            ref,
            why: '${e.key} without proof',
          );
          // a perfectly valid proof of a stranger
          expectPlain404(
            await e.value(mallory),
            ref,
            why: '${e.key} valid proof, stranger',
          );
        }
        expect(rig.handler.calls, isEmpty);
      });

      test(
        'a malformed or garbage header is a stranger too (404, not 401)',
        () async {
          final ref = await unknownRoute();
          for (final e in gated().entries) {
            for (final h in ['', 'junk', 'v1.a.b.c.d']) {
              expectPlain404(
                await e.value(null, header: h),
                ref,
                why: '${e.key} header "$h"',
              );
            }
          }
          expect(rig.handler.calls, isEmpty);
        },
      );

      test(
        '404 for a stranger carries a Date header like every secure response',
        () async {
          final r = await gated()['GET /info']!(mallory);
          expect(r.date, isNotNull);
        },
      );

      test('a blocked fingerprint is not a contact (404, not 403)', () async {
        await p3Pin(rig, alice);
        await rig.trust.block(alice.fp);
        final ref = await unknownRoute();
        for (final e in gated().entries) {
          expectPlain404(await e.value(alice), ref, why: '${e.key} blocked');
        }
        expect(rig.handler.calls, isEmpty);
      });

      test(
        'a known deviceId presenting another key is a stranger (404)',
        () async {
          await p3Pin(rig, alice);
          final impostor = P3Peer(alice.deviceId); // same CN, new key
          final ref = await unknownRoute();
          expectPlain404(await gated()['POST /sessions']!(impostor), ref);
          expect(rig.handler.calls, isEmpty);
        },
      );

      test('the gate comes before the body: a stranger with a 5 MiB body gets 404, a contact 413', () async {
        final ref = await unknownRoute();
        final big = p3SessionBody(alice, length: 5 * 1024 * 1024);
        final stranger = await rig.request(
          'POST',
          '/sessions',
          body: big,
          headers: {'content-type': 'application/json'},
          signAs: mallory,
        );
        expectPlain404(stranger, ref, why: 'stranger oversize');
        await p3Pin(rig, alice);
        final contact = await rig.request(
          'POST',
          '/sessions',
          body: big,
          headers: {'content-type': 'application/json'},
          signAs: alice,
        );
        expect(
          contact.status,
          413,
          reason: 'twin: the contact reaches the size check',
        );
      });

      test('the gate comes before the rate limit: strangers never see 429 and never use up tokens', () async {
        await rig.stop();
        final clock = P3Clock();
        rig = await P3Rig.start(
          contactsOnly: () => true,
          enableRateLimit: true,
          rateLimiter: RateLimiter(clock: clock.now),
        );
        await p3Pin(rig, alice);
        for (var i = 0; i < 15; i++) {
          final r = await rig.postSession(mallory);
          expect(r.status, 404, reason: 'stranger request $i');
        }
        // the same IP as a contact: the full burst of 10 is still there, the 11th is limited
        for (var i = 0; i < 10; i++) {
          expect(
            (await rig.postSession(alice)).status,
            202,
            reason: 'contact request $i',
          );
        }
        expect((await rig.postSession(alice)).status, 429);
      });
    },
  );

  group('contact (5.4: known or trusted, served after full verification)', () {
    for (final level in [PeerTrust.known, PeerTrust.trusted]) {
      test(
        '${level.name} contact with a valid proof is served on all three routes',
        () async {
          await p3Pin(rig, alice, trust: level);
          final ref = await unknownRoute();
          for (final e in gated().entries) {
            final r = await e.value(alice);
            expect(r.status, anyOf(200, 202), reason: '${e.key}: ${r.text}');
            expect(r.bytes, isNot(ref.bytes));
          }
          expect(
            rig.handler.names,
            containsAll([
              'deviceInfo',
              'register',
              'createAuthenticatedSession',
            ]),
          );
          expect(
            rig.handler.last('createAuthenticatedSession').peer!.fingerprint,
            alice.fp,
          );
        },
      );
    }

    test('removing the contact makes the very next request a 404 again (evaluated per request)', () async {
      await p3Pin(rig, alice);
      expect((await gated()['POST /sessions']!(alice)).status, 202);
      await rig.trust.remove(alice.deviceId);
      final ref = await unknownRoute();
      for (final e in gated().entries) {
        expectPlain404(
          await e.value(alice),
          ref,
          why: '${e.key} after removal',
        );
      }
      expect(rig.handler.count('createAuthenticatedSession'), 1);
    });

    test('blocking the contact makes the next request a 404', () async {
      await p3Pin(rig, alice);
      expect((await gated()['GET /info']!(alice)).status, 200);
      await rig.trust.block(alice.fp);
      expect((await gated()['GET /info']!(alice)).status, 404);
    });

    test('GET /info: a contact whose proof fails full verification gets the plain 404', () async {
      await p3Pin(rig, alice);
      final ref = await unknownRoute();
      final good = rig.proof(alice, 'GET', '/info', const []);
      // replay: first use fine, second use is a failed verification
      expect((await rig.request('GET', '/info', authHeader: good)).status, 200);
      expectPlain404(
        await rig.request('GET', '/info', authHeader: good),
        ref,
        why: 'replayed',
      );
      // forged signature on a contact certificate
      final parts = rig.proof(alice, 'GET', '/info', const []).split('.');
      final forged = [
        ...parts.take(4),
        parts[4].replaceRange(
          0,
          4,
          parts[4].startsWith('AAAA') ? 'BBBB' : 'AAAA',
        ),
      ].join('.');
      expectPlain404(
        await rig.request('GET', '/info', authHeader: forged),
        ref,
        why: 'forged',
      );
    });

    test('POST routes: a contact certificate with a failed verification is 401 AUTH_INVALID', () async {
      await p3Pin(rig, alice);
      final b = p3SessionBody(alice);
      final h = rig.proof(alice, 'POST', '/sessions', b);
      expect(
        (await rig.request(
          'POST',
          '/sessions',
          body: b,
          headers: {'content-type': 'application/json'},
          authHeader: h,
        )).status,
        202,
      );
      final replay = await rig.request(
        'POST',
        '/sessions',
        body: b,
        headers: {'content-type': 'application/json'},
        authHeader: h,
      );
      expect(replay.status, 401);
      expect(replay.error['code'], 'AUTH_INVALID');
    });

    test('contactsOnly = false (or toggled off at run time): strangers are served normally', () async {
      expect((await gated()['GET /info']!(mallory)).status, 404);
      contactsOnly = false;
      expect(
        (await gated()['GET /info']!(null)).status,
        200,
        reason: 'no proof needed on /info',
      );
      expect((await gated()['POST /sessions']!(mallory)).status, 202);
      contactsOnly = true;
      expect((await gated()['GET /info']!(mallory)).status, 404);
    });

    test('no contactsOnly callback at all: nobody is gated', () async {
      await rig.stop();
      rig = await P3Rig.start();
      expect((await rig.request('GET', '/info')).status, 200);
      expect((await rig.postSession(mallory)).status, 202);
    });
  });

  group('exempt routes (5.4: /pair, and accepted sessions by session id / file token)', () {
    test(
      'POST /pair reaches the handler for a stranger with a valid proof',
      () async {
        final b = utf8.encode(
          jsonEncode(
            PairRequest(
              sender: mallory.info(),
              nonce: p3Nonce22,
              mac: 'A' * 43,
            ).toJson(),
          ),
        );
        final r = await rig.request(
          'POST',
          '/pair',
          body: b,
          headers: {'content-type': 'application/json'},
          signAs: mallory,
        );
        expect(r.status, 200, reason: r.text);
        expect(rig.handler.count('pair'), 1);
        expect(rig.handler.last('pair').peer!.fingerprint, mallory.fp);
      },
    );

    test(
      'POST /pair without a proof is 401 AUTH_INVALID, not the stranger 404',
      () async {
        final r = await rig.request(
          'POST',
          '/pair',
          body: utf8.encode(
            jsonEncode(
              PairRequest(
                sender: mallory.info(),
                nonce: p3Nonce22,
                mac: 'A' * 43,
              ).toJson(),
            ),
          ),
          headers: {'content-type': 'application/json'},
        );
        expect(r.status, 401);
        expect(r.error['code'], 'AUTH_INVALID');
      },
    );

    test('POST /pair "no invite" is the handler 404 (envelope of an unknown route)', () async {
      rig.handler.failWith = LsException(LsErrorCode.notFound, 'No such route');
      final b = utf8.encode(
        jsonEncode(
          PairRequest(
            sender: mallory.info(),
            nonce: p3Nonce22,
            mac: 'A' * 43,
          ).toJson(),
        ),
      );
      final r = await rig.request(
        'POST',
        '/pair',
        body: b,
        headers: {'content-type': 'application/json'},
        signAs: mallory,
      );
      final ref = await unknownRoute();
      expect(r.status, 404);
      expect(r.bytes, ref.bytes);
    });

    test('session and file routes are not gated (the session id and the file token authorise them)', () async {
      for (final (method, path, headers) in [
        ('GET', '/sessions/s1?wait=0', <String, String>{}),
        ('POST', '/sessions/s1/finish', <String, String>{}),
        ('POST', '/sessions/s1/cancel', <String, String>{}),
        (
          'GET',
          '/sessions/s1/files/f1/state',
          {'authorization': 'Bearer tok-1'},
        ),
        (
          'POST',
          '/sessions/s1/files/f1/complete',
          {'authorization': 'Bearer tok-1'},
        ),
      ]) {
        final r = await rig.request(method, path, headers: headers);
        expect(r.status, 200, reason: '$method $path: ${r.text}');
      }
      expect(
        rig.handler.names,
        containsAll([
          'getSession',
          'finish',
          'cancel',
          'fileState',
          'completeFile',
        ]),
      );
    });
  });
}

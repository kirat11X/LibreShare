// P3 verifying review: findings of the second (adversarial) tester that the first test set did
// not cover. Spec: LSP-1 4.3.1 (Retry-After, Date), 5.2 (PIN throttling), 4.3.5.
//
// Tests marked [RED] fail against the P3 code as delivered; the coder must make them pass without
// editing them. Unmarked tests pass today and guard behaviour the review verified by hand.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_handler.dart';
import '../helpers/p3_secure_rig.dart';
import '../helpers/p3v_support.dart';

const _tenMinutes = Duration(minutes: 10);

LsException? _thrown(void Function() body) {
  try {
    body();
  } on LsException catch (e) {
    return e;
  }
  return null;
}

void main() {
  late P3Clock clock;

  PinGuard makeGuard() => PinGuard(
    policy: const PinPolicy(mode: PinMode.window),
    clock: clock,
  );

  setUp(() => clock = P3Clock());

  // ------------------------------------------------------------------------------------------
  group(
    '[RED] PinGuard BLOCKED carries the remaining block time (LSP-1 4.3.1)',
    () {
      int seconds(LsException e) {
        final d = e.retryAfter;
        expect(d, isNotNull, reason: 'BLOCKED must set LsException.retryAfter');
        return d!.inSeconds;
      }

      test('per-IP block: retryAfter is the remaining time, rounded up, at least 1 s', () {
        final g = makeGuard();
        final bad = p3vWrongPin(g.currentPin!);
        for (var i = 0; i < 5; i++) {
          _thrown(
            () => g.check(remoteAddress: '10.0.0.1', pin: bad, exempt: false),
          );
        }
        final first = _thrown(
          () => g.check(remoteAddress: '10.0.0.1', pin: bad, exempt: false),
        )!;
        expect(first.code, LsErrorCode.blocked);
        expect(seconds(first), inInclusiveRange(599, 600));

        clock.advance(const Duration(minutes: 4));
        final later = _thrown(
          () => g.check(
            remoteAddress: '10.0.0.1',
            pin: g.currentPin,
            exempt: false,
          ),
        )!;
        expect(later.code, LsErrorCode.blocked);
        expect(seconds(later), inInclusiveRange(359, 360));

        // Half a second before the end: still blocked, and the header must not be 0.
        clock.advance(const Duration(minutes: 6) - const Duration(seconds: 4));
        clock.advance(const Duration(milliseconds: 500));
        final last = _thrown(
          () => g.check(remoteAddress: '10.0.0.1', pin: bad, exempt: false),
        )!;
        expect(last.code, LsErrorCode.blocked);
        expect(last.retryAfter!.inMilliseconds, greaterThanOrEqualTo(1000));
        expect(last.retryAfter!, lessThanOrEqualTo(const Duration(seconds: 4)));
      });

      test('global lock: retryAfter is the remaining lock time', () {
        final g = makeGuard();
        final bad = p3vWrongPin(g.currentPin!);
        for (var ip = 1; ip <= 5; ip++) {
          for (var i = 0; i < 5; i++) {
            _thrown(
              () =>
                  g.check(remoteAddress: '10.0.1.$ip', pin: bad, exempt: false),
            );
          }
        }
        final e = _thrown(
          () => g.check(
            remoteAddress: '10.0.2.1',
            pin: g.currentPin,
            exempt: false,
          ),
        )!;
        expect(e.code, LsErrorCode.blocked);
        expect(seconds(e), inInclusiveRange(599, 600));
        clock.advance(const Duration(minutes: 9));
        final e2 = _thrown(
          () => g.check(
            remoteAddress: '10.0.2.2',
            pin: g.currentPin,
            exempt: false,
          ),
        )!;
        expect(seconds(e2), inInclusiveRange(59, 60));
      });

      test(
        'PIN_INVALID and PIN_REQUIRED carry no retryAfter (not a block)',
        () {
          final g = makeGuard();
          final invalid = _thrown(
            () => g.check(
              remoteAddress: '10.0.0.9',
              pin: p3vWrongPin(g.currentPin!),
              exempt: false,
            ),
          )!;
          expect(invalid.code, LsErrorCode.pinInvalid);
          expect(invalid.retryAfter, isNull);
          final required = _thrown(
            () => g.check(remoteAddress: '10.0.0.9', pin: null, exempt: false),
          )!;
          expect(required.code, LsErrorCode.pinRequired);
          expect(required.retryAfter, isNull);
        },
      );
    },
  );

  // ------------------------------------------------------------------------------------------
  group('[RED] the HTTP layer answers Retry-After for a BLOCKED PIN failure', () {
    late PinGuard guard;
    late P3Rig rig;

    setUp(() async {
      guard = makeGuard();
      rig = await P3Rig.start(handler: P3vPinHandler(guard));
    });
    tearDown(() => rig.stop());

    Future<P3Res> send(String? pin, {String? from}) => rig.postSession(
      p3Alice,
      body: p3vSessionBodyWithPin(p3Alice, pin),
      from: from,
      headers: const {'content-type': 'application/json'},
    );

    void expectBlocked(P3Res r, {required int maxSeconds}) {
      expect(r.status, 403, reason: r.text);
      expect(r.error['code'], 'BLOCKED');
      final s = p3vRetryAfterSeconds(r);
      expect(
        s,
        isNotNull,
        reason:
            'Retry-After must be whole seconds, got ${r.header('retry-after')}',
      );
      expect(s, inInclusiveRange(1, maxSeconds));
    }

    test('per-IP block: 5 wrong PINs, then BLOCKED with Retry-After <= 600 even for the right PIN', () async {
      final bad = p3vWrongPin(guard.currentPin!);
      for (var i = 0; i < 4; i++) {
        expect((await send(bad)).error['code'], 'PIN_INVALID');
      }
      final fifth = await send(bad);
      if (fifth.status == 403) {
        expectBlocked(fifth, maxSeconds: 600);
      } else {
        expect(fifth.error['code'], 'PIN_INVALID');
      }
      expectBlocked(await send(guard.currentPin), maxSeconds: 600);
      clock.advance(const Duration(seconds: 100));
      final r = await send(guard.currentPin);
      expectBlocked(r, maxSeconds: 500);
      // 99 s later the value is the remaining time, not the full window.
      expect(p3vRetryAfterSeconds(r), lessThanOrEqualTo(500));
    });

    test('the block of one IP is per IP: another source is not blocked and gets no Retry-After', () async {
      final bad = p3vWrongPin(guard.currentPin!);
      for (var i = 0; i < 5; i++) {
        await send(bad);
      }
      expectBlocked(await send(bad), maxSeconds: 600);
      final other = await send(guard.currentPin, from: '127.0.0.2');
      expect(other.status, 202, reason: other.text);
      expect(other.header('retry-after'), isNull);
    });

    test('global lock: 25 wrong PINs from 5 sources, then every source gets BLOCKED + Retry-After <= 600', () async {
      final bad = p3vWrongPin(guard.currentPin!);
      for (var ip = 2; ip <= 6; ip++) {
        for (var i = 0; i < 5; i++) {
          await send(bad, from: '127.0.0.$ip');
        }
      }
      expectBlocked(
        await send(guard.currentPin, from: '127.0.0.9'),
        maxSeconds: 600,
      );
      clock.advance(_tenMinutes - const Duration(seconds: 30));
      expectBlocked(
        await send(guard.currentPin, from: '127.0.0.10'),
        maxSeconds: 30,
      );
      clock.advance(const Duration(seconds: 31));
      final ok = await send(guard.currentPin, from: '127.0.0.11');
      expect(ok.status, 202, reason: ok.text);
      expect(ok.header('retry-after'), isNull);
    });

    test('a handler that throws LsException(retryAfter) is answered with that many whole seconds', () async {
      final h = P3SecureHandler()
        ..onCreateAuthenticated = (r, a, p) async => throw LsException(
          LsErrorCode.blocked,
          'Too many attempts',
          const Duration(seconds: 42),
        );
      await rig.stop();
      rig = await P3Rig.start(handler: h);
      final r = await rig.postSession(p3Alice);
      expect(r.status, 403, reason: r.text);
      expect(p3vRetryAfterSeconds(r), 42);
      // Never part of the JSON envelope (LsException doc).
      expect(r.error.keys, containsAll(['code', 'message', 'retryable']));
      expect(r.error.containsKey('retryAfter'), isFalse);
    });

    test('a sub-second retryAfter is rounded up to 1, never 0', () async {
      final h = P3SecureHandler()
        ..onCreateAuthenticated = (r, a, p) async => throw LsException(
          LsErrorCode.blocked,
          'Too many attempts',
          const Duration(milliseconds: 400),
        );
      await rig.stop();
      rig = await P3Rig.start(handler: h);
      final r = await rig.postSession(p3Alice);
      expect(p3vRetryAfterSeconds(r), 1);
    });

    test(
      'an LsException without retryAfter answers without a Retry-After header',
      () async {
        final h = P3SecureHandler()
          ..failWith = LsException(LsErrorCode.blocked, 'Blocked');
        await rig.stop();
        rig = await P3Rig.start(handler: h);
        final r = await rig.postSession(p3Alice);
        expect(r.status, 403);
        expect(r.header('retry-after'), isNull);
      },
    );
  });

  // ------------------------------------------------------------------------------------------
  group('PinGuard boundaries the first set left open (mutant: global strikes kept after a lock)', () {
    test('right when the lock ends, one wrong PIN is a plain PIN_INVALID and the right PIN is accepted afterwards', () {
      final g = makeGuard();
      final bad = p3vWrongPin(g.currentPin!);
      for (var ip = 1; ip <= 5; ip++) {
        for (var i = 0; i < 5; i++) {
          _thrown(
            () => g.check(remoteAddress: '10.1.0.$ip', pin: bad, exempt: false),
          );
        }
      }
      clock.advance(
        _tenMinutes,
      ); // the lock ends exactly now (isBefore is false)
      final one = _thrown(
        () => g.check(remoteAddress: '10.1.9.1', pin: bad, exempt: false),
      );
      expect(one?.code, LsErrorCode.pinInvalid);
      final ok = _thrown(
        () => g.check(
          remoteAddress: '10.1.9.2',
          pin: g.currentPin,
          exempt: false,
        ),
      );
      expect(ok, isNull, reason: 'one wrong PIN after a lock must not re-lock');
    });

    test('a blocked IP stays blocked while 24 other IPs spend their strikes (no eviction of blocked entries)', () {
      final g = makeGuard();
      final bad = p3vWrongPin(g.currentPin!);
      for (var i = 0; i < 5; i++) {
        _thrown(
          () => g.check(remoteAddress: '10.2.0.1', pin: bad, exempt: false),
        );
      }
      for (var ip = 0; ip < 19; ip++) {
        _thrown(
          () => g.check(remoteAddress: '10.2.1.$ip', pin: bad, exempt: false),
        );
      }
      clock.advance(const Duration(minutes: 1));
      expect(
        _thrown(
          () => g.check(
            remoteAddress: '10.2.0.1',
            pin: g.currentPin,
            exempt: false,
          ),
        )?.code,
        LsErrorCode.blocked,
      );
    });
  });

  // ------------------------------------------------------------------------------------------
  group('request targets the HTTP stack cannot represent (LOW)', () {
    late P3Rig rig;
    setUp(() async => rig = await P3Rig.start());
    tearDown(() => rig.stop());

    test('[RED, low] a target with a #fragment gets the JSON 400 envelope and a Date header, not shelf\'s text/plain "Bad Request"', () async {
      final raw = await P3Raw.tls(rig.port);
      addTearDown(raw.destroy);
      raw.write(
        'GET $kApiPrefix/info# HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n',
      );
      await raw.waitForHead();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final text = raw.text;
      expect(text, startsWith('HTTP/1.1 400'));
      expect(text.toLowerCase(), contains('content-type: application/json'));
      expect(text.toLowerCase(), contains('\r\ndate: '));
      expect(text, contains('"code":"BAD_REQUEST"'));
    });

    test(
      'garbage TLS handshakes and plaintext junk do not stop the listener',
      () async {
        for (var i = 0; i < 40; i++) {
          final s = await Socket.connect('127.0.0.1', rig.port);
          switch (i % 4) {
            case 0:
              s.add(List<int>.generate(100, (j) => j));
            case 1:
              s.add('GET / HTTP/1.1\r\n\r\n'.codeUnits);
            case 2:
              s.add([0x16, 0x03, 0x01, 0x00, 0x05, 1, 2]);
            default:
              s.add([0x16, 0x03, 0x01, 0xff, 0xff]);
          }
          s.destroy();
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final r = await rig.request('GET', '/info');
        expect(r.status, 200, reason: r.text);
        expect(r.header('date'), isNotNull);
      },
    );
  });
}

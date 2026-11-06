// PinGuard (security/pin_guard.dart): PIN format, constant-answer failures, per-IP and global
// throttling, rotation, one-time PINs, exempt contacts. Spec: LSP-1 5.2, 4.3.4 (secure order,
// step 10), 4.3.5 (PIN_REQUIRED / PIN_INVALID / BLOCKED), docs/plans/inc3.md D5.
//
// New symbol under test (P3 writes it): lib/src/security/pin_guard.dart
//   class PinGuard implements PinVerifier {
//     PinGuard({PinPolicy policy = const PinPolicy.off(), String? pin, Duration? pinTtl,
//               Clock clock = const SystemClock(), void Function()? onBruteForce});
//     String? get currentPin;   // null when the policy is off
//     void rotate();            // new random 6-digit PIN, TTL restarts
//   }
import 'package:libreshare_core/libreshare_core.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../helpers/p3_secure_rig.dart' show P3Clock, P3LogCapture;

const _windowPolicy = PinPolicy(mode: PinMode.window);
const _fixedPolicy = PinPolicy(mode: PinMode.fixed);
const _tenMinutes = Duration(minutes: 10);
const _ms = Duration(milliseconds: 1);

/// Runs [body] and returns the LsException it throws (null if it returns).
LsException? _thrown(void Function() body) {
  try {
    body();
  } on LsException catch (e) {
    return e;
  }
  return null;
}

String _wrongPinFor(String pin) => pin == '000000' ? '111111' : '000000';

void main() {
  late P3Clock clock;
  var bruteForce = 0;

  PinGuard make({
    PinPolicy policy = _windowPolicy,
    String? pin,
    Duration? pinTtl,
  }) => PinGuard(
    policy: policy,
    pin: pin,
    pinTtl: pinTtl,
    clock: clock,
    onBruteForce: () => bruteForce++,
  );

  /// Sends a wrong PIN from [ip]; returns the error code (null = accepted).
  LsErrorCode? wrong(PinGuard g, String ip) {
    final bad = _wrongPinFor(g.currentPin!);
    return _thrown(() => g.check(remoteAddress: ip, pin: bad, exempt: false))
        ?.code;
  }

  LsErrorCode? right(PinGuard g, String ip) => _thrown(
    () => g.check(remoteAddress: ip, pin: g.currentPin, exempt: false),
  )?.code;

  setUp(() {
    clock = P3Clock();
    bruteForce = 0;
  });

  // ---- LSP-1 5.2 / 4.3.5: policy off, PIN format, required vs invalid -------------------
  group('policy and PIN format (LSP-1 5.2)', () {
    test('policy off: not enforced, no PIN, nothing is ever refused', () {
      final g = make(policy: const PinPolicy.off());
      expect(g.enforced, isFalse);
      expect(g.currentPin, isNull);
      for (final pin in [null, '', '123456', 'abc']) {
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.1', pin: pin, exempt: false),
          ),
          isNull,
        );
      }
    });

    test('window and fixed policies are enforced and have a 6-digit PIN', () {
      for (final policy in [_windowPolicy, _fixedPolicy]) {
        final g = make(policy: policy);
        expect(g.enforced, isTrue, reason: policy.mode.name);
        expect(g.currentPin, matches(RegExp(r'^[0-9]{6}$')));
      }
    });

    test('fixed policy keeps the PIN it was given; window PIN is random', () {
      expect(make(policy: _fixedPolicy, pin: '042042').currentPin, '042042');
      final seen = <String>{};
      for (var i = 0; i < 40; i++) {
        final g = make();
        expect(g.currentPin, matches(RegExp(r'^[0-9]{6}$')));
        seen.add(g.currentPin!);
      }
      // 40 uniform draws from 10^6 collide with probability < 0.1 %: this fails a constant PIN.
      expect(seen.length, greaterThan(35));
    });

    test(
      'a malformed fixed PIN is refused at construction without echoing it',
      () {
        for (final bad in ['12345', '1234567', 'abcdef', '12 456', '']) {
          Object? thrown;
          try {
            make(policy: _fixedPolicy, pin: bad);
          } on Object catch (e) {
            thrown = e;
          }
          expect(thrown, isNotNull, reason: 'accepted malformed PIN');
          if (bad.isNotEmpty) {
            expect('$thrown', isNot(contains(bad)));
          }
        }
      },
    );

    test(
      'correct PIN is accepted; no PIN is PIN_REQUIRED; wrong is PIN_INVALID',
      () {
        final g = make();
        expect(right(g, '10.0.0.1'), isNull);
        final none = _thrown(
          () => g.check(remoteAddress: '10.0.0.1', pin: null, exempt: false),
        );
        expect(none?.code, LsErrorCode.pinRequired);
        expect(none?.httpStatus, 401);
        final bad = _thrown(
          () => g.check(
            remoteAddress: '10.0.0.1',
            pin: _wrongPinFor(g.currentPin!),
            exempt: false,
          ),
        );
        expect(bad?.code, LsErrorCode.pinInvalid);
        expect(bad?.httpStatus, 401);
      },
    );

    test('a request without a PIN is never a strike (the sender asks only after PIN_REQUIRED)', () {
      final g = make();
      for (var i = 0; i < 30; i++) {
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.1', pin: null, exempt: false),
          )?.code,
          LsErrorCode.pinRequired,
        );
      }
      // Still not blocked after 30 PIN-less requests, from that IP or globally.
      expect(right(g, '10.0.0.1'), isNull);
      expect(bruteForce, 0);
    });
  });

  // ---- LSP-1 5.2: wrong, expired and consumed PINs answer identically ---------------------
  group('no oracle: wrong, expired and consumed PINs look the same (5.2)', () {
    test('same code, status, retryable flag and message', () {
      final wrongG = make();
      final wrongErr = _thrown(
        () => wrongG.check(
          remoteAddress: '10.0.0.1',
          pin: _wrongPinFor(wrongG.currentPin!),
          exempt: false,
        ),
      )!;

      final expiredG = make(pinTtl: const Duration(minutes: 5));
      final expiredPin = expiredG.currentPin!;
      clock.advance(const Duration(minutes: 5) + _ms);
      final expiredErr = _thrown(
        () => expiredG.check(
          remoteAddress: '10.0.0.2',
          pin: expiredPin,
          exempt: false,
        ),
      )!;

      final onceG = make(
        policy: const PinPolicy(mode: PinMode.window, oneTime: true),
      );
      final oncePin = onceG.currentPin!;
      expect(right(onceG, '10.0.0.3'), isNull);
      onceG.consume();
      final usedErr = _thrown(
        () =>
            onceG.check(remoteAddress: '10.0.0.4', pin: oncePin, exempt: false),
      )!;

      for (final e in [expiredErr, usedErr]) {
        expect(e.code, wrongErr.code);
        expect(e.httpStatus, wrongErr.httpStatus);
        expect(e.retryable, wrongErr.retryable);
        expect(e.message, wrongErr.message);
        expect(e.toEnvelope(), wrongErr.toEnvelope());
      }
      expect(wrongErr.code, LsErrorCode.pinInvalid);
    });

    test('an expired PIN counts as a strike like any wrong PIN', () {
      final g = make(pinTtl: const Duration(minutes: 5));
      final pin = g.currentPin!;
      clock.advance(const Duration(minutes: 5) + _ms);
      for (var i = 0; i < 4; i++) {
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.9', pin: pin, exempt: false),
          )?.code,
          LsErrorCode.pinInvalid,
        );
      }
      // SPEC-GAP: the 5th may already answer BLOCKED. The IP is blocked right after it either way.
      expect(
        _thrown(
          () => g.check(remoteAddress: '10.0.0.9', pin: pin, exempt: false),
        )?.code,
        anyOf(LsErrorCode.pinInvalid, LsErrorCode.blocked),
      );
      expect(
        _thrown(
          () =>
              g.check(remoteAddress: '10.0.0.9', pin: '555555', exempt: false),
        )?.code,
        LsErrorCode.blocked,
      );
      // Twin: 4 expired strikes alone do not block.
      final h = make(pinTtl: const Duration(minutes: 5));
      final hp = h.currentPin!;
      clock.advance(const Duration(minutes: 6));
      for (var i = 0; i < 4; i++) {
        _thrown(
          () => h.check(remoteAddress: '10.0.0.8', pin: hp, exempt: false),
        );
      }
      expect(
        _thrown(
          () =>
              h.check(remoteAddress: '10.0.0.8', pin: '555555', exempt: false),
        )?.code,
        LsErrorCode.pinInvalid,
      );
    });
  });

  // ---- TTL (window mode) ------------------------------------------------------------------
  group('PIN lifetime (D5: optional TTL for window PINs)', () {
    test(
      'valid up to the TTL, invalid after it, rotate() restarts the TTL',
      () {
        const ttl = Duration(minutes: 5);
        final g = make(pinTtl: ttl);
        final first = g.currentPin!;
        clock.advance(ttl - _ms);
        expect(right(g, '10.0.0.1'), isNull, reason: 'one ms before expiry');
        clock.advance(const Duration(milliseconds: 2));
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.2', pin: first, exempt: false),
          )?.code,
          LsErrorCode.pinInvalid,
          reason: 'one ms after expiry',
        );
        g.rotate();
        final second = g.currentPin!;
        clock.advance(ttl - _ms);
        expect(
          _thrown(
            () =>
                g.check(remoteAddress: '10.0.0.3', pin: second, exempt: false),
          ),
          isNull,
          reason: 'TTL restarted by rotate()',
        );
      },
    );

    test('without a TTL a PIN never expires', () {
      final g = make();
      clock.advance(const Duration(days: 30));
      expect(right(g, '10.0.0.1'), isNull);
    });
  });

  // ---- LSP-1 5.2: 5 failures per IP in 10 min ---------------------------------------------
  group('per-IP throttle: 5 failures in 10 minutes (5.2)', () {
    test('4 failures do not block (correct PIN still accepted); 5 do, even for the correct PIN', () {
      final four = make();
      for (var i = 0; i < 4; i++) {
        expect(
          wrong(four, '10.0.0.1'),
          LsErrorCode.pinInvalid,
          reason: 'strike ${i + 1}',
        );
      }
      expect(
        right(four, '10.0.0.1'),
        isNull,
        reason: '4 strikes must not block',
      );

      final five = make();
      for (var i = 0; i < 4; i++) {
        expect(wrong(five, '10.0.0.1'), LsErrorCode.pinInvalid);
      }
      // SPEC-GAP: whether the 5th wrong PIN is itself answered PIN_INVALID or already BLOCKED.
      expect(
        wrong(five, '10.0.0.1'),
        anyOf(LsErrorCode.pinInvalid, LsErrorCode.blocked),
      );
      final e = _thrown(
        () => five.check(
          remoteAddress: '10.0.0.1',
          pin: five.currentPin,
          exempt: false,
        ),
      );
      expect(e?.code, LsErrorCode.blocked);
      expect(e?.httpStatus, 403);
      expect(e?.retryable, isFalse);
    });

    test('a success is never a strike: 4 failures, 20 successes, then 1 failure still does not block', () {
      final g = make();
      for (var i = 0; i < 4; i++) {
        wrong(g, '10.0.0.1');
      }
      for (var i = 0; i < 20; i++) {
        expect(right(g, '10.0.0.1'), isNull, reason: 'success $i');
      }
      expect(
        wrong(g, '10.0.0.1'),
        anyOf(LsErrorCode.pinInvalid, LsErrorCode.blocked),
      );
      // 5 strikes in total (4 + 1): blocked now. If successes had counted, the 5th/6th success
      // above would already have been refused.
      expect(right(g, '10.0.0.1'), LsErrorCode.blocked);
    });

    test(
      'block lasts 10 minutes: refused one ms before, accepted again after',
      () {
        final g = make();
        for (var i = 0; i < 5; i++) {
          wrong(g, '10.0.0.1');
        }
        clock.advance(_tenMinutes - _ms);
        expect(right(g, '10.0.0.1'), LsErrorCode.blocked);
      },
    );

    test('block is lifted after 10 minutes', () {
      final g = make();
      for (var i = 0; i < 5; i++) {
        wrong(g, '10.0.0.1');
      }
      clock.advance(_tenMinutes + _ms);
      expect(right(g, '10.0.0.1'), isNull);
    });

    test('failures older than 10 minutes expire from the window', () {
      final g = make();
      for (var i = 0; i < 4; i++) {
        wrong(g, '10.0.0.1');
      }
      clock.advance(_tenMinutes + _ms);
      expect(
        wrong(g, '10.0.0.1'),
        LsErrorCode.pinInvalid,
        reason: 'the 5th is the first in a new window',
      );
      expect(right(g, '10.0.0.1'), isNull);
    });

    test('4 failures still inside the window plus a 5th block', () {
      final g = make();
      for (var i = 0; i < 4; i++) {
        wrong(g, '10.0.0.1');
        clock.advance(const Duration(minutes: 2));
      }
      // first failure is 8 min old, the last 2 min old: all inside 10 min
      wrong(g, '10.0.0.1');
      expect(right(g, '10.0.0.1'), LsErrorCode.blocked);
    });

    test('a blocked IP does not affect another IP', () {
      final g = make();
      for (var i = 0; i < 5; i++) {
        wrong(g, '10.0.0.1');
      }
      expect(right(g, '10.0.0.1'), LsErrorCode.blocked);
      expect(right(g, '10.0.0.2'), isNull);
    });

    test('strikes are counted per IP: 4 + 4 from two IPs block neither', () {
      final g = make();
      for (var i = 0; i < 4; i++) {
        wrong(g, '10.0.0.1');
        wrong(g, '10.0.0.2');
      }
      expect(right(g, '10.0.0.1'), isNull);
      expect(right(g, '10.0.0.2'), isNull);
      expect(bruteForce, 0);
    });

    test('a blocked request carries no PIN hint: PIN_REQUIRED does not leak while blocked either', () {
      final g = make();
      for (var i = 0; i < 5; i++) {
        wrong(g, '10.0.0.1');
      }
      final e = _thrown(
        () => g.check(remoteAddress: '10.0.0.1', pin: null, exempt: false),
      );
      // SPEC-GAP: the order of block vs PIN_REQUIRED for a PIN-less request from a blocked IP.
      // Safer reading: the block wins (the IP learns nothing and cannot probe).
      expect(e?.code, LsErrorCode.blocked);
    });
  });

  // ---- LSP-1 5.2: 25 failures from all IPs -> lock + rotate -------------------------------
  group('global throttle: 25 failures in 10 minutes lock the PIN and rotate it (5.2)', () {
    void failFromManyIps(PinGuard g, int n) {
      for (var i = 0; i < n; i++) {
        wrong(g, '10.1.${i ~/ 200}.${i % 200 + 1}');
      }
    }

    test(
      '24 failures from 24 IPs: no lock, no callback, correct PIN accepted',
      () {
        final g = make();
        final pin = g.currentPin!;
        failFromManyIps(g, 24);
        expect(bruteForce, 0);
        expect(right(g, '10.9.9.9'), isNull);
        expect(
          g.currentPin,
          pin,
          reason: 'must not rotate below the threshold',
        );
      },
    );

    test('the 25th failure locks PIN checks, rotates the PIN and calls onBruteForce once', () {
      final g = make();
      final old = g.currentPin!;
      failFromManyIps(g, 25);
      expect(bruteForce, 1);
      expect(g.currentPin, isNot(old));
      expect(g.currentPin, matches(RegExp(r'^[0-9]{6}$')));
      // Locked: even the NEW correct PIN from a fresh IP gets BLOCKED (403).
      final e = _thrown(
        () => g.check(
          remoteAddress: '10.9.9.9',
          pin: g.currentPin,
          exempt: false,
        ),
      );
      expect(e?.code, LsErrorCode.blocked);
      expect(e?.httpStatus, 403);
      // The old PIN does not work either.
      expect(
        _thrown(
          () => g.check(remoteAddress: '10.9.9.8', pin: old, exempt: false),
        )?.code,
        LsErrorCode.blocked,
      );
      expect(
        bruteForce,
        1,
        reason: 'refused checks while locked are not new triggers',
      );
    });

    test('a lock is not triggered by 12 failures + 12 successes + 1 failure (successes never count)', () {
      final g = make();
      failFromManyIps(g, 12);
      for (var i = 0; i < 12; i++) {
        expect(right(g, '10.2.0.${i + 1}'), isNull);
      }
      failFromManyIps(g, 1);
      expect(bruteForce, 0);
      expect(right(g, '10.9.9.9'), isNull);
    });

    test('lock still holds one ms before 10 minutes are over', () {
      final g = make();
      failFromManyIps(g, 25);
      final fresh = g.currentPin!;
      clock.advance(_tenMinutes - _ms);
      expect(
        _thrown(
          () => g.check(remoteAddress: '10.9.9.9', pin: fresh, exempt: false),
        )?.code,
        LsErrorCode.blocked,
      );
    });

    test(
      'lock ends after 10 minutes: the rotated PIN works, the old one does not',
      () {
        final g = make();
        final old = g.currentPin!;
        failFromManyIps(g, 25);
        final fresh = g.currentPin!;
        clock.advance(_tenMinutes + _ms);
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.9.9.7', pin: old, exempt: false),
          )?.code,
          LsErrorCode.pinInvalid,
          reason: 'the old PIN is dead after rotation',
        );
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.9.9.6', pin: fresh, exempt: false),
          ),
          isNull,
        );
      },
    );

    test('failures older than 10 minutes do not add up to a lock', () {
      final g = make();
      failFromManyIps(g, 20);
      clock.advance(_tenMinutes + _ms);
      failFromManyIps(g, 20);
      expect(bruteForce, 0);
      expect(right(g, '10.9.9.9'), isNull);
    });

    test(
      'a second trigger after the lock expired calls onBruteForce again',
      () {
        final g = make();
        failFromManyIps(g, 25);
        clock.advance(_tenMinutes + const Duration(seconds: 1));
        failFromManyIps(g, 25);
        expect(bruteForce, 2);
      },
    );

    test('a fixed PIN is rotated too', () {
      final g = make(policy: _fixedPolicy, pin: '424242');
      failFromManyIps(g, 25);
      expect(bruteForce, 1);
      expect(g.currentPin, isNot('424242'));
    });

    test(
      'onBruteForce may throw: the guard stays consistent (locked, rotated)',
      () {
        var calls = 0;
        final g = PinGuard(
          policy: _windowPolicy,
          clock: clock,
          onBruteForce: () {
            calls++;
            throw StateError('listener bug');
          },
        );
        final old = g.currentPin!;
        for (var i = 0; i < 25; i++) {
          try {
            g.check(
              remoteAddress: '10.3.0.${i + 1}',
              pin: _wrongPinFor(g.currentPin!),
              exempt: false,
            );
          } on LsException {
            // expected refusals
          } on StateError {
            fail('a throwing onBruteForce callback must not escape check()');
          }
        }
        expect(calls, 1);
        expect(g.currentPin, isNot(old));
      },
    );
  });

  // ---- rotate() -------------------------------------------------------------------------
  group('rotate()', () {
    test('changes the PIN to a different 6-digit value; the old one is PIN_INVALID', () {
      final g = make();
      final old = g.currentPin!;
      g.rotate();
      final fresh = g.currentPin!;
      expect(fresh, matches(RegExp(r'^[0-9]{6}$')));
      expect(fresh, isNot(old));
      expect(
        _thrown(
          () => g.check(remoteAddress: '10.0.0.1', pin: old, exempt: false),
        )?.code,
        LsErrorCode.pinInvalid,
      );
      expect(right(g, '10.0.0.2'), isNull);
    });

    test('50 rotations give 50 well-formed PINs, nearly all distinct', () {
      final g = make();
      final seen = <String>{};
      for (var i = 0; i < 50; i++) {
        g.rotate();
        expect(g.currentPin, matches(RegExp(r'^[0-9]{6}$')));
        seen.add(g.currentPin!);
      }
      expect(seen.length, greaterThan(45));
    });
  });

  // ---- oneTime --------------------------------------------------------------------------
  group('one-time PINs (consume)', () {
    test('without oneTime, consume() changes nothing', () {
      final g = make();
      final pin = g.currentPin!;
      expect(right(g, '10.0.0.1'), isNull);
      g.consume();
      expect(g.currentPin, pin);
      expect(right(g, '10.0.0.2'), isNull);
    });

    test(
      'with oneTime, the PIN works until consume(), then it is PIN_INVALID',
      () {
        final g = make(
          policy: const PinPolicy(mode: PinMode.window, oneTime: true),
        );
        final pin = g.currentPin!;
        expect(right(g, '10.0.0.1'), isNull);
        expect(
          right(g, '10.0.0.1'),
          isNull,
          reason: 'check() alone must not consume: the receiver consumes after it authorised a session',
        );
        g.consume();
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.2', pin: pin, exempt: false),
          )?.code,
          LsErrorCode.pinInvalid,
        );
        expect(
          g.enforced,
          isTrue,
          reason: 'consuming must not switch the PIN requirement off',
        );
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.2', pin: null, exempt: false),
          )?.code,
          LsErrorCode.pinRequired,
        );
      },
    );

    test('a consumed PIN counts as a strike', () {
      final g = make(
        policy: const PinPolicy(mode: PinMode.window, oneTime: true),
      );
      final pin = g.currentPin!;
      g.consume();
      for (var i = 0; i < 4; i++) {
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.1', pin: pin, exempt: false),
          )?.code,
          LsErrorCode.pinInvalid,
        );
      }
      // SPEC-GAP: the 5th may already answer BLOCKED. The IP is blocked right after it either way.
      expect(
        _thrown(
          () => g.check(remoteAddress: '10.0.0.1', pin: pin, exempt: false),
        )?.code,
        anyOf(LsErrorCode.pinInvalid, LsErrorCode.blocked),
      );
      expect(
        _thrown(
          () =>
              g.check(remoteAddress: '10.0.0.1', pin: '555555', exempt: false),
        )?.code,
        LsErrorCode.blocked,
      );
    });

    test('rotate() after consumption makes the new PIN usable once more', () {
      final g = make(
        policy: const PinPolicy(mode: PinMode.window, oneTime: true),
      );
      g.consume();
      g.rotate();
      expect(right(g, '10.0.0.1'), isNull);
    });
  });

  // ---- exempt contacts --------------------------------------------------------------------
  group('exempt contacts (5.2: trusted contacts are exempt by default)', () {
    test('exempt: no PIN, wrong PIN and correct PIN are all accepted', () {
      final g = make();
      for (final pin in [null, '999999', g.currentPin]) {
        expect(
          _thrown(
            () => g.check(remoteAddress: '10.0.0.1', pin: pin, exempt: true),
          ),
          isNull,
        );
      }
    });

    test('exempt requests are never strikes (and not counted globally)', () {
      final g = make();
      for (var i = 0; i < 10; i++) {
        // one IP: would be blocked after 5 if exempt requests counted
        g.check(remoteAddress: '10.4.0.1', pin: '${100000 + i}', exempt: true);
      }
      for (var i = 0; i < 40; i++) {
        // many IPs: would lock the PIN after 25 if exempt requests counted globally
        g.check(
          remoteAddress: '10.4.1.${i + 1}',
          pin: '${100000 + i}',
          exempt: true,
        );
      }
      expect(bruteForce, 0);
      // Same IP as the exempt wrong-PIN requests: still not blocked, and the first real strike is a plain PIN_INVALID.
      expect(wrong(g, '10.4.0.1'), LsErrorCode.pinInvalid);
      expect(right(g, '10.4.0.1'), isNull);
    });

    test('exempt does not consume a one-time PIN', () {
      final g = make(
        policy: const PinPolicy(mode: PinMode.window, oneTime: true),
      );
      g.check(remoteAddress: '10.0.0.1', pin: null, exempt: true);
      expect(right(g, '10.0.0.2'), isNull);
    });

    test('not exempt (policy.exemptContacts false is applied by the receiver): PIN needed', () {
      final g = make(
        policy: const PinPolicy(mode: PinMode.window, exemptContacts: false),
      );
      expect(
        _thrown(
          () => g.check(remoteAddress: '10.0.0.1', pin: null, exempt: false),
        )?.code,
        LsErrorCode.pinRequired,
      );
    });
  });

  // ---- hygiene ----------------------------------------------------------------------------
  group('the PIN never appears in logs, exceptions or toString (5.2)', () {
    test(
      'nothing is logged or thrown with the PIN in it, through every code path',
      () async {
        final logs = P3LogCapture();
        addTearDown(logs.close);
        final texts = <String>[];
        final g = make(
          policy: const PinPolicy(mode: PinMode.window, oneTime: true),
        );
        final pin = g.currentPin!;
        const guesses = ['135790', '246810', '111222'];

        void run(String ip, String? p, {bool exempt = false}) {
          final e = _thrown(
            () => g.check(remoteAddress: ip, pin: p, exempt: exempt),
          );
          if (e != null) texts.addAll([e.message, '$e', '${e.toEnvelope()}']);
        }

        run('10.0.0.1', null);
        for (final guess in guesses) {
          run('10.0.0.1', guess);
        }
        run('10.0.0.1', pin);
        g.consume();
        run('10.0.0.2', pin); // consumed
        for (var i = 0; i < 6; i++) {
          run('10.0.0.3', guesses[i % 3]); // block this IP
        }
        run('10.0.0.3', g.currentPin); // blocked
        for (var i = 0; i < 25; i++) {
          run('10.5.0.${i + 1}', guesses[i % 3]); // global lock
        }
        final after = g.currentPin!;
        run('10.9.9.9', after); // locked
        run('10.9.9.9', pin, exempt: true);
        g.rotate();
        texts.add('$g');

        final secrets = {pin, after, ...guesses, g.currentPin!};
        final blob = '${texts.join('\n')}\n${logs.all}';
        for (final s in secrets) {
          expect(blob, isNot(contains(s)), reason: 'a PIN leaked');
        }
        // Twin: the capture works and the blob contains the control sentinel.
        Logger('p3.test').info('sentinel-$pin');
        expect(logs.all, contains('sentinel-$pin'));
      },
    );

    test('a malformed fixed PIN neither lands in the exception text nor in the log', () {
      final logs = P3LogCapture();
      addTearDown(logs.close);
      Object? thrown;
      try {
        make(policy: _fixedPolicy, pin: 'zz9999');
      } on Object catch (e) {
        thrown = e;
      }
      expect(thrown, isNotNull);
      expect('$thrown${logs.all}', isNot(contains('zz9999')));
    });
  });
}

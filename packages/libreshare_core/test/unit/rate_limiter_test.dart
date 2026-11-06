import 'package:libreshare_core/src/server/rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late RateLimiter limiter;

  setUp(() {
    now = DateTime.utc(2026, 11, 3, 12);
    limiter = RateLimiter(clock: () => now);
  });

  test('defaults to 10 per minute (spec section 5)', () {
    expect(limiter.capacity, 10);
    expect(limiter.window, const Duration(minutes: 1));
  });

  test('allows a burst of capacity then rejects', () {
    for (var i = 0; i < 10; i++) {
      expect(limiter.tryAcquire('1.2.3.4'), isTrue, reason: 'request ${i + 1}');
    }
    expect(limiter.tryAcquire('1.2.3.4'), isFalse);
    expect(
      limiter.tryAcquire('1.2.3.4'),
      isFalse,
      reason: 'rejections stay rejected',
    );
  });

  test('rejected attempts consume nothing', () {
    for (var i = 0; i < 10; i++) {
      limiter.tryAcquire('ip');
    }
    for (var i = 0; i < 50; i++) {
      expect(limiter.tryAcquire('ip'), isFalse);
    }
    now = now.add(const Duration(seconds: 6)); // exactly one token
    expect(limiter.tryAcquire('ip'), isTrue);
    expect(limiter.tryAcquire('ip'), isFalse);
  });

  test('refills continuously at capacity/window (1 token per 6 s)', () {
    for (var i = 0; i < 10; i++) {
      limiter.tryAcquire('ip');
    }
    now = now.add(const Duration(seconds: 5));
    expect(limiter.tryAcquire('ip'), isFalse, reason: '5 s < 6 s');
    now = now.add(const Duration(seconds: 1));
    expect(limiter.tryAcquire('ip'), isTrue, reason: '6 s elapsed');
    expect(limiter.tryAcquire('ip'), isFalse);
    now = now.add(const Duration(seconds: 12));
    expect(limiter.tryAcquire('ip'), isTrue);
    expect(limiter.tryAcquire('ip'), isTrue);
    expect(limiter.tryAcquire('ip'), isFalse);
  });

  test(
    'a full window restores the whole burst but never more than capacity',
    () {
      for (var i = 0; i < 10; i++) {
        limiter.tryAcquire('ip');
      }
      now = now.add(const Duration(hours: 5));
      var granted = 0;
      while (limiter.tryAcquire('ip')) {
        granted++;
        if (granted > 100) break;
      }
      expect(granted, 10);
    },
  );

  test('keys are independent', () {
    for (var i = 0; i < 10; i++) {
      limiter.tryAcquire('a');
    }
    expect(limiter.tryAcquire('a'), isFalse);
    expect(limiter.tryAcquire('b'), isTrue);
  });

  test('retryAfter reports time until next token', () {
    expect(limiter.retryAfter('ip'), Duration.zero, reason: 'unknown key');
    for (var i = 0; i < 10; i++) {
      limiter.tryAcquire('ip');
    }
    expect(limiter.retryAfter('ip'), const Duration(seconds: 6));
    now = now.add(const Duration(seconds: 2));
    expect(limiter.retryAfter('ip'), const Duration(seconds: 4));
    now = now.add(const Duration(seconds: 4));
    expect(limiter.retryAfter('ip'), Duration.zero);
  });

  test('clock moving backwards does not freeze or over-grant', () {
    for (var i = 0; i < 10; i++) {
      limiter.tryAcquire('ip');
    }
    now = now.subtract(const Duration(hours: 1));
    expect(limiter.tryAcquire('ip'), isFalse);
    now = now.add(const Duration(seconds: 6));
    expect(limiter.tryAcquire('ip'), isTrue);
  });

  test('custom capacity and window', () {
    final l = RateLimiter(
      capacity: 2,
      window: const Duration(seconds: 10),
      clock: () => now,
    );
    expect(l.tryAcquire('x'), isTrue);
    expect(l.tryAcquire('x'), isTrue);
    expect(l.tryAcquire('x'), isFalse);
    now = now.add(const Duration(seconds: 5)); // 1 token per 5 s
    expect(l.tryAcquire('x'), isTrue);
    expect(l.tryAcquire('x'), isFalse);
  });

  test('reset clears one key or everything', () {
    for (var i = 0; i < 10; i++) {
      limiter.tryAcquire('a');
      limiter.tryAcquire('b');
    }
    limiter.reset('a');
    expect(limiter.tryAcquire('a'), isTrue);
    expect(limiter.tryAcquire('b'), isFalse);
    limiter.reset();
    expect(limiter.tryAcquire('b'), isTrue);
    expect(limiter.trackedKeys, 1);
  });

  test('memory is bounded by maxKeys', () {
    final l = RateLimiter(maxKeys: 100, clock: () => now);
    for (var i = 0; i < 1000; i++) {
      l.tryAcquire('ip-$i');
    }
    expect(l.trackedKeys, lessThanOrEqualTo(100));
  });

  test('idle buckets are pruned before active ones are evicted', () {
    final l = RateLimiter(maxKeys: 3, clock: () => now);
    for (var i = 0; i < 10; i++) {
      l.tryAcquire('abuser');
    }
    l.tryAcquire('idle1');
    l.tryAcquire('idle2');
    now = now.add(const Duration(minutes: 2));
    for (var i = 0; i < 10; i++) {
      l.tryAcquire('active'); // drains 'active'; triggers pruning of idle ones
    }
    l.tryAcquire('new');
    expect(l.trackedKeys, lessThanOrEqualTo(3));
    expect(
      l.tryAcquire('active'),
      isFalse,
      reason: 'recent drained bucket kept',
    );
  });

  test('rejects invalid configuration', () {
    expect(() => RateLimiter(capacity: 0), throwsArgumentError);
    expect(() => RateLimiter(window: Duration.zero), throwsArgumentError);
    expect(() => RateLimiter(maxKeys: 0), throwsArgumentError);
  });

  test('works with the real clock', () {
    final l = RateLimiter(capacity: 1);
    expect(l.tryAcquire('k'), isTrue);
    expect(l.tryAcquire('k'), isFalse);
  });
}

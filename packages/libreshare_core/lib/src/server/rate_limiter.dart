/// Per-key token-bucket limiter (spec §5: 10 `POST /sessions` per minute per
/// IP). Pure logic with an injectable time source so tests never sleep.
///
/// Note: this is the *request-rate* limiter used by `ApiServer`. The PIN
/// brute-force block (5 failures -> 10 min) lives with the security module.
library;

/// Token bucket per key: each bucket holds up to [capacity] tokens and refills
/// continuously at `capacity / window` tokens per unit time, so a quiet client
/// may burst [capacity] requests and then sustain `capacity` per [window].
class RateLimiter {
  RateLimiter({
    this.capacity = 10,
    this.window = const Duration(minutes: 1),
    DateTime Function()? clock,
    this.maxKeys = 4096,
  }) : _clock = clock ?? DateTime.now,
       _refillPerMicro = capacity / window.inMicroseconds {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be > 0');
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', 'must be positive');
    }
    if (maxKeys <= 0) {
      throw ArgumentError.value(maxKeys, 'maxKeys', 'must be > 0');
    }
  }

  /// Maximum burst size (and tokens per [window]).
  final int capacity;

  /// Time over which a drained bucket refills completely.
  final Duration window;

  /// Upper bound on tracked keys; idle buckets are pruned, then oldest dropped.
  final int maxKeys;

  final DateTime Function() _clock;
  final double _refillPerMicro;
  final Map<String, _Bucket> _buckets = {};

  /// Number of keys currently tracked (for tests / diagnostics).
  int get trackedKeys => _buckets.length;

  /// Consumes one token for [key]; returns false (and consumes nothing) when
  /// the bucket is empty.
  bool tryAcquire(String key) {
    final now = _clock();
    final bucket = _buckets.remove(key) ?? _Bucket(capacity.toDouble(), now);
    _refill(bucket, now);
    // Re-insert last so iteration order is least-recently-used first.
    _buckets[key] = bucket;
    _pruneIfNeeded(now);
    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return true;
    }
    return false;
  }

  /// How long until one token is available for [key] (zero if available now).
  Duration retryAfter(String key) {
    final bucket = _buckets[key];
    if (bucket == null) return Duration.zero;
    _refill(bucket, _clock());
    if (bucket.tokens >= 1) return Duration.zero;
    final micros = ((1 - bucket.tokens) / _refillPerMicro).ceil();
    return Duration(microseconds: micros);
  }

  /// Forgets all state (or just [key]).
  void reset([String? key]) {
    if (key == null) {
      _buckets.clear();
    } else {
      _buckets.remove(key);
    }
  }

  void _refill(_Bucket b, DateTime now) {
    final elapsed = now.difference(b.updated).inMicroseconds;
    if (elapsed > 0) {
      final t = b.tokens + elapsed * _refillPerMicro;
      b.tokens = t > capacity ? capacity.toDouble() : t;
    }
    // A clock that moved backwards must not freeze the bucket forever.
    b.updated = now;
  }

  void _pruneIfNeeded(DateTime now) {
    if (_buckets.length <= maxKeys) return;
    // 1) Buckets idle for a full window are indistinguishable from fresh ones.
    _buckets.removeWhere((_, b) => now.difference(b.updated) >= window);
    // 2) Still too many: drop least-recently-used keys.
    while (_buckets.length > maxKeys) {
      _buckets.remove(_buckets.keys.first);
    }
  }
}

class _Bucket {
  _Bucket(this.tokens, this.updated);
  double tokens;
  DateTime updated;
}

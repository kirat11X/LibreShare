/// PIN enforcement and brute-force throttling (LSP-1 5.2, docs/plans/inc3.md D5).
///
///  * A PIN is 6 decimal digits drawn uniformly and compared in constant time.
///  * A wrong, expired or already used PIN is answered identically (`PIN_INVALID`, one fixed
///    message) and counts as a strike; a missing PIN (`PIN_REQUIRED`) never does.
///  * 5 strikes from one source address inside 10 minutes block that address for 10 minutes,
///    even for the correct PIN. 25 strikes from all addresses inside 10 minutes lock PIN checks
///    for 10 minutes and rotate the PIN.
///  * State lives in memory only; a restart clears it.
///
/// The PIN never appears in an exception, a log line or [toString].
library;

import 'dart:convert';
import 'dart:math';

import '../clock.dart';
import '../model/ls_exception.dart';
import 'contracts.dart';
import 'crypto_primitives.dart';

const int kPinDigits = 6;
const int kPinMaxStrikesPerIp = 5;
const int kPinMaxStrikesGlobal = 25;
const Duration kPinThrottleWindow = Duration(minutes: 10);

/// Upper bound on tracked source addresses (memory bound against many-source floods).
const int _kMaxTrackedIps = 1024;

final RegExp _pinFormat = RegExp(r'^[0-9]{6}$');

class PinGuard implements PinVerifier {
  /// [pin] is the PIN to use for a fixed/window policy (null = generate one); a malformed one
  /// throws [ArgumentError] (without the value). [pinTtl] makes a PIN expire that long after it
  /// was set or rotated. [onBruteForce] runs once each time the global lock triggers.
  PinGuard({
    this.policy = const PinPolicy.off(),
    String? pin,
    this.pinTtl,
    this.clock = const SystemClock(),
    this.onBruteForce,
  }) {
    if (!policy.enabled) return;
    if (pin != null && !_pinFormat.hasMatch(pin)) {
      throw ArgumentError('PIN must be $kPinDigits digits');
    }
    _pin = pin ?? _randomPin();
    _setAt = clock.now();
  }

  final PinPolicy policy;
  final Duration? pinTtl;
  final Clock clock;
  final void Function()? onBruteForce;

  static final Random _rng = Random.secure();

  String? _pin;
  DateTime _setAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _consumed = false;

  /// Strike times per source address (insertion order = least recently struck first).
  final Map<String, List<DateTime>> _strikes = {};
  final Map<String, DateTime> _blockedUntil = {};
  final List<DateTime> _globalStrikes = [];
  DateTime? _lockedUntil;

  static String _randomPin() =>
      _rng.nextInt(1000000).toString().padLeft(kPinDigits, '0');

  @override
  bool get enforced => policy.enabled;

  /// The PIN to show the user; null when the policy is off.
  String? get currentPin => _pin;

  /// Replaces the PIN with a fresh random one (different from the old), restarts its TTL and
  /// makes it usable again.
  void rotate() {
    if (!enforced) return;
    String next;
    do {
      next = _randomPin();
    } while (next == _pin);
    _pin = next;
    _setAt = clock.now();
    _consumed = false;
  }

  @override
  void consume() {
    if (enforced && policy.oneTime) _consumed = true;
  }

  @override
  void check({
    required String remoteAddress,
    required String? pin,
    required bool exempt,
  }) {
    if (!enforced || exempt) return;
    final now = clock.now();

    // Blocks win over everything else: even the correct PIN is refused.
    final lock = _lockedUntil;
    if (lock != null && now.isBefore(lock)) _throwBlocked(lock.difference(now));
    final blocked = _blockedUntil[remoteAddress];
    if (blocked != null) {
      if (now.isBefore(blocked)) _throwBlocked(blocked.difference(now));
      _blockedUntil.remove(remoteAddress);
    }

    if (pin == null) {
      throw LsException(LsErrorCode.pinRequired, 'PIN required');
    }

    final ttl = pinTtl;
    final expired = ttl != null && now.difference(_setAt) > ttl;
    // Evaluate every term so timing does not depend on which condition failed.
    final matches = constantTimeEquals(utf8.encode(pin), utf8.encode(_pin!));
    if (matches && !expired && !_consumed) return;

    _recordStrike(remoteAddress, now);
    throw LsException(LsErrorCode.pinInvalid, 'PIN not accepted');
  }

  void _recordStrike(String ip, DateTime now) {
    final list = _strikes.remove(ip) ?? <DateTime>[];
    list.removeWhere((t) => now.difference(t) > kPinThrottleWindow);
    list.add(now);
    _strikes[ip] = list;
    if (list.length >= kPinMaxStrikesPerIp) {
      _blockedUntil[ip] = now.add(kPinThrottleWindow);
    }
    _prune(now);

    _globalStrikes.removeWhere((t) => now.difference(t) > kPinThrottleWindow);
    _globalStrikes.add(now);
    if (_globalStrikes.length >= kPinMaxStrikesGlobal) {
      _globalStrikes.clear();
      _lockedUntil = now.add(kPinThrottleWindow);
      rotate();
      try {
        onBruteForce?.call();
      } on Object {
        // A faulty observer must not change the answer to the caller.
      }
    }
  }

  void _prune(DateTime now) {
    if (_strikes.length <= _kMaxTrackedIps) return;
    _blockedUntil.removeWhere((_, until) => !now.isBefore(until));
    _strikes.removeWhere(
      (ip, list) =>
          !_blockedUntil.containsKey(ip) &&
          list.every((t) => now.difference(t) > kPinThrottleWindow),
    );
    // Still too many: drop the least recently struck addresses that are not blocked.
    for (final ip in _strikes.keys.toList()) {
      if (_strikes.length <= _kMaxTrackedIps) break;
      if (!_blockedUntil.containsKey(ip)) _strikes.remove(ip);
    }
  }

  static Never _throwBlocked(Duration remaining) =>
      throw LsException(LsErrorCode.blocked, 'Too many attempts', remaining);

  @override
  String toString() => 'PinGuard(enforced: $enforced)';
}

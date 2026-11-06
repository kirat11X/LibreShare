/// Android `WifiManager.MulticastLock` (spec section 15, CLAUDE.md gotcha:
/// "hold MulticastLock while discovering").
///
/// Without the lock the Wi-Fi chip drops inbound multicast to save power, so
/// UDP announcements on 224.0.0.168:53318 are never received. Increment 2 is
/// foreground-only on Android (design 01 section 4.3, fallback 2): acquire when
/// the app starts discovering or receiving, release when it stops; the Kotlin
/// side also releases everything when the activity goes away.
///
/// UNVERIFIED: there is no Android SDK on the dev box, so neither this class
/// nor the Kotlin counterpart (`MulticastLockChannel.kt`) has been run.
library;

import 'package:flutter/services.dart';

import '../platform_log.dart';
import '../platform_services.dart';

/// Method channel shared with `MulticastLockChannel.kt`.
const String kMulticastLockChannel = 'dev.libreshare/multicast_lock';

class AndroidMulticastLock implements MulticastLockService {
  AndroidMulticastLock({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kMulticastLockChannel);

  static const PlatformLog _log = PlatformLog('multicast-lock');

  final MethodChannel _channel;
  int _held = 0;

  /// How many acquires are outstanding (the native lock is released at 0).
  int get holders => _held;

  @override
  Future<void> acquire() async {
    _held++;
    try {
      await _channel.invokeMethod<void>('acquire');
    } on PlatformException catch (e) {
      // e.g. SecurityException when CHANGE_WIFI_MULTICAST_STATE is missing.
      _held--;
      _log.warning('cannot acquire the multicast lock: ${e.code}', e.message);
    } on MissingPluginException {
      _held--;
      _log.warning('multicast lock channel not registered');
    }
  }

  @override
  Future<void> release() async {
    if (_held == 0) return; // Unbalanced release: ignore.
    _held--;
    try {
      await _channel.invokeMethod<void>('release');
    } on PlatformException catch (e) {
      _log.warning('cannot release the multicast lock: ${e.code}', e.message);
    } on MissingPluginException {
      _log.warning('multicast lock channel not registered');
    }
  }
}

/// Every other platform: nothing to hold.
class NoopMulticastLock implements MulticastLockService {
  const NoopMulticastLock();

  @override
  Future<void> acquire() async {}

  @override
  Future<void> release() async {}
}

/// Is there something on this desktop that can show a tray icon?
///
/// Windows and macOS always have a notification area. On Linux the icon is a
/// StatusNotifierItem and needs a *host* on the session bus: KDE Plasma and
/// most other desktops have one; GNOME only with the "AppIndicator and
/// KStatusNotifierItem Support" extension (Ubuntu enables it, Fedora does not -
/// design 01 section 2.2). Without a host the tray would silently show nothing,
/// so the app must fall back to "close button minimizes".
library;

import 'dart:async';

import 'package:dbus/dbus.dart';

import '../platform_log.dart';

abstract interface class TrayHostProbe {
  /// Whether a tray host is present *right now*. Never throws.
  Future<bool> isHostPresent();

  /// `true` when presence can change at runtime (GNOME extension toggled, shell
  /// restarted) and the tray service should poll.
  bool get needsPolling;

  Future<void> dispose();
}

/// Windows / macOS: the shell always provides a notification area.
class AlwaysPresentTrayHost implements TrayHostProbe {
  const AlwaysPresentTrayHost();

  @override
  Future<bool> isHostPresent() async => true;

  @override
  bool get needsPolling => false;

  @override
  Future<void> dispose() async {}
}

/// `NameHasOwner(name)` on the session bus; injectable for tests.
typedef DBusNameCheck = Future<bool> Function(String busName);

class LinuxTrayHostProbe implements TrayHostProbe {
  /// [nameHasOwner] replaces the real session-bus call in tests;
  /// [watcherNames] are the bus names the tray plugin registers with (it tries
  /// both, see nativeapi `tray_icon_linux.cpp`).
  LinuxTrayHostProbe({
    this._nameHasOwner,
    this.watcherNames = const [
      'org.kde.StatusNotifierWatcher',
      'com.canonical.StatusNotifierWatcher',
    ],
    this.timeout = const Duration(seconds: 3),
  });

  static const PlatformLog _log = PlatformLog('tray-probe');

  final List<String> watcherNames;
  final Duration timeout;
  final DBusNameCheck? _nameHasOwner;
  DBusClient? _client;
  bool _warned = false;

  @override
  bool get needsPolling => true;

  @override
  Future<bool> isHostPresent() async {
    try {
      for (final name in watcherNames) {
        if (await (_nameHasOwner ?? _sessionBusNameHasOwner)(name)) {
          return true;
        }
      }
      return false;
    } on Object catch (e) {
      // No session bus (SSH, CI, container) or it hung: treat as "no tray".
      if (!_warned) {
        _warned = true;
        _log.info('cannot query the session bus; assuming no tray host', e);
      }
      await _dropClient();
      return false;
    }
  }

  Future<bool> _sessionBusNameHasOwner(String name) {
    final client = _client ??= DBusClient.session();
    return client.nameHasOwner(name).timeout(timeout);
  }

  Future<void> _dropClient() async {
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        await client.close().timeout(timeout);
      } on Object {
        // The connection was already dead.
      }
    }
  }

  @override
  Future<void> dispose() => _dropClient();
}

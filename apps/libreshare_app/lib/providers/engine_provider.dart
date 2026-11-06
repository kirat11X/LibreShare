/// Creates, starts and disposes the [LibreShareEngine].
///
/// The engine's identity (name), download folder and preferred port are fixed
/// at construction, so changing one of them in Settings rebuilds the engine;
/// the Receive mode that was active is re-entered afterwards.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import '../platform/platform_services.dart';
import '../services/device_identity.dart';
import '../services/paths.dart';
import 'platform_providers.dart';
import 'settings_provider.dart';

/// Knobs that production leaves alone and tests turn (in-memory multicast,
/// loopback bind address, short timeouts, a manual scheduler).
class EngineTuning {
  const EngineTuning({
    this.bindAddress,
    this.enableRateLimit = true,
    this.discovery,
    this.permissionTimeout = kPermissionTimeout,
    this.scheduler,
    this.initialMode = const ReceiveOff(),
    this.allowInsecurePeers = false,
  });

  final InternetAddress? bindAddress;
  final bool enableRateLimit;

  /// Replaces the default `DiscoveryConfig(mdns: services.mdns)`.
  final DiscoveryConfig? discovery;
  final Duration permissionTimeout;
  final ReceiveScheduler? scheduler;

  /// Entered on a first run only; later runs restore what was stored.
  final ReceiveMode initialMode;
  final bool allowInsecurePeers;
}

final engineTuningProvider = Provider<EngineTuning>(
  (ref) => const EngineTuning(),
);

/// Bumped (a plain counter, no secret) after the fixed PIN was rewritten while
/// the mode was already Fixed: the engine reads the PIN at construction, so it
/// is rebuilt to enforce the new one.
class PinRevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final pinRevisionProvider = NotifierProvider<PinRevisionNotifier, int>(
  PinRevisionNotifier.new,
);

/// A fixed PIN is exactly six digits; anything else stored is unusable.
final RegExp _sixDigits = RegExp(r'^[0-9]{6}$');

/// Everything one build() created, so a superseded build releases only its
/// own resources. [close] is idempotent.
class _BuildResources {
  LibreShareEngine? engine;
  SecurityWiring? security;
  MulticastLockService? lock;
  bool lockHeld = false;
}

class EngineNotifier extends AsyncNotifier<LibreShareEngine> {
  _BuildResources? _res;
  int _buildSeq = 0;
  Future<void> _closing = Future<void>.value();
  ReceiveMode? _resumeMode;

  /// The stored fixed PIN, or null when it is missing, unreadable or not six
  /// digits (the caller then falls back to a temporary window PIN).
  Future<String?> _readFixedPin(Directory securityDir) async {
    try {
      final bytes = await FileSecretStore(securityDir).get('app-pin');
      if (bytes == null) return null;
      final pin = utf8.decode(bytes);
      return _sixDigits.hasMatch(pin) ? pin : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<LibreShareEngine> build() async {
    // Name, folder, port and pinMode are baked into the engine: a change rebuilds it.
    final settings = ref.watch(
      settingsProvider.select(
        (s) => (
          alias: s.alias,
          downloadDir: s.downloadDir,
          preferredPort: s.preferredPort,
          pinMode: s.pinMode,
        ),
      ),
    );
    ref.watch(pinRevisionProvider);
    // Only a suggestion for a first run (the stored identity wins), so a
    // change of it does not rebuild the engine.
    final suggestedId = ref.read(settingsProvider).deviceId;
    final downloadDir = ref.watch(downloadDirProvider);
    final services = ref.read(platformServicesProvider);
    final tuning = ref.read(engineTuningProvider);
    final dirs = ref.read(appDirsProvider);
    final clock = ref.read(clockProvider);

    // `ref.mounted` stays true across a rebuild: a token tells a superseded
    // build from the current one.
    final token = ++_buildSeq;
    bool superseded() => token != _buildSeq || !ref.mounted;
    final res = _BuildResources();
    _res = res;
    ref.onDispose(() {
      _closing = _closeResources(res);
    });
    await _closing; // the previous engine must release its port first
    if (superseded()) throw StateError('engine start superseded');

    final securityDir = Directory(joinPath(dirs.supportDir.path, 'security'));
    var policy = PinPolicy(mode: settings.pinMode);
    String? fixedPin;
    if (settings.pinMode == PinMode.fixed) {
      fixedPin = await _readFixedPin(securityDir);
      // No usable stored PIN: a temporary window PIN for this run (shown on
      // the Receive card) instead of a failed start; Settings asks for a new one.
      if (fixedPin == null) policy = const PinPolicy(mode: PinMode.window);
      if (superseded()) throw StateError('engine start superseded');
    }

    final SecurityWiring security;
    try {
      security = await SecurityWiring.open(
        directory: securityDir,
        deviceId: suggestedId,
        pinPolicy: policy,
        pin: fixedPin,
        allowInsecurePeers: tuning.allowInsecurePeers,
      );
    } on Object {
      await _closeResources(res);
      rethrow;
    }
    res.security = security;
    if (superseded()) {
      await _closeResources(res);
      throw StateError('engine start superseded');
    }

    final storedDeviceId = security.identity.identity.deviceId;
    // Settings follow the stored identity id; a failing save must not
    // surface as an uncaught error (log the type only).
    if (storedDeviceId != suggestedId && !superseded()) {
      unawaited(
        ref
            .read(settingsProvider.notifier)
            .setDeviceId(storedDeviceId)
            .catchError((Object e) {
              debugPrint('device id not saved: ${e.runtimeType}');
            }),
      );
    }

    final engine = LibreShareEngine(
      self: DeviceInfo(
        deviceId: storedDeviceId,
        alias: settings.alias,
        platform: currentPlatformName(),
        deviceType: currentDeviceType(),
      ),
      downloadDir: downloadDir,
      preferredPort: settings.preferredPort,
      // Consent is always required in this build (spec section 5).
      autoAccept: false,
      bindAddress: tuning.bindAddress,
      enableRateLimit: tuning.enableRateLimit,
      clock: clock,
      permissionTimeout: tuning.permissionTimeout,
      discovery: tuning.discovery ?? DiscoveryConfig(mdns: services.mdns),
      receiveConfig: ReceiveConfig(
        // Nothing listens until the user turns Receive on.
        initialMode: tuning.initialMode,
        store: FileReceiveSettingsStore(dirs.supportDir),
        env: services.environment.events,
        caps: services.caps,
        scheduler: tuning.scheduler,
      ),
      security: security,
    );
    res.engine = engine;
    // Android: multicast is filtered unless the lock is held while discovering.
    res.lock = services.multicastLock;
    try {
      await services.multicastLock.acquire();
      res.lockHeld = true;
    } on Object {
      res.lockHeld = false;
    }
    if (superseded()) {
      await _closeResources(res);
      throw StateError('engine start superseded');
    }
    try {
      await engine.start();
    } on Object {
      // A restored mode that cannot bind leaves a usable engine in
      // Failed(...); any other failure is fatal for this build().
      if (!engine.isStarted) {
        await _closeResources(res);
        rethrow;
      }
    }
    if (superseded()) {
      await _closeResources(res);
      throw StateError('engine start superseded');
    }
    final resume = _resumeMode;
    _resumeMode = null;
    if (resume != null && engine.receive.state is Off) {
      try {
        await engine.receive.turnOn(resume);
      } on Object {
        // shown as Failed(...) by the Receive card
      }
    }
    return engine;
  }

  /// Completes when the engine that was running has been shut down (after
  /// the provider was disposed or restarted).
  Future<void> get closed => _closing;

  /// Stops and disposes the running engine (app exit, tests). Idempotent.
  Future<void> shutdown() {
    final res = _res;
    return _closing = res == null ? _closing : _closeResources(res);
  }

  Future<void> _closeResources(_BuildResources res) async {
    final engine = res.engine;
    res.engine = null;
    if (engine != null) {
      final receive = engine.receive;
      if (receive.isReceiving) _resumeMode = receive.lastMode;
      try {
        await engine.dispose();
      } on Object {
        // already closed
      }
    }
    final sec = res.security;
    res.security = null;
    if (sec != null) {
      try {
        await sec.close();
      } on Object {
        // best effort
      }
    }
    if (res.lockHeld) {
      res.lockHeld = false;
      try {
        await res.lock?.release();
      } on Object {
        // best effort
      }
    }
  }
}

final engineProvider = AsyncNotifierProvider<EngineNotifier, LibreShareEngine>(
  EngineNotifier.new,
);

/// The running engine, or null while it is (re)starting or failed.
final engineOrNullProvider = Provider<LibreShareEngine?>((ref) {
  final a = ref.watch(engineProvider);
  if (a.isLoading || a.hasError) return null;
  return a.value;
});

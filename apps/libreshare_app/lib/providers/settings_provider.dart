/// App-level settings (name, download folder, preferred port) and the device
/// identity. Receive-mode settings are the core's and live in
/// `receive_provider.dart`.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart' hide sanitizeAlias;

import '../services/app_settings_store.dart';
import '../services/device_identity.dart';
import 'platform_providers.dart';

/// Loaded before `runApp` (tests override with a prepared value).
final initialAppSettingsProvider = Provider<AppSettings>(
  (ref) => throw StateError('initialAppSettingsProvider must be overridden'),
);

final appSettingsStoreProvider = Provider<AppSettingsStore>(
  (ref) => AppSettingsStore(ref.watch(appDirsProvider).supportDir),
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.watch(initialAppSettingsProvider);

  Future<void> setAlias(String alias) async {
    final clean = sanitizeAlias(alias);
    if (clean == state.alias) return;
    state = state.copyWith(alias: clean);
    await _save();
  }

  /// `null` returns to the default folder.
  Future<void> setDownloadDir(String? path) async {
    if (path == null || path.trim().isEmpty) {
      state = state.copyWith(clearDownloadDir: true);
    } else {
      if (path == state.downloadDir) return;
      state = state.copyWith(downloadDir: path);
    }
    await _save();
  }

  Future<void> setPreferredPort(int port) async {
    if (port < 0 || port > 65535 || port == state.preferredPort) return;
    state = state.copyWith(preferredPort: port);
    await _save();
  }

  Future<void> setDeviceId(String deviceId) async {
    if (deviceId == state.deviceId) return;
    state = state.copyWith(deviceId: deviceId);
    await _save();
  }

  Future<void> setPinMode(PinMode mode) async {
    if (mode == state.pinMode) return;
    final previous = state;
    state = state.copyWith(pinMode: mode);
    try {
      await _save();
    } on Object {
      // Not persisted: the mode must not stay changed in memory either.
      if (ref.mounted && state.pinMode == mode) {
        state = state.copyWith(pinMode: previous.pinMode);
      }
      rethrow;
    }
  }

  /// Remembers that the first-Receive storage question was answered.
  Future<void> markStorageAsked() async {
    if (state.storageAsked) return;
    state = state.copyWith(storageAsked: true);
    await _save();
  }

  /// Sets hardware-accelerated SHA-256 (Option 2).
  Future<void> setHardwareHashing(bool enabled) async {
    if (enabled == state.hardwareHashingEnabled) return;
    state = state.copyWith(hardwareHashingEnabled: enabled);
    await _save();
  }

  /// Sets the transfer speed of sends from this device. Running sends keep
  /// their mode; the engine follows the new one for the next send. The mode
  /// is stored first, so a state change means it is on disk.
  Future<void> setSpeedMode(SpeedMode mode) async {
    if (mode == state.speedMode) return;
    await ref
        .read(appSettingsStoreProvider)
        .save(state.copyWith(speedMode: mode));
    state = state.copyWith(speedMode: mode);
  }

  Future<void> _save() => ref.read(appSettingsStoreProvider).save(state);
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(
  SettingsNotifier.new,
);

/// The folder received files go to: the chosen one or the default.
final downloadDirProvider = Provider<Directory>((ref) {
  final chosen = ref.watch(settingsProvider.select((s) => s.downloadDir));
  return chosen == null
      ? ref.watch(appDirsProvider).defaultDownloadDir
      : Directory(chosen);
});

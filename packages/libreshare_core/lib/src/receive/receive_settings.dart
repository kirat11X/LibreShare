/// Persisted Receive-mode data (design 01 section 1.5): the user's settings and
/// the last runtime record used for crash recovery. JSON round-trip is total:
/// unknown members are ignored and a member of the wrong type falls back to
/// its default, so a damaged or newer file can never throw.
library;

import 'receive_state.dart';

/// User-visible Receive settings.
class ReceiveSettings {
  const ReceiveSettings({
    this.defaultMode = const ReceiveAlways(),
    this.visibility = ReceiveVisibility.everyone,
    this.autostart = false,
    this.startHidden = true,
    this.androidWindow = const Duration(hours: 6),
    this.receiveOnBoot = false,
  });

  /// What `turnOn()` without an argument means (never [ReceiveOff]).
  final ReceiveMode defaultMode;
  final ReceiveVisibility visibility;

  /// Start the app when the user signs in (opt-in, design 01 D3/D5). The host
  /// acts on it; the core only stores it.
  final bool autostart;
  final bool startHidden;

  /// Android's app-level receive window.
  final Duration androidWindow;
  final bool receiveOnBoot;

  ReceiveSettings copyWith({
    ReceiveMode? defaultMode,
    ReceiveVisibility? visibility,
    bool? autostart,
    bool? startHidden,
    Duration? androidWindow,
    bool? receiveOnBoot,
  }) => ReceiveSettings(
    defaultMode: defaultMode ?? this.defaultMode,
    visibility: visibility ?? this.visibility,
    autostart: autostart ?? this.autostart,
    startHidden: startHidden ?? this.startHidden,
    androidWindow: androidWindow ?? this.androidWindow,
    receiveOnBoot: receiveOnBoot ?? this.receiveOnBoot,
  );

  Map<String, Object?> toJson() => {
    'defaultMode': modeToJson(defaultMode),
    'visibility': visibility.name,
    'autostart': autostart,
    'startHidden': startHidden,
    'androidWindowMinutes': androidWindow.inMinutes,
    'receiveOnBoot': receiveOnBoot,
  };

  factory ReceiveSettings.fromJson(Map<String, Object?> j) {
    const d = ReceiveSettings();
    final mode = modeFromJson(j['defaultMode']);
    final minutes = j['androidWindowMinutes'];
    return ReceiveSettings(
      defaultMode: mode == null || mode is ReceiveOff ? d.defaultMode : mode,
      visibility:
          ReceiveVisibility.values.asNameMap()[j['visibility']] ?? d.visibility,
      autostart: j['autostart'] is bool ? j['autostart']! as bool : d.autostart,
      startHidden: j['startHidden'] is bool
          ? j['startHidden']! as bool
          : d.startHidden,
      androidWindow: minutes is int && minutes > 0 && minutes <= 7 * 24 * 60
          ? Duration(minutes: minutes)
          : d.androidWindow,
      receiveOnBoot: j['receiveOnBoot'] is bool
          ? j['receiveOnBoot']! as bool
          : d.receiveOnBoot,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReceiveSettings &&
      other.defaultMode == defaultMode &&
      other.visibility == visibility &&
      other.autostart == autostart &&
      other.startHidden == startHidden &&
      other.androidWindow == androidWindow &&
      other.receiveOnBoot == receiveOnBoot;

  @override
  int get hashCode => Object.hash(
    defaultMode,
    visibility,
    autostart,
    startHidden,
    androidWindow,
    receiveOnBoot,
  );

  @override
  String toString() => 'ReceiveSettings(${toJson()})';
}

/// The `runtime` record: what the controller was doing when it last wrote.
class ReceiveRuntime {
  const ReceiveRuntime({
    this.state = ReceiveRuntimeState.off,
    this.offReason = OffReason.neverEnabled,
    this.pauseReason,
    this.mode,
    this.until,
    this.cleanStop = true,
  });

  final ReceiveRuntimeState state;
  final OffReason offReason;
  final PauseReason? pauseReason;

  /// The mode last requested (what `resume()` re-uses).
  final ReceiveMode? mode;

  /// Wall-clock end of the window, if any.
  final DateTime? until;

  /// `false` from entering On until a clean exit; a record that is still
  /// `on`/`paused` with `cleanStop == false` therefore means the process died.
  final bool cleanStop;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'offReason': offReason.name,
    'pauseReason': pauseReason?.name,
    'mode': mode == null ? null : modeToJson(mode!),
    'until': until?.toUtc().toIso8601String(),
    'cleanStop': cleanStop,
  };

  factory ReceiveRuntime.fromJson(Map<String, Object?> j) {
    final untilRaw = j['until'];
    return ReceiveRuntime(
      state:
          ReceiveRuntimeState.values.asNameMap()[j['state']] ??
          ReceiveRuntimeState.off,
      offReason:
          OffReason.values.asNameMap()[j['offReason']] ??
          OffReason.neverEnabled,
      pauseReason: PauseReason.values.asNameMap()[j['pauseReason']],
      mode: modeFromJson(j['mode']),
      until: untilRaw is String ? DateTime.tryParse(untilRaw)?.toUtc() : null,
      cleanStop: j['cleanStop'] is bool ? j['cleanStop']! as bool : true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReceiveRuntime &&
      other.state == state &&
      other.offReason == offReason &&
      other.pauseReason == pauseReason &&
      other.mode == mode &&
      other.until == until &&
      other.cleanStop == cleanStop;

  @override
  int get hashCode =>
      Object.hash(state, offReason, pauseReason, mode, until, cleanStop);

  @override
  String toString() => 'ReceiveRuntime(${toJson()})';
}

enum ReceiveRuntimeState { off, on, paused }

/// Everything stored in `receive_settings.json`.
class ReceivePersisted {
  const ReceivePersisted({
    this.settings = const ReceiveSettings(),
    this.runtime = const ReceiveRuntime(),
  });

  final ReceiveSettings settings;
  final ReceiveRuntime runtime;

  /// File format version.
  static const int version = 1;

  Map<String, Object?> toJson() => {
    'v': version,
    ...settings.toJson(),
    'runtime': runtime.toJson(),
  };

  factory ReceivePersisted.fromJson(Map<String, Object?> j) {
    final rt = j['runtime'];
    return ReceivePersisted(
      settings: ReceiveSettings.fromJson(j),
      runtime: rt is Map
          ? ReceiveRuntime.fromJson(rt.cast<String, Object?>())
          : const ReceiveRuntime(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReceivePersisted &&
      other.settings == settings &&
      other.runtime == runtime;

  @override
  int get hashCode => Object.hash(settings, runtime);
}

/// `{"kind":"off"|"always"|"for","minutes":N}` (a window is stored in seconds
/// when it is not a whole number of minutes).
Map<String, Object?> modeToJson(ReceiveMode m) => switch (m) {
  ReceiveOff() => {'kind': 'off'},
  ReceiveAlways() => {'kind': 'always'},
  ReceiveFor(:final duration) => {'kind': 'for', 'seconds': duration.inSeconds},
};

/// Inverse of [modeToJson]; null for anything unrecognised.
ReceiveMode? modeFromJson(Object? raw) {
  if (raw is! Map) return null;
  switch (raw['kind']) {
    case 'off':
      return const ReceiveOff();
    case 'always':
      return const ReceiveAlways();
    case 'for':
      final s = raw['seconds'];
      final m = raw['minutes'];
      final seconds = s is int ? s : (m is int ? m * 60 : null);
      if (seconds == null || seconds <= 0 || seconds > 366 * 24 * 3600) {
        return null;
      }
      return ReceiveFor(Duration(seconds: seconds));
  }
  return null;
}

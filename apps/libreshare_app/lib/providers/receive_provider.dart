/// Receive mode as the UI sees it: the state stream, the persisted settings
/// and the actions (on/off, durations, visibility, resume).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'engine_provider.dart';
import 'platform_providers.dart';

/// Current [ReceiveState] and every change. `Starting` while the engine
/// itself is (re)starting.
final receiveStateProvider = StreamProvider<ReceiveState>((ref) {
  final engine = ref.watch(engineOrNullProvider);
  if (engine == null) return Stream.value(const Starting());
  final out = StreamController<ReceiveState>();
  final sub = engine.receive.states.listen(out.add);
  out.add(engine.receive.state);
  ref.onDispose(() {
    unawaited(sub.cancel());
    unawaited(out.close());
  });
  return out.stream;
});

/// The state as a plain value.
final receiveStatusProvider = Provider<ReceiveState>(
  (ref) => ref.watch(receiveStateProvider).value ?? const Starting(),
);

/// Persisted Receive settings. The core offers no change stream for them, so
/// every change goes through [update].
class ReceiveSettingsNotifier extends Notifier<ReceiveSettings> {
  @override
  ReceiveSettings build() {
    final engine = ref.watch(engineOrNullProvider);
    return engine?.receive.settings ?? const ReceiveSettings();
  }

  Future<void> update(ReceiveSettings settings) async {
    final engine = ref.read(engineOrNullProvider);
    if (engine == null) return;
    await engine.receive.updateSettings(settings);
    if (ref.mounted) state = engine.receive.settings;
  }
}

final receiveSettingsProvider =
    NotifierProvider<ReceiveSettingsNotifier, ReceiveSettings>(
      ReceiveSettingsNotifier.new,
    );

/// The quick-duration choices for this OS: 15 min, 1 h, 6 h and Always, minus
/// whatever the platform cap rules out (Android: no "Always", nothing above
/// 6 h).
final receiveChoicesProvider = Provider<List<ReceiveMode>>((ref) {
  final cap = ref.watch(platformServicesProvider).caps.maxContinuous;
  const windows = [
    Duration(minutes: 15),
    Duration(hours: 1),
    Duration(hours: 6),
  ];
  return [
    for (final w in windows)
      if (cap == null || w <= cap) ReceiveFor(w),
    if (cap == null) const ReceiveAlways(),
  ];
});

/// The choice to highlight: the saved default mode, folded into what this
/// platform offers ("Always" on Android becomes its longest window).
final selectedReceiveChoiceProvider = Provider<ReceiveMode>((ref) {
  final choices = ref.watch(receiveChoicesProvider);
  final mode = ref.watch(receiveSettingsProvider.select((s) => s.defaultMode));
  if (choices.contains(mode)) return mode;
  final cap = ref.watch(platformServicesProvider).caps.maxContinuous;
  if (mode is ReceiveAlways && cap != null) {
    final inRange = choices.whereType<ReceiveFor>().toList();
    if (inRange.isNotEmpty) return inRange.last;
  }
  return choices.last;
});

class ReceiveActions {
  ReceiveActions(this._ref);

  final Ref _ref;

  LibreShareEngine? get _engine => _ref.read(engineOrNullProvider);

  /// Switch on (with the saved default mode) or off.
  Future<void> setEnabled(bool on) async {
    final engine = await _ref.read(engineProvider.future);
    if (on) {
      if (engine.pinGuard?.policy.mode == PinMode.window) {
        engine.pinGuard?.rotate();
      }
      // No argument: the controller applies its own saved default mode (and
      // the platform cap), in order after any settings change just made.
      await engine.receive.turnOn();
    } else {
      await engine.receive.turnOff();
    }
  }

  /// Picks a duration. It becomes the default; while receiving it also
  /// re-arms the window ("extend").
  Future<void> choose(ReceiveMode mode) async {
    final engine = _engine;
    if (engine == null) return;
    final settings = _ref.read(receiveSettingsProvider);
    await _ref
        .read(receiveSettingsProvider.notifier)
        .update(settings.copyWith(defaultMode: mode));
    if (engine.receive.isReceiving) await engine.receive.turnOn(mode);
  }

  /// "Resume": a fresh window of the last mode (Paused / Off(expired)).
  Future<void> resume() async {
    final engine = _engine;
    if (engine?.pinGuard?.policy.mode == PinMode.window) {
      engine?.pinGuard?.rotate();
    }
    await engine?.receive.resume();
  }

  Future<void> setVisibility(ReceiveVisibility visibility) async {
    final engine = _engine;
    if (engine == null) return;
    final settings = _ref.read(receiveSettingsProvider);
    await _ref
        .read(receiveSettingsProvider.notifier)
        .update(settings.copyWith(visibility: visibility));
  }

  Future<void> setStartHidden(bool value) async {
    final settings = _ref.read(receiveSettingsProvider);
    await _ref
        .read(receiveSettingsProvider.notifier)
        .update(settings.copyWith(startHidden: value));
  }

  /// Tray "Receive" item: flips between receiving and not.
  Future<void> toggle() async {
    final engine = _engine;
    if (engine == null) return;
    await setEnabled(!engine.receive.isReceiving);
  }
}

final receiveActionsProvider = Provider<ReceiveActions>(ReceiveActions.new);

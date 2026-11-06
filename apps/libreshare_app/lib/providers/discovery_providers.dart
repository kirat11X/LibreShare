/// The device list and the "scan the network" action.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'engine_provider.dart';

/// Devices around right now, in first-seen order (never this device).
final devicesProvider = StreamProvider<List<DiscoveredDevice>>((ref) {
  final engine = ref.watch(engineOrNullProvider);
  if (engine == null) return Stream.value(const <DiscoveredDevice>[]);
  return engine.devices;
});

/// The list as a plain value (empty while loading).
final deviceListProvider = Provider<List<DiscoveredDevice>>(
  (ref) => ref.watch(devicesProvider).value ?? const <DiscoveredDevice>[],
);

class ScanState {
  const ScanState({this.scanning = false, this.lastCount, this.failed = false});

  final bool scanning;

  /// Devices listed when the last scan finished.
  final int? lastCount;
  final bool failed;
}

class ScanNotifier extends Notifier<ScanState> {
  @override
  ScanState build() => const ScanState();

  /// Announces again and sweeps the local /24 (`engine.refresh`).
  Future<void> scan() async {
    if (state.scanning) return;
    final engine = ref.read(engineOrNullProvider);
    if (engine == null) return;
    state = const ScanState(scanning: true);
    try {
      await engine.refresh();
      if (!ref.mounted) return;
      state = ScanState(lastCount: engine.currentDevices.length);
    } on Object {
      if (!ref.mounted) return;
      state = const ScanState(failed: true);
    }
  }
}

final scanProvider = NotifierProvider<ScanNotifier, ScanState>(
  ScanNotifier.new,
);

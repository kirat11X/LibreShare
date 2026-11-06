/// "Start LibreShare when I sign in": the real OS state, read from and
/// written to the platform's [AutostartService].
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/autostart/autostart_windows.dart' show WindowsAutostart;
import 'platform_providers.dart';
import 'receive_provider.dart';

class AutostartNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final service = ref.watch(platformServicesProvider).autostart;
    if (!service.isSupported) return false;
    return service.isEnabled();
  }

  /// Writes the OS entry. A real failure (e.g. the file or registry cannot
  /// be written) is rethrown after the state shows what is true now.
  Future<void> set(bool enabled) async {
    final service = ref.read(platformServicesProvider).autostart;
    if (!service.isSupported) return;
    Object? failure;
    try {
      await service.setEnabled(enabled);
    } on Object catch (e) {
      failure = e;
    }
    final actual = await service.isEnabled();
    if (!ref.mounted) return;
    state = AsyncData(actual);
    final settings = ref.read(receiveSettingsProvider);
    if (failure == null && settings.autostart != actual) {
      await ref
          .read(receiveSettingsProvider.notifier)
          .update(settings.copyWith(autostart: actual));
    }
    if (failure != null) throw failure;
  }
}

final autostartProvider = AsyncNotifierProvider<AutostartNotifier, bool>(
  AutostartNotifier.new,
);

/// Whether the platform can start the app at sign-in at all (hides the switch).
final autostartSupportedProvider = Provider<bool>(
  (ref) => ref.watch(platformServicesProvider).autostart.isSupported,
);

/// Windows: the user switched the entry off in Task Manager / Settings > Apps
/// > Startup. The Run value is still there, so the toggle alone would lie.
final autostartDisabledByOsProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(platformServicesProvider).autostart;
  // Re-read whenever the toggle changes.
  ref.watch(autostartProvider);
  if (service is WindowsAutostart) return service.isDisabledInWindowsSettings();
  return false;
});

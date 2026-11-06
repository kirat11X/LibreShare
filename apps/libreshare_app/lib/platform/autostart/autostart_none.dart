/// Platforms without a start-with-OS implementation (Android in Increment 2,
/// macOS, tests). [isSupported] is `false` so the Settings toggle is hidden.
library;

import '../platform_services.dart';

class NoAutostart implements AutostartService {
  const NoAutostart();

  @override
  bool get isSupported => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> setEnabled(bool enabled) async {}
}

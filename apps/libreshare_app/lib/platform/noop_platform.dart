/// Do-nothing adapters for platforms without a tray or window control (Android,
/// macOS in Increment 2, tests that want a real object instead of a fake).
library;

import 'platform_services.dart';

class NoopTrayService implements TrayService {
  const NoopTrayService();

  @override
  bool get isAvailable => false;

  @override
  Future<void> init({
    required void Function() onOpen,
    required void Function() onToggleReceive,
    required void Function() onQuit,
  }) async {}

  @override
  Future<void> setStatus({
    required bool receiving,
    required String tooltip,
  }) async {}

  @override
  Future<void> dispose() async {}
}

class NoopWindowController implements WindowController {
  const NoopWindowController();

  @override
  Future<void> init({required bool startHidden, required bool hasTray}) async {}

  @override
  Future<void> show() async {}

  @override
  Future<void> hide() async {}
}

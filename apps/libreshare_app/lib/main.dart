import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import 'app.dart';
import 'platform/platform_factory.dart';
import 'platform/platform_services.dart';
import 'providers/platform_providers.dart';
import 'providers/settings_provider.dart';
import 'services/app_dirs.dart';
import 'services/app_logging.dart';
import 'services/app_settings_store.dart';
import 'services/device_identity.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Core and platform-adapter records go to one place from the first line on.
  installAppLogging(level: kReleaseMode ? Level.INFO : Level.FINE);

  final services = createPlatformServices(args: args);
  // `libreshare --remove-autostart` (Windows uninstaller): do it and leave.
  if (await runLaunchCommands(services, args)) {
    exit(0);
  }

  final dirs = await resolveAppDirs();
  final settings = await AppSettingsStore(dirs.supportDir)
      .loadOrCreate(defaultAlias: await resolveDeviceAlias());

  runApp(
    ProviderScope(
      // A failing provider is shown to the user (Retry), not retried silently.
      retry: (retryCount, error) => null,
      overrides: [
        platformServicesProvider.overrideWithValue(services),
        launchArgsProvider.overrideWithValue(args),
        appDirsProvider.overrideWithValue(dirs),
        initialAppSettingsProvider.overrideWithValue(settings),
        quitHandlerProvider.overrideWithValue(() => _quit(services)),
      ],
      child: const LibreShareApp(),
    ),
  );
}

Future<void> _quit(PlatformServices services) async {
  final window = services.window;
  if (window is WindowControllerImpl) {
    await window.quit();
  } else {
    exit(0);
  }
}

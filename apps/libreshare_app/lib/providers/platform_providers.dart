/// Injection points for everything environment-specific: platform services,
/// clock, file dialogs, the "open file" launcher, the QR scanner and the
/// directories. Tests override these; `main` overrides the real ones.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../platform/platform_services.dart';
import '../services/app_dirs.dart';
import '../services/file_launcher.dart';
import '../services/file_picker_service.dart';

/// The OS adapters. Defaults to no-op fakes; `main` installs the real ones.
final platformServicesProvider = Provider<PlatformServices>(
  (ref) => PlatformServices.fake(),
);

/// Wall clock for display (countdowns, "last seen", speed). Tests install a
/// manual clock.
final clockProvider = Provider<Clock>((ref) => const SystemClock());

final appDirsProvider = Provider<AppDirs>(
  (ref) => throw StateError('appDirsProvider must be overridden'),
);

final fileLauncherProvider = Provider<FileLauncher>(
  (ref) => createFileLauncher(isAndroid: Platform.isAndroid),
);

/// Whether this really is an Android device. Not `defaultTargetPlatform`
/// (flutter_test reports Android everywhere); tests override this.
final isAndroidProvider = Provider<bool>((ref) => Platform.isAndroid);

final filePickerServiceProvider = Provider<FilePickerService>(
  (ref) => const SystemFilePickerService(),
);

/// The command line (`main`'s arguments); `--hidden` starts without showing
/// the window (auto-start).
final launchArgsProvider = Provider<List<String>>((ref) => const []);

/// Ends the app (tray "Quit"). The default stops the engine first.
final quitHandlerProvider = Provider<Future<void> Function()>(
  (ref) =>
      () async => exit(0),
);

/// Whether the camera QR scanner exists on this platform (Android and iOS
/// only; desktops paste the link instead).
final qrScanSupportedProvider = Provider<bool>(
  (ref) =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS),
);

/// Builds the camera view; [onDetect] gets the raw text of a scanned code.
typedef QrScannerBuilder = Widget Function(
  BuildContext context,
  void Function(String raw) onDetect,
);

final qrScannerBuilderProvider = Provider<QrScannerBuilder>(
  (ref) =>
      (context, onDetect) => MobileScanner(
        onDetect: (capture) {
          for (final b in capture.barcodes) {
            final raw = b.rawValue;
            if (raw != null) {
              onDetect(raw);
              return;
            }
          }
        },
      ),
);

/// Emits the current time every few seconds so relative labels ("12 s ago",
/// "5 h 12 min left") stay fresh. Disposed with the last listener.
final nowTickProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  final clock = ref.watch(clockProvider);
  yield clock.now();
  yield* Stream<DateTime>.periodic(
    const Duration(seconds: 5),
    (_) => clock.now(),
  );
});

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n_strings.dart';
import '../providers/engine_provider.dart';
import '../providers/platform_providers.dart';
import '../providers/settings_provider.dart';

enum _Answer { choose, keep }

/// The one-time question before Receive is first turned on, on Android, while
/// the download folder is still the app-private default. Returns true when
/// Receive may be turned on now.
Future<bool> askStorageIfNeeded(BuildContext context) async {
  // The engine restart below may unmount the calling widget: keep to the
  // container, which outlives it.
  final ref = ProviderScope.containerOf(context);
  final settings = ref.read(settingsProvider);
  if (!ref.read(isAndroidProvider) ||
      settings.downloadDir != null ||
      settings.storageAsked) {
    return true;
  }
  final path = ref.read(downloadDirProvider).path;
  final answer = await showDialog<_Answer>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      key: const Key('storage-prompt'),
      title: Text(tr('storage.title')),
      content: Text(tr('storage.body', {'path': path})),
      actions: [
        TextButton(
          key: const Key('storage-prompt-choose'),
          onPressed: () => Navigator.of(context).pop(_Answer.choose),
          child: Text(tr('storage.choose')),
        ),
        FilledButton(
          key: const Key('storage-prompt-keep'),
          onPressed: () => Navigator.of(context).pop(_Answer.keep),
          child: Text(tr('storage.keep')),
        ),
      ],
    ),
  );
  final settingsNotifier = ref.read(settingsProvider.notifier);
  if (answer == _Answer.choose) {
    final picked = await ref.read(filePickerServiceProvider).pickDirectory();
    if (picked != null) {
      // The folder is baked into the engine: it restarts. Wait for the new one.
      await settingsNotifier.setDownloadDir(picked);
      await Future<void>.delayed(Duration.zero);
      try {
        await ref.read(engineProvider.future);
      } on Object {
        // the Receive card shows the failure
      }
    }
  }
  await settingsNotifier.markStorageAsked();
  return true;
}

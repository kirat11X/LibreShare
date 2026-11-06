/// Where the app keeps its data: the support dir (settings, Receive-mode
/// record) and the default download folder.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'paths.dart';

class AppDirs {
  const AppDirs({required this.supportDir, required this.defaultDownloadDir});

  /// `receive_settings.json`, `app_settings.json` live here.
  final Directory supportDir;

  /// `~/Downloads/LibreShare` unless the user picked another folder.
  final Directory defaultDownloadDir;
}

/// Resolves the real directories through `path_provider`.
Future<AppDirs> resolveAppDirs() async {
  final support = await getApplicationSupportDirectory();
  Directory? downloads;
  try {
    downloads = await getDownloadsDirectory();
  } on Object {
    downloads = null;
  }
  downloads ??= await getApplicationDocumentsDirectory();
  return AppDirs(
    supportDir: support,
    defaultDownloadDir: Directory(joinPath(downloads.path, 'LibreShare')),
  );
}

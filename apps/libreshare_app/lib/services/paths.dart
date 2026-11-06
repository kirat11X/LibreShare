/// Tiny path helpers (the app does not depend on `package:path`).
library;

import 'dart:io';

/// Joins [parts] with the platform separator, without doubling separators.
String joinPath(String first, [String? second, String? third]) {
  final sep = Platform.pathSeparator;
  final parts = <String>[first, ?second, ?third];
  final buf = StringBuffer(parts.first);
  for (final part in parts.skip(1)) {
    final soFar = buf.toString();
    if (!soFar.endsWith('/') && !soFar.endsWith(r'\')) buf.write(sep);
    buf.write(
      part.startsWith('/') || part.startsWith(r'\') ? part.substring(1) : part,
    );
  }
  return buf.toString();
}

/// Directory part of [path] (handles both separators); '.' when there is none.
String parentDir(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  if (i < 0) return '.';
  if (i == 0) return path.substring(0, 1);
  return path.substring(0, i);
}

/// File name part of [path].
String baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  return i < 0 ? path : path.substring(i + 1);
}

final RegExp _publicRoot = RegExp(
  r'^(?:/storage/emulated/\d+|/storage/self/primary|/sdcard)/'
  r'(Download|Documents|Pictures|DCIM|Music|Movies)(/.*)?$',
);

/// Plain words for a folder: `Downloads/LibreShare` for folders under the
/// public shared-storage roots of Android, the path unchanged otherwise.
String describeSavedLocation(String folderPath) {
  final m = _publicRoot.firstMatch(folderPath);
  if (m == null) return folderPath;
  final top = m.group(1)! == 'Download' ? 'Downloads' : m.group(1)!;
  final rest = (m.group(2) ?? '').replaceAll(RegExp(r'/+$'), '');
  return '$top$rest';
}

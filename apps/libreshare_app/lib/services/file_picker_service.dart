/// File and folder pickers behind an interface (the native dialogs cannot run
/// in widget tests).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'paths.dart';

/// A file the user picked to send.
class PickedFile {
  const PickedFile({
    required this.path,
    required this.name,
    required this.size,
  });

  factory PickedFile.fromFile(File file) => PickedFile(
    path: file.path,
    name: baseName(file.path),
    size: file.existsSync() ? file.lengthSync() : 0,
  );

  final String path;
  final String name;
  final int size;

  File get file => File(path);

  @override
  bool operator ==(Object other) => other is PickedFile && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

abstract interface class FilePickerService {
  /// Lets the user choose one or more files; empty when cancelled.
  Future<List<PickedFile>> pickFiles();

  /// Lets the user choose a folder; null when cancelled.
  Future<String?> pickDirectory();
}

class SystemFilePickerService implements FilePickerService {
  const SystemFilePickerService();

  @override
  Future<List<PickedFile>> pickFiles() async {
    final picked = await FilePicker.pickFiles();
    final out = <PickedFile>[];
    for (final f in picked) {
      final path = f.path;
      if (path == null) continue; // not a local file (web)
      out.add(
        PickedFile(path: path, name: f.name, size: await f.length() ?? 0),
      );
    }
    return out;
  }

  @override
  Future<String?> pickDirectory() => FilePicker.getDirectoryPath();
}

/// Returns canned answers; for tests.
class FakeFilePickerService implements FilePickerService {
  FakeFilePickerService({this.files = const [], this.directory});

  List<PickedFile> files;
  String? directory;
  int pickFilesCalls = 0;

  @override
  Future<List<PickedFile>> pickFiles() async {
    pickFilesCalls++;
    return files;
  }

  @override
  Future<String?> pickDirectory() async => directory;
}

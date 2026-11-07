/// "Open" and "Show in folder" for received files, behind an interface so the
/// completion UI is testable without spawning processes.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'paths.dart';

abstract interface class FileLauncher {
  /// Opens [path] with the default application. False if it could not.
  Future<bool> open(String path);

  /// Reveals [path] in the file manager. False if it could not.
  Future<bool> showInFolder(String path);
}

/// A process to start: [executable] with [arguments] (one list element per
/// argument; Dart quotes them for the platform).
class LaunchCommand {
  const LaunchCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;
}

/// The command that opens [path] with the default application, or null when
/// [platform] (`Platform.operatingSystem`) has no process launcher.
LaunchCommand? openCommand(String path, {required String platform}) {
  switch (platform) {
    case 'linux':
      return LaunchCommand('xdg-open', [path]);
    case 'windows':
      return LaunchCommand('rundll32', [
        'url.dll,FileProtocolHandler',
        path.replaceAll('/', r'\'),
      ]);
    case 'macos':
      return LaunchCommand('open', [path]);
  }
  return null;
}

/// The command that reveals [path] in the file manager, or null.
LaunchCommand? showInFolderCommand(String path, {required String platform}) {
  switch (platform) {
    case 'linux':
      return LaunchCommand('xdg-open', [parentDir(path)]);
    case 'windows':
      return LaunchCommand('explorer.exe', [
        '/select,',
        path.replaceAll('/', r'\'),
      ]);
    case 'macos':
      return LaunchCommand('open', ['-R', path]);
  }
  return null;
}

/// Uses `xdg-open` (Linux), `rundll32`/`explorer` (Windows), `open` (macOS).
/// Android and iOS have no equivalent without a plugin: returns false and the
/// UI shows where the file is.
class SystemFileLauncher implements FileLauncher {
  const SystemFileLauncher();

  @override
  Future<bool> open(String path) =>
      _start(openCommand(path, platform: Platform.operatingSystem));

  @override
  Future<bool> showInFolder(String path) =>
      _start(showInFolderCommand(path, platform: Platform.operatingSystem));

  Future<bool> _start(LaunchCommand? cmd) async {
    if (cmd == null) return false;
    try {
      await Process.start(
        cmd.executable,
        cmd.arguments,
        mode: ProcessStartMode.detached,
      );
      return true;
    } on Object {
      return false;
    }
  }
}

/// Native channel of the Android launcher (Open / Show in folder).
const String kFileOpenerChannel = 'dev.libreshare/file_opener';

/// Android: asks the Kotlin side (FileProvider + ACTION_VIEW). Never throws;
/// any failure is "could not", and the UI then shows where the file is.
class AndroidFileLauncher implements FileLauncher {
  AndroidFileLauncher({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kFileOpenerChannel);

  final MethodChannel _channel;

  @override
  Future<bool> open(String path) => _call('open', path);

  @override
  Future<bool> showInFolder(String path) => _call('showInFolder', path);

  Future<bool> _call(String method, String path) async {
    try {
      final ok = await _channel.invokeMethod<Object?>(method, {'path': path});
      return ok == true;
    } on Object {
      return false;
    }
  }
}

/// The launcher for this platform.
FileLauncher createFileLauncher({
  required bool isAndroid,
  MethodChannel? channel,
}) => isAndroid
    ? AndroidFileLauncher(channel: channel)
    : const SystemFileLauncher();

/// Records calls; for tests.
class FakeFileLauncher implements FileLauncher {
  FakeFileLauncher({this.succeeds = true});

  final bool succeeds;
  final List<String> opened = [];
  final List<String> shown = [];

  @override
  Future<bool> open(String path) async {
    opened.add(path);
    return succeeds;
  }

  @override
  Future<bool> showInFolder(String path) async {
    shown.add(path);
    return succeeds;
  }
}

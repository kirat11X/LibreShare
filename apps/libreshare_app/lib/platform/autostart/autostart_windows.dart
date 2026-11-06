/// Windows start-at-logon via `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
/// (design 01 section 3).
///
/// Per-user (no admin), written by the app itself so it lands in the right
/// user's hive; the installer only adds firewall rules. The uninstaller runs
/// `libreshare.exe --remove-autostart` (see [kRemoveAutostartFlag]).
library;

import 'dart:io';

import '../platform_log.dart';
import '../platform_services.dart';
import 'autostart_common.dart';
import 'registry_access.dart';

class WindowsAutostart implements AutostartService, SelfHealingAutostart {
  /// [registry] is the real `Win32RegistryAccess` in production and a
  /// [FakeRegistryAccess] in tests; [executable] defaults to
  /// [Platform.resolvedExecutable].
  WindowsAutostart({required this._registry, this._executable});

  static const PlatformLog _log = PlatformLog('autostart');

  /// Name of the `Run` value.
  static const String valueName = 'LibreShare';

  static const String runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';

  /// Where Task Manager / Settings > Apps > Startup record the user's own
  /// enable/disable choice. UNVERIFIED: community reports only, no Microsoft
  /// documentation (design 01 section 3).
  static const String startupApprovedKey =
      r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

  /// Windows ignores `Run` command lines longer than 260 characters.
  static const int maxCommandLength = 260;

  final RegistryAccess _registry;
  final String? _executable;

  @override
  bool get isSupported => true;

  String get executablePath => _executable ?? Platform.resolvedExecutable;

  /// `"C:\Program Files\LibreShare\libreshare.exe" --hidden`.
  String get command => buildCommand(executablePath);

  /// Always quotes the path (spaces are normal under `Program Files`). A
  /// double quote cannot occur in a Windows path; a path that contains one is
  /// refused rather than mis-parsed.
  static String buildCommand(String executable) {
    if (executable.isEmpty || executable.contains('"')) {
      throw AutostartException('unusable executable path: $executable');
    }
    final command = '"$executable" $kHiddenFlag';
    if (command.length > maxCommandLength) {
      throw AutostartException(
        'autostart command is ${command.length} characters; Windows ignores Run entries over $maxCommandLength',
      );
    }
    return command;
  }

  @override
  Future<bool> isEnabled() async {
    try {
      final value = _registry.readString(runKey, valueName);
      if (value == null || value.isEmpty) return false;
      return !await isDisabledInWindowsSettings();
    } on Object catch (e) {
      _log.warning('cannot read the Run key', e);
      return false;
    }
  }

  /// `true` when the user switched the entry off in Task Manager or Settings >
  /// Apps > Startup: the `Run` value is still there but Windows ignores it.
  /// The UI should then say "Disabled in Windows Startup settings" and offer
  /// `ms-settings:startupapps` (UNVERIFIED URI) instead of a plain toggle.
  Future<bool> isDisabledInWindowsSettings() async {
    try {
      final bytes = _registry.readBinary(startupApprovedKey, valueName);
      // First byte: even (02, 06) = enabled, odd (03, 07) = disabled.
      return bytes != null && bytes.isNotEmpty && (bytes.first & 1) == 1;
    } on Object catch (e) {
      _log.fine('cannot read StartupApproved', e);
      return false;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    try {
      if (enabled) {
        _registry.writeString(runKey, valueName, command);
        _log.info('autostart enabled');
      } else {
        _registry.deleteValue(runKey, valueName);
        _log.info('autostart disabled');
      }
    } on AutostartException {
      rethrow;
    } on Object catch (e) {
      throw AutostartException(
        'cannot ${enabled ? 'write' : 'remove'} the Run value',
        e,
      );
    }
  }

  /// Rewrites the `Run` value when it points somewhere else (portable folder
  /// moved, reinstall into another directory). Never creates the value.
  @override
  Future<bool> selfHeal() async {
    try {
      final current = _registry.readString(runKey, valueName);
      if (current == null || current.isEmpty) return false;
      final wanted = command;
      if (current == wanted) return false;
      _registry.writeString(runKey, valueName, wanted);
      _log.info('autostart entry repaired (executable moved)');
      return true;
    } on Object catch (e) {
      _log.warning('autostart self-heal failed', e);
      return false;
    }
  }
}

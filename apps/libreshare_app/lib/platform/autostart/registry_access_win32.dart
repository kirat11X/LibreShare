/// Real registry access on Windows through `win32_registry`.
///
/// UNVERIFIED on a real Windows box (this was written on Linux; the logic above
/// it is covered by [FakeRegistryAccess] tests, and `windows-latest` CI should
/// run a round-trip, design 01 section 6).
library;

import 'dart:typed_data';

import 'package:win32_registry/win32_registry.dart' as w32;

import '../platform_log.dart';
import 'registry_access.dart';

class Win32RegistryAccess implements RegistryAccess {
  const Win32RegistryAccess();

  static const PlatformLog _log = PlatformLog('registry');

  @override
  String? readString(String keyPath, String valueName) =>
      _readKey(keyPath, (key) => key.getString(valueName));

  @override
  Uint8List? readBinary(String keyPath, String valueName) =>
      _readKey(keyPath, (key) => key.getBinary(valueName));

  T? _readKey<T>(String keyPath, T? Function(w32.RegistryKey key) read) {
    w32.RegistryKey? key;
    try {
      key = w32.CURRENT_USER.open(keyPath);
      return read(key);
    } on Object catch (e) {
      // Missing key (StartupApproved\Run often does not exist) or unreadable:
      // callers treat both as "not set".
      _log.fine('registry read of $keyPath failed', e);
      return null;
    } finally {
      if (key != null && !key.isClosed) key.close();
    }
  }

  @override
  void writeString(String keyPath, String valueName, String value) {
    final key = w32.CURRENT_USER.create(keyPath);
    try {
      key.setValue(valueName, w32.RegistryValue.string(value));
    } finally {
      key.close();
    }
  }

  @override
  bool deleteValue(String keyPath, String valueName) {
    w32.RegistryKey key;
    try {
      key = w32.CURRENT_USER.open(
        keyPath,
        config: const w32.RegistryOpenConfig(
          access: w32.RegistryAccess.readWrite,
        ),
      );
    } on Object catch (e) {
      _log.fine('registry key $keyPath not openable for delete', e);
      return false;
    }
    try {
      if (key.getValue(valueName) == null) return false;
      key.removeValue(valueName);
      return true;
    } finally {
      key.close();
    }
  }
}

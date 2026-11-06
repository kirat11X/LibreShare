/// The slice of the Windows registry that [WindowsAutostart] needs, behind an
/// interface so the logic is testable on every OS (a fake here, the real
/// `win32_registry` implementation in `registry_access_win32.dart`).
///
/// Every `keyPath` is relative to `HKEY_CURRENT_USER`. Reads are best-effort
/// (`null` when the key or value is missing or unreadable); writes and deletes
/// throw on real failures (access denied, policy).
library;

import 'dart:typed_data';

abstract interface class RegistryAccess {
  String? readString(String keyPath, String valueName);
  Uint8List? readBinary(String keyPath, String valueName);

  /// Creates [keyPath] if needed and sets a `REG_SZ` value.
  void writeString(String keyPath, String valueName, String value);

  /// Removes the value; returns `false` if it did not exist.
  bool deleteValue(String keyPath, String valueName);
}

/// In-memory registry for tests (and for platforms without one).
class FakeRegistryAccess implements RegistryAccess {
  FakeRegistryAccess();

  final Map<String, Map<String, String>> strings = {};
  final Map<String, Map<String, Uint8List>> binaries = {};

  /// Set to make [writeString] / [deleteValue] throw (access denied).
  Object? failWritesWith;

  int writeCount = 0;

  static String _k(String path) => path.toLowerCase();
  static String _v(String name) => name.toLowerCase();

  @override
  String? readString(String keyPath, String valueName) =>
      strings[_k(keyPath)]?[_v(valueName)];

  @override
  Uint8List? readBinary(String keyPath, String valueName) =>
      binaries[_k(keyPath)]?[_v(valueName)];

  @override
  void writeString(String keyPath, String valueName, String value) {
    final failure = failWritesWith;
    if (failure != null) throw failure;
    writeCount++;
    (strings[_k(keyPath)] ??= {})[_v(valueName)] = value;
  }

  @override
  bool deleteValue(String keyPath, String valueName) {
    final failure = failWritesWith;
    if (failure != null) throw failure;
    return strings[_k(keyPath)]?.remove(_v(valueName)) != null;
  }

  /// Test helper: what Task Manager / Settings write into `StartupApproved`.
  void setBinary(String keyPath, String valueName, List<int> bytes) {
    (binaries[_k(keyPath)] ??= {})[_v(valueName)] = Uint8List.fromList(bytes);
  }
}

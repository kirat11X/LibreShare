/// Where Receive-mode settings live (design 01 section 1.5): one small JSON
/// file, written atomically (tmp + rename) so a crash can never leave half a
/// file. The directory is a parameter; the host decides where (no Flutter here).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../receive/receive_settings.dart';

abstract interface class ReceiveSettingsStore {
  /// Never throws: a missing, unreadable or corrupt record yields defaults.
  Future<ReceivePersisted> load();

  /// Persists [data]. Saves are applied in call order; failures are reported
  /// to the caller.
  Future<void> save(ReceivePersisted data);
}

/// In-memory store (tests, ephemeral engines).
class InMemoryReceiveSettingsStore implements ReceiveSettingsStore {
  InMemoryReceiveSettingsStore([ReceivePersisted? initial])
    : value = initial ?? const ReceivePersisted();

  ReceivePersisted value;

  /// Number of [save] calls so far.
  int saves = 0;

  @override
  Future<ReceivePersisted> load() async => value;

  @override
  Future<void> save(ReceivePersisted data) async {
    saves++;
    value = data;
  }
}

/// `<dir>/receive_settings.json`, atomic JSON.
class FileReceiveSettingsStore implements ReceiveSettingsStore {
  FileReceiveSettingsStore(this.directory, {this.fileName = fileNameDefault});

  static const String fileNameDefault = 'receive_settings.json';

  static final Logger _log = Logger('libreshare.receive.store');

  final Directory directory;
  final String fileName;

  Future<void> _tail = Future<void>.value();

  File get file => File('${directory.path}${Platform.pathSeparator}$fileName');
  File get _tmp =>
      File('${directory.path}${Platform.pathSeparator}$fileName.tmp');

  @override
  Future<ReceivePersisted> load() async {
    try {
      final f = file;
      if (!await f.exists()) return const ReceivePersisted();
      final Object? root = jsonDecode(await f.readAsString());
      if (root is! Map) return const ReceivePersisted();
      return ReceivePersisted.fromJson(root.cast<String, Object?>());
    } on Object catch (e) {
      // FormatException (corrupt), FileSystemException, bad member types...
      _log.warning('ignoring unreadable receive settings: ${e.runtimeType}');
      return const ReceivePersisted();
    }
  }

  @override
  Future<void> save(ReceivePersisted data) {
    final next = _tail.then((_) => _write(data));
    // The chain itself must survive a failed write.
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _write(ReceivePersisted data) async {
    await directory.create(recursive: true);
    final tmp = _tmp;
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data.toJson()),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

/// File-backed [SecretStore] for the CLI, Docker, tests and desktop (docs/plans/inc3.md D6).
///
/// One file per secret, written atomically (temporary file in the same
/// directory, `flush`, rename), POSIX mode 0600 on the files and 0700 on the
/// directory. Secret names are validated (`[A-Za-z0-9._/-]{1,128}`, no empty,
/// `.` or `..` segment, no leading `/`) and then mapped to a flat file name
/// (hex SHA-256 of the name plus `.secret`), so a name can never address a
/// path: `../x`, absolute paths and NUL are refused before the file system is
/// touched, and `kpair/<deviceId>` lands in the same directory as every other
/// secret.
///
/// On Windows the permission calls are a no-op: the directory is expected to
/// live in the user profile (`%APPDATA%`), whose ACL already denies other
/// users (UNVERIFIED: not run on Windows here). A same-user attacker reads
/// the files on every platform; that is the stated D6 risk.
///
/// Nothing in this file logs a secret name or value, and no exception message
/// carries one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../security/contracts.dart';
import 'atomic_file.dart';

final Logger _log = Logger('libreshare.storage.secret');

/// The secret store could not do what was asked (cannot restrict permissions,
/// cannot read, cannot write). The message never names a secret.
class SecretStoreException implements Exception {
  const SecretStoreException(this.message);
  final String message;

  @override
  String toString() => 'SecretStoreException: $message';
}

final RegExp _nameChars = RegExp(r'^[A-Za-z0-9._/-]+$');

/// True for `[A-Za-z0-9._/-]{1,128}` without a leading `/` and without an
/// empty, `.` or `..` segment.
bool isValidSecretName(String name) {
  if (name.isEmpty || name.length > 128) return false;
  if (!_nameChars.hasMatch(name)) return false;
  for (final segment in name.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

void _requireName(String name) {
  // Deliberately no value in the message: names are not logged.
  if (!isValidSecretName(name)) throw ArgumentError('invalid secret name');
}

void _requireSize(int length) {
  if (length > FileSecretStore.maxValueBytes) {
    throw ArgumentError('secret value too large');
  }
}

/// Runs `chmod <mode> <path>` and returns the exit code. Injectable for tests.
typedef ChmodRunner = Future<int> Function(String mode, String path);

Future<int> _systemChmod(String mode, String path) async {
  final r = await Process.run('chmod', [mode, path]);
  return r.exitCode;
}

/// Writes [data] to `<target>.tmp`, flushes, then renames over [target]: a
/// crash leaves either the old file or the new one, never half of it. A stale
/// `.tmp` from an earlier crash is overwritten and never read. [prepareTmp]
/// runs on the (still empty) temporary file before any byte is written, which
/// is where permissions are applied so content is never briefly world-readable.
/// Delegates to [atomicWriteBytes] (writers to one target are serialised).
@internal
Future<void> writeFileAtomically(
  File target,
  List<int> data, {
  Future<void> Function(File tmp)? prepareTmp,
}) async {
  await atomicWriteBytes(target, data, prepareTmp: prepareTmp);
}

// File framing: "LSS1" | u32be length | payload | SHA-256(everything before).
// Atomic rename already prevents torn writes; the frame makes truncation,
// bit rot or a foreign file detectable, so such a file reads as "no secret".
const List<int> _magic = [0x4C, 0x53, 0x53, 0x31];
const int _headerLength = 8;
const int _digestLength = 32;

Uint8List _frame(Uint8List value) {
  final out = Uint8List(_headerLength + value.length + _digestLength);
  out.setRange(0, 4, _magic);
  ByteData.sublistView(out).setUint32(4, value.length);
  out.setRange(_headerLength, _headerLength + value.length, value);
  final digest = sha256.convert(out.sublist(0, _headerLength + value.length));
  out.setRange(_headerLength + value.length, out.length, digest.bytes);
  return out;
}

Uint8List? _unframe(Uint8List raw) {
  if (raw.length < _headerLength + _digestLength) return null;
  for (var i = 0; i < 4; i++) {
    if (raw[i] != _magic[i]) return null;
  }
  final length = ByteData.sublistView(raw).getUint32(4);
  if (length > FileSecretStore.maxValueBytes) return null;
  if (raw.length != _headerLength + length + _digestLength) return null;
  final body = raw.sublist(0, _headerLength + length);
  final digest = sha256.convert(body).bytes;
  var diff = 0;
  for (var i = 0; i < _digestLength; i++) {
    diff |= digest[i] ^ raw[_headerLength + length + i];
  }
  if (diff != 0) return null;
  return Uint8List.fromList(raw.sublist(_headerLength, _headerLength + length));
}

class FileSecretStore implements SecretStore {
  /// [directory] should be dedicated to secrets: it is created if missing and
  /// set to 0700 on the first write. [chmod] is for tests (see [ChmodRunner]).
  FileSecretStore(this.directory, {ChmodRunner? chmod})
    : _chmod = chmod ?? _systemChmod;

  /// Largest value accepted (a PKCS#8 key is about 250 bytes, K_pair 32).
  static const int maxValueBytes = 64 * 1024;

  final Directory directory;
  final ChmodRunner _chmod;

  Future<void> _tail = Future<void>.value();
  bool _directorySecured = false;

  /// The file that holds [name] (validates the name). Exposed for tests.
  @visibleForTesting
  File fileFor(String name) {
    _requireName(name);
    final hash = sha256.convert(utf8.encode(name)).toString();
    return File('${directory.path}${Platform.pathSeparator}$hash.secret');
  }

  /// All operations run one after another in call order; a failed one does not
  /// stop the queue.
  Future<T> _serial<T>(Future<T> Function() op) {
    final next = _tail.then((_) => op());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<Uint8List?> get(String name) async {
    final file = fileFor(name);
    return _serial(() async {
      try {
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) return null;
        if (type != FileSystemEntityType.file) {
          _log.warning('secret slot is not a regular file; treated as empty');
          return null;
        }
        final length = await file.length();
        if (length > maxValueBytes + _headerLength + _digestLength) {
          _log.warning('secret file has an impossible size; treated as empty');
          return null;
        }
        final value = _unframe(await file.readAsBytes());
        if (value == null) {
          _log.warning('secret file is corrupt; treated as empty');
        }
        return value;
      } on PathNotFoundException {
        return null;
      } on FileSystemException catch (e) {
        _log.warning('secret file unreadable: ${e.runtimeType}');
        throw const SecretStoreException('secret store is not readable');
      }
    });
  }

  @override
  Future<void> put(String name, Uint8List value) async {
    final file = fileFor(name);
    _requireSize(value.length);
    final framed = _frame(
      value,
    ); // copies: later changes to [value] do not matter
    return _serial(() async {
      try {
        await _ensureDirectory();
        await writeFileAtomically(
          file,
          framed,
          prepareTmp: (tmp) => _restrict('600', tmp.path),
        );
      } on SecretStoreException {
        rethrow;
      } on FileSystemException catch (e) {
        _log.warning('secret write failed: ${e.runtimeType}');
        throw const SecretStoreException('secret store is not writable');
      }
    });
  }

  @override
  Future<void> delete(String name) async {
    final file = fileFor(name);
    return _serial(() async {
      for (final f in [file, File('${file.path}.tmp')]) {
        try {
          await f.delete();
        } on PathNotFoundException {
          // already gone
        } on FileSystemException catch (e) {
          _log.warning('secret delete failed: ${e.runtimeType}');
          throw const SecretStoreException('secret store is not writable');
        }
      }
    });
  }

  Future<void> _ensureDirectory() async {
    if (_directorySecured && await directory.exists()) return;
    await directory.create(recursive: true);
    await _restrict('700', directory.path);
    _directorySecured = true;
  }

  /// Fails closed: a secret is never stored with permissions we could not set.
  Future<void> _restrict(String mode, String path) async {
    if (Platform.isWindows) return; // profile ACL; documented above
    int code;
    try {
      code = await _chmod(mode, File(path).absolute.path);
    } on ProcessException catch (e) {
      _log.warning('chmod unavailable: ${e.runtimeType}');
      throw const SecretStoreException('cannot restrict file permissions');
    }
    if (code != 0) {
      throw const SecretStoreException('cannot restrict file permissions');
    }
  }
}

/// Keeps secrets in memory (tests, ephemeral engines). Same name rules and
/// size limit as [FileSecretStore]; values are copied in and out.
class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, List<int>>? initial]) {
    initial?.forEach((name, value) {
      _requireName(name);
      _requireSize(value.length);
      _data[name] = Uint8List.fromList(value);
    });
  }

  final Map<String, Uint8List> _data = {};

  /// Number of stored secrets.
  int get length => _data.length;

  /// Names currently stored (for test assertions only).
  Iterable<String> get names => List.unmodifiable(_data.keys);

  @override
  Future<Uint8List?> get(String name) async {
    _requireName(name);
    final v = _data[name];
    return v == null ? null : Uint8List.fromList(v);
  }

  @override
  Future<void> put(String name, Uint8List value) async {
    _requireName(name);
    _requireSize(value.length);
    _data[name] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String name) async {
    _requireName(name);
    _data.remove(name);
  }
}

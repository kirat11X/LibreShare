/// Shared atomic-replace helper (E5 / R1b).
///
/// Contract: after a call the target holds exactly the new bytes or, on any
/// failure, exactly the OLD bytes; no temporary or backup file is left behind.
/// The old file is never deleted before the new one is committed: where the
/// OS refuses to rename onto an existing file (Windows), the old file is moved
/// aside, the new one renamed in, and the old one restored if that fails.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Performs one rename. Tests set [atomicRenameOverride] to observe or fail it.
typedef AtomicRenameFn = Future<void> Function(File from, String toPath);

/// Test seam: when set, EVERY rename done by this library goes through it.
AtomicRenameFn? atomicRenameOverride;

Future<void> _rename(File from, String toPath) {
  final hook = atomicRenameOverride;
  return hook != null ? hook(from, toPath) : from.rename(toPath);
}

final Map<String, Future<void>> _queues = {};

/// Errors for which moving the old file aside cannot help (the data cannot
/// be moved to the target's directory / disk is full): rethrown at once.
bool _isHopeless(FileSystemException e) {
  final code = e.osError?.errorCode;
  if (code == null) return false;
  return Platform.isWindows
      ? (code == 17 || code == 112 || code == 39) // NOT_SAME_DEVICE, DISK_FULL
      : (code == 18 || code == 28 || code == 30 || code == 122);
  // POSIX: EXDEV, ENOSPC, EROFS, EDQUOT (not EIO 5: tests simulate it)
}

File _bakOf(File target) => File('${target.path}.bak');

final Random _rng = Random();

/// A backup name next to [target] that no existing entry uses (never collides
/// with a user's own file).
File _uniqueBak(File target) {
  for (;;) {
    final f = File(
      '${target.path}.lsbak-${_rng.nextInt(1 << 32).toRadixString(16)}',
    );
    if (FileSystemEntity.typeSync(f.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return f;
    }
  }
}

void _deleteQuietly(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } on Object {
    // best effort
  }
}

/// Restores `<target>.bak` (left by an interrupted or doubly failed
/// replace-with-move-aside) to [target], but only when [target] is missing.
/// Returns whether it restored. Not wired into the stores yet.
Future<bool> recoverAtomicBackup(File target) async {
  final bak = _bakOf(target);
  if (!bak.existsSync() ||
      FileSystemEntity.typeSync(target.path) != FileSystemEntityType.notFound) {
    return false;
  }
  await _rename(bak, target.path);
  return true;
}

/// Writes [bytes] to `<target>.tmp`, flushes, then commits it over [target].
/// Writers to the same target are serialised in-process. [mode] (POSIX, e.g.
/// 0x180 for 0600) is applied to the empty temporary file before any byte is
/// written and ignored on Windows. [prepareTmp] also runs on the empty file.
Future<void> atomicWriteBytes(
  File target,
  List<int> bytes, {
  int? mode,
  Future<void> Function(File tmp)? prepareTmp,
}) {
  final key = p.normalize(p.absolute(target.path));
  final prev = _queues[key] ?? Future<void>.value();
  final run = prev.then((_) => _write(target, bytes, mode, prepareTmp));
  final tail = run.then<void>((_) {}, onError: (Object _) {});
  _queues[key] = tail;
  tail.then((_) {
    if (identical(_queues[key], tail)) _queues.remove(key);
  });
  return run;
}

Future<void> _write(
  File target,
  List<int> bytes,
  int? mode,
  Future<void> Function(File tmp)? prepareTmp,
) async {
  final tmp = File('${target.path}.tmp');
  try {
    final tmpType = FileSystemEntity.typeSync(tmp.path, followLinks: false);
    if (tmpType == FileSystemEntityType.file) {
      await tmp.delete(); // stale file from an earlier crash
    } else if (tmpType == FileSystemEntityType.link) {
      await Link(tmp.path).delete(); // never write through a link
    }
    await tmp.create();
    if (mode != null && !Platform.isWindows) {
      final r = await Process.run('chmod', [
        mode.toRadixString(8),
        tmp.absolute.path,
      ]);
      if (r.exitCode != 0) {
        throw FileSystemException('cannot set file mode', tmp.path);
      }
    }
    if (prepareTmp != null) await prepareTmp(tmp);
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await raf.writeFrom(bytes);
      await raf.flush();
    } finally {
      await raf.close();
    }
    await _replace(tmp, target, fixedBak: true);
  } on Object {
    try {
      if (tmp.existsSync()) await tmp.delete();
    } on Object {
      // best effort: the temporary file is never read anyway
    }
    rethrow;
  }
}

/// Renames [tmp] over [target]. [tmp] must exist (else [FileSystemException]
/// and [target] is untouched). On failure [target] keeps its old content and
/// [tmp] is left for the caller to clean up. Safe for user-visible
/// directories: it never reads, deletes or overwrites a file it did not
/// create (its move-aside backup has a unique `.lsbak-<hex>` name).
Future<void> atomicReplace(File tmp, File target) =>
    _replace(tmp, target, fixedBak: false);

/// [fixedBak] (app-owned files only): the backup is `<target>.bak`, a stale
/// one is removed when the target exists, and one is removed after a commit.
Future<void> _replace(File tmp, File target, {required bool fixedBak}) async {
  if (!tmp.existsSync()) {
    throw FileSystemException('temporary file is missing', tmp.path);
  }
  File? bak;
  try {
    await _rename(tmp, target.path);
  } on FileSystemException catch (first) {
    if (_isHopeless(first) ||
        FileSystemEntity.typeSync(target.path, followLinks: false) !=
            FileSystemEntityType.file) {
      rethrow;
    }
    // Windows-style refusal to replace: move the old file aside, never delete
    // it before the new one is committed.
    final b = bak = fixedBak ? _bakOf(target) : _uniqueBak(target);
    if (fixedBak) _deleteQuietly(b); // target exists, so the bak is older
    try {
      await _rename(target, b.path);
    } on Object {
      throw first; // old file is still in place
    }
    try {
      await _rename(tmp, target.path);
    } on Object {
      try {
        await _rename(b, target.path);
      } on Object {
        // double failure: the old data stays in the backup file
        // (see recoverAtomicBackup for the fixed name)
      }
      throw first;
    }
  }
  // Committed. Only a backup we made (or, for app-owned files, the fixed
  // `.bak`) is removed.
  if (bak != null) {
    _deleteQuietly(bak);
  } else if (fixedBak) {
    _deleteQuietly(_bakOf(target));
  }
}

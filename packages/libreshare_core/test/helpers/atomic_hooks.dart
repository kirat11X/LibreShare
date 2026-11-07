// Rename hooks for the E5/R1b tests (new file, test-only).
//
// The tests rely on this API of lib/src/storage/atomic_file.dart (to be
// written by the coder, see docs/plans/e-proposals/r1b/tests-plan.md):
//
//   typedef AtomicRenameFn = Future<void> Function(File from, String toPath);
//   AtomicRenameFn? atomicRenameOverride;   // null = real File.rename
//
// EVERY rename the helper performs (tmp -> target, and any "move the old file
// aside / restore" step) must go through this hook when it is set.
import 'dart:io';

import 'package:libreshare_core/src/storage/atomic_file.dart';
import 'package:path/path.dart' as p;

String norm(String path) => p.normalize(p.absolute(path));

class RenameLog {
  final List<({String from, String to})> calls = [];

  /// True if some rename had [path] as its destination.
  bool sawDestination(String path) =>
      calls.any((c) => norm(c.to) == norm(path));

  int destinationCount(String path) =>
      calls.where((c) => norm(c.to) == norm(path)).length;
}

FileSystemException _denied(String to) => FileSystemException(
  'simulated rename failure',
  to,
  const OSError('Access is denied.', 5),
);

/// Records every rename, then performs it for real.
AtomicRenameFn recordingRename(RenameLog log) => (from, to) async {
  log.calls.add((from: from.path, to: to));
  await from.rename(to);
};

/// Windows-like: renaming onto an EXISTING path fails (what the readiness
/// report fears); renaming onto a free path works.
AtomicRenameFn windowsLikeRename(RenameLog log) => (from, to) async {
  log.calls.add((from: from.path, to: to));
  if (FileSystemEntity.typeSync(to, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw _denied(to);
  }
  await from.rename(to);
};

/// Every rename fails (antivirus / indexer holding the file).
AtomicRenameFn failingRename(RenameLog log) => (from, to) async {
  log.calls.add((from: from.path, to: to));
  throw _denied(to);
};

/// [lockedPath] cannot be replaced NOR moved away (a locked file on Windows);
/// every other rename works. Plain File.delete is NOT affected, so an
/// implementation that deletes the old file first would lose it here.
AtomicRenameFn lockedFileRename(String lockedPath, RenameLog log) =>
    (from, to) async {
      log.calls.add((from: from.path, to: to));
      if (norm(from.path) == norm(lockedPath) || norm(to) == norm(lockedPath)) {
        throw _denied(to);
      }
      await from.rename(to);
    };

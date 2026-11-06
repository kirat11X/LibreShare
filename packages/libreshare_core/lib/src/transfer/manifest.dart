/// Builds the session manifest (spec §4.3, §8): turns local files into
/// [FileItem]s and a [SessionRequest]. Smallest file first so the receiver sees
/// quick wins early (spec §8 "Multiple files: one session, smallest first").
library;

import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import '../model/device.dart';
import '../model/file_item.dart';
import '../model/session_models.dart';
import '../protocol.dart';
import 'chunker.dart';
import 'hashing.dart';

/// Files larger than this are announced with `sha256: null` (spec §4.3); the
/// sender supplies the digest in the `/complete` body instead.
const int kManifestHashLimit = 2 * 1024 * 1024 * 1024; // 2 GiB

/// A manifest item together with the local file it was built from.
class ManifestEntry {
  const ManifestEntry(this.file, this.item);
  final File file;
  final FileItem item;
}

class ManifestBuilder {
  const ManifestBuilder({
    this.chunker = const Chunker(),
    this.maxHashedSize = kManifestHashLimit,
  });

  final Chunker chunker;

  /// Largest file (bytes) whose SHA-256 is computed up front.
  final int maxHashedSize;

  /// Builds the manifest for [files], smallest first, ids `f1`, `f2`, ...
  /// assigned in that order. Throws [FileSystemException] if an entry is
  /// missing or not a regular file, [ArgumentError] if there are more than
  /// [kMaxFilesPerSession] files.
  Future<List<FileItem>> build(List<File> files) async => [
    for (final e in await buildEntries(files)) e.item,
  ];

  /// Like [build] but keeps the source [File] next to each item (the sender
  /// needs it to read chunks).
  Future<List<ManifestEntry>> buildEntries(List<File> files) async {
    if (files.length > kMaxFilesPerSession) {
      throw ArgumentError.value(
        files.length,
        'files',
        'a session carries at most $kMaxFilesPerSession files',
      );
    }

    final stats = <_Stat>[];
    for (var i = 0; i < files.length; i++) {
      final st = await files[i].stat();
      if (st.type == FileSystemEntityType.notFound) {
        throw FileSystemException('File not found', files[i].path);
      }
      if (st.type != FileSystemEntityType.file) {
        throw FileSystemException('Not a regular file', files[i].path);
      }
      stats.add(_Stat(i, files[i], st));
    }
    // Dart's List.sort is not guaranteed stable: tie-break on input position.
    stats.sort((a, b) {
      final c = a.stat.size.compareTo(b.stat.size);
      return c != 0 ? c : a.position.compareTo(b.position);
    });

    final out = <ManifestEntry>[];
    for (var i = 0; i < stats.length; i++) {
      final s = stats[i];
      final size = s.stat.size;
      final String? hash;
      if (size == 0) {
        hash = kSha256Empty;
      } else if (size > maxHashedSize) {
        hash = null;
      } else {
        hash = await sha256OfFile(s.file);
      }
      out.add(
        ManifestEntry(
          s.file,
          FileItem(
            fileId: 'f${i + 1}',
            fileName: sanitizeDisplayName(p.basename(s.file.path)),
            size: size,
            chunkCount: chunker.chunkCount(size),
            mime: lookupMimeType(s.file.path) ?? 'application/octet-stream',
            sha256: hash,
            modified: s.stat.modified.toUtc(),
          ),
        ),
      );
    }
    return out;
  }

  /// SessionRequest for [files] (already built by [build]); `totalSize` is the
  /// sum of the file sizes and `chunkSize` is this builder's chunk size.
  SessionRequest buildSessionRequest({
    required DeviceInfo sender,
    required List<FileItem> files,
    String? pin,
    TunnelOffer? tunnelOffer,
  }) => SessionRequest(
    sender: sender,
    files: files,
    totalSize: files.fold<int>(0, (sum, f) => sum + f.size),
    pin: pin,
    chunkSize: chunker.chunkSize,
    tunnelOffer: tunnelOffer,
  );

  /// Makes a local file name safe to show in a prompt and to put in JSON:
  /// control characters, path separators and bidi-override characters become
  /// `_`; surrounding whitespace is trimmed; an empty or dots-only result
  /// becomes `file`. The receiver still sanitizes independently (Inc 3).
  static String sanitizeDisplayName(String name) {
    final cleaned = name
        .replaceAll(_unsafe, '_')
        .replaceAll(RegExp(r'^\s+|\s+$'), '');
    if (cleaned.isEmpty || RegExp(r'^\.+$').hasMatch(cleaned)) return 'file';
    return cleaned;
  }

  // C0/C1 controls, DEL, '/', '\', and bidi embedding/override/isolate marks.
  static final RegExp _unsafe = RegExp(
    r'[\u0000-\u001F\u007F-\u009F/\\\u202A-\u202E\u2066-\u2069]',
  );
}

class _Stat {
  _Stat(this.position, this.file, this.stat);
  final int position;
  final File file;
  final FileStat stat;
}

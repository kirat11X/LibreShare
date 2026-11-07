/// Filename / path sanitization for incoming files (spec §5, UML 7.0).
///
/// Everything a remote sender controls (`fileName`, `relativePath`) goes
/// through this file before it is allowed near the file system. Rules:
///
///  * strip control characters, bidi/zero-width spoofing characters and
///    `<>:"/\|?*`, then NFC-normalize ([nfcNormalize]);
///  * split `relativePath` on `/` and `\`, drop empty and `.` segments and
///    REJECT any `..` segment ([LsErrorCode.badRequest]);
///  * strip leading spaces and trailing dots/spaces; prefix Windows reserved
///    device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, with or without
///    extension, any case) with `_`;
///  * truncate to 255 UTF-8 bytes keeping the extension; empty -> `unnamed`;
///  * resolve the final path (following symlinks of the part of the chain that
///    already exists) and ASSERT it is inside the download directory
///    (Warpinator CVE-2022-42725 lesson). Symlinks are never written through;
///  * collisions never overwrite: `name (1).ext`, `name (2).ext`, ...
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../model/ls_exception.dart';
import 'unicode_nfc.dart';

/// Longest permitted file-name component in bytes (ext4/NTFS/APFS limit).
const int kMaxNameBytes = 255;

/// Suffix of in-flight partial files.
const String kPartialSuffix = '.lspart';

/// Name budget for final files so every companion name still fits in 255
/// bytes: `<name>.lspart`, its sidecar `<name>.lspart.json` and the sidecar's
/// temp file `<name>.lspart.json.tmp` (16 bytes of suffix).
const int kTargetNameMaxBytes = kMaxNameBytes - 16;

/// Longest extension (including the dot, in bytes) that is "kept" on truncation.
const int _kMaxExtensionBytes = 20;

const String _kFallbackName = 'unnamed';

/// Windows reserved device names (compared upper-case, before the first dot).
const Set<String> _kReserved = {
  'CON', 'PRN', 'AUX', 'NUL', 'CONIN\$', 'CONOUT\$', //
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  // Superscript digits are reserved too on Windows 10+.
  'COM\u00B9', 'COM\u00B2', 'COM\u00B3', 'LPT\u00B9', 'LPT\u00B2', 'LPT\u00B3',
};

final RegExp _separators = RegExp(r'[\\/]');

/// Invisible / direction-changing characters used for filename spoofing
/// (right-to-left override, zero-width space, BOM, ...). ZWJ/ZWNJ are kept:
/// they are meaningful in emoji sequences and several scripts.
bool _isFormatChar(int c) =>
    c == 0x00AD ||
    c == 0x061C ||
    c == 0x200B ||
    c == 0x200E ||
    c == 0x200F ||
    c == 0x2028 ||
    c == 0x2029 ||
    (c >= 0x202A && c <= 0x202E) ||
    (c >= 0x2060 && c <= 0x2064) ||
    (c >= 0x2066 && c <= 0x2069) ||
    c == 0xFEFF ||
    (c >= 0xFFF9 && c <= 0xFFFB) ||
    c == 0xFFFE ||
    c == 0xFFFF;

bool _isControl(int c) => c < 0x20 || (c >= 0x7F && c <= 0x9F);

bool _isForbidden(int c) =>
    c == 0x3C || // <
    c == 0x3E || // >
    c == 0x3A || // :
    c == 0x22 || // "
    c == 0x2F || // /
    c == 0x5C || // \
    c == 0x7C || // |
    c == 0x3F || // ?
    c == 0x2A; // *

bool _isSurrogate(int c) => c >= 0xD800 && c <= 0xDFFF;

/// Removes control, format, forbidden characters and lone surrogates.
String _stripUnsafe(String s) {
  final sb = StringBuffer();
  for (final r in s.runes) {
    if (_isControl(r) ||
        _isFormatChar(r) ||
        _isForbidden(r) ||
        _isSurrogate(r)) {
      continue;
    }
    sb.writeCharCode(r);
  }
  return sb.toString();
}

int _utf8Length(String s) => utf8.encode(s).length;

String _trimLeadingSpaces(String s) {
  var i = 0;
  while (i < s.length && s.codeUnitAt(i) == 0x20) {
    i++;
  }
  return s.substring(i);
}

String _trimTrailingDotsAndSpaces(String s) {
  var end = s.length;
  while (end > 0) {
    final c = s.codeUnitAt(end - 1);
    if (c == 0x2E || c == 0x20) {
      end--;
    } else {
      break;
    }
  }
  return s.substring(0, end);
}

/// Splits [s] into (stem, extension-with-dot). The extension is the part from
/// the last dot, if the dot is not the first character and the extension is
/// short enough to be worth preserving.
(String, String) _splitExtension(String s, int maxBytes) {
  final dot = s.lastIndexOf('.');
  if (dot <= 0 || dot == s.length - 1) return (s, '');
  final ext = s.substring(dot);
  final extBytes = _utf8Length(ext);
  if (extBytes > _kMaxExtensionBytes || extBytes > maxBytes ~/ 2) {
    return (s, '');
  }
  return (s.substring(0, dot), ext);
}

/// Truncates [stem] on code point boundaries to at most [budget] UTF-8 bytes.
String _truncateBytes(String stem, int budget) {
  if (budget <= 0) return '';
  var bytes = 0;
  final sb = StringBuffer();
  for (final r in stem.runes) {
    final n = r < 0x80
        ? 1
        : r < 0x800
        ? 2
        : r < 0x10000
        ? 3
        : 4;
    if (bytes + n > budget) break;
    bytes += n;
    sb.writeCharCode(r);
  }
  return sb.toString();
}

String _fitToBytes(String s, int maxBytes) {
  if (_utf8Length(s) <= maxBytes) return s;
  final (stem, ext) = _splitExtension(s, maxBytes);
  var cut = _truncateBytes(stem, maxBytes - _utf8Length(ext));
  if (ext.isEmpty) cut = _trimTrailingDotsAndSpaces(cut);
  final out = '$cut$ext';
  return out.isEmpty ? _kFallbackName : out;
}

bool _isReservedName(String s) {
  final dot = s.indexOf('.');
  final base = (dot < 0 ? s : s.substring(0, dot)).trimRight().toUpperCase();
  return _kReserved.contains(base);
}

/// Sanitizes one path component that is already free of separators.
String _sanitizeComponent(String raw, int maxBytes) {
  var s = nfcNormalize(_stripUnsafe(raw));
  s = _stripUnsafe(s); // NFC cannot introduce these, but be defensive
  s = _trimTrailingDotsAndSpaces(_trimLeadingSpaces(s));
  if (s.isEmpty) return _kFallbackName;
  s = _fitToBytes(s, maxBytes);
  if (_isReservedName(s)) {
    s = _fitToBytes('_$s', maxBytes);
  }
  return s;
}

/// Sanitizes a sender-supplied file name into a single safe path component.
///
/// If [name] contains path separators only its last non-empty component is
/// used (`../../etc/passwd` -> `passwd`). The result is never empty, never a
/// reserved device name, has no control / forbidden characters, no trailing
/// dot or space and is at most [maxBytes] UTF-8 bytes (extension preserved).
String sanitizeFileName(String name, {int maxBytes = kMaxNameBytes}) {
  if (maxBytes < 16) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must be >= 16');
  }
  final parts = name.split(_separators);
  var last = '';
  for (var i = parts.length - 1; i >= 0; i--) {
    if (parts[i].isNotEmpty) {
      last = parts[i];
      break;
    }
  }
  return _sanitizeComponent(last, maxBytes);
}

/// Sanitizes a sender-supplied relative directory path into safe segments.
///
/// Splits on `/` and `\`, drops empty and `.` segments, sanitizes every
/// segment like a file name and throws [LsErrorCode.badRequest] on any `..`.
/// An absolute path (`/etc`, `C:\Windows`) is simply re-rooted.
List<String> sanitizeRelativePath(String? relativePath) {
  if (relativePath == null || relativePath.isEmpty) return const [];
  final out = <String>[];
  for (final raw in relativePath.split(_separators)) {
    if (raw.isEmpty) continue;
    final probe = _stripUnsafe(raw).trim();
    if (probe == '.') continue;
    if (probe == '..') {
      throw LsException(
        LsErrorCode.badRequest,
        'path traversal segment ".." is not allowed',
      );
    }
    out.add(_sanitizeComponent(raw, kMaxNameBytes));
  }
  return out;
}

/// `name (n).ext` collision name, shortened to fit [maxBytes].
String withCollisionSuffix(
  String fileName,
  int n, {
  int maxBytes = kMaxNameBytes,
}) {
  final suffix = ' ($n)';
  final dot = fileName.lastIndexOf('.');
  final hasExt = dot > 0 && dot < fileName.length - 1;
  final stem = hasExt ? fileName.substring(0, dot) : fileName;
  final ext = hasExt ? fileName.substring(dot) : '';
  final budget = maxBytes - _utf8Length(suffix) - _utf8Length(ext);
  final cutStem = _utf8Length(stem) <= budget
      ? stem
      : _truncateBytes(stem, budget);
  return '$cutStem$suffix$ext';
}

/// True only if [candidate] is strictly inside [root] (equal -> false).
///
/// [windows] null means `Platform.isWindows`. With `windows: true` the
/// extended-length prefix is dropped (`\\?\C:\x` == `C:\x`,
/// `\\?\UNC\h\s\x` == `\\h\s\x`), `/` and `\` are both separators, the
/// comparison ignores case and `.`/`..` are normalised. With `windows: false`
/// it is `package:path`'s POSIX `isWithin`.
bool isPathWithin(String root, String candidate, {bool? windows}) {
  if (!(windows ?? Platform.isWindows)) {
    return p.posix.isWithin(root, candidate);
  }
  String norm(String s) {
    var t = s.replaceAll('/', r'\');
    if (t.startsWith(r'\\?\UNC\')) {
      t = r'\\' + t.substring(8);
    } else if (t.startsWith(r'\\?\')) {
      t = t.substring(4);
    }
    return t;
  }

  return p.windows.isWithin(norm(root), norm(candidate));
}

/// Throws [LsErrorCode.badRequest] unless [path] (which need not exist yet) is
/// strictly inside [root] after resolving symlinks of its existing ancestors.
void assertInsideDir(Directory root, String path) {
  LsException escape(String why) => LsException(
    LsErrorCode.badRequest,
    'target path escapes download directory ($why)',
  );

  final rootAbs = p.normalize(root.absolute.path);
  final rootReal = _realOrSelf(rootAbs);

  if (p.split(path).contains('..')) throw escape('dot-dot segment');
  final target = p.normalize(p.absolute(path));

  var existing = target;
  final tail = <String>[];
  while (FileSystemEntity.typeSync(existing, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(existing);
    if (parent == existing) break;
    tail.insert(0, p.basename(existing));
    existing = parent;
  }
  final String real;
  try {
    real = Directory(existing).resolveSymbolicLinksSync();
  } on FileSystemException {
    throw escape('unresolvable link');
  }
  final resolved = tail.isEmpty ? real : p.joinAll([real, ...tail]);
  if (!isPathWithin(rootReal, resolved)) throw escape('outside');
}

String _realOrSelf(String dir) {
  try {
    return Directory(dir).resolveSymbolicLinksSync();
  } on FileSystemException {
    return dir;
  }
}

/// Computes the file a received item should be written to inside
/// [downloadDir], never overwriting anything and never leaving the directory.
///
/// * [fileName] is sanitized with [sanitizeFileName] (budget [maxNameBytes]
///   so a `.lspart` suffix always fits).
/// * [relativePath] is the DIRECTORY part of the sender's folder structure
///   (`photos/2024`); a trailing component equal to the file name is tolerated
///   and dropped. `..` segments throw [LsErrorCode.badRequest].
/// * Existing entries (files, directories, ANY symlink, dangling or not) and
///   paths for which [isReserved] returns true are treated as taken and get
///   the `name (n).ext` treatment. A symlinked directory is only traversed if
///   it resolves to a directory inside [downloadDir]; otherwise it is treated
///   as a name collision.
/// * [downloadDir] is created if missing; intermediate sub directories are NOT
///   created (the caller does that after calling [assertInsideDir] again).
///
/// [collisionHints] (optional, caller-owned, e.g. one per session) remembers
/// the next free `(n)` suffix per base name so that resolving thousands of
/// identically named files is linear instead of quadratic.
///
/// The returned path is built from [downloadDir]'s own path (not its resolved
/// form) so `p.isWithin(downloadDir.path, result.path)` always holds.
File resolveTarget({
  required Directory downloadDir,
  required String fileName,
  String? relativePath,
  bool Function(String path)? isReserved,
  int maxNameBytes = kTargetNameMaxBytes,
  Map<String, int>? collisionHints,
}) {
  final dirs = sanitizeRelativePath(relativePath);
  final name = sanitizeFileName(fileName, maxBytes: maxNameBytes);
  if (dirs.isNotEmpty && dirs.last == sanitizeFileName(fileName)) {
    dirs.removeLast();
  }

  final root = Directory(p.normalize(downloadDir.absolute.path))
    ..createSync(recursive: true);
  final rootReal = root.resolveSymbolicLinksSync();

  var cur = root.path;
  var curReal = rootReal;
  var exists = true; // false once we pass a directory that does not exist yet
  for (final seg in dirs) {
    var candidate = seg;
    var n = 0;
    while (true) {
      final candPath = p.join(cur, candidate);
      if (!exists) {
        cur = candPath;
        curReal = p.join(curReal, candidate);
        break;
      }
      final type = FileSystemEntity.typeSync(candPath, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        exists = false;
        cur = candPath;
        curReal = p.join(curReal, candidate);
        break;
      }
      if (type == FileSystemEntityType.directory) {
        cur = candPath;
        curReal = p.join(curReal, candidate);
        break;
      }
      if (type == FileSystemEntityType.link) {
        final resolved = _resolveDirLink(candPath);
        if (resolved != null &&
            (resolved == rootReal || isPathWithin(rootReal, resolved))) {
          cur = candPath;
          curReal = resolved;
          break;
        }
      }
      // A file, a foreign / dangling link ...: pick another directory name.
      candidate = withCollisionSuffix(seg, ++n);
      if (n > 100000) {
        throw LsException(LsErrorCode.internal, 'too many name collisions');
      }
    }
  }

  bool isTaken(String candPath) =>
      (isReserved?.call(candPath) ?? false) ||
      (exists &&
          FileSystemEntity.typeSync(candPath, followLinks: false) !=
              FileSystemEntityType.notFound);

  File accept(String candidate) {
    final resolved = p.join(curReal, candidate);
    if (!isPathWithin(rootReal, resolved)) {
      throw LsException(
        LsErrorCode.badRequest,
        'target path escapes download directory',
      );
    }
    return File(p.join(cur, candidate));
  }

  if (!isTaken(p.join(cur, name))) return accept(name);

  final hintKey = p.join(cur, name).toLowerCase();
  var n = (collisionHints?[hintKey] ?? 0);
  while (true) {
    final candidate = withCollisionSuffix(name, ++n, maxBytes: maxNameBytes);
    if (!isTaken(p.join(cur, candidate))) {
      collisionHints?[hintKey] = n;
      return accept(candidate);
    }
    if (n > 100000) {
      throw LsException(LsErrorCode.internal, 'too many name collisions');
    }
  }
}

String? _resolveDirLink(String linkPath) {
  try {
    final resolved = Link(linkPath).resolveSymbolicLinksSync();
    return FileSystemEntity.isDirectorySync(resolved) ? resolved : null;
  } on FileSystemException {
    return null;
  }
}

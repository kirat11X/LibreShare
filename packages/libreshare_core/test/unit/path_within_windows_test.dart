// E5 / R1d: assertInsideDir / resolveTarget compare resolved paths with
// p.isWithin. On Windows resolveSymbolicLinksSync() can return `\\?\C:\...`
// for one side and the plain form for the other (the fallback in _realOrSelf),
// and the file system is case-insensitive. A pure, OS-independent function is
// needed so the comparison is testable on Linux:
//
//   // lib/src/transfer/filename_sanitizer.dart (exported by the barrel)
//   bool isPathWithin(String root, String candidate, {bool? windows});
//
// true only if [candidate] is STRICTLY inside [root] (equal -> false).
// windows == null means Platform.isWindows. With windows: true:
//   - `\\?\C:\x` and `C:\x` are the same path; `\\?\UNC\h\s\x` is `\\h\s\x`;
//   - `/` and `\` are both separators; comparison ignores case;
//   - `.`/`..` segments are normalised (no escape through `..`);
// with windows: false it is exactly p.isWithin (case sensitive, `\` is part of
// a name). assertInsideDir and resolveTarget must use it instead of p.isWithin.
//
// Every test name starts with the guard it protects.
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

void main() {
  bool win(String root, String child) =>
      isPathWithin(root, child, windows: true);
  bool posix(String root, String child) =>
      isPathWithin(root, child, windows: false);

  group('Windows, extended-length prefix', () {
    test('guard prefix-mixed: plain root, \\\\?\\ candidate', () {
      expect(win(r'C:\a', r'\\?\C:\a\b'), isTrue);
    });
    test('guard prefix-mixed: \\\\?\\ root, plain candidate', () {
      expect(win(r'\\?\C:\a', r'C:\a\b'), isTrue);
    });
    test('guard prefix-both: both \\\\?\\', () {
      expect(win(r'\\?\C:\a', r'\\?\C:\a\b\c.txt'), isTrue);
    });
    test('guard prefix-unc: \\\\?\\UNC\\h\\s equals \\\\h\\s', () {
      expect(win(r'\\host\share\dl', r'\\?\UNC\host\share\dl\x'), isTrue);
      expect(win(r'\\?\UNC\host\share\dl', r'\\host\share\dl\x'), isTrue);
    });
    test('guard prefix-strict: same directory is NOT within itself', () {
      expect(win(r'\\?\C:\a', r'C:\a'), isFalse);
      expect(win(r'C:\a', r'\\?\C:\a\'), isFalse);
    });
    test('guard prefix-sibling: \\\\?\\C:\\ab is not inside C:\\a', () {
      expect(win(r'C:\a', r'\\?\C:\ab\x'), isFalse);
    });
    test('guard prefix-other-drive: D:\\a\\x is not inside \\\\?\\C:\\a', () {
      expect(win(r'\\?\C:\a', r'D:\a\x'), isFalse);
    });
    test('guard prefix-unc-other-share: other share is outside', () {
      expect(win(r'\\?\UNC\host\share\dl', r'\\host\other\dl\x'), isFalse);
    });
  });

  group('Windows, case and separators', () {
    test('guard case-insensitive: drive letter and folders', () {
      expect(win(r'C:\Users\Me', r'c:\users\me\Downloads\x'), isTrue);
      expect(win(r'\\?\C:\Users\Me', r'\\?\c:\USERS\ME\x'), isTrue);
    });
    test('guard slash-equivalence: / and \\ are both separators', () {
      expect(win(r'C:\a', 'C:/a/b'), isTrue);
      expect(win('C:/a', r'C:\a\b'), isTrue);
    });
    test('guard dotdot-escape: C:\\a\\..\\b is outside C:\\a', () {
      expect(win(r'C:\a', r'C:\a\..\b'), isFalse);
      expect(win(r'C:\a', r'\\?\C:\a\..\b'), isFalse);
    });
    test('guard dotdot-inside: C:\\a\\x\\..\\y is inside C:\\a', () {
      expect(win(r'C:\a', r'C:\a\x\..\y'), isTrue);
    });
    test('guard windows-plain: ordinary inside / outside answers', () {
      expect(win(r'C:\a', r'C:\a\b'), isTrue);
      expect(win(r'C:\a', r'C:\b'), isFalse);
      expect(win(r'C:\a\b', r'C:\a'), isFalse);
    });
  });

  group('POSIX (regression: exactly p.isWithin)', () {
    test('guard posix-plain', () {
      expect(posix('/a', '/a/b'), isTrue);
      expect(posix('/a', '/a'), isFalse);
      expect(posix('/a', '/ab/c'), isFalse);
      expect(posix('/a/b', '/a'), isFalse);
    });
    test('guard posix-case-sensitive: /A is not /a', () {
      expect(posix('/A', '/a/b'), isFalse);
    });
    test('guard posix-backslash-is-a-name: backslash is no separator', () {
      expect(posix('/a', r'/a\b'), isFalse); // sibling named a\b
      expect(posix('/a', r'/a/b\c'), isTrue);
    });
    test('guard posix-question-prefix-is-just-a-name', () {
      expect(posix(r'\\?\C:\a', r'\\?\C:\a\b'), isFalse);
    });
    test(
      'guard default-platform: windows == null follows Platform.isWindows',
      () {
        expect(isPathWithin('/a', '/a/b'), isTrue);
      },
      skip: Platform.isWindows ? 'POSIX default expected' : null,
    );
  });
}

// E5 / R1c: parentDir must understand Windows roots (pure function, runs on
// any OS). Present behaviour truncates `C:\a` to the drive-relative `C:`, and
// `\\host\share\x` to `\\host\share`-less garbage for shallow UNC paths.
//
//   String parentDir(String path)   // lib/services/paths.dart, unchanged API
//
// Every test name starts with the guard it protects.
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/services/paths.dart';

void main() {
  group('parentDir Windows drive paths', () {
    const cases = <String, String>{
      r'C:\a': r'C:\',
      r'C:\a.txt': r'C:\',
      r'C:\': r'C:\',
      r'C:\a\b': r'C:\a',
      r'C:\a\b\c.txt': r'C:\a\b',
      r'c:\Users\Me\Downloads\f.bin': r'c:\Users\Me\Downloads',
      r'C:/a': r'C:/',
      r'C:/': r'C:/',
      r'C:/a/b': r'C:/a',
    };
    for (final e in cases.entries) {
      test('guard drive-root: parentDir(${e.key}) == ${e.value}', () {
        expect(parentDir(e.key), e.value);
      });
    }
  });

  group('parentDir UNC and extended-length paths', () {
    const cases = <String, String>{
      r'\\host\share\x': r'\\host\share',
      r'\\host\share\x\y.txt': r'\\host\share\x',
      r'\\host\share': r'\\host\share', // share root has no parent
      r'\\?\C:\a': r'\\?\C:\',
      r'\\?\C:\a\b': r'\\?\C:\a',
      r'\\?\C:\': r'\\?\C:\',
      r'\\?\UNC\host\share\x': r'\\?\UNC\host\share',
      r'\\?\UNC\host\share\x\y': r'\\?\UNC\host\share\x',
    };
    for (final e in cases.entries) {
      test(
        'guard unc-and-extended-prefix: parentDir(${e.key}) == ${e.value}',
        () {
          expect(parentDir(e.key), e.value);
        },
      );
    }
  });

  group('parentDir POSIX behaviour is unchanged (regression)', () {
    const cases = <String, String>{
      '/a': '/',
      '/': '/',
      '/a/b': '/a',
      '/a/b/c.txt': '/a/b',
      'a/b': 'a',
      'a': '.',
      '': '.',
      '/storage/emulated/0/Download/LibreShare/f.bin':
          '/storage/emulated/0/Download/LibreShare',
      '/tmp/a b#1&2,3/f é.txt': '/tmp/a b#1&2,3',
    };
    for (final e in cases.entries) {
      test('guard posix-unchanged: parentDir("${e.key}") == "${e.value}"', () {
        expect(parentDir(e.key), e.value);
      });
    }
  });
}

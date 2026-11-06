import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/src/model/ls_exception.dart';
import 'package:libreshare_core/src/transfer/filename_sanitizer.dart';
import 'package:libreshare_core/src/transfer/unicode_nfc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

int utf8Len(String s) => utf8.encode(s).length;

Matcher throwsBadRequest() => throwsA(
  isA<LsException>().having((e) => e.code, 'code', LsErrorCode.badRequest),
);

void main() {
  group('nfcNormalize', () {
    final cases = <String, String>{
      'plain ascii': 'plain ascii',
      'e\u0301': '\u00e9',
      'A\u030a': '\u00c5',
      'n\u0303': '\u00f1',
      'o\u0308': '\u00f6',
      'c\u0327': '\u00e7',
      'a\u0323\u0302': '\u1ead', // Vietnamese ậ
      'a\u0302\u0323': '\u1ead', // reordered by canonical combining class
      'a\u0308\u0323': '\u1ea1\u0308', // a + dot below + diaeresis (reorder)
      '\u212b': '\u00c5', // ANGSTROM SIGN singleton
      '\u1112\u1161\u11ab': '\ud55c', // Hangul jamo -> syllable
      '\u304b\u3099': '\u304c', // kana + voiced mark
      'e\u0301\u0301': '\u00e9\u0301',
      '\u0301': '\u0301', // lone combining mark
      '\u00e9': '\u00e9', // already NFC
      '\u{1F600}e\u0301': '\u{1F600}\u00e9', // astral char untouched
    };
    cases.forEach((input, expected) {
      test('nfc(${input.runes.map((r) => r.toRadixString(16)).join(' ')})', () {
        expect(nfcNormalize(input), expected);
      });
    });
  });

  group('sanitizeFileName', () {
    final table = <String, String>{
      'report.pdf': 'report.pdf',
      'my file (1).txt': 'my file (1).txt',
      // traversal / absolute: only the last path component survives
      '../../etc/passwd': 'passwd',
      '..\\..\\windows\\system32': 'system32',
      '/etc/passwd': 'passwd',
      'C:\\Windows\\win.ini': 'win.ini',
      'a/b/': 'b',
      'a/..': 'unnamed',
      '/': 'unnamed',
      '\\': 'unnamed',
      // reserved names, case-insensitive, with and without extension
      'CON': '_CON',
      'con': '_con',
      'con.txt': '_con.txt',
      'NUL.tar.gz': '_NUL.tar.gz',
      'Prn.log': '_Prn.log',
      'AUX': '_AUX',
      'com1': '_com1',
      'COM9.txt': '_COM9.txt',
      'LPT1': '_LPT1',
      'lpt9.dat': '_lpt9.dat',
      'aux .txt': '_aux .txt',
      'COM0': 'COM0',
      'CONSOLE': 'CONSOLE',
      'COM10': 'COM10',
      'xcon.txt': 'xcon.txt',
      'a.con': 'a.con',
      // trailing dots and spaces
      'file.': 'file',
      'file...': 'file',
      'file. . ': 'file',
      'a b ': 'a b',
      '  lead.txt': 'lead.txt',
      // forbidden characters are stripped
      'a<b>c:d"e|f?g*h.txt': 'abcdefgh.txt',
      'tab\there\u0000.txt': 'tabhere.txt',
      'bell\u0007\u001f\u007f\u0085x': 'bellx',
      // bidi override / zero width tricks
      'evil\u202Egpj.exe': 'evilgpj.exe',
      'inv\u200Bisible.txt': 'invisible.txt',
      '\uFEFFbom.txt': 'bom.txt',
      // empty fallbacks
      '': 'unnamed',
      '.': 'unnamed',
      '..': 'unnamed',
      '...': 'unnamed',
      '   ': 'unnamed',
      '<>:"|?*': 'unnamed',
      // dot files are kept
      '.bashrc': '.bashrc',
      '.gitignore': '.gitignore',
      // unicode
      'caf\u00e9.txt': 'caf\u00e9.txt',
      'cafe\u0301.txt': 'caf\u00e9.txt',
      '\u65e5\u672c\u8a9e\u30d5\u30a1\u30a4\u30eb.txt':
          '\u65e5\u672c\u8a9e\u30d5\u30a1\u30a4\u30eb.txt',
      '\u{1F600}.png': '\u{1F600}.png',
      // lone surrogates are dropped
      '${String.fromCharCode(0xD800)}x.txt': 'x.txt',
      'y${String.fromCharCode(0xDC00)}.txt': 'y.txt',
    };
    table.forEach((input, expected) {
      test('"${input.replaceAll('\u0000', '\\0')}" -> "$expected"', () {
        expect(sanitizeFileName(input), expected);
        // idempotent
        expect(sanitizeFileName(expected), expected);
      });
    });

    test('300-byte ASCII name keeps extension and fits 255 bytes', () {
      final r = sanitizeFileName('${'a' * 300}.txt');
      expect(utf8Len(r), lessThanOrEqualTo(255));
      expect(r, endsWith('.txt'));
      expect(r, startsWith('aaaa'));
      expect(utf8Len(r), 255);
    });

    test('multi-byte names are cut on code point boundaries', () {
      for (final ch in ['\u00e9', '\u65e5', '\u{1F600}']) {
        final r = sanitizeFileName('${ch * 200}.pdf');
        expect(utf8Len(r), lessThanOrEqualTo(255));
        expect(r, endsWith('.pdf'));
        // round-trips through UTF-8 (no half characters)
        expect(utf8.decode(utf8.encode(r)), r);
        expect(r.codeUnits.any((u) => u == 0xFFFD), isFalse);
      }
    });

    test('very long extension is truncated instead of starving the stem', () {
      final r = sanitizeFileName('name.${'x' * 400}');
      expect(utf8Len(r), lessThanOrEqualTo(255));
      expect(r, startsWith('name.'));
    });

    test('name that is only a long dot-suffix', () {
      final r = sanitizeFileName('.${'x' * 400}');
      expect(utf8Len(r), lessThanOrEqualTo(255));
      expect(r, isNotEmpty);
    });

    test('maxBytes is honoured and extension kept', () {
      final r = sanitizeFileName('${'a' * 100}.txt', maxBytes: 50);
      expect(utf8Len(r), 50);
      expect(r, endsWith('.txt'));
    });

    test('truncation never produces a reserved name', () {
      final r = sanitizeFileName('CON.${'a' * 400}');
      expect(utf8Len(r), lessThanOrEqualTo(255));
      expect(r.toUpperCase().startsWith('CON.'), isFalse);
      expect(r, startsWith('_CON'));
    });

    test('exactly 255 bytes is left alone; 256 is cut', () {
      final ok = '${'b' * 251}.txt';
      expect(sanitizeFileName(ok), ok);
      final cut = sanitizeFileName('${'b' * 252}.txt');
      expect(utf8Len(cut), 255);
      expect(cut, endsWith('.txt'));
    });
  });

  group('withCollisionSuffix', () {
    test('inserts before the extension', () {
      expect(withCollisionSuffix('a.txt', 1), 'a (1).txt');
      expect(withCollisionSuffix('a.txt', 12), 'a (12).txt');
      expect(withCollisionSuffix('README', 2), 'README (2)');
      expect(withCollisionSuffix('.bashrc', 1), '.bashrc (1)');
      expect(withCollisionSuffix('x.tar.gz', 1), 'x.tar (1).gz');
    });

    test('stays within maxBytes by shortening the stem', () {
      final r = withCollisionSuffix('${'a' * 251}.txt', 3, maxBytes: 255);
      expect(utf8Len(r), lessThanOrEqualTo(255));
      expect(r, endsWith(' (3).txt'));
    });
  });

  group('sanitizeRelativePath', () {
    test('null / empty / only dots', () {
      expect(sanitizeRelativePath(null), isEmpty);
      expect(sanitizeRelativePath(''), isEmpty);
      expect(sanitizeRelativePath('/'), isEmpty);
      expect(sanitizeRelativePath('././/.'), isEmpty);
    });

    test('splits on both separators and drops empty / dot segments', () {
      expect(sanitizeRelativePath('a/b/c'), ['a', 'b', 'c']);
      expect(sanitizeRelativePath('a\\b\\c'), ['a', 'b', 'c']);
      expect(sanitizeRelativePath('a/b\\c'), ['a', 'b', 'c']);
      expect(sanitizeRelativePath('/a//b/./c/'), ['a', 'b', 'c']);
      expect(sanitizeRelativePath('./a'), ['a']);
      expect(sanitizeRelativePath('\\\\server\\share\\x'), [
        'server',
        'share',
        'x',
      ]);
    });

    test('rejects any .. segment', () {
      for (final bad in [
        '..',
        '../a',
        'a/..',
        'a/../b',
        'a\\..\\b',
        '../../etc/passwd',
        '..\\..\\windows\\system32',
        'a/ .. /b',
        'a/.. /b',
        'a/<..>/b',
        'a/..\u200B/b',
        'a/\u202E../b',
        '/..',
        'a/b/../../..',
      ]) {
        expect(
          () => sanitizeRelativePath(bad),
          throwsBadRequest(),
          reason: 'should reject "$bad"',
        );
      }
    });

    test('dots-only segments longer than 2 are harmless and renamed', () {
      expect(sanitizeRelativePath('a/.../b'), ['a', 'unnamed', 'b']);
      expect(sanitizeRelativePath('....'), ['unnamed']);
    });

    test('each segment is sanitized like a file name', () {
      expect(sanitizeRelativePath('CON/dir<>/x.'), ['_CON', 'dir', 'x']);
      expect(sanitizeRelativePath('C:\\Users\\bob'), ['C', 'Users', 'bob']);
      expect(sanitizeRelativePath('${'d' * 300}/x'), ['d' * 255, 'x']);
    });
  });

  group('resolveTarget / assertInsideDir', () {
    late Directory tmp;
    late Directory dl;
    late Directory outside;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ls_sanitizer_');
      dl = Directory(p.join(tmp.path, 'Downloads'))..createSync();
      outside = Directory(p.join(tmp.path, 'outside'))..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    String rel(File f) => p.relative(f.path, from: dl.path);

    test('plain file lands directly in the download dir', () {
      final f = resolveTarget(downloadDir: dl, fileName: 'a.txt');
      expect(f.path, p.join(dl.path, 'a.txt'));
      expect(f.existsSync(), isFalse);
    });

    test('missing download dir is created', () {
      final d = Directory(p.join(tmp.path, 'new', 'deep'));
      final f = resolveTarget(downloadDir: d, fileName: 'a.txt');
      expect(d.existsSync(), isTrue);
      expect(f.path, p.join(d.path, 'a.txt'));
    });

    test('relativePath becomes sub directories (not created)', () {
      final f = resolveTarget(
        downloadDir: dl,
        fileName: 'x.jpg',
        relativePath: 'photos\\2024/trip',
      );
      expect(rel(f), p.join('photos', '2024', 'trip', 'x.jpg'));
    });

    test(
      'relativePath that already ends with the file name is not doubled',
      () {
        final f = resolveTarget(
          downloadDir: dl,
          fileName: 'x.jpg',
          relativePath: 'photos/x.jpg',
        );
        expect(rel(f), p.join('photos', 'x.jpg'));
      },
    );

    test('traversal in fileName lands inside the dir', () {
      for (final n in [
        '../../etc/passwd',
        '..\\..\\windows\\system32',
        '/etc/passwd',
        'C:\\Windows\\win.ini',
        '....//....//x',
      ]) {
        final f = resolveTarget(downloadDir: dl, fileName: n);
        expect(p.isWithin(dl.path, f.path), isTrue, reason: n);
        expect(p.dirname(f.path), dl.path, reason: n);
      }
    });

    test('traversal in relativePath is rejected', () {
      expect(
        () => resolveTarget(
          downloadDir: dl,
          fileName: 'x',
          relativePath: '../../etc',
        ),
        throwsBadRequest(),
      );
    });

    test('absolute relativePath is re-rooted inside the dir', () {
      final f = resolveTarget(
        downloadDir: dl,
        fileName: 'passwd',
        relativePath: '/etc',
      );
      expect(rel(f), p.join('etc', 'passwd'));
      final g = resolveTarget(
        downloadDir: dl,
        fileName: 'win.ini',
        relativePath: 'C:\\Windows',
      );
      expect(p.isWithin(dl.path, g.path), isTrue);
    });

    test('collisions never overwrite: name (1).ext, name (2).ext', () {
      File(p.join(dl.path, 'a.txt')).writeAsStringSync('orig');
      var f = resolveTarget(downloadDir: dl, fileName: 'a.txt');
      expect(rel(f), 'a (1).txt');
      File(f.path).writeAsStringSync('1');
      f = resolveTarget(downloadDir: dl, fileName: 'a.txt');
      expect(rel(f), 'a (2).txt');
      File(f.path).writeAsStringSync('2');
      f = resolveTarget(downloadDir: dl, fileName: 'a.txt');
      expect(rel(f), 'a (3).txt');
      expect(File(p.join(dl.path, 'a.txt')).readAsStringSync(), 'orig');
    });

    test('extension-less and directory collisions', () {
      File(p.join(dl.path, 'README')).writeAsStringSync('x');
      Directory(p.join(dl.path, 'dirname')).createSync();
      expect(
        rel(resolveTarget(downloadDir: dl, fileName: 'README')),
        'README (1)',
      );
      expect(
        rel(resolveTarget(downloadDir: dl, fileName: 'dirname')),
        'dirname (1)',
      );
    });

    test('isReserved paths are treated as taken', () {
      final taken = <String>{p.join(dl.path, 'a.txt').toLowerCase()};
      final f = resolveTarget(
        downloadDir: dl,
        fileName: 'a.txt',
        isReserved: (path) => taken.contains(path.toLowerCase()),
      );
      expect(rel(f), 'a (1).txt');
    });

    test('long names leave room for the .lspart suffix', () {
      final f = resolveTarget(downloadDir: dl, fileName: '${'n' * 400}.bin');
      final base = p.basename(f.path);
      expect(utf8Len('$base.lspart.json.tmp'), lessThanOrEqualTo(255));
      expect(base, endsWith('.bin'));
    });

    test('a file where a directory is needed is not used as one', () {
      File(p.join(dl.path, 'photos')).writeAsStringSync('i am a file');
      final f = resolveTarget(
        downloadDir: dl,
        fileName: 'x.jpg',
        relativePath: 'photos',
      );
      expect(rel(f), p.join('photos (1)', 'x.jpg'));
    });

    test('symlinked directory pointing OUTSIDE is never traversed', () {
      Link(p.join(dl.path, 'link')).createSync(outside.path);
      final f = resolveTarget(
        downloadDir: dl,
        fileName: 'evil.txt',
        relativePath: 'link/sub',
      );
      expect(p.isWithin(dl.path, f.path), isTrue);
      expect(rel(f), isNot(startsWith('link${p.separator}')));
      // Simulate the receiver writing the file.
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('payload');
      expect(outside.listSync(), isEmpty, reason: 'nothing may land outside');
      assertInsideDir(dl, f.path);
    });

    test('symlinked FILE pointing outside is treated as a collision', () {
      final victim = File(p.join(outside.path, 'victim.txt'))
        ..writeAsStringSync('precious');
      Link(p.join(dl.path, 'victim.txt')).createSync(victim.path);
      final f = resolveTarget(downloadDir: dl, fileName: 'victim.txt');
      expect(rel(f), 'victim (1).txt');
      f.writeAsStringSync('payload');
      expect(victim.readAsStringSync(), 'precious');
    });

    test('dangling symlink is treated as a collision', () {
      Link(p.join(dl.path, 'ghost.txt'))
          .createSync(p.join(outside.path, 'nonexistent.txt'));
      final f = resolveTarget(downloadDir: dl, fileName: 'ghost.txt');
      expect(rel(f), 'ghost (1).txt');
    });

    test('symlinked directory pointing INSIDE the dir is fine', () {
      Directory(p.join(dl.path, 'real')).createSync();
      Link(p.join(dl.path, 'alias')).createSync(p.join(dl.path, 'real'));
      final f = resolveTarget(
        downloadDir: dl,
        fileName: 'x.txt',
        relativePath: 'alias',
      );
      expect(rel(f), p.join('alias', 'x.txt'));
    });

    test('download dir that is itself a symlink works', () {
      final real = Directory(p.join(tmp.path, 'real_dl'))..createSync();
      final link = Link(p.join(tmp.path, 'link_dl'))..createSync(real.path);
      final f = resolveTarget(
        downloadDir: Directory(link.path),
        fileName: 'a.txt',
        relativePath: 'sub',
      );
      expect(f.path, p.join(link.path, 'sub', 'a.txt'));
    });

    test('assertInsideDir accepts inside, rejects outside and escapes', () {
      assertInsideDir(dl, p.join(dl.path, 'a', 'b.txt'));
      expect(
        () => assertInsideDir(dl, p.join(outside.path, 'x')),
        throwsBadRequest(),
      );
      expect(() => assertInsideDir(dl, dl.path), throwsBadRequest());
      expect(
        () => assertInsideDir(dl, p.join(dl.path, '..', 'outside', 'x')),
        throwsBadRequest(),
      );
      Link(p.join(dl.path, 'link')).createSync(outside.path);
      expect(
        () => assertInsideDir(dl, p.join(dl.path, 'link', 'x.txt')),
        throwsBadRequest(),
      );
      expect(
        () => assertInsideDir(dl, p.join(dl.path, 'link', 'new', 'x.txt')),
        throwsBadRequest(),
      );
    });
  });
}

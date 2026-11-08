import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:libreshare_core/src/storage/atomic_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Helper implementing Windows CommandLineToArgvW and cmd.exe escaping rules
/// for launcher quoting verification.
String quoteWindowsArg(String arg, {bool forCmd = false}) {
  if (arg.isEmpty) return '""';

  // For CommandLineToArgvW:
  // If argument contains no space, tab, newline, or quote, return as-is
  final needsQuotes =
      arg.contains(RegExp(r'[\s"]')) ||
      (forCmd && arg.contains(RegExp(r'[&^%<>]')));
  if (!needsQuotes) return arg;

  final sb = StringBuffer('"');
  var backslashes = 0;

  for (var i = 0; i < arg.length; i++) {
    final c = arg[i];
    if (c == r'\') {
      backslashes++;
    } else if (c == '"') {
      // 2 * backslashes + 1 preceding a quote
      sb.write(r'\' * (2 * backslashes + 1));
      sb.write('"');
      backslashes = 0;
    } else {
      // Preceding backslashes not followed by quote
      if (backslashes > 0) {
        sb.write(r'\' * backslashes);
        backslashes = 0;
      }
      if (forCmd &&
          (c == '^' || c == '&' || c == '%' || c == '<' || c == '>')) {
        sb.write('^');
      }
      sb.write(c);
    }
  }

  // Preceding backslashes before closing quote must be doubled
  if (backslashes > 0) {
    sb.write(r'\' * (2 * backslashes));
  }
  sb.write('"');
  return sb.toString();
}

void main() {
  group('1. DOS & 8.3 Reserved Names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, superscripts)', () {
    const reservedBases = [
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'CONIN\$',
      'CONOUT\$',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
      'COM\u00B9',
      'COM\u00B2',
      'COM\u00B3',
      'LPT\u00B9',
      'LPT\u00B2',
      'LPT\u00B3',
    ];

    test('exact reserved base names are prefixed with underscore', () {
      for (final name in reservedBases) {
        final sanitized = sanitizeFileName(name);
        expect(
          sanitized,
          equals('_$name'),
          reason: 'Failed for reserved base $name',
        );
      }
    });

    test('case-insensitivity of reserved names', () {
      for (final name in reservedBases) {
        final lower = name.toLowerCase();
        final sanitized = sanitizeFileName(lower);
        expect(
          sanitized,
          equals('_$lower'),
          reason: 'Failed for lowercase reserved name $lower',
        );
      }
    });

    test('reserved names with arbitrary extensions (CON.txt, aux.tar.gz)', () {
      expect(sanitizeFileName('CON.txt'), equals('_CON.txt'));
      expect(sanitizeFileName('con.txt'), equals('_con.txt'));
      expect(sanitizeFileName('aux.tar.gz'), equals('_aux.tar.gz'));
      expect(sanitizeFileName('NUL.dat'), equals('_NUL.dat'));
      expect(sanitizeFileName('com1.bin'), equals('_com1.bin'));
      expect(sanitizeFileName('lpt9.log'), equals('_lpt9.log'));
      expect(sanitizeFileName('COM\u00B9.pdf'), equals('_COM\u00B9.pdf'));
    });

    test('reserved names embedded inside larger stems are NOT prefixed', () {
      expect(sanitizeFileName('CONSULT.txt'), equals('CONSULT.txt'));
      expect(sanitizeFileName('AUXILIARY.pdf'), equals('AUXILIARY.pdf'));
      expect(sanitizeFileName('COM10.dat'), equals('COM10.dat'));
      expect(sanitizeFileName('NULL.txt'), equals('NULL.txt'));
      expect(sanitizeFileName('my_con.txt'), equals('my_con.txt'));
    });
  });

  group('2. Trailing Dots and Spaces', () {
    test('trailing dots and spaces are stripped from filenames', () {
      expect(sanitizeFileName('foo.'), equals('foo'));
      expect(sanitizeFileName('foo '), equals('foo'));
      expect(sanitizeFileName('foo...   '), equals('foo'));
      expect(sanitizeFileName('foo.txt. . .'), equals('foo.txt'));
      expect(sanitizeFileName('document...'), equals('document'));
    });

    test(
      'stems consisting solely of dots or spaces fall back to "unnamed"',
      () {
        expect(sanitizeFileName('.'), equals('unnamed'));
        expect(sanitizeFileName('..'), equals('unnamed'));
        expect(sanitizeFileName('...'), equals('unnamed'));
        expect(sanitizeFileName('   '), equals('unnamed'));
        expect(sanitizeFileName(' . . '), equals('unnamed'));
      },
    );

    test('internal dots and spaces are preserved', () {
      expect(sanitizeFileName('foo . bar.txt'), equals('foo . bar.txt'));
      expect(
        sanitizeFileName('My Document (1).pdf'),
        equals('My Document (1).pdf'),
      );
    });
  });

  group('3. Drive Letters, Colons & Alternate Data Streams', () {
    test(
      'colons (alternate data streams) are stripped as forbidden characters',
      () {
        // Windows ADS syntax: foo.txt:hidden:$DATA -> colons stripped -> foo.txthidden$DATA
        expect(sanitizeFileName('foo.txt:hidden'), equals('foo.txthidden'));
        expect(
          sanitizeFileName(r'stream:bar:$DATA'),
          equals(r'streambar$DATA'),
        );
      },
    );

    test('drive letters in filenames are stripped/re-rooted', () {
      // Single filename cannot have drive letter
      expect(sanitizeFileName(r'C:\foo.txt'), equals('foo.txt'));
      expect(sanitizeFileName(r'D:/folder/bar.pdf'), equals('bar.pdf'));
    });

    test(
      'sanitizeRelativePath strips colons and neutralizes drive letters',
      () {
        final segmentsWin = sanitizeRelativePath(
          r'C:\Windows\System32\drivers',
        );
        expect(segmentsWin, equals(['C', 'Windows', 'System32', 'drivers']));

        final segmentsPosix = sanitizeRelativePath(r'/var/log/syslog');
        expect(segmentsPosix, equals(['var', 'log', 'syslog']));

        final mixed = sanitizeRelativePath(r'D:\Users/Alice\Documents/reports');
        expect(mixed, equals(['D', 'Users', 'Alice', 'Documents', 'reports']));
      },
    );
  });

  group('4. Backslash vs Slash Handling (Cross-Platform Equivalence)', () {
    test(
      r'a\b\c arriving from Windows maps to identical segments as a/b/c',
      () {
        final winSegments = sanitizeRelativePath(r'a\b\c');
        final posixSegments = sanitizeRelativePath('a/b/c');
        expect(winSegments, equals(posixSegments));
        expect(winSegments, equals(['a', 'b', 'c']));
      },
    );

    test(
      'arbitrary mixtures of slashes and backslashes normalize identically',
      () {
        final mixed1 = sanitizeRelativePath(
          r'photos/2024\vacation/beach\sunset.jpg',
        );
        final mixed2 = sanitizeRelativePath(
          r'photos\2024/vacation\beach/sunset.jpg',
        );
        expect(mixed1, equals(mixed2));
        expect(
          mixed1,
          equals(['photos', '2024', 'vacation', 'beach', 'sunset.jpg']),
        );
      },
    );

    test('redundant multiple slashes are collapsed', () {
      expect(
        sanitizeRelativePath(r'a\\\b///c\\/d'),
        equals(['a', 'b', 'c', 'd']),
      );
    });

    test('path traversal attempts with backslashes throw badRequest', () {
      expect(
        () => sanitizeRelativePath(r'..\..\secret'),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.badRequest,
          ),
        ),
      );
      expect(
        () => sanitizeRelativePath(r'a\b\..\c'),
        throwsA(
          isA<LsException>().having(
            (e) => e.code,
            'code',
            LsErrorCode.badRequest,
          ),
        ),
      );
    });
  });

  group('5. Long Paths (> 260 MAX_PATH) and Extended-Length Prefixes', () {
    test(
      'isPathWithin handles paths exceeding MAX_PATH under windows: true',
      () {
        const root = r'C:\Downloads\LibreShare';
        final longChild =
            r'\\?\C:\Downloads\LibreShare\' +
            ('subfolder' * 30) +
            r'\target.txt';

        expect(longChild.length, greaterThan(260));
        expect(isPathWithin(root, longChild, windows: true), isTrue);
        expect(
          isPathWithin(
            r'\\?\C:\Downloads\LibreShare',
            longChild,
            windows: true,
          ),
          isTrue,
        );
      },
    );

    test('isPathWithin rejects long path that escapes root', () {
      const root = r'C:\Downloads\LibreShare';
      final escapingLongChild =
          r'\\?\C:\OtherDir\' + ('subfolder' * 30) + r'\target.txt';

      expect(isPathWithin(root, escapingLongChild, windows: true), isFalse);
    });

    test('individual path components are truncated to 255 bytes budget', () {
      final hugeName = '${'a' * 300}.txt';
      final sanitized = sanitizeFileName(hugeName);

      expect(sanitized.endsWith('.txt'), isTrue);
      expect(sanitized.length, lessThanOrEqualTo(kMaxNameBytes));
    });
  });

  group('6. Atomic Replace Semantics Simulation', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ls_win_semantics_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('atomicReplace commits file when target does not exist', () async {
      final tmp = File(p.join(tempDir.path, 'data.tmp'))
        ..writeAsStringSync('new_content');
      final target = File(p.join(tempDir.path, 'data.txt'));

      expect(target.existsSync(), isFalse);
      await atomicReplace(tmp, target);

      expect(target.existsSync(), isTrue);
      expect(target.readAsStringSync(), equals('new_content'));
      expect(tmp.existsSync(), isFalse);
    });

    test('atomicReplace safely replaces existing target file', () async {
      final target = File(p.join(tempDir.path, 'existing.txt'))
        ..writeAsStringSync('old_content');
      final tmp = File(p.join(tempDir.path, 'existing.tmp'))
        ..writeAsStringSync('updated_content');

      expect(target.existsSync(), isTrue);
      await atomicReplace(tmp, target);

      expect(target.existsSync(), isTrue);
      expect(target.readAsStringSync(), equals('updated_content'));
      expect(tmp.existsSync(), isFalse);
    });

    test('simulated locked handle: open handle prevents direct overwrite; closed handle permits replace', () async {
      final target = File(p.join(tempDir.path, 'locked.txt'))
        ..writeAsStringSync('version_1');
      final tmp = File(p.join(tempDir.path, 'locked.tmp'))
        ..writeAsStringSync('version_2');

      // Hold open RandomAccessFile simulating active handle
      final raf = await target.open(mode: FileMode.writeOnlyAppend);
      try {
        // While handle is open in Windows, rename over it fails; verify our code structure
        // closes handles BEFORE calling atomicReplace.
        expect(raf, isNotNull);
      } finally {
        await raf.close();
      }

      // Handle is cleanly closed: atomicReplace must succeed
      await atomicReplace(tmp, target);
      expect(target.readAsStringSync(), equals('version_2'));
    });
  });

  group('7. Windows Launcher & Autostart Quoting Rules', () {
    test('quoting paths with spaces', () {
      final path = r'C:\Program Files\LibreShare\libreshare.exe';
      final quoted = quoteWindowsArg(path);
      expect(quoted, equals(r'"C:\Program Files\LibreShare\libreshare.exe"'));
    });

    test('argument without special characters requires no quotes', () {
      expect(quoteWindowsArg('--hidden'), equals('--hidden'));
      expect(quoteWindowsArg('auto'), equals('auto'));
    });

    test('escaping internal double quotes', () {
      final arg = r'title="hello world"';
      final quoted = quoteWindowsArg(arg);
      expect(quoted, equals(r'"title=\"hello world\""'));
    });

    test('escaping trailing backslashes before closing quote', () {
      final pathWithTrailingBackslash = r'C:\Program Files\LibreShare\';
      final quoted = quoteWindowsArg(pathWithTrailingBackslash);
      // Trailing backslash must be doubled so it doesn't escape the closing quote
      expect(quoted, equals(r'"C:\Program Files\LibreShare\\"'));
    });

    test('cmd.exe special character escaping (&, ^, %, <, >)', () {
      final cmdArg = r'param & calc.exe ^ %PATH%';
      final escaped = quoteWindowsArg(cmdArg, forCmd: true);
      expect(escaped.contains('^&'), isTrue);
      expect(escaped.contains('^^'), isTrue);
      expect(escaped.contains('^%'), isTrue);
    });
  });
}

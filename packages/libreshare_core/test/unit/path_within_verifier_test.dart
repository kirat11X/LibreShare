// VERIFIER test (E5 R1d, written by the verifier, not by tester/coder).
// 1. DIFFERENTIAL: on a non-Windows host, isPathWithin(...) with windows
//    unset or false is IDENTICAL to package:path's p.isWithin (>= 100,000
//    random pairs, zero differences allowed).
// 2. SOUNDNESS of windows:true against an independent reference model of
//    documented Win32 path resolution: whenever isPathWithin says "within",
//    the model must agree (a false "within" would let a file land outside).
import 'dart:io';
import 'dart:math';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _posixSegs = [
  'a',
  'b',
  'c',
  '..',
  '.',
  '',
  ' ',
  'a b',
  'ä',
  'Ä',
  'A',
  'ab',
  'a\\b',
  '日本',
  '...',
  'a.',
  ' a',
  '?',
  'C:',
  '\\\\?\\',
];

String _posixPath(Random r, {required bool allowRel}) {
  final n = r.nextInt(6);
  final b = StringBuffer();
  final abs = !allowRel || r.nextBool();
  if (abs) b.write('/');
  for (var i = 0; i < n; i++) {
    b.write(_posixSegs[r.nextInt(_posixSegs.length)]);
    if (i < n - 1 || r.nextInt(4) == 0) b.write(r.nextInt(8) == 0 ? '//' : '/');
  }
  return b.toString();
}

// ---- reference model of documented Win32 resolution ----
String? _modelRoot(String s, List<String> rest) {
  var t = s.replaceAll('/', r'\');
  String up(String x) => x.toLowerCase();
  String body;
  String root;
  final lower = t.toLowerCase();
  if (lower.startsWith(r'\\?\unc\')) {
    body = t.substring(8);
    final parts = body.split(r'\').where((e) => e.isNotEmpty).toList();
    if (parts.length < 2) return null;
    root = '\\\\${up(parts[0])}\\${up(parts[1])}';
    rest.addAll(parts.skip(2));
    return root;
  }
  if (t.startsWith(r'\\?\') || t.startsWith(r'\\.\')) t = t.substring(4);
  final m = RegExp(r'^([A-Za-z]):(\\|$)').firstMatch(t);
  if (m != null) {
    root = '${up(m[1]!)}:';
    rest.addAll(t.substring(m.end).split(r'\').where((e) => e.isNotEmpty));
    return root;
  }
  if (t.startsWith(r'\\')) {
    final parts = t.split(r'\').where((e) => e.isNotEmpty).toList();
    if (parts.length < 2) return null;
    rest.addAll(parts.skip(2));
    return '\\\\${up(parts[0])}\\${up(parts[1])}';
  }
  return null; // relative / drive-relative / rooted-no-drive: not comparable
}

List<String>? _modelResolve(String s, List<String> out) {
  final raw = <String>[];
  final root = _modelRoot(s, raw);
  if (root == null) return null;
  final segs = <String>[];
  for (final seg in raw) {
    if (seg == '.') continue;
    if (seg == '..') {
      if (segs.isNotEmpty) segs.removeLast();
      continue;
    }
    segs.add(seg.toLowerCase());
  }
  out
    ..add(root)
    ..addAll(segs);
  return out;
}

bool _modelWithin(String root, String cand) {
  final a = <String>[];
  final b = <String>[];
  final ra = _modelResolve(root, a);
  final rb = _modelResolve(cand, b);
  if (ra == null || rb == null) return false; // model cannot say "within"
  if (a.first != b.first || b.length <= a.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const _winPrefixes = [
  r'C:\',
  r'c:\',
  r'\\?\C:\',
  r'\\?\c:\',
  r'\\?\UNC\h\s\',
  r'\\h\s\',
  r'\\H\S\',
  r'C:',
  'C:/',
  r'D:\',
  r'\',
  r'\\.\C:\',
  '',
  r'\\?\UNC\h\s2\',
  r'\\?\unc\h\s\',
];
const _winRootPrefixes = [
  r'C:\',
  r'c:\',
  r'\\?\C:\',
  r'\\?\c:\',
  r'\\?\UNC\h\s\',
  r'\\h\s\',
  r'\\H\S\',
  'C:/',
  r'D:\',
  r'\\.\C:\',
  r'\\?\UNC\h\s2\',
  r'\\?\unc\h\s\',
];
const _winSegs = [
  'a',
  'b',
  'A',
  'B',
  'ab',
  '..',
  '.',
  '',
  'c d',
  'a.',
  'a ',
  '.. ',
  '...',
  'f.txt:s',
  'CON',
  'ä',
  'Ä',
  'a:b',
  '..\\..',
  'a/..',
];

String _winPath(Random r, {bool dotdot = true, bool rooted = false}) {
  final pre = rooted ? _winRootPrefixes : _winPrefixes;
  final b = StringBuffer(pre[r.nextInt(pre.length)]);
  final n = r.nextInt(5);
  for (var i = 0; i < n; i++) {
    var s = _winSegs[r.nextInt(_winSegs.length)];
    if (!dotdot && s.contains('..')) s = 'x';
    b.write(s);
    if (i < n - 1) b.write(r.nextBool() ? r'\' : '/');
  }
  return b.toString();
}

void main() {
  group('VERIFIER differential (POSIX host)', () {
    test('windows unset/false == p.isWithin for 250,000 random pairs '
        '(both absolute or both relative: zero differences allowed)', () {
      final r = Random(20261106);
      var pairs = 0, diffs = 0, trues = 0;
      var mixed = 0, mixedDiffs = 0, newMorePermissive = 0;
      final firstDiffs = <String>[];
      for (var i = 0; i < 250000; i++) {
        final root = _posixPath(r, allowRel: true);
        final cand = r.nextBool()
            ? _posixPath(r, allowRel: true)
            : root +
                  (r.nextBool() ? '/' : '') +
                  _posixPath(r, allowRel: false).replaceFirst('/', '');
        final ref = p.isWithin(root, cand);
        final a = isPathWithin(root, cand);
        final b = isPathWithin(root, cand, windows: false);
        // A relative path whose normal form starts with `..` (or any abs/rel
        // mix) depends on the process cwd for p.isWithin; the new code
        // (p.posix, current '.') cannot resolve it.
        bool upRel(String x) =>
            !p.isAbsolute(x) && p.posix.normalize(x).startsWith('..');
        final isMixed =
            p.isAbsolute(root) != p.isAbsolute(cand) ||
            upRel(root) ||
            upRel(cand);
        if (isMixed) {
          mixed++;
          if (a != ref || b != ref) mixedDiffs++;
          if ((a && !ref) || (b && !ref)) newMorePermissive++;
          continue;
        }
        pairs++;
        if (ref) trues++;
        if (a != ref || b != ref) {
          diffs++;
          if (firstDiffs.length < 5) firstDiffs.add('[$root] [$cand]');
        }
      }
      // ignore: avoid_print
      print(
        'DIFFERENTIAL same-kind pairs=$pairs within-true=$trues '
        'differences=$diffs | cwd-dependent (abs/rel mix or leading ..) pairs=$mixed '
        'differences=$mixedDiffs new-more-permissive=$newMorePermissive',
      );
      expect(firstDiffs, isEmpty);
      expect(diffs, 0);
      expect(trues, greaterThan(10000), reason: 'generator must hit true');
      // the new code is NEVER more permissive than p.isWithin
      expect(newMorePermissive, 0);
    }, skip: Platform.isWindows ? 'POSIX host only' : null);

    test(
      'KNOWN DEVIATION (informational): absolute root vs relative candidate '
      'differs from p.isWithin (p.posix has current ".", p.context uses cwd)',
      () {
        // old p.isWithin('/', 'a') is true when cwd is under '/', new is false:
        // stricter, and production always passes absolute paths.
        expect(isPathWithin('/', 'a'), isFalse);
      },
      skip: Platform.isWindows ? 'POSIX host only' : null,
    );
  });

  group('VERIFIER windows:true soundness vs reference model', () {
    test('within => the independent Win32 model agrees (300,000 pairs)', () {
      final r = Random(77);
      var unsound = 0;
      var withinTrue = 0;
      var pairs = 0;
      final examples = <String>[];
      for (var i = 0; i < 300000; i++) {
        final root = _winPath(r, dotdot: false, rooted: true);
        final cand = r.nextBool()
            ? _winPath(r)
            : root +
                  (r.nextBool() ? r'\' : '/') +
                  _winPath(r).replaceFirst(RegExp(r'^[^\\/]*[\\/]?'), '');
        final got = isPathWithin(root, cand, windows: true);
        pairs++;
        if (got) withinTrue++;
        if (got && !_modelWithin(root, cand)) {
          unsound++;
          if (examples.length < 15) examples.add('[$root] [$cand]');
        }
      }
      // ignore: avoid_print
      print(
        'WIN-SOUNDNESS pairs=$pairs within-true=$withinTrue '
        'model-disagrees=$unsound',
      );
      for (final e in examples) {
        // ignore: avoid_print
        print('  disagreement: $e');
      }
      expect(withinTrue, greaterThan(5000));
      expect(examples, isEmpty);
    });
  });

  group('VERIFIER windows:true explicit probes', () {
    bool w(String a, String b) => isPathWithin(a, b, windows: true);
    test('equal root is not within; common-prefix sibling is not within', () {
      expect(w(r'C:\a', r'C:\a'), isFalse);
      expect(w(r'C:\a', r'C:\a\'), isFalse);
      expect(w(r'C:\a', r'C:\ab'), isFalse);
      expect(w(r'C:\a', r'\\?\C:\AB\x'), isFalse);
    });
    test('drive-relative, rooted-without-drive, other drive, device paths', () {
      expect(w(r'C:\a', 'C:x'), isFalse);
      expect(w(r'C:\a', r'C:a\b'), isFalse);
      expect(w(r'C:\a', r'\a\b'), isFalse);
      expect(w(r'C:\a', r'D:\a\b'), isFalse);
      expect(w(r'C:\a', r'\\.\C:\a\b'), isFalse); // conservative
      expect(w(r'C:\a', r'\\.\CON'), isFalse);
    });
    test('dot-dot via any separator / prefix cannot escape', () {
      expect(w(r'C:\a', r'C:\a\..\b'), isFalse);
      expect(w(r'C:\a', 'C:/a/../b'), isFalse);
      expect(w(r'C:\a', r'\\?\C:\a\b\..\..\x'), isFalse);
      expect(w(r'\\h\s\d', r'\\?\UNC\h\s\d\..\..\x'), isFalse);
    });
    test('ADS and trailing dot stay inside (same directory on Windows)', () {
      expect(w(r'C:\a', r'C:\a\f.txt:s'), isTrue);
      expect(w(r'C:\a', r'C:\a\b.'), isTrue);
    });
    test('KNOWN LIMIT (informational): lower-case \\\\?\\unc\\ prefix is not '
        'recognised -> false negative only (safe direction)', () {
      expect(w(r'\\?\UNC\h\s\d', r'\\?\unc\h\s\d\x'), isFalse);
    });
    test(
      'forward-slash verbatim forms are unified before prefix stripping',
      () {
        expect(w(r'C:\a', '//?/C:/a/b'), isTrue);
        expect(w(r'\\h\s\d', '//?/UNC/h/s/d/x'), isTrue);
        expect(w('//?/C:/a', r'C:\a\b'), isTrue);
        expect(w(r'C:\a', '//?/C:/a/../b'), isFalse);
      },
    );
    test('default (null) on a POSIX host takes the POSIX branch', () {
      expect(isPathWithin(r'C:\a', r'C:\a\b'), isFalse);
      expect(isPathWithin(r'C:\a', r'C:\a\b', windows: true), isTrue);
    }, skip: Platform.isWindows ? 'POSIX host only' : null);
  });

  group('VERIFIER wiring (source guard; the swap is behaviour-neutral on '
      'POSIX so only the source can show it)', () {
    final src = File('lib/src/transfer/filename_sanitizer.dart')
        .readAsStringSync();
    String body(String startMarker, String endMarker) {
      final a = src.indexOf(startMarker);
      final b = src.indexOf(endMarker, a + 1);
      expect(a, greaterThanOrEqualTo(0), reason: startMarker);
      expect(b, greaterThan(a), reason: endMarker);
      return src.substring(a, b);
    }

    test('assertInsideDir compares with isPathWithin, not p.isWithin', () {
      final b = body('void assertInsideDir(', 'String _realOrSelf(');
      expect(b, contains('isPathWithin(rootReal, resolved)'));
      expect(b, isNot(contains('p.isWithin')));
    });
    test('resolveTarget symlinked-dir check (site 1) uses isPathWithin', () {
      final b = body(
        'if (type == FileSystemEntityType.link) {',
        'candidate = withCollisionSuffix(seg',
      );
      expect(b, contains('isPathWithin(rootReal, resolved)'));
      expect(b, isNot(contains('p.isWithin')));
    });
    test('resolveTarget accept() (site 2) uses isPathWithin', () {
      final b = body(
        'File accept(String candidate) {',
        'return File(p.join(cur, candidate));',
      );
      expect(b, contains('isPathWithin(rootReal, resolved)'));
      expect(b, isNot(contains('p.isWithin')));
    });
    test('no p.isWithin( call is left in the sanitizer code', () {
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(RegExp(r'\bp\.isWithin\(').hasMatch(code), isFalse);
    });
  });
}

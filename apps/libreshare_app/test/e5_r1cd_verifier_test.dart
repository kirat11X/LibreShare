// VERIFIER tests (E5 R1c/R1d), written by the verifier, not tester/coder.
//  1. parentDir NEW vs the ORIGINAL implementation (copied below): identical
//     for every input that does not begin with a Windows root.
//  2. parentDir invariants on random Windows-looking paths.
//  3. Launcher argv invariants over random names on every platform: no shell,
//     the path is exactly ONE element, option elements are fixed literals.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/services/file_launcher.dart';
import 'package:libreshare_app/services/paths.dart';

String _oldParentDir(String path) {
  final i = path.lastIndexOf(RegExp(r'[/\\]'));
  if (i < 0) return '.';
  if (i == 0) return path.substring(0, 1);
  return path.substring(0, i);
}

const _segs = [
  'a',
  'b',
  'a b',
  '',
  '.',
  '..',
  'é',
  '日本',
  '#1',
  '&',
  ',',
  '"',
  "'",
  '%',
  '-x',
  '--help',
  '/select,',
  r'C:',
  '?',
  'x\\y',
  ' ',
];

String _rand(Random r, List<String> prefixes) {
  final b = StringBuffer(prefixes[r.nextInt(prefixes.length)]);
  final n = r.nextInt(5);
  for (var i = 0; i < n; i++) {
    b.write(_segs[r.nextInt(_segs.length)]);
    if (i < n - 1 || r.nextInt(5) == 0) b.write(r.nextBool() ? '/' : r'\');
  }
  return b.toString();
}

void main() {
  test('VERIFIER parentDir == original for non-Windows-root inputs (200k)', () {
    final r = Random(11);
    final winRoot = RegExp(r'^(?:\\\\|[A-Za-z]:[/\\])');
    var n = 0, diffs = 0;
    for (var i = 0; i < 200000; i++) {
      final s = _rand(r, [
        '',
        '/',
        '//',
        'a/',
        '/storage/emulated/0/',
        '.',
        r'\x',
      ]);
      if (winRoot.hasMatch(s)) continue;
      n++;
      if (parentDir(s) != _oldParentDir(s)) diffs++;
    }
    // ignore: avoid_print
    print('PARENTDIR differential compared=$n differences=$diffs');
    expect(diffs, 0);
  });

  test('VERIFIER parentDir invariants on Windows-looking paths (200k)', () {
    final r = Random(12);
    const pre = [
      r'C:\',
      'c:/',
      r'\\?\C:\',
      r'\\host\share\',
      r'\\?\UNC\h\s\',
      r'\\host\share',
      r'C:\Users\',
    ];
    for (var i = 0; i < 200000; i++) {
      final s = _rand(r, pre);
      final d = parentDir(s);
      // never throws, result is a prefix of the input (or '.'), idempotent end
      expect(s.startsWith(d) || d == '.', isTrue, reason: s);
      expect(d.length <= s.length, isTrue, reason: s);
      expect(
        parentDir(d) == d || parentDir(d).length < d.length,
        isTrue,
        reason: s,
      );
      // a drive root / share root is never truncated below the root
      if (RegExp(r'^[A-Za-z]:[/\\]').hasMatch(s)) {
        expect(d.length >= 3, isTrue, reason: s);
      }
    }
  });

  test('VERIFIER launcher argv: one path element, fixed options, no shell', () {
    final r = Random(13);
    const shells = {'cmd', 'cmd.exe', 'sh', 'bash', 'powershell', 'pwsh'};
    for (var i = 0; i < 20000; i++) {
      final path = _rand(r, [
        r'C:\Users\Me\',
        r'\\h\s\d\',
        '/home/me/',
        '/tmp/',
      ]);
      for (final os in ['windows', 'linux', 'macos']) {
        final shown = os == 'windows' ? path.replaceAll('/', r'\') : path;
        for (final c in [
          openCommand(path, platform: os)!,
          showInFolderCommand(path, platform: os)!,
        ]) {
          expect(shells.contains(c.executable.toLowerCase()), isFalse);
          expect(
            c.arguments.every((a) => !a.contains('&&')) || path.contains('&&'),
            isTrue,
          );
          final opts = c.arguments
              .where((a) => a != shown && a != parentDir(path))
              .toList();
          // only fixed literals besides the path
          expect(
            opts.every(
              (a) => const {
                'url.dll,FileProtocolHandler',
                '/select,',
                '-R',
              }.contains(a),
            ),
            isTrue,
            reason: '$os $path -> ${c.arguments}',
          );
          expect(c.arguments.length, lessThanOrEqualTo(2));
        }
      }
    }
  });

  test('VERIFIER exact argv table', () {
    String d(LaunchCommand? c) =>
        c == null ? 'null' : '${c.executable} ${c.arguments}';
    const w = r'C:/Users/Me/a b.txt';
    // ignore: avoid_print
    for (final os in [
      'windows',
      'linux',
      'macos',
      'android',
      'ios',
      'fuchsia',
    ]) {
      // ignore: avoid_print
      print(
        'ARGV $os open=${d(openCommand(os == 'windows' ? w : '/h/a b.txt', platform: os))} '
        'show=${d(showInFolderCommand(os == 'windows' ? w : '/h/a b.txt', platform: os))}',
      );
    }
  });
}

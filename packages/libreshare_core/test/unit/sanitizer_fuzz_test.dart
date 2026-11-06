import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:libreshare_core/src/model/ls_exception.dart';
import 'package:libreshare_core/src/transfer/filename_sanitizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _tokens = <String>[
  '..',
  '.',
  '...',
  '/',
  '\\',
  '//',
  '\\\\',
  ':',
  '<',
  '>',
  '"',
  '|',
  '?',
  '*',
  ' ',
  '  ',
  '\t',
  '\n',
  '\r',
  '\u0000',
  '\u0001',
  '\u001f',
  '\u007f',
  '\u0085',
  '\u009f',
  '\u202E',
  '\u200B',
  '\u200D',
  '\uFEFF',
  '\u2028',
  'CON',
  'con',
  'NUL',
  'nul.txt',
  'PRN',
  'AUX',
  'COM1',
  'com9.txt',
  'LPT1',
  'lpt9',
  'COM\u00B9',
  '../',
  '..\\',
  '/..',
  '\\..',
  '../../',
  '..\\..\\',
  '/etc/passwd',
  'C:\\Windows\\system32',
  'C:',
  '~',
  '\$HOME',
  '%2e%2e%2f',
  '%00',
  'a',
  'b.txt',
  '.txt',
  '.hidden',
  'name',
  'Caf\u00e9',
  'e\u0301',
  'a\u0308\u0323',
  '\u1112\u1161\u11ab',
  '\u304b\u3099',
  '\u65e5\u672c\u8a9e',
  '\u{1F600}',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}',
  '\u0627\u0644\u0639\u0631\u0628\u064a\u0629',
  '\u00e9'
      '\u00e9'
      '\u00e9'
      '\u00e9'
      '\u00e9'
      '\u00e9'
      '\u00e9'
      '\u00e9',
];

String _randomString(Random rnd) {
  final sb = StringBuffer();
  final n = rnd.nextInt(10);
  for (var i = 0; i < n; i++) {
    switch (rnd.nextInt(10)) {
      case 0:
        // arbitrary BMP code point (incl. lone surrogates)
        sb.writeCharCode(rnd.nextInt(0x10000));
      case 1:
        // arbitrary astral code point
        sb.writeCharCode(0x10000 + rnd.nextInt(0x100000));
      case 2:
        // long run to force truncation
        sb.write(
          String.fromCharCode(
                rnd.nextBool() ? 0x61 : (rnd.nextBool() ? 0xE9 : 0x65E5),
              ) *
              (50 + rnd.nextInt(400)),
        );
      case 3:
        sb.writeCharCode(rnd.nextInt(0x80));
      default:
        sb.write(_tokens[rnd.nextInt(_tokens.length)]);
    }
  }
  return sb.toString();
}

bool _hasControl(String s) => s.runes.any(
  (r) =>
      r < 0x20 ||
      (r >= 0x7F && r <= 0x9F) ||
      r == 0x202E ||
      r == 0x200B ||
      r == 0xFEFF ||
      r == 0x2028 ||
      (r >= 0xD800 && r <= 0xDFFF),
);

final _forbidden = RegExp(r'[<>:"/\\|?*]');
final _reserved = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9\u00B9\u00B2\u00B3]|LPT[1-9\u00B9\u00B2\u00B3])$',
  caseSensitive: false,
);

void _expectSafeComponent(String c, {required String ctx}) {
  expect(c, isNotEmpty, reason: ctx);
  expect(c, isNot('.'), reason: ctx);
  expect(c, isNot('..'), reason: ctx);
  expect(_hasControl(c), isFalse, reason: 'control char in "$c" ($ctx)');
  expect(_forbidden.hasMatch(c), isFalse, reason: 'forbidden char in "$c"');
  expect(utf8.encode(c).length, lessThanOrEqualTo(255), reason: ctx);
  expect(c.endsWith('.') || c.endsWith(' '), isFalse, reason: '"$c"');
  expect(c.startsWith(' '), isFalse, reason: '"$c"');
  final dot = c.indexOf('.');
  final base = (dot < 0 ? c : c.substring(0, dot)).trimRight();
  expect(_reserved.hasMatch(base), isFalse, reason: 'reserved "$c"');
  // valid UTF-16 (no lone surrogates) and valid UTF-8 round trip
  expect(utf8.decode(utf8.encode(c)), c, reason: ctx);
}

bool _relativePathHasDotDotSegment(String rel) =>
    rel.split(RegExp(r'[\\/]')).any((s) => s == '..');

void main() {
  late Directory tmp;
  late Directory dl;
  late String dlReal;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('ls_fuzz_');
    dl = Directory(p.join(tmp.path, 'dl'))..createSync();
    dlReal = dl.resolveSymbolicLinksSync();
    // A hostile layout: symlinks inside the download dir pointing outside.
    final outside = Directory(p.join(tmp.path, 'outside'))..createSync();
    for (final n in ['link', 'a', 'photos', 'etc', 'name', 'b.txt', 'CON']) {
      Link(p.join(dl.path, n)).createSync(outside.path);
    }
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('sanitizeFileName: 10,000 adversarial names are always safe', () {
    final rnd = Random(0x5eed);
    for (var i = 0; i < 10000; i++) {
      final input = _randomString(rnd);
      final out = sanitizeFileName(input);
      _expectSafeComponent(out, ctx: 'input #$i ${jsonEncode(input)}');
      // idempotent
      expect(
        sanitizeFileName(out),
        out,
        reason: 'not idempotent: ${jsonEncode(input)} -> ${jsonEncode(out)}',
      );
    }
  });

  test('sanitizeRelativePath: never emits .. / separators, rejects ..', () {
    final rnd = Random(0xC0FFEE);
    for (var i = 0; i < 10000; i++) {
      final input = _randomString(rnd);
      final hasDotDot = _relativePathHasDotDotSegment(input);
      try {
        final segs = sanitizeRelativePath(input);
        expect(
          hasDotDot,
          isFalse,
          reason: 'accepted ".." segment in ${jsonEncode(input)}',
        );
        for (final s in segs) {
          _expectSafeComponent(s, ctx: 'segment of ${jsonEncode(input)}');
        }
      } on LsException catch (e) {
        expect(e.code, LsErrorCode.badRequest);
        expect(
          input.contains('..'),
          isTrue,
          reason: 'rejected without any ".." in ${jsonEncode(input)}',
        );
      }
    }
  });

  test('resolveTarget: 10,000 random name/path pairs stay inside the dir', () {
    final rnd = Random(42);
    var rejected = 0;
    for (var i = 0; i < 10000; i++) {
      final name = _randomString(rnd);
      final rel = rnd.nextInt(3) == 0 ? null : _randomString(rnd);
      final ctx = 'name=${jsonEncode(name)} rel=${jsonEncode(rel)}';
      final File f;
      try {
        f = resolveTarget(downloadDir: dl, fileName: name, relativePath: rel);
      } on LsException catch (e) {
        expect(e.code, LsErrorCode.badRequest, reason: ctx);
        expect(rel, isNotNull, reason: ctx);
        expect(rel!.contains('..'), isTrue, reason: ctx);
        rejected++;
        continue;
      }
      if (rel != null) {
        expect(
          _relativePathHasDotDotSegment(rel),
          isFalse,
          reason: 'accepted ".." in $ctx',
        );
      }
      // lexically inside, canonical, no '..' segments
      expect(p.isWithin(dl.path, f.path), isTrue, reason: ctx);
      expect(p.normalize(f.path), f.path, reason: ctx);
      final relParts = p.split(p.relative(f.path, from: dl.path));
      expect(relParts, isNotEmpty, reason: ctx);
      for (final c in relParts) {
        _expectSafeComponent(c, ctx: ctx);
      }
      // base name leaves room for the .lspart suffix
      expect(
        utf8.encode(relParts.last).length + '.lspart.json.tmp'.length,
        lessThanOrEqualTo(255),
        reason: ctx,
      );
      // really inside after resolving symlinks of the existing chain
      assertInsideDir(dl, f.path);
      var existing = f.path;
      while (FileSystemEntity.typeSync(existing, followLinks: false) ==
          FileSystemEntityType.notFound) {
        existing = p.dirname(existing);
      }
      final real = Directory(existing).resolveSymbolicLinksSync();
      expect(
        real == dlReal || p.isWithin(dlReal, real),
        isTrue,
        reason: 'resolved $real escapes $dlReal ($ctx)',
      );
      // the target itself must not exist (never overwrite / follow a link)
      expect(
        FileSystemEntity.typeSync(f.path, followLinks: false),
        FileSystemEntityType.notFound,
        reason: ctx,
      );
    }
    // sanity: the generator actually exercised the rejection path
    expect(rejected, greaterThan(100));
  });
}

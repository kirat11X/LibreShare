// Proof for mutant M68: direct candidate kind must be in the whitelist.
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/src/share/share_link.dart';
import 'package:test/test.dart';

String _b64(List<int> b) => base64UrlEncode(b).replaceAll('=', '');

void main() {
  final t = _b64(Uint8List.fromList(List.generate(16, (i) => i + 1)));
  final k = _b64(Uint8List.fromList(List.generate(32, (i) => i + 10)));
  final pin = 'ab' * 32;
  test('unknown candidate kind is dropped', () {
    final l = ShareLink.parse(
      'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$t&k=$k&m=1&d=bogus:93.184.216.34:443&pin=$pin',
    );
    expect(l.candidates, isEmpty);
  });
  test('known kind with same host is kept (positive control)', () {
    final l = ShareLink.parse(
      'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$t&k=$k&m=1&d=manual:93.184.216.34:443&pin=$pin',
    );
    expect(l.candidates, hasLength(1));
  });
}

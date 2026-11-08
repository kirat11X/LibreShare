// Proof for mutant M65: an orphan pin (pin without any valid direct candidate) is not kept.
import 'dart:convert';
import 'dart:typed_data';

import 'package:libreshare_core/src/share/share_link.dart';
import 'package:test/test.dart';

String _b64(List<int> b) => base64UrlEncode(b).replaceAll('=', '');

void main() {
  final t = _b64(Uint8List.fromList(List.generate(16, (i) => i + 1)));
  final k = _b64(Uint8List.fromList(List.generate(32, (i) => i + 10)));
  final pin = 'ab' * 32;
  test('valid pin without candidates -> tlsPinHex null', () {
    final l = ShareLink.parse(
      'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$t&k=$k&m=1&pin=$pin',
    );
    expect(l.candidates, isEmpty);
    expect(l.tlsPinHex, isNull);
  });
  test('pin with a valid public candidate is kept (positive control)', () {
    final l = ShareLink.parse(
      'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$t&k=$k&m=1&d=ipv6:[2606:4700::1]:4430&pin=$pin',
    );
    expect(l.candidates, isNotEmpty);
    expect(l.tlsPinHex, pin);
  });
}

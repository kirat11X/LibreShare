import 'package:test/test.dart';
import 'package:libreshare_core/src/share/share_link.dart';

void main() {
  group('ShareLink d and pin Conformance Tests', () {
    const validPin =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test('Round-trip with candidates and pin', () {
      final link = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=ipv6:2001:db8::1:53330,mapped4:198.51.100.1:53330&pin=$validPin',
      );

      expect(link.host, 'alice.example.com');
      expect(link.candidates.length, 2);
      expect(link.candidates[0], 'ipv6:2001:db8::1:53330');
      expect(link.candidates[1], 'mapped4:198.51.100.1:53330');
      expect(link.tlsPinHex, validPin);

      // Verify re-encode matches
      final encoded = link.encode();
      final reparsed = ShareLink.parse(encoded);
      expect(reparsed, equals(link));
      expect(reparsed.candidates, equals(link.candidates));
      expect(reparsed.tlsPinHex, equals(link.tlsPinHex));
    });

    test('Deep link round-trip with candidates and pin', () {
      final link = ShareLink.parse(
        'libreshare://r?v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=cf:x.trycloudflare.com:443&pin=$validPin',
      );

      expect(link.candidates.length, 1);
      expect(link.candidates[0], 'cf:x.trycloudflare.com:443');
      expect(link.tlsPinHex, validPin);

      final deepEncoded = link.encodeDeepLink();
      expect(deepEncoded, startsWith('libreshare://r?'));
      final reparsed = ShareLink.parse(deepEncoded);
      expect(reparsed, equals(link));
    });

    test('Caps candidates to at most 4 (dropping surplus candidates beyond 4)', () {
      final link = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=mapped4:8.8.8.1:53330,mapped4:8.8.8.2:53330,mapped4:8.8.8.3:53330,mapped4:8.8.8.4:53330,mapped4:8.8.8.5:53330&pin=$validPin',
      );
      expect(link.candidates.length, 4);
      expect(link.candidates[0], 'mapped4:8.8.8.1:53330');
      expect(link.candidates[3], 'mapped4:8.8.8.4:53330');
    });

    test('Malformed pin drops all candidates (tunnel candidate only)', () {
      // 63 characters (too short)
      final shortPin = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=ipv6:2001:db8::1:53330&pin=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde',
      );
      expect(shortPin.candidates, isEmpty);
      expect(shortPin.tlsPinHex, isNull);

      // Non-hex character
      final badHexPin = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=ipv6:2001:db8::1:53330&pin=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg',
      );
      expect(badHexPin.candidates, isEmpty);
      expect(badHexPin.tlsPinHex, isNull);

      // 6-digit receiver PIN is not cert pin
      final numPin = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=ipv6:2001:db8::1:53330&pin=123456',
      );
      expect(numPin.candidates, isEmpty);
      expect(numPin.tlsPinHex, isNull);
    });

    test('Security Invariant: direct candidates without valid pin are never used or stored', () {
      final linkWithoutPin = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=ipv6:2001:db8::1:53330',
      );
      expect(linkWithoutPin.candidates, isEmpty);
      expect(linkWithoutPin.tlsPinHex, isNull);
      expect(linkWithoutPin.encode(), isNot(contains('&d=')));
      expect(linkWithoutPin.encode(), isNot(contains('&pin=')));
    });

    test('Private or non-routable candidates are dropped', () {
      final link = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=alice.example.com&t=QkJCQkJCQkJCQkJCQkJCQg&k=mZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZk&m=1&d=mapped4:192.168.1.50:53318,ipv6:2001:db8::1:53330&pin=$validPin',
      );
      expect(link.candidates.length, 1);
      expect(link.candidates[0], 'ipv6:2001:db8::1:53330');
    });
  });
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:libreshare_core/src/share/share_link.dart';
import 'package:test/test.dart';

String _b64url(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');

void main() {
  final sampleTokenBytes = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final sampleKeyBytes = Uint8List.fromList(List.generate(32, (i) => i + 10));
  final validToken = _b64url(sampleTokenBytes);
  final validKey = _b64url(sampleKeyBytes);
  final validHttps =
      'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$validToken&k=$validKey&m=1';
  final validDeepLink =
      'libreshare://r?v=1&h=node1.trycloudflare.com&t=$validToken&k=$validKey&m=1';

  group('Constants & Exception Formatting', () {
    test('constants match contract', () {
      expect(kShareLinkMaxChars, 2048);
      expect(kDefaultLandingBase, 'https://libreshare.github.io/r');
    });

    test(
      'ShareLinkException toString contains only error.name, never secrets',
      () {
        for (final err in ShareLinkError.values) {
          final ex = ShareLinkException(err);
          expect(ex.toString(), 'ShareLinkException(${err.name})');
          expect(ex.error, err);
        }
      },
    );

    test('ShareLink toString is redacted', () {
      final link = ShareLink.parse(validHttps);
      expect(link.toString(), 'ShareLink(redacted)');
    });
  });

  group('Parsing and Round-Trip', () {
    test('parse and round trip standard https link', () {
      final link = ShareLink.parse(validHttps);
      expect(link.version, 1);
      expect(link.host, 'node1.trycloudflare.com');
      expect(link.token, equals(sampleTokenBytes));
      expect(link.rootKey, equals(sampleKeyBytes));
      expect(link.maxReceivers, 1);
      expect(link.expiresAtUnixSeconds, isNull);
      expect(link.senderAlias, isNull);
      expect(link.senderFingerprintHint, isNull);
      expect(link.tokenB64, validToken);
      expect(link.originBase, Uri.parse('https://node1.trycloudflare.com'));

      final encoded = link.encode();
      expect(encoded, equals(validHttps));
      expect(ShareLink.parse(encoded), equals(link));
    });

    test('parse and round trip deep link', () {
      final link = ShareLink.parse(validDeepLink);
      expect(link.version, 1);
      expect(link.host, 'node1.trycloudflare.com');
      final encodedDeep = link.encodeDeepLink();
      expect(encodedDeep, equals(validDeepLink));
      expect(ShareLink.parse(encodedDeep), equals(link));
    });

    test('all optional fields present (e, n, fp)', () {
      final fullHttps =
          'https://libreshare.github.io/r#v=1&h=tunnel.example.com&t=$validToken&k=$validKey&m=5&e=1893456000&n=Alice%27s%20Phone&fp=A1B2C3D4E5F60718';
      final link = ShareLink.parse(fullHttps);
      expect(link.maxReceivers, 5);
      expect(link.expiresAtUnixSeconds, 1893456000);
      expect(link.senderAlias, "Alice's Phone");
      expect(link.senderFingerprintHint, 'A1B2C3D4E5F60718');

      final reEncoded = link.encode();
      expect(reEncoded, equals(fullHttps));
      expect(ShareLink.parse(reEncoded), equals(link));
    });

    test('trailing slash on https path /r/ is accepted', () {
      final link = ShareLink.parse(
        'https://libreshare.github.io/r/#v=1&h=node1.trycloudflare.com&t=$validToken&k=$validKey',
      );
      expect(link.host, 'node1.trycloudflare.com');
      expect(link.maxReceivers, 1); // default
    });

    test('d and pin params are accepted, ignored, and not stored', () {
      final link = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$validToken&k=$validKey&d=192.168.1.50:53318&pin=123456',
      );
      expect(link.host, 'node1.trycloudflare.com');
      expect(link.encode(), equals(validHttps));
    });

    test('unknown params are ignored', () {
      final link = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$validToken&k=$validKey&custom_foo=bar',
      );
      expect(link.host, 'node1.trycloudflare.com');
    });
  });

  group('Validation errors and security checks', () {
    test('input longer than 2048 chars throws tooLong', () {
      final long = '$validHttps&pad=${'x' * 2100}';
      expect(
        () => ShareLink.parse(long),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.tooLong,
          ),
        ),
      );
    });

    test('invalid URL scheme or path throws notALink', () {
      expect(
        () => ShareLink.parse(
          'http://libreshare.github.io/r#v=1&h=foo.com&t=$validToken&k=$validKey',
        ),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.notALink,
          ),
        ),
      );
      expect(
        () => ShareLink.parse(
          'https://libreshare.github.io/other#v=1&h=foo.com&t=$validToken&k=$validKey',
        ),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.notALink,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('ftp://foo.com/r#v=1'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.notALink,
          ),
        ),
      );
    });

    test('version != 1 throws unsupportedVersion', () {
      expect(
        () => ShareLink.parse(
          'https://libreshare.github.io/r#v=2&h=node1.trycloudflare.com&t=$validToken&k=$validKey',
        ),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.unsupportedVersion,
          ),
        ),
      );
    });

    test('missing required param throws missingParam', () {
      for (final param in ['v', 'h', 't', 'k']) {
        final uri = Uri.parse(validHttps);
        final parts = uri.fragment
            .split('&')
            .where((p) => !p.startsWith('$param='))
            .join('&');
        expect(
          () => ShareLink.parse('https://libreshare.github.io/r#$parts'),
          throwsA(
            isA<ShareLinkException>().having(
              (e) => e.error,
              'error',
              ShareLinkError.missingParam,
            ),
          ),
          reason: 'missing $param',
        );
      }
    });

    test('duplicate param throws duplicateParam', () {
      expect(
        () => ShareLink.parse('$validHttps&h=other.trycloudflare.com'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.duplicateParam,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$validHttps&v=1'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.duplicateParam,
          ),
        ),
      );
    });

    test('host validation (SSRF refusal table)', () {
      void expectBadHost(String h) {
        expect(
          () => ShareLink.parse(
            'https://libreshare.github.io/r#v=1&h=$h&t=$validToken&k=$validKey',
          ),
          throwsA(
            isA<ShareLinkException>().having(
              (e) => e.error,
              'error',
              ShareLinkError.badHost,
            ),
          ),
          reason: 'host: $h should be rejected as badHost',
        );
      }

      // IP literals in all formats
      expectBadHost('127.0.0.1');
      expectBadHost('192.168.1.1');
      expectBadHost('10.0.0.1');
      expectBadHost('2130706433'); // decimal IPv4
      expectBadHost('0x7f.0.0.1'); // hex IPv4
      expectBadHost('[::1]');
      expectBadHost('::1');
      expectBadHost('[::ffff:127.0.0.1]');

      // Local / internal domains
      expectBadHost('localhost');
      expectBadHost('myhost.localhost');
      expectBadHost('service.local');
      expectBadHost('router.internal');
      expectBadHost('server.lan');
      expectBadHost('node.home.arpa');
      expectBadHost('device.test');
      expectBadHost('device.invalid');
      expectBadHost('device.example');

      // Formatting violations
      expectBadHost(
        'tunnel.com:8080',
      ); // port disallowed without allowDeveloperHosts
      expectBadHost('user@tunnel.com'); // userinfo disallowed
      expectBadHost('tunnel..com');
      expectBadHost('-startdash.com');
      expectBadHost('enddash-.com');
      expectBadHost('nodot'); // single label
      expectBadHost('tunnel.123'); // TLD all digits
      expectBadHost('tunnel.com.'); // trailing dot disallowed
      expectBadHost('tünnel.com'); // non-ASCII without punycode
      expectBadHost('tunnel%20name.com'); // percent encoding disallowed in host
    });

    test('allowDeveloperHosts allows localhost, IP literal and port suffix', () {
      final link1 = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=127.0.0.1:8080&t=$validToken&k=$validKey',
        allowDeveloperHosts: true,
      );
      expect(link1.host, '127.0.0.1:8080');
      expect(link1.originBase, Uri.parse('https://127.0.0.1:8080'));

      final link2 = ShareLink.parse(
        'https://libreshare.github.io/r#v=1&h=localhost:3000&t=$validToken&k=$validKey',
        allowDeveloperHosts: true,
      );
      expect(link2.host, 'localhost:3000');
    });

    test('token and key validation (badToken, badKey)', () {
      // Wrong lengths
      expect(
        () => ShareLink.parse(
          'https://libreshare.github.io/r#v=1&h=foo.com&t=AAAA&k=$validKey',
        ),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badToken,
          ),
        ),
      );
      expect(
        () => ShareLink.parse(
          'https://libreshare.github.io/r#v=1&h=foo.com&t=$validToken&k=AAAA',
        ),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badKey,
          ),
        ),
      );

      // Padding disallowed
      expect(
        () => ShareLink.parse(
          'https://libreshare.github.io/r#v=1&h=foo.com&t=$validToken==&k=$validKey',
        ),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badToken,
          ),
        ),
      );

      // Illegal characters
      expect(
        () => ShareLink.parse(
          'https://libreshare.github.io/r#v=1&h=foo.com&t=${validToken.substring(0, 21)}!&k=$validKey',
        ),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badToken,
          ),
        ),
      );
    });

    test('bounds validation for m, e, n, fp', () {
      final baseNoM =
          'https://libreshare.github.io/r#v=1&h=node1.trycloudflare.com&t=$validToken&k=$validKey';

      // badMaxReceivers (must be decimal integer 0..1000)
      expect(
        () => ShareLink.parse('$baseNoM&m=-1'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badMaxReceivers,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$baseNoM&m=1001'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badMaxReceivers,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$baseNoM&m=abc'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badMaxReceivers,
          ),
        ),
      );

      // badExpiry (decimal 1..2^40)
      expect(
        () => ShareLink.parse('$validHttps&e=0'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badExpiry,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$validHttps&e=-10'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badExpiry,
          ),
        ),
      );

      // badAlias (1..64 chars, no control chars, no bidi overrides U+202A-202E, U+2066-2069)
      expect(
        () => ShareLink.parse('$validHttps&n='),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badAlias,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$validHttps&n=${Uri.encodeComponent('x' * 65)}'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badAlias,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$validHttps&n=Hello%00World'),
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badAlias,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$validHttps&n=test%E2%80%AAname'), // U+202A
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badAlias,
          ),
        ),
      );

      // badFingerprintHint (8..64 hex characters)
      expect(
        () => ShareLink.parse('$validHttps&fp=1234'), // too short (< 8)
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badFingerprintHint,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$validHttps&fp=${'A' * 65}'), // too long (> 64)
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badFingerprintHint,
          ),
        ),
      );
      expect(
        () => ShareLink.parse('$validHttps&fp=1234567Z'), // non-hex
        throwsA(
          isA<ShareLinkException>().having(
            (e) => e.error,
            'error',
            ShareLinkError.badFingerprintHint,
          ),
        ),
      );
    });

    test('isExpired check with injected DateTime', () {
      final link = ShareLink.parse('$validHttps&e=1000');
      expect(
        link.isExpired(
          DateTime.fromMillisecondsSinceEpoch(999 * 1000, isUtc: true),
        ),
        isFalse,
      );
      expect(
        link.isExpired(
          DateTime.fromMillisecondsSinceEpoch(1000 * 1000, isUtc: true),
        ),
        isTrue,
      );
      expect(
        link.isExpired(
          DateTime.fromMillisecondsSinceEpoch(1001 * 1000, isUtc: true),
        ),
        isTrue,
      );

      final unexpired = ShareLink.parse(validHttps);
      expect(unexpired.isExpired(DateTime.now()), isFalse);
    });
  });

  group('Fuzz loop (1000 iterations)', () {
    test('random mutations throw ShareLinkException or return valid link, never other exception', () {
      final rng = Random(12345);
      final chars =
          'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789&=%_/-.:?#';

      for (var i = 0; i < 1000; i++) {
        var str = validHttps;
        final mutationType = rng.nextInt(4);
        if (mutationType == 0) {
          // Flip random char
          final pos = rng.nextInt(str.length);
          str =
              str.substring(0, pos) +
              chars[rng.nextInt(chars.length)] +
              str.substring(pos + 1);
        } else if (mutationType == 1) {
          // Truncate
          str = str.substring(0, rng.nextInt(str.length));
        } else if (mutationType == 2) {
          // Insert garbage
          final pos = rng.nextInt(str.length);
          str =
              str.substring(0, pos) +
              chars[rng.nextInt(chars.length)] +
              str.substring(pos);
        } else {
          // Append random query/param
          str = '$str&extra=${chars[rng.nextInt(chars.length)]}';
        }

        try {
          ShareLink.parse(str);
        } on ShareLinkException {
          // Expected
        } catch (e, st) {
          fail(
            'Unexpected exception type ${e.runtimeType} on input "$str":\n$e\n$st',
          );
        }
      }
    });
  });
}

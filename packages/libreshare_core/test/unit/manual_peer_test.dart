// QR / manual pairing (spec 4.2 rule 6, screen 8): strict parsing of
// libreshare://peer?... links, the fingerprint helpers and ManualPeerResolver.
import 'dart:async';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:test/test.dart';

import '../helpers/api_fake_handler.dart';

final String fp =
    List.generate(32, (i) => (i * 7 % 256)) // deterministic
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
const String uuid = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

Matcher get badLink => isA<FormatException>();

String link(String query) => 'libreshare://peer?$query';

void main() {
  group('PeerLink.parse - valid links', () {
    test('full link, every field', () {
      final l = PeerLink.parse(
        'libreshare://peer?ip=192.168.1.23&port=53320&fp=${fp.toLowerCase()}'
        '&id=${uuid.toUpperCase()}&n=Ravi-ThinkPad',
      );
      expect(l.ip, '192.168.1.23');
      expect(l.port, 53320);
      expect(l.fingerprint, fp, reason: 'fingerprint is normalised to upper');
      expect(l.deviceId, uuid, reason: 'uuid is normalised to lower');
      expect(l.alias, 'Ravi-ThinkPad');
    });

    test('only ip is required; port defaults to 53318', () {
      final l = PeerLink.parse(link('ip=10.0.0.5'));
      expect(l.port, kDefaultPort);
      expect(l.fingerprint, isNull);
      expect(l.deviceId, isNull);
      expect(l.alias, isNull);
    });

    test(
      'scheme and host are case-insensitive (RFC 3986); one "/" allowed',
      () {
        expect(PeerLink.parse('LibreShare://PEER?ip=10.0.0.5').ip, '10.0.0.5');
        expect(PeerLink.parse('libreshare://peer/?ip=10.0.0.5').ip, '10.0.0.5');
      },
    );

    test('surrounding whitespace from a paste/scan is trimmed', () {
      expect(PeerLink.parse('  ${link('ip=10.0.0.5')}\r\n').ip, '10.0.0.5');
    });

    test('IPv6 literal, encoded or with raw colons, is normalised', () {
      expect(PeerLink.parse(link('ip=%3A%3A1')).ip, '::1');
      expect(PeerLink.parse(link('ip=fe80::1')).ip, 'fe80::1');
      expect(PeerLink.parse(link('ip=2001:db8::1&port=1')).port, 1);
    });

    test('unknown parameters are ignored, even malformed or repeated ones', () {
      final l = PeerLink.parse(
        link('ip=10.0.0.5&x=1&x=2&future&%69p=9&IP=8.8.8.8&&=&v=%zz'),
      );
      expect(l.ip, '10.0.0.5', reason: 'encoded/upper-case keys are unknown');
    });

    test('percent-decoding happens exactly once', () {
      expect(PeerLink.parse(link('ip=10.0.0.5&n=a%2520b')).alias, 'a%20b');
      expect(PeerLink.parse(link('ip=10.0.0.5&n=a%2Bb+c')).alias, 'a+b+c');
    });

    test('hostile-looking text in the alias is data and kept verbatim', () {
      for (final s in [
        "<script>alert(1)</script>",
        "'; DROP TABLE peers; --",
        r'${jndi:ldap://evil}',
        '../../etc/passwd',
        'libreshare://peer?ip=6.6.6.6',
      ]) {
        final l = PeerLink.parse(link('ip=10.0.0.5&n=${_enc(s)}'));
        expect(l.alias, s);
        expect(l.ip, '10.0.0.5');
      }
    });

    test('an encoded "&" or "=" in a value cannot smuggle parameters', () {
      final l = PeerLink.parse(link('ip=10.0.0.5&n=a%26ip%3D6.6.6.6'));
      expect(l.alias, 'a&ip=6.6.6.6');
      expect(l.ip, '10.0.0.5');
    });

    test('alias of exactly 64 characters is accepted', () {
      final a = 'x' * 64;
      expect(PeerLink.parse(link('ip=10.0.0.5&n=$a')).alias, a);
    });

    test('the 64 limit counts characters (code points), not bytes', () {
      expect(
        PeerLink.parse(link('ip=10.0.0.5&n=${_enc('ü' * 64)}')).alias,
        'ü' * 64,
      );
      expect(
        () => PeerLink.parse(link('ip=10.0.0.5&n=${_enc('ü' * 65)}')),
        throwsA(badLink),
      );
      expect(
        PeerLink.parse(link('ip=10.0.0.5&n=${_enc('😀' * 20)}')).alias,
        '😀' * 20,
      );
    });
  });

  group('PeerLink.parse - rejects', () {
    final invalid = <String, String>{
      // --- structure ---
      'empty': '',
      'whitespace only': '   ',
      'http scheme': 'http://peer?ip=10.0.0.5',
      'other scheme': 'libreshare2://peer?ip=10.0.0.5',
      'no scheme': 'peer?ip=10.0.0.5',
      'no authority': 'libreshare:peer?ip=10.0.0.5',
      'triple slash': 'libreshare:///peer?ip=10.0.0.5',
      'wrong host': 'libreshare://other?ip=10.0.0.5',
      'host suffix': 'libreshare://peer.evil.com?ip=10.0.0.5',
      'host prefix': 'libreshare://xpeer?ip=10.0.0.5',
      'userinfo': 'libreshare://peer@evil.com?ip=10.0.0.5',
      'userinfo before': 'libreshare://evil.com@peer?ip=10.0.0.5',
      'authority port': 'libreshare://peer:80?ip=10.0.0.5',
      'path': 'libreshare://peer/x?ip=10.0.0.5',
      'double slash path': 'libreshare://peer//?ip=10.0.0.5',
      'no query': 'libreshare://peer',
      'empty query': 'libreshare://peer?',
      'fragment': 'libreshare://peer?ip=10.0.0.5#frag',
      'fragment only': 'libreshare://peer#?ip=10.0.0.5',
      // --- ip ---
      'missing ip': link('port=53318'),
      'empty ip': link('ip='),
      'ip without =': link('ip'),
      'hostname': link('ip=example.com'),
      'localhost': link('ip=localhost'),
      'short ipv4': link('ip=1.2.3'),
      'long ipv4': link('ip=1.2.3.4.5'),
      'octet > 255': link('ip=256.1.1.1'),
      'leading zero': link('ip=010.0.0.5'),
      'hex octets': link('ip=0x7f.0.0.1'),
      'decimal ip': link('ip=2130706433'),
      'ip with slash': link('ip=10.0.0.5%2F8'),
      'ip with crlf': link('ip=10.0.0.5%0D%0AHost:%20evil'),
      'ip with space': link('ip=10.0.0.5%20'),
      'ip with port': link('ip=10.0.0.5%3A80'),
      'ip with parameter injection': link('ip=10.0.0.5%26port%3D1'),
      'bracketed ipv6': link('ip=%5B%3A%3A1%5D'),
      'ipv6 zone id': link('ip=fe80%3A%3A1%25eth0'),
      'unspecified v4': link('ip=0.0.0.0'),
      'this-network v4': link('ip=0.1.2.3'),
      'multicast v4': link('ip=224.0.0.168'),
      'broadcast v4': link('ip=255.255.255.255'),
      'unspecified v6': link('ip=%3A%3A'),
      'multicast v6': link('ip=ff02%3A%3A1'),
      'mapped unspecified': link('ip=%3A%3Affff%3A0.0.0.0'),
      'ipv6 junk': link('ip=%3A%3A%3A1'),
      // --- port ---
      'port 0': link('ip=10.0.0.5&port=0'),
      'port 65536': link('ip=10.0.0.5&port=65536'),
      'negative port': link('ip=10.0.0.5&port=-1'),
      'port word': link('ip=10.0.0.5&port=abc'),
      'port suffix': link('ip=10.0.0.5&port=53318abc'),
      'port leading zero': link('ip=10.0.0.5&port=053318'),
      'port hex': link('ip=10.0.0.5&port=0x10'),
      'port float': link('ip=10.0.0.5&port=1e3'),
      'port plus': link('ip=10.0.0.5&port=%2B80'),
      'empty port': link('ip=10.0.0.5&port='),
      'huge port': link('ip=10.0.0.5&port=99999999999999999999'),
      // --- fingerprint ---
      'fp 63 chars': link('ip=10.0.0.5&fp=${fp.substring(1)}'),
      'fp 65 chars': link('ip=10.0.0.5&fp=${fp}A'),
      'fp non-hex': link('ip=10.0.0.5&fp=${'G' * 64}'),
      'fp empty': link('ip=10.0.0.5&fp='),
      'fp with colons': link(
        'ip=10.0.0.5&fp=${List.generate(32, (i) => 'AB').join(':')}',
      ),
      'fp truncated 16': link('ip=10.0.0.5&fp=${fp.substring(0, 16)}'),
      // --- id ---
      'id not uuid': link('ip=10.0.0.5&id=not-a-uuid'),
      'id empty': link('ip=10.0.0.5&id='),
      'id traversal': link('ip=10.0.0.5&id=..%2F..%2Fx'),
      'id no dashes': link('ip=10.0.0.5&id=${uuid.replaceAll('-', '')}'),
      'id too long': link('ip=10.0.0.5&id=${uuid}0'),
      'id non-hex': link('ip=10.0.0.5&id=${uuid.replaceFirst('3f', 'zz')}'),
      // --- alias ---
      'alias empty': link('ip=10.0.0.5&n='),
      'alias 65 chars': link('ip=10.0.0.5&n=${'x' * 65}'),
      'alias NUL': link('ip=10.0.0.5&n=a%00b'),
      'alias newline': link('ip=10.0.0.5&n=a%0Ab'),
      'alias CR LF': link('ip=10.0.0.5&n=a%0D%0ASet-Cookie%3A%20x'),
      'alias tab': link('ip=10.0.0.5&n=a%09b'),
      'alias ESC': link('ip=10.0.0.5&n=%1B%5B31mred'),
      'alias DEL': link('ip=10.0.0.5&n=a%7Fb'),
      'alias C1 control': link('ip=10.0.0.5&n=a%C2%85b'),
      'alias RTL override': link('ip=10.0.0.5&n=%E2%80%AEgpj.exe'),
      'alias bidi isolate': link('ip=10.0.0.5&n=a%E2%81%A6b'),
      'alias line separator': link('ip=10.0.0.5&n=a%E2%80%A8b'),
      'alias BOM': link('ip=10.0.0.5&n=a%EF%BB%BFb'),
      'alias invalid utf-8': link('ip=10.0.0.5&n=%FF%FE'),
      'alias overlong utf-8': link('ip=10.0.0.5&n=%C0%AF'),
      'alias lone surrogate': link('ip=10.0.0.5&n=%ED%A0%80'),
      // --- percent-encoding / raw characters ---
      'bad percent hex': link('ip=10.0.0.5&n=%zz'),
      'truncated percent': link('ip=10.0.0.5&n=%4'),
      'trailing percent': link('ip=10.0.0.5&n=abc%'),
      'raw space': link('ip=10.0.0.5&n=a b'),
      'raw newline': 'libreshare://peer?ip=10.0.0.5&n=a\nb',
      'raw tab': 'libreshare://peer?ip=10.0.0.5&n=a\tb',
      'raw NUL': 'libreshare://peer?ip=10.0.0.5&n=a\u0000b',
      'raw non-ascii': link('ip=10.0.0.5&n=Küche'),
      'raw quote': link('ip=10.0.0.5&n=a"b'),
      'raw angle': link('ip=10.0.0.5&n=<b>'),
      'raw backslash': link(r'ip=10.0.0.5&n=a\b'),
      'raw bracket': link('ip=[::1]'),
      'raw pipe': link('ip=10.0.0.5&n=a|b'),
      // --- duplicates ---
      'duplicate ip': link('ip=10.0.0.5&ip=10.0.0.6'),
      'duplicate ip same value': link('ip=10.0.0.5&ip=10.0.0.5'),
      'duplicate port': link('ip=10.0.0.5&port=1&port=2'),
      'duplicate fp': link('ip=10.0.0.5&fp=$fp&fp=$fp'),
      'duplicate id': link('ip=10.0.0.5&id=$uuid&id=$uuid'),
      'duplicate n': link('ip=10.0.0.5&n=a&n=b'),
      'duplicate hidden by order': link('n=a&ip=10.0.0.5&x=1&n=b'),
      // --- length ---
      'longer than 512': link('ip=10.0.0.5&x=${'a' * 600}'),
    };
    invalid.forEach((name, input) {
      test(name, () {
        expect(() => PeerLink.parse(input), throwsA(badLink));
        expect(PeerLink.tryParse(input), isNull);
      });
    });

    test('512 characters is the limit (inclusive)', () {
      final prefix = link('ip=10.0.0.5&x=');
      final ok = prefix + 'a' * (512 - prefix.length);
      expect(ok.length, 512);
      expect(PeerLink.parse(ok).ip, '10.0.0.5');
      expect(() => PeerLink.parse('${ok}a'), throwsA(badLink));
    });

    test('error messages never echo the (hostile) input', () {
      const evil = 'libreshare://peer?ip=EVIL-SENTINEL%0D%0A&n=<script>';
      try {
        PeerLink.parse(evil);
        fail('expected FormatException');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains('EVIL-SENTINEL')));
        expect(e.toString(), isNot(contains('<script>')));
        expect(e.message, isNotEmpty);
        expect(e.source, isNull);
      }
      try {
        PeerLink.parse('libreshare://peer?ip=10.0.0.5&n=%00SENTINEL2');
        fail('expected FormatException');
      } on FormatException catch (e) {
        expect(e.toString(), isNot(contains('SENTINEL2')));
      }
    });
  });

  group('PeerLink - building and round trip', () {
    test('toUri produces the documented format and field order', () {
      final l = PeerLink(
        ip: '192.168.1.23',
        port: 53320,
        fingerprint: fp.toLowerCase(),
        deviceId: uuid,
        alias: 'Ravi-ThinkPad',
      );
      expect(
        l.toUri(),
        'libreshare://peer?ip=192.168.1.23&port=53320&fp=$fp&id=$uuid'
        '&n=Ravi-ThinkPad',
      );
    });

    test('optional fields are omitted', () {
      expect(
        PeerLink(ip: '10.0.0.5').toUri(),
        'libreshare://peer?ip=10.0.0.5&port=53318',
      );
    });

    test('alias is percent-encoded per RFC 3986 (UTF-8, upper-case hex)', () {
      final uri = PeerLink(ip: '10.0.0.5', alias: 'Küche & Bad+1/#?=%').toUri();
      expect(uri, endsWith('&n=K%C3%BCche%20%26%20Bad%2B1%2F%23%3F%3D%25'));
      expect(uri, isNot(contains(' ')));
    });

    test('round trip with a unicode alias', () {
      for (final alias in [
        'Küche-Laptop ✓',
        '日本語のデバイス',
        'Ana 👩‍💻 & Ben',
        'عربى',
        'a%20b',
        'a+b c',
        "it's \"quoted\"",
        'x' * 64,
      ]) {
        final l = PeerLink(
          ip: '10.1.2.3',
          port: 9999,
          fingerprint: fp,
          deviceId: uuid,
          alias: alias,
        );
        final back = PeerLink.parse(l.toUri());
        expect(back, l, reason: alias);
        expect(back.alias, alias);
        expect(back.hashCode, l.hashCode);
        expect(l.toUri().length, lessThanOrEqualTo(512));
        expect(l.toUri().codeUnits.every((c) => c > 0x20 && c < 0x7f), isTrue);
      }
    });

    test('round trip for an IPv6 peer', () {
      final l = PeerLink(ip: '2001:db8::1', port: 53318, alias: 'v6');
      expect(l.toUri(), contains('ip=2001%3Adb8%3A%3A1'));
      expect(PeerLink.parse(l.toUri()), l);
    });

    test('the constructor is as strict as parse', () {
      expect(() => PeerLink(ip: 'example.com'), throwsA(badLink));
      expect(() => PeerLink(ip: '10.0.0.5', port: 0), throwsA(badLink));
      expect(() => PeerLink(ip: '10.0.0.5', port: 65536), throwsA(badLink));
      expect(
        () => PeerLink(ip: '10.0.0.5', fingerprint: 'abc'),
        throwsA(badLink),
      );
      expect(() => PeerLink(ip: '10.0.0.5', deviceId: 'x'), throwsA(badLink));
      expect(() => PeerLink(ip: '10.0.0.5', alias: 'a\nb'), throwsA(badLink));
      expect(() => PeerLink(ip: '10.0.0.5', alias: ''), throwsA(badLink));
      expect(() => PeerLink(ip: '10.0.0.5', alias: 'x' * 65), throwsA(badLink));
    });

    test('an alias whose encoding would exceed 512 chars is refused', () {
      expect(
        () => PeerLink(ip: '10.0.0.5', alias: '😀' * 64),
        throwsA(badLink),
        reason: 'would produce an unparsable link',
      );
    });

    test('equality covers every field', () {
      final a = PeerLink(ip: '10.0.0.5', alias: 'x');
      expect(a, PeerLink(ip: '10.0.0.5', alias: 'x'));
      expect(a == PeerLink(ip: '10.0.0.5', alias: 'y'), isFalse);
      expect(a == PeerLink(ip: '10.0.0.6', alias: 'x'), isFalse);
      expect(a == PeerLink(ip: '10.0.0.5', alias: 'x', port: 1), isFalse);
    });

    test('fromDevice: fingerprint/uuid/alias are adapted, never thrown on', () {
      final l = PeerLink.fromDevice(
        DeviceInfo(
          deviceId: uuid,
          alias: 'Ravi',
          platform: 'linux',
          fingerprint: fp,
          port: 53321,
        ),
        '10.0.0.7',
      );
      expect(l.ip, '10.0.0.7');
      expect(l.port, 53321);
      expect(l.fingerprint, fp);
      expect(l.deviceId, uuid);
      expect(l.alias, 'Ravi');

      // Pre-TLS (Inc 2): empty fingerprint, non-UUID id, silly alias.
      final odd = PeerLink.fromDevice(
        DeviceInfo(
          deviceId: 'dev-1',
          alias: '  ${'ü' * 100}\n\u202E ',
          platform: 'linux',
        ),
        '10.0.0.7',
      );
      expect(odd.fingerprint, isNull);
      expect(odd.deviceId, isNull);
      expect(odd.alias, 'ü' * 64);
      expect(PeerLink.parse(odd.toUri()), odd);

      // Astral alias is truncated until the link fits in 512 chars.
      final emoji = PeerLink.fromDevice(
        DeviceInfo(
          deviceId: uuid,
          alias: '😀' * 100,
          platform: 'linux',
          fingerprint: fp,
        ),
        '2001:db8::1',
      );
      expect(emoji.toUri().length, lessThanOrEqualTo(512));
      expect(emoji.alias, isNotEmpty);
      expect(PeerLink.parse(emoji.toUri()), emoji);

      final blank = PeerLink.fromDevice(
        const DeviceInfo(deviceId: 'x', alias: ' \n ', platform: 'linux'),
        '10.0.0.7',
      );
      expect(blank.alias, isNull);
    });
  });

  group('fingerprint helpers', () {
    test('displayFingerprint groups by four, upper-case', () {
      expect(
        displayFingerprint(fp.toLowerCase())
            .split(' ')
            .every((g) => g.length == 4),
        isTrue,
      );
      expect(displayFingerprint(fp).split(' '), hasLength(16));
      expect(displayFingerprint(fp).startsWith('${fp.substring(0, 4)} '), true);
      expect(displayFingerprint(fp).replaceAll(' ', ''), fp);
      expect(displayFingerprint('ab12cd34ef'), 'AB12 CD34 EF');
      expect(displayFingerprint('AB:12:cd:34'), 'AB12 CD34');
      expect(displayFingerprint(''), '');
    });

    test('shortFingerprint is the first 16 hex, upper-case', () {
      expect(shortFingerprint(fp.toLowerCase()), fp.substring(0, 16));
      expect(shortFingerprint('abc'), 'ABC');
      expect(shortFingerprint(''), '');
    });

    test('normalizeFingerprint', () {
      expect(normalizeFingerprint(fp.toLowerCase()), fp);
      expect(normalizeFingerprint(''), isNull);
      expect(normalizeFingerprint('${fp}0'), isNull);
      expect(normalizeFingerprint(fp.replaceFirst(fp[0], 'Z')), isNull);
    });
  });

  group('ManualPeerResolver (fake probe)', () {
    DeviceInfo peer({String? fingerprint, String id = uuid}) => DeviceInfo(
      deviceId: id,
      alias: 'Peer',
      platform: 'linux',
      port: 53318,
      fingerprint: fingerprint ?? '',
    );

    ManualPeerResolver resolverFor(
      DeviceInfo? info, {
      List<(String, int, Duration)>? calls,
    }) => ManualPeerResolver(
      probe: (ip, port, timeout) async {
        calls?.add((ip, port, timeout));
        return info;
      },
    );

    test(
      'manual entry: peer fingerprint is returned for user confirmation',
      () async {
        final r = await resolverFor(peer(fingerprint: fp.toLowerCase()))
            .resolve('192.168.1.9', 53318);
        expect(r.info.deviceId, uuid);
        expect(r.address, '192.168.1.9');
        expect(r.port, 53318);
        expect(r.fingerprintToConfirm, fp, reason: 'upper-case for display');
        expect(r.fingerprintVerified, isFalse);
      },
    );

    test('manual entry without TLS: nothing to confirm yet', () async {
      final r = await resolverFor(peer()).resolve('192.168.1.9', 53318);
      expect(r.fingerprintToConfirm, isNull);
      expect(r.fingerprintVerified, isFalse);
    });

    test('QR with matching fp: verified, nothing to confirm', () async {
      final r = await resolverFor(peer(fingerprint: fp)).resolve(
        '192.168.1.9',
        53318,
        expectedFingerprint: fp.toLowerCase(),
        expectedDeviceId: uuid.toUpperCase(),
      );
      expect(r.fingerprintToConfirm, isNull);
      expect(r.fingerprintVerified, isTrue);
    });

    test(
      'QR with fp that differs from the peer: FingerprintMismatch',
      () async {
        final other = fp.replaceRange(0, 2, fp.startsWith('00') ? 'FF' : '00');
        await expectLater(
          resolverFor(peer(fingerprint: other))
              .resolve('192.168.1.9', 53318, expectedFingerprint: fp),
          throwsA(
            isA<FingerprintMismatch>()
                .having((e) => e.expected, 'expected', fp)
                .having((e) => e.actual, 'actual', other)
                .having((e) => e.toString(), 'toString', isNot(contains(fp))),
          ),
        );
      },
    );

    test(
      'QR with fp but the peer presents none: mismatch (no downgrade)',
      () async {
        await expectLater(
          resolverFor(peer())
              .resolve('192.168.1.9', 53318, expectedFingerprint: fp),
          throwsA(
            isA<FingerprintMismatch>().having((e) => e.actual, 'actual', ''),
          ),
        );
      },
    );

    test('QR id that differs from the peer: DeviceIdMismatch', () async {
      await expectLater(
        resolverFor(peer(id: '11111111-1111-4111-8111-111111111111'))
            .resolve('192.168.1.9', 53318, expectedDeviceId: uuid),
        throwsA(isA<DeviceIdMismatch>()),
      );
    });

    test('resolveLink applies every field of the link', () async {
      final calls = <(String, int, Duration)>[];
      final l = PeerLink(
        ip: '192.168.1.9',
        port: 53325,
        fingerprint: fp,
        deviceId: uuid,
      );
      final ok = await resolverFor(
        peer(fingerprint: fp),
        calls: calls,
      ).resolveLink(l, timeout: const Duration(seconds: 1));
      expect(ok.fingerprintVerified, isTrue);
      expect(calls.single, ('192.168.1.9', 53325, const Duration(seconds: 1)));

      await expectLater(
        resolverFor(peer(fingerprint: fp)).resolveLink(_withFp(l, 'F' * 64)),
        throwsA(isA<FingerprintMismatch>()),
      );
    });

    test('unreachable peer: PeerUnreachable', () async {
      await expectLater(
        resolverFor(null).resolve('192.168.1.9', 53318),
        throwsA(
          isA<PeerUnreachable>()
              .having((e) => e.address, 'address', '192.168.1.9')
              .having((e) => e.port, 'port', 53318),
        ),
      );
    });

    test('a throwing or hanging probe is also "unreachable"', () async {
      final boom = ManualPeerResolver(
        probe: (ip, port, timeout) async => throw StateError('boom'),
      );
      await expectLater(
        boom.resolve('192.168.1.9', 53318),
        throwsA(isA<PeerUnreachable>()),
      );
      final hang = ManualPeerResolver(
        probe: (ip, port, timeout) => Completer<DeviceInfo?>().future,
      );
      final sw = Stopwatch()..start();
      await expectLater(
        hang.resolve(
          '192.168.1.9',
          53318,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<PeerUnreachable>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test('rejects an invalid address or port before probing', () async {
      final calls = <(String, int, Duration)>[];
      final r = resolverFor(peer(), calls: calls);
      await expectLater(r.resolve('example.com', 53318), throwsA(badLink));
      await expectLater(r.resolve('10.0.0.5', 0), throwsA(badLink));
      await expectLater(r.resolve('10.0.0.5', 70000), throwsA(badLink));
      await expectLater(r.resolve(' 10.0.0.5', 80), throwsA(badLink));
      await expectLater(
        r.resolve('10.0.0.5', 80, expectedFingerprint: 'xyz'),
        throwsA(badLink),
      );
      expect(calls, isEmpty);
    });
  });

  group('ManualPeerResolver (real ApiServer, default probe)', () {
    late FakeIncomingHandler handler;
    late ApiServer server;
    late int port;

    setUp(() async {
      handler = FakeIncomingHandler()
        ..info = DeviceInfo(
          deviceId: uuid,
          alias: 'Real Peer',
          platform: 'linux',
          port: 1,
          fingerprint: fp,
        );
      server = ApiServer(
        handler: handler,
        bindAddress: InternetAddress.loopbackIPv4,
        preferredPort: 0,
      );
      port = await server.start();
    });
    tearDown(() => server.stop(force: true));

    test(
      'resolve over HTTP, then QR verification against the live peer',
      () async {
        final resolver = ManualPeerResolver();
        final r = await resolver.resolve('127.0.0.1', port);
        expect(r.info.alias, 'Real Peer');
        expect(r.fingerprintToConfirm, fp);

        final l = PeerLink(ip: '127.0.0.1', port: port, fingerprint: fp);
        expect((await resolver.resolveLink(l)).fingerprintVerified, isTrue);

        await expectLater(
          resolver.resolveLink(_withFp(l, 'A' * 64)),
          throwsA(isA<FingerprintMismatch>()),
        );
      },
    );

    test('nothing listening: PeerUnreachable, promptly', () async {
      await server.stop(force: true);
      final sw = Stopwatch()..start();
      await expectLater(
        ManualPeerResolver().resolve(
          '127.0.0.1',
          port,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<PeerUnreachable>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      server = ApiServer(handler: handler); // keep tearDown happy
    });
  });
}

PeerLink _withFp(PeerLink l, String fp) => PeerLink(
  ip: l.ip,
  port: l.port,
  fingerprint: fp,
  deviceId: l.deviceId,
  alias: l.alias,
);

/// Test-side RFC 3986 encoder (independent of the implementation's).
String _enc(String s) =>
    Uri.encodeComponent(s)
        .replaceAll('!', '%21')
        .replaceAll("'", '%27')
        .replaceAll('(', '%28')
        .replaceAll(')', '%29')
        .replaceAll('*', '%2A');

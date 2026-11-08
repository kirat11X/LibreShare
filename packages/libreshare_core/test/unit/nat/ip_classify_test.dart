import 'dart:math';

import 'package:test/test.dart';
import 'package:libreshare_core/src/nat/ip_classify.dart';

void main() {
  group('IpClassifier Table-Driven Tests', () {
    test('Loopback classification', () {
      expect(IpClassifier.classify('127.0.0.1').category, IpCategory.loopback);
      expect(
        IpClassifier.classify('127.255.255.255').category,
        IpCategory.loopback,
      );
      expect(IpClassifier.classify('::1').category, IpCategory.loopback);
      expect(IpClassifier.classify('[::1]').category, IpCategory.loopback);
      expect(IpClassifier.isPublicRoutable('127.0.0.1'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('127.0.0.1'), isTrue);
      expect(IpClassifier.isPublicRoutable('::1'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('::1'), isTrue);
    });

    test('Private IPv4 classification (RFC 1918)', () {
      expect(
        IpClassifier.classify('10.0.0.1').category,
        IpCategory.privateIpv4,
      );
      expect(
        IpClassifier.classify('10.255.255.255').category,
        IpCategory.privateIpv4,
      );
      expect(
        IpClassifier.classify('172.16.0.1').category,
        IpCategory.privateIpv4,
      );
      expect(
        IpClassifier.classify('172.31.255.255').category,
        IpCategory.privateIpv4,
      );
      expect(
        IpClassifier.classify('192.168.1.1').category,
        IpCategory.privateIpv4,
      );
      expect(
        IpClassifier.classify('192.168.254.254').category,
        IpCategory.privateIpv4,
      );
      expect(IpClassifier.isPublicRoutable('192.168.1.1'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('192.168.1.1'), isTrue);
    });

    test('CGNAT classification (RFC 6598 100.64.0.0/10)', () {
      expect(IpClassifier.classify('100.64.0.1').category, IpCategory.cgnat);
      expect(IpClassifier.classify('100.100.50.25').category, IpCategory.cgnat);
      expect(
        IpClassifier.classify('100.127.255.254').category,
        IpCategory.cgnat,
      );
      // Boundaries
      expect(
        IpClassifier.classify('100.63.255.255').category,
        IpCategory.globalUnicast,
      );
      expect(
        IpClassifier.classify('100.128.0.0').category,
        IpCategory.globalUnicast,
      );
      expect(IpClassifier.isPublicRoutable('100.64.0.1'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('100.64.0.1'), isTrue);
    });

    test('Link-Local classification', () {
      expect(
        IpClassifier.classify('169.254.0.1').category,
        IpCategory.linkLocal,
      );
      expect(
        IpClassifier.classify('169.254.255.254').category,
        IpCategory.linkLocal,
      );
      expect(IpClassifier.classify('fe80::1').category, IpCategory.linkLocal);
      expect(
        IpClassifier.classify('fe80::dead:beef').category,
        IpCategory.linkLocal,
      );
      expect(IpClassifier.isPublicRoutable('169.254.1.1'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('fe80::1'), isTrue);
    });

    test('IPv6 Unique Local Address (ULA RFC 4193 fc00::/7)', () {
      expect(IpClassifier.classify('fc00::1').category, IpCategory.ula);
      expect(IpClassifier.classify('fd00::1').category, IpCategory.ula);
      expect(
        IpClassifier.classify('fd12:3456:789a:1::1').category,
        IpCategory.ula,
      );
      expect(IpClassifier.isPublicRoutable('fd00::1'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('fd00::1'), isTrue);
    });

    test('Multicast classification', () {
      expect(IpClassifier.classify('224.0.0.1').category, IpCategory.multicast);
      expect(
        IpClassifier.classify('239.255.255.250').category,
        IpCategory.multicast,
      );
      expect(IpClassifier.classify('ff02::1').category, IpCategory.multicast);
      expect(IpClassifier.isPublicRoutable('224.0.0.1'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('ff02::1'), isTrue);
    });

    test('Public routable Global Unicast classification', () {
      expect(
        IpClassifier.classify('8.8.8.8').category,
        IpCategory.globalUnicast,
      );
      expect(
        IpClassifier.classify('1.1.1.1').category,
        IpCategory.globalUnicast,
      );
      expect(
        IpClassifier.classify('93.184.216.34').category,
        IpCategory.globalUnicast,
      );
      expect(
        IpClassifier.classify('2606:4700:4700::1111').category,
        IpCategory.globalUnicast,
      );
      expect(
        IpClassifier.classify('2001:4860:4860::8888').category,
        IpCategory.globalUnicast,
      );
      expect(IpClassifier.isPublicRoutable('8.8.8.8'), isTrue);
      expect(IpClassifier.isPrivateOrLocal('8.8.8.8'), isFalse);
      expect(IpClassifier.isPublicRoutable('2606:4700:4700::1111'), isTrue);
      expect(IpClassifier.isPrivateOrLocal('2606:4700:4700::1111'), isFalse);
    });

    test('IPv4-mapped IPv6 classification', () {
      expect(
        IpClassifier.classify('::ffff:192.168.1.1').category,
        IpCategory.ipv4MappedIpv6,
      );
      expect(
        IpClassifier.classify('::ffff:8.8.8.8').category,
        IpCategory.ipv4MappedIpv6,
      );
      expect(IpClassifier.isPublicRoutable('::ffff:8.8.8.8'), isFalse);
    });

    test('Documentation / Test networks', () {
      expect(
        IpClassifier.classify('192.0.2.1').category,
        IpCategory.reservedOrDoc,
      );
      expect(
        IpClassifier.classify('198.51.100.1').category,
        IpCategory.reservedOrDoc,
      );
      expect(
        IpClassifier.classify('203.0.113.1').category,
        IpCategory.reservedOrDoc,
      );
      expect(
        IpClassifier.classify('2001:db8::1').category,
        IpCategory.reservedOrDoc,
      );
      expect(IpClassifier.isPublicRoutable('203.0.113.1'), isFalse);
    });

    test('Invalid hostnames and malformed IPs', () {
      expect(IpClassifier.classify('').category, IpCategory.invalid);
      expect(IpClassifier.classify('   ').category, IpCategory.invalid);
      expect(IpClassifier.classify('localhost').category, IpCategory.invalid);
      expect(IpClassifier.classify('example.com').category, IpCategory.invalid);
      expect(IpClassifier.classify('256.0.0.1').category, IpCategory.invalid);
      expect(IpClassifier.classify('192.168.1').category, IpCategory.invalid);
      expect(
        IpClassifier.classify('192.168.1.1.1').category,
        IpCategory.invalid,
      );
      expect(
        IpClassifier.classify('01.02.03.04').category,
        IpCategory.invalid,
      ); // leading zeros
      expect(
        IpClassifier.classify('1:::1').category,
        IpCategory.invalid,
      ); // multiple ::
      expect(IpClassifier.classify('gggg::1').category, IpCategory.invalid);
      expect(IpClassifier.isPublicRoutable('malformed'), isFalse);
      expect(IpClassifier.isPrivateOrLocal('malformed'), isFalse);
    });

    test('Fuzz loop: random mutations never throw unhandled exception', () {
      final rand = Random(42);
      final validSamples = [
        '192.168.1.1',
        '10.0.0.1',
        '100.64.0.1',
        '8.8.8.8',
        '::1',
        'fe80::1',
        '2001:4860:4860::8888',
        'fd00::1',
      ];

      for (var i = 0; i < 2000; i++) {
        final base = validSamples[rand.nextInt(validSamples.length)];
        var mutated = base;
        final action = rand.nextInt(4);
        if (action == 0 && mutated.isNotEmpty) {
          // Mutate character
          final pos = rand.nextInt(mutated.length);
          mutated =
              mutated.substring(0, pos) +
              String.fromCharCode(rand.nextInt(128)) +
              mutated.substring(pos + 1);
        } else if (action == 1) {
          // Truncate
          mutated = mutated.substring(0, rand.nextInt(mutated.length));
        } else if (action == 2) {
          // Insert colon or dot
          final pos = rand.nextInt(mutated.length);
          mutated =
              mutated.substring(0, pos) +
              (rand.nextBool() ? ':' : '.') +
              mutated.substring(pos);
        } else {
          // Append random garbage
          mutated += String.fromCharCode(rand.nextInt(128));
        }

        final res = IpClassifier.classify(mutated);
        expect(res, isNotNull);
      }
    });
  });
}

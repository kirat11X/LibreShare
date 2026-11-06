// F3 defect 5: the phone must not call itself "localhost".
//
// New seam (Dart side, in services/device_identity.dart):
//   const String kDeviceInfoChannel = 'dev.libreshare/device_info';
//   const String kAndroidFallbackAlias = 'Android phone';
//   Future<String> resolveDeviceAlias({
//     bool? isAndroid,                  // default Platform.isAndroid
//     MethodChannel? channel,           // default MethodChannel(kDeviceInfoChannel)
//     String Function()? hostname,      // default () => Platform.localHostname
//   });
// Android: invokes `deviceName` (no arguments) on the channel; the answer is
// trimmed, cleaned with sanitizeAlias and cut to kPeerLinkMaxAliasLength code
// points. Missing channel, PlatformException, null/empty/whitespace and any
// casing of "localhost" give "Android phone". Other platforms never touch the
// channel and behave exactly like defaultDeviceAlias().
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/services/device_identity.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/f3_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<String> onAndroid(Object? nativeAnswer) async {
    f3MockChannel(kDeviceInfoChannel, (_) async => nativeAnswer);
    return resolveDeviceAlias(isAndroid: true, hostname: () => 'localhost');
  }

  test('the channel and fallback names are the documented ones', () {
    expect(kDeviceInfoChannel, 'dev.libreshare/device_info');
    expect(kAndroidFallbackAlias, 'Android phone');
  });

  group('Android', () {
    test(
      'uses the device name from the platform, asked with deviceName',
      () async {
        final calls = f3MockChannel(kDeviceInfoChannel, (_) async => 'Pixel 8');
        final alias = await resolveDeviceAlias(
          isAndroid: true,
          hostname: () => 'localhost',
        );
        expect(alias, 'Pixel 8');
        expect(calls.map((c) => c.method), ['deviceName']);
        expect(calls.single.arguments, isNull);
      },
    );

    test('a different name comes through (not hard-coded)', () async {
      expect(await onAndroid("Mira's Galaxy S24"), "Mira's Galaxy S24");
    });

    test('the name is trimmed', () async {
      expect(await onAndroid('   Pixel 8 \n'), 'Pixel 8');
    });

    test(
      'empty, blank or missing answers fall back to "Android phone"',
      () async {
        expect(await onAndroid(''), 'Android phone');
        expect(await onAndroid('   '), 'Android phone');
        expect(await onAndroid('\t\n'), 'Android phone');
        expect(await onAndroid(null), 'Android phone');
      },
    );

    test('"localhost" in any spelling falls back to "Android phone"', () async {
      expect(await onAndroid('localhost'), 'Android phone');
      expect(await onAndroid('LocalHost'), 'Android phone');
      expect(await onAndroid('  localhost  '), 'Android phone');
    });

    test('a name that merely contains "localhost" is kept', () async {
      expect(await onAndroid('localhost-phone'), 'localhost-phone');
    });

    test('a channel that is not registered falls back', () async {
      // No handler installed: invokeMethod throws MissingPluginException.
      final alias = await resolveDeviceAlias(
        isAndroid: true,
        hostname: () => 'localhost',
      );
      expect(alias, 'Android phone');
    });

    test('a native error falls back', () async {
      f3MockChannel(kDeviceInfoChannel, (_) async {
        throw PlatformException(code: 'unavailable', message: 'no settings');
      });
      final alias = await resolveDeviceAlias(
        isAndroid: true,
        hostname: () => 'localhost',
      );
      expect(alias, 'Android phone');
    });

    test('a non-text answer falls back', () async {
      expect(await onAndroid(42), 'Android phone');
      expect(await onAndroid(<String>['x']), 'Android phone');
    });

    test('a long name is cut to the protocol alias limit', () async {
      final alias = await onAndroid('A' * 100);
      expect(alias.runes.length, kPeerLinkMaxAliasLength);
      expect(alias, 'A' * kPeerLinkMaxAliasLength);
    });

    test('a name of exactly the limit is untouched', () async {
      final name = 'B' * kPeerLinkMaxAliasLength;
      expect(await onAndroid(name), name);
    });

    test('trimming happens before cutting', () async {
      final alias = await onAndroid('${' ' * 10}${'C' * 80}');
      expect(alias, 'C' * kPeerLinkMaxAliasLength);
    });

    test('cutting never splits an emoji', () async {
      final alias = await onAndroid('😀' * 70);
      expect(alias.runes.length, kPeerLinkMaxAliasLength);
      expect(alias, '😀' * kPeerLinkMaxAliasLength);
      expect(alias.codeUnits.length, kPeerLinkMaxAliasLength * 2);
    });

    test('control characters are dropped', () async {
      expect(await onAndroid('Pi\u0000xel\u0007 8'), 'Pixel 8');
    });
  });

  group('desktop is unchanged', () {
    test('uses the host name and never calls the channel', () async {
      final calls = f3MockChannel(kDeviceInfoChannel, (_) async => 'Pixel 8');
      final alias = await resolveDeviceAlias(
        isAndroid: false,
        hostname: () => 'work-pc.local',
      );
      expect(alias, 'work-pc');
      expect(calls, isEmpty);
    });

    test('a host name that throws gives the generic name', () async {
      final alias = await resolveDeviceAlias(
        isAndroid: false,
        hostname: () => throw StateError('no hostname'),
      );
      expect(alias, 'LibreShare');
    });

    test('an empty host name gives the generic name', () async {
      final alias = await resolveDeviceAlias(
        isAndroid: false,
        hostname: () => '  ',
      );
      expect(alias, 'LibreShare');
    });

    test('the result matches the existing default for the same host', () async {
      final alias = await resolveDeviceAlias(isAndroid: false);
      expect(alias, defaultDeviceAlias());
    });
  });
}

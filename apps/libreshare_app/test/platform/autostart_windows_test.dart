import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/autostart/autostart_common.dart';
import 'package:libreshare_app/platform/autostart/autostart_none.dart';
import 'package:libreshare_app/platform/autostart/autostart_windows.dart';
import 'package:libreshare_app/platform/autostart/registry_access.dart';

void main() {
  const exe = r'C:\Program Files\LibreShare\libreshare.exe';
  const runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';

  late FakeRegistryAccess registry;
  late WindowsAutostart service;

  setUp(() {
    registry = FakeRegistryAccess();
    service = WindowsAutostart(registry: registry, executable: exe);
  });

  test(
    'writes HKCU Run value LibreShare with a quoted path and --hidden',
    () async {
      expect(WindowsAutostart.runKey, runKey);
      expect(WindowsAutostart.valueName, 'LibreShare');
      await service.setEnabled(true);
      expect(
        registry.readString(runKey, 'LibreShare'),
        r'"C:\Program Files\LibreShare\libreshare.exe" --hidden',
      );
      expect(await service.isEnabled(), isTrue);
    },
  );

  test('enable / disable round trip is idempotent', () async {
    expect(service.isSupported, isTrue);
    expect(await service.isEnabled(), isFalse);

    await service.setEnabled(true);
    await service.setEnabled(true);
    expect(registry.strings[runKey.toLowerCase()], hasLength(1));
    expect(await service.isEnabled(), isTrue);

    await service.setEnabled(false);
    await service.setEnabled(false); // already gone: must not throw
    expect(registry.readString(runKey, 'LibreShare'), isNull);
    expect(await service.isEnabled(), isFalse);
  });

  test(
    'registry paths and value names are case-insensitive like Windows',
    () async {
      await service.setEnabled(true);
      expect(
        registry.readString(runKey.toUpperCase(), 'libreshare'),
        isNotNull,
      );
    },
  );

  test('a path without spaces is quoted too', () {
    expect(
      WindowsAutostart.buildCommand(r'D:\LS\libreshare.exe'),
      r'"D:\LS\libreshare.exe" --hidden',
    );
  });

  test('unusable paths and over-long commands are refused', () async {
    expect(
      () => WindowsAutostart.buildCommand(r'C:\we"ird\x.exe'),
      throwsA(isA<AutostartException>()),
    );
    expect(
      () => WindowsAutostart.buildCommand(''),
      throwsA(isA<AutostartException>()),
    );
    final tooLong = 'C:\\${'a' * 260}\\libreshare.exe';
    expect(
      () => WindowsAutostart.buildCommand(tooLong),
      throwsA(isA<AutostartException>()),
    );
    // And through the service: nothing is written.
    await expectLater(
      WindowsAutostart(
        registry: registry,
        executable: tooLong,
      ).setEnabled(true),
      throwsA(isA<AutostartException>()),
    );
    expect(registry.writeCount, 0);
  });

  test('a registry failure surfaces as AutostartException', () async {
    registry.failWritesWith = StateError('access denied');
    await expectLater(
      service.setEnabled(true),
      throwsA(isA<AutostartException>()),
    );
    await expectLater(
      service.setEnabled(false),
      throwsA(isA<AutostartException>()),
    );
  });

  group('honest state (StartupApproved)', () {
    const approved =
        r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';

    test(
      'Run value present but disabled in Windows settings => not enabled',
      () async {
        await service.setEnabled(true);
        registry.setBinary(approved, 'LibreShare', [3, 0, 0, 0, 0, 0, 0, 0]);
        expect(await service.isDisabledInWindowsSettings(), isTrue);
        expect(await service.isEnabled(), isFalse);
        // The Run value is left alone: Windows owns the user's choice.
        expect(registry.readString(runKey, 'LibreShare'), isNotNull);
      },
    );

    test('StartupApproved "enabled" markers keep it enabled', () async {
      await service.setEnabled(true);
      for (final first in [2, 6]) {
        registry.setBinary(approved, 'LibreShare', [first, 0, 0, 0]);
        expect(await service.isDisabledInWindowsSettings(), isFalse);
        expect(await service.isEnabled(), isTrue);
      }
    });
  });

  group('self-heal', () {
    test(
      'rewrites a stale value, leaves a current one, never creates one',
      () async {
        expect(await service.selfHeal(), isFalse);
        expect(registry.readString(runKey, 'LibreShare'), isNull);

        registry.writeString(
          runKey,
          'LibreShare',
          r'"E:\old\libreshare.exe" --hidden',
        );
        expect(await service.selfHeal(), isTrue);
        expect(
          registry.readString(runKey, 'LibreShare'),
          r'"C:\Program Files\LibreShare\libreshare.exe" --hidden',
        );
        expect(await service.selfHeal(), isFalse);
      },
    );
  });

  test('NoAutostart reports unsupported and does nothing', () async {
    const none = NoAutostart();
    expect(none.isSupported, isFalse);
    expect(await none.isEnabled(), isFalse);
    await none.setEnabled(true);
    expect(await none.isEnabled(), isFalse);
  });
}

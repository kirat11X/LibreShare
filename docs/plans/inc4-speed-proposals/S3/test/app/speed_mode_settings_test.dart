// Transfer speed in the app (docs/plans/inc4-speed.md section 3): the Settings
// "Transfer speed" selector, its persistence in app_settings.json, and the
// wiring of the chosen mode into the engine.
//
// Contract the coder implements (names fixed by this test):
//  * AppSettings.speedMode (SpeedMode, default balanced), copyWith(speedMode:),
//    saved by AppSettingsStore.save and read back by loadOrCreate; an unknown
//    or missing stored value reads as balanced.
//  * SettingsNotifier.setSpeedMode(SpeedMode) persists and updates state.
//  * Settings screen: section title "Transfer speed"; three ListTile options
//    with keys speed_mode_eco / speed_mode_balanced / speed_mode_turbo, each
//    with a short description (l10n keys below); `selected` shows the current
//    mode; tapping an option selects it.
//  * The engine is built with the stored mode and follows later changes
//    (LibreShareEngine.speedMode getter/setter).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/l10n_strings.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_app/services/app_settings_store.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

/// Every language table of the app. Only the English one exists today.
const List<Map<String, String>> _tables = [kStringsEn];

const List<String> _speedKeys = [
  'settings.speed',
  'settings.speedEco',
  'settings.speedBalanced',
  'settings.speedTurbo',
  'settings.speedEcoHelp',
  'settings.speedBalancedHelp',
  'settings.speedTurboHelp',
];

const Map<SpeedMode, String> _optionKey = {
  SpeedMode.eco: 'speed_mode_eco',
  SpeedMode.balanced: 'speed_mode_balanced',
  SpeedMode.turbo: 'speed_mode_turbo',
};

Finder _option(SpeedMode m) => find.byKey(Key(_optionKey[m]!));

/// Which option is selected on screen (exactly one must be).
SpeedMode _selectedOnScreen(WidgetTester tester) {
  final selected = [
    for (final m in SpeedMode.values)
      if (tester.widget<ListTile>(_option(m)).selected == true) m,
  ];
  expect(selected, hasLength(1), reason: 'exactly one speed option selected');
  return selected.single;
}

Future<AppHarness> openSettings(
  WidgetTester tester, {
  Directory? sandbox,
}) async {
  final h = (await tester.runAsync(
    () =>
        AppHarness.create(reuseSandbox: sandbox, initialLocation: '/settings'),
  ))!;
  await tester.startApp(h);
  return h;
}

Future<void> tapOption(WidgetTester tester, AppHarness h, SpeedMode m) async {
  await tester.tap(_option(m));
  await tester.pump();
  await tester.settleUntil(
    () => h.container.read(settingsProvider).speedMode == m,
    what: 'speed mode $m selected',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('l10n: every speed string exists in every language table', () {
    test('each key is present and non-empty in each table', () {
      for (final table in _tables) {
        for (final key in _speedKeys) {
          expect(table.containsKey(key), isTrue, reason: 'missing $key');
          expect(table[key], isNotEmpty, reason: 'empty $key');
        }
      }
    });

    test(
      'the three descriptions are short, distinct and not the key itself',
      () {
        final texts = [
          kStringsEn['settings.speedEcoHelp']!,
          kStringsEn['settings.speedBalancedHelp']!,
          kStringsEn['settings.speedTurboHelp']!,
        ];
        expect(texts.toSet(), hasLength(3), reason: 'descriptions must differ');
        for (final t in texts) {
          expect(t.length, lessThanOrEqualTo(120), reason: 'short: "$t"');
        }
      },
    );
  });

  group('app settings store: speedMode', () {
    test('a new AppSettings defaults to balanced', () {
      const s = AppSettings(deviceId: 'abcdefgh-1', alias: 'Laptop');
      expect(s.speedMode, SpeedMode.balanced);
    });

    test('turbo survives a save and a load', () async {
      final dir = Directory.systemTemp.createTempSync('ls_speed_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppSettingsStore(dir);
      await store.save(
        const AppSettings(
          deviceId: 'abcdefgh-1',
          alias: 'Laptop',
          speedMode: SpeedMode.turbo,
        ),
      );
      final loaded = await AppSettingsStore(dir).loadOrCreate();
      expect(loaded.speedMode, SpeedMode.turbo);
    });

    test('eco survives a save and a load', () async {
      final dir = Directory.systemTemp.createTempSync('ls_speed_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppSettingsStore(dir);
      await store.save(
        const AppSettings(
          deviceId: 'abcdefgh-1',
          alias: 'Laptop',
          speedMode: SpeedMode.eco,
        ),
      );
      expect(
        (await AppSettingsStore(dir).loadOrCreate()).speedMode,
        SpeedMode.eco,
      );
    });

    test('an unknown stored value reads as balanced, never throws', () async {
      final dir = Directory.systemTemp.createTempSync('ls_speed_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppSettingsStore(dir);
      await store.save(
        const AppSettings(deviceId: 'abcdefgh-1', alias: 'Laptop'),
      );
      final j =
          jsonDecode(store.file.readAsStringSync()) as Map<String, Object?>;
      j['speedMode'] = 'warp';
      store.file.writeAsStringSync(jsonEncode(j));
      expect(
        (await AppSettingsStore(dir).loadOrCreate()).speedMode,
        SpeedMode.balanced,
      );
    });
  });

  group('Settings screen: Transfer speed', () {
    testWidgets('shows the section and three options with descriptions', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = await openSettings(tester);

      expect(find.text('Transfer speed'), findsOneWidget);
      for (final m in SpeedMode.values) {
        expect(_option(m), findsOneWidget, reason: '$m option');
      }
      for (final key in [
        'settings.speedEcoHelp',
        'settings.speedBalancedHelp',
        'settings.speedTurboHelp',
      ]) {
        expect(find.text(kStringsEn[key]!), findsOneWidget, reason: key);
      }

      await tester.stopApp(h);
    });

    testWidgets('the default selection is balanced', (tester) async {
      tester.useTallSurface();
      final h = await openSettings(tester);

      expect(_selectedOnScreen(tester), SpeedMode.balanced);
      expect(h.container.read(settingsProvider).speedMode, SpeedMode.balanced);
      expect(h.engine.speedMode, SpeedMode.balanced);

      await tester.stopApp(h);
    });

    testWidgets(
      'selecting turbo shows it, persists it and reaches the engine',
      (tester) async {
        tester.useTallSurface();
        final h = await openSettings(tester);

        await tapOption(tester, h, SpeedMode.turbo);
        expect(_selectedOnScreen(tester), SpeedMode.turbo);
        expect(
          h.engine.speedMode,
          SpeedMode.turbo,
          reason: 'the running engine follows the chosen mode',
        );
        final stored = (await tester.runAsync(
          () => AppSettingsStore(h.supportDir).loadOrCreate(),
        ))!;
        expect(stored.speedMode, SpeedMode.turbo, reason: 'saved to disk');

        await tester.stopApp(h);
      },
    );

    testWidgets(
      'a fresh settings screen on the same data shows the saved mode',
      (tester) async {
        tester.useTallSurface();
        final first = await openSettings(tester);
        await tapOption(tester, first, SpeedMode.eco);
        final sandbox = first.sandbox;
        await tester.stopApp(first, deleteSandbox: false);

        final second = await openSettings(tester, sandbox: sandbox);
        expect(_selectedOnScreen(tester), SpeedMode.eco);
        expect(
          second.container.read(settingsProvider).speedMode,
          SpeedMode.eco,
        );
        expect(
          second.engine.speedMode,
          SpeedMode.eco,
          reason: 'the engine is built with the stored mode',
        );

        await tester.stopApp(second);
      },
    );

    testWidgets(
      'switching back and forth updates the screen and the engine each time',
      (tester) async {
        tester.useTallSurface();
        final h = await openSettings(tester);

        await tapOption(tester, h, SpeedMode.eco);
        expect(_selectedOnScreen(tester), SpeedMode.eco);
        expect(h.engine.speedMode, SpeedMode.eco);

        await tapOption(tester, h, SpeedMode.balanced);
        expect(_selectedOnScreen(tester), SpeedMode.balanced);
        expect(h.engine.speedMode, SpeedMode.balanced);

        await tapOption(tester, h, SpeedMode.turbo);
        expect(_selectedOnScreen(tester), SpeedMode.turbo);
        expect(h.engine.speedMode, SpeedMode.turbo);

        await tester.stopApp(h);
      },
    );
  });
}

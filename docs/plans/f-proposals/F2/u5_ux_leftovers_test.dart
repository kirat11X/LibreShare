import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/l10n_strings.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

void main() {
  group('Card F2: U5 UX leftovers', () {
    testWidgets(
      'foreground banner appears when receive is on and background service is inactive',
      timeout: const Timeout(Duration(seconds: 60)),
      (tester) async {
        final h = (await tester.runAsync(AppHarness.create))!;
        await tester.startApp(h);

        // Initially Receive is OFF: banner must not be present
        expect(
          find.byKey(const Key('receive-foreground-only-banner')),
          findsNothing,
        );

        // Turn Receive ON
        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => h.engine.receive.state is On,
          what: 'receive on',
        );

        // Foreground-only banner must appear because isBackgroundReceiving is false
        final banner = find.byKey(const Key('receive-foreground-only-banner'));
        expect(banner, findsOneWidget);
        expect(
          find.descendant(
            of: banner,
            matching: find.text(tr('receive.foregroundOnlyBanner')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: banner,
            matching: find.byIcon(Icons.info_outline),
          ),
          findsOneWidget,
        );

        await tester.stopApp(h);
      },
    );

    testWidgets(
      'foreground banner is hidden when receive is off and when background service is active',
      timeout: const Timeout(Duration(seconds: 60)),
      (tester) async {
        // Part 1: banner hides when receive turned off
        final h = (await tester.runAsync(AppHarness.create))!;
        await tester.startApp(h);

        expect(
          find.byKey(const Key('receive-foreground-only-banner')),
          findsNothing,
        );

        // Turn ON
        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => h.engine.receive.state is On,
          what: 'receive on',
        );
        expect(
          find.byKey(const Key('receive-foreground-only-banner')),
          findsOneWidget,
        );

        // Turn OFF again
        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => h.engine.receive.state is Off,
          what: 'receive off',
        );
        expect(
          find.byKey(const Key('receive-foreground-only-banner')),
          findsNothing,
        );

        await tester.stopApp(h);

        // Part 2 (twin): banner is hidden even when receive is ON if background service is active
        final h2 = (await tester.runAsync(
          () => AppHarness.create(
            overrides: [isBackgroundReceivingProvider.overrideWithValue(true)],
          ),
        ))!;
        await tester.startApp(h2);

        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => h2.engine.receive.state is On,
          what: 'receive on with background service',
        );

        expect(
          find.byKey(const Key('receive-foreground-only-banner')),
          findsNothing,
        );

        await tester.stopApp(h2);
      },
    );

    testWidgets(
      'battery saver guidance tile renders on Android / mock platform',
      timeout: const Timeout(Duration(seconds: 60)),
      (tester) async {
        // Positive twin: renders when isAndroidProvider is true
        final h = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/settings',
            overrides: [isAndroidProvider.overrideWithValue(true)],
          ),
        ))!;
        await tester.startApp(h);

        final tileFinder = find.byKey(const Key('battery-saver-guidance-tile'));
        expect(tileFinder, findsOneWidget);
        expect(find.text(tr('settings.batterySaverTitle')), findsOneWidget);
        expect(
          find.text(tr('settings.batterySaverGuidance')),
          findsAtLeastNWidgets(1),
        );

        // Tap to expand tile
        await tester.tap(tileFinder);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('battery-saver-guidance-text')),
          findsOneWidget,
        );

        await tester.stopApp(h);

        // Negative twin: hidden on non-Android platform
        final h2 = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/settings',
            overrides: [isAndroidProvider.overrideWithValue(false)],
          ),
        ))!;
        await tester.startApp(h2);

        expect(
          find.byKey(const Key('battery-saver-guidance-tile')),
          findsNothing,
        );

        await tester.stopApp(h2);
      },
    );

    testWidgets(
      'Windows toast switch toggles setting value',
      timeout: const Timeout(Duration(seconds: 60)),
      (tester) async {
        final h = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/settings',
            overrides: [isWindowsProvider.overrideWithValue(true)],
          ),
        ))!;
        await tester.startApp(h);

        final switchFinder = find.byKey(
          const Key('settings-windows-toast-switch'),
        );
        await tester.scrollUntilVisible(
          switchFinder,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        expect(switchFinder, findsOneWidget);
        expect(find.text(tr('settings.windowsToastTitle')), findsOneWidget);
        expect(find.text(tr('settings.windowsToastSubtitle')), findsOneWidget);

        // Default is opt-in (false)
        expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
        expect(
          h.container.read(settingsProvider).windowsToastsEnabled,
          isFalse,
        );
        expect(h.container.read(windowsToastsEnabledProvider), isFalse);

        // Toggle ON
        await tester.tap(switchFinder);
        await tester.pumpAndSettle();

        expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
        expect(h.container.read(settingsProvider).windowsToastsEnabled, isTrue);
        expect(h.container.read(windowsToastsEnabledProvider), isTrue);

        // Toggle OFF
        await tester.tap(switchFinder);
        await tester.pumpAndSettle();

        expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
        expect(
          h.container.read(settingsProvider).windowsToastsEnabled,
          isFalse,
        );
        expect(h.container.read(windowsToastsEnabledProvider), isFalse);

        await tester.stopApp(h);

        // Negative twin: not rendered when isWindows is false
        final h2 = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/settings',
            overrides: [isWindowsProvider.overrideWithValue(false)],
          ),
        ))!;
        await tester.startApp(h2);

        expect(
          find.byKey(const Key('settings-windows-toast-switch')),
          findsNothing,
        );

        await tester.stopApp(h2);
      },
    );

    testWidgets(
      'screen size responsive test: 360x640 at textScaler 1.3 with zero RenderFlex overflow',
      timeout: const Timeout(Duration(seconds: 60)),
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });

        // Test 1: Home screen with Receive ON (foreground banner visible)
        final hHome = (await tester.runAsync(AppHarness.create))!;
        await tester.startApp(hHome);

        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => hHome.engine.receive.state is On,
          what: 'receive on',
        );

        expect(
          find.byKey(const Key('receive-foreground-only-banner')),
          findsOneWidget,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.stopApp(hHome);

        // Test 2: Settings screen with all OS-specific items active
        final hSettings = (await tester.runAsync(
          () => AppHarness.create(
            initialLocation: '/settings',
            overrides: [
              isAndroidProvider.overrideWithValue(true),
              isWindowsProvider.overrideWithValue(true),
            ],
          ),
        ))!;
        await tester.startApp(hSettings);

        // Battery saver guidance tile must be visible
        final batteryTile = find.byKey(
          const Key('battery-saver-guidance-tile'),
        );
        expect(batteryTile, findsOneWidget);

        // Tap to expand it
        await tester.tap(batteryTile);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Scroll all the way down to Windows toast switch
        final scrollable = find.byType(Scrollable).first;
        final toastSwitch = find.byKey(
          const Key('settings-windows-toast-switch'),
        );
        await tester.scrollUntilVisible(
          toastSwitch,
          200,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(toastSwitch, findsOneWidget);

        await tester.stopApp(hSettings);
      },
    );
  });
}

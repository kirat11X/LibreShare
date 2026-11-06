// D1 PIN persistence tests: verifies PIN modes (Off, Fixed, Window),
// secure storage of the fixed PIN in FileSecretStore (never in app_settings JSON),
// rotation on new Receive window, display on Receive card, and input validation.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  if (f.evaluate().isNotEmpty) return;
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  try {
    await tester.scrollUntilVisible(f, 200, scrollable: scrollable.first);
    await tester.pump();
  } catch (_) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PIN mode - Off vs Fixed and PIN persistence', () {
    test('negative twin: default PIN mode is Off with enforced == false and no active PIN', () async {
      final h = await AppHarness.create();
      addTearDown(() => h.dispose());
      await h.boot();

      final guard = h.engine.pinGuard;
      expect(
        guard,
        isNotNull,
        reason: 'secure engine must have a pinGuard instance',
      );
      expect(
        guard!.enforced,
        isFalse,
        reason: 'PIN mode Off must have enforced == false',
      );
      expect(guard.policy.mode, equals(PinMode.off));
      expect(guard.currentPin, isNull);
    }, timeout: kSixtySeconds);

    testWidgets(
      'positive twin: Fixed mode saves 6 digits to FileSecretStore, enforced == true, survives restart, and never leaks into settings JSON/logs',
      (tester) async {
        tester.useTallSurface();
        final h1 = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        await tester.startApp(h1);

        // Switch to Fixed PIN mode
        final fixedSegment = find.text('Fixed');
        await scrollTo(tester, fixedSegment);
        await tester.tap(fixedSegment);
        await tester.pump();

        // Enter 6 digits and tap Save
        const testPin = '654321';
        final pinInput = find.byKey(const Key('settings-pin-input'));
        expect(pinInput, findsOneWidget);
        await tester.enterText(pinInput, testPin);

        final saveBtn = find.byKey(const Key('settings-pin-save'));
        expect(saveBtn, findsOneWidget);
        await tester.tap(saveBtn);
        await tester.pump();

        // The save writes files and rebuilds the engine: wait for that
        // (A(2): the guard was read before the rebuild had happened).
        await tester.settleUntil(
          () =>
              h1.container.read(engineOrNullProvider)?.pinGuard?.policy.mode ==
              PinMode.fixed,
          what: 'engine rebuilt with pin mode fixed',
        );

        // Shows PIN configured (after the save really finished)
        expect(
          find.text('PIN configured'),
          findsOneWidget,
          reason: 'must show PIN configured after successful save',
        );

        // Verify engine pinGuard is enforced and has the fixed PIN
        final guard1 = h1.engine.pinGuard;
        expect(guard1, isNotNull);
        expect(
          guard1!.enforced,
          isTrue,
          reason: 'Fixed PIN must set enforced == true',
        );
        expect(guard1.policy.mode, equals(PinMode.fixed));
        expect(guard1.currentPin, equals(testPin));

        // Secret store verification: saved under <supportDir>/security as "app-pin"
        final secDir = Directory(pj(h1.supportDir.path, 'security'));
        final secretStore = FileSecretStore(secDir);
        final storedBytes = await tester.runAsync(
          () => secretStore.get('app-pin'),
        );
        expect(
          storedBytes,
          isNotNull,
          reason: 'Fixed PIN must be stored in FileSecretStore under app-pin',
        );
        expect(utf8.decode(storedBytes!), equals(testPin));

        // Privacy rules: PIN must NOT be in app_settings JSON or toString()
        // A(4): no `if (exists)` guard: the settings file must exist and
        // carry the mode. Let the asynchronous settings write finish first.
        await tester.settle(ms: 100);
        final settingsFile = File(pj(h1.supportDir.path, 'app_settings.json'));
        expect(
          settingsFile.existsSync(),
          isTrue,
          reason: 'app_settings.json must exist after the mode was saved',
        );
        final settingsContent = settingsFile.readAsStringSync();
        expect(settingsContent, contains('"pinMode": "fixed"'));
        expect(
          settingsContent.contains(testPin),
          isFalse,
          reason: 'PIN must never appear in app_settings.json',
        );
        final currentSettings = h1.container.read(settingsProvider);
        expect(
          currentSettings.toString().contains(testPin),
          isFalse,
          reason: 'PIN must never appear in AppSettings.toString()',
        );

        final sandbox = h1.sandbox;
        await tester.stopApp(h1, deleteSandbox: false);

        // Restart survival: create new harness reusing same support dir
        final h2 = (await tester.runAsync(
          () => AppHarness.create(
            reuseSandbox: sandbox,
            initialLocation: '/settings',
          ),
        ))!;
        await tester.startApp(h2);

        final guard2 = h2.engine.pinGuard;
        expect(
          guard2,
          isNotNull,
          reason: 'rebuilt engine must have a pinGuard',
        );
        expect(
          guard2!.enforced,
          isTrue,
          reason: 'Fixed PIN must survive restart and remain enforced',
        );
        expect(guard2.policy.mode, equals(PinMode.fixed));
        expect(
          guard2.currentPin,
          equals(testPin),
          reason: 'Fixed PIN must survive restart with same value',
        );

        await tester.stopApp(h2);
      },
      timeout: kSixtySeconds,
    );
  });

  group('PIN mode - New each time (Window policy)', () {
    testWidgets(
      'positive twin: window PIN is active while Receive is on, rotates on new window, and is displayed on Receive card',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        await tester.startApp(h);

        final windowSegment = find.text('New each time');
        await scrollTo(tester, windowSegment);
        await tester.tap(windowSegment);
        await tester.pump();

        // In window mode, no fixed PIN input field is shown
        expect(find.byKey(const Key('settings-pin-input')), findsNothing);

        // The mode change rebuilds the engine: wait for it, then turn Receive
        // on with the real switch (A(1): runAsync(setEnabled) deadlocked).
        await tester.settleUntil(
          () =>
              h.container.read(engineOrNullProvider)?.pinGuard?.policy.mode ==
              PinMode.window,
          what: 'engine rebuilt with pin mode window',
        );
        Future<void> flip() =>
            tester.tap(find.byKey(const Key('receive-switch')));
        await flip();
        await tester.settleUntil(
          () => h.engine.receive.state is On,
          what: 'receive on',
        );

        // While Receive is On, engine has active currentPin
        final guard = h.engine.pinGuard;
        expect(guard, isNotNull);
        expect(
          guard!.currentPin,
          isNotNull,
          reason:
              'currentPin must be non-null while Receive is on in window mode',
        );
        final pin1 = guard.currentPin!;
        expect(
          pin1,
          matches(RegExp(r'^[0-9]{6}$')),
          reason: 'PIN must be 6 digits',
        );

        // Verify PIN is displayed on the ReceiveCard while Receive is on
        expect(
          find.textContaining(pin1),
          findsAtLeastNWidgets(1),
          reason: 'Active PIN must be visible on the Receive card while Receive is on',
        );

        // Next Receive window: turn off and back on -> PIN must rotate
        await flip();
        await tester.settleUntil(
          () => h.engine.receive.state is Off,
          what: 'receive off',
        );
        await flip();
        await tester.settleUntil(
          () => h.engine.receive.state is On,
          what: 'receive on again',
        );

        final pin2 = h.engine.pinGuard!.currentPin!;
        expect(
          pin2,
          isNot(equals(pin1)),
          reason: 'PIN must rotate on the next Receive window',
        );
        expect(pin2, matches(RegExp(r'^[0-9]{6}$')));

        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: window PIN is NOT displayed on the Receive card when Receive is Off',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(() => AppHarness.create()))!;
        await tester.startApp(h);

        // No PIN digits should appear on ReceiveCard when Receive is Off
        expect(find.byKey(const Key('receive-pin')), findsNothing);
        expect(find.byKey(const Key('receive-card-pin')), findsNothing);

        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );
  });

  group('Fixed PIN input validation', () {
    testWidgets(
      'positive twin: valid 6 decimal digits are accepted and saved',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        await tester.startApp(h);

        final fixedSegment = find.text('Fixed');
        await scrollTo(tester, fixedSegment);
        await tester.tap(fixedSegment);
        await tester.pump();

        final pinInput = find.byKey(const Key('settings-pin-input'));
        await tester.enterText(pinInput, '849201');

        final saveBtn = find.byKey(const Key('settings-pin-save'));
        await tester.tap(saveBtn);
        await tester.pump();

        await tester.settleUntil(
          () => find.text('PIN configured').evaluate().isNotEmpty,
          what: 'PIN configured after the save finished',
        );
        expect(find.text('PIN configured'), findsOneWidget);

        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: 5 digits is rejected with visible error and nothing is saved',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        await tester.startApp(h);

        final fixedSegment = find.text('Fixed');
        await scrollTo(tester, fixedSegment);
        await tester.tap(fixedSegment);
        await tester.pump();

        final pinInput = find.byKey(const Key('settings-pin-input'));
        await tester.enterText(pinInput, '12345');

        final saveBtn = find.byKey(const Key('settings-pin-save'));
        await tester.tap(saveBtn);
        await tester.pump();

        // "PIN configured" must NOT appear
        expect(
          find.text('PIN configured'),
          findsNothing,
          reason: '5 digits must not be saved as configured PIN',
        );

        // Visible error must be shown
        expect(
          find.textContaining('6 digits'),
          findsAtLeastNWidgets(1),
          reason: 'A visible validation error must be displayed for 5 digits',
        );

        // Secret store must have no app-pin
        // A(4): no `if (exists)` guard. The security directory exists once
        // the secure engine started; nothing may be stored, and the mode
        // must still be off.
        await tester.settle(ms: 100);
        final secDir = Directory(pj(h.supportDir.path, 'security'));
        expect(secDir.existsSync(), isTrue);
        final secretStore = FileSecretStore(secDir);
        final stored = await tester.runAsync(() => secretStore.get('app-pin'));
        expect(stored, isNull);
        expect(
          File(pj(h.supportDir.path, 'app_settings.json')).readAsStringSync(),
          contains('"pinMode": "off"'),
        );

        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: letters (non-digits) are rejected with visible error and nothing is saved',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        await tester.startApp(h);

        final fixedSegment = find.text('Fixed');
        await scrollTo(tester, fixedSegment);
        await tester.tap(fixedSegment);
        await tester.pump();

        final pinInput = find.byKey(const Key('settings-pin-input'));
        await tester.enterText(pinInput, 'abcdef');

        final saveBtn = find.byKey(const Key('settings-pin-save'));
        await tester.tap(saveBtn);
        await tester.pump();

        expect(
          find.text('PIN configured'),
          findsNothing,
          reason: 'Alphabetical characters must not be accepted as PIN',
        );
        expect(
          find.textContaining('digits'),
          findsAtLeastNWidgets(1),
          reason:
              'Validation error must be visible when non-digits are entered',
        );

        // A(4): no `if (exists)` guard. The security directory exists once
        // the secure engine started; nothing may be stored, and the mode
        // must still be off.
        await tester.settle(ms: 100);
        final secDir = Directory(pj(h.supportDir.path, 'security'));
        expect(secDir.existsSync(), isTrue);
        final secretStore = FileSecretStore(secDir);
        final stored = await tester.runAsync(() => secretStore.get('app-pin'));
        expect(stored, isNull);
        expect(
          File(pj(h.supportDir.path, 'app_settings.json')).readAsStringSync(),
          contains('"pinMode": "off"'),
        );

        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );
  });
}

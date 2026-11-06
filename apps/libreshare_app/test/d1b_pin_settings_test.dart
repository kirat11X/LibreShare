// D1 round-2 (docs/plans/d1-fixes.md): the Settings PIN card and the Receive
// card, asserted through keys and visible texts only.
//   S1  success is shown only after a real write + read-back; failure shows
//       "Could not save the PIN. Nothing was changed." and changes nothing
//   S2  changing the PIN while already Fixed enforces the NEW PIN
//   S10 an unreadable / invalid stored PIN never counts as "PIN configured"
//   D   the Fixed PIN is not shown on the Receive card, the Window PIN is
//   F3  360x640 at text scale 1.3: no RenderFlex overflow
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

Future<AppHarness> openSettings(
  WidgetTester tester, {
  Directory? sandbox,
  String location = '/settings',
}) async {
  final h = (await tester.runAsync(
    () => AppHarness.create(reuseSandbox: sandbox, initialLocation: location),
  ))!;
  await bootApp(tester, h);
  return h;
}

void narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

String settingsJson(AppHarness h) =>
    File(pj(h.supportDir.path, 'app_settings.json')).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S1 Save shows success only after the PIN was really stored', () {
    testWidgets(
      'positive twin: nothing is shown before the write finished, then "PIN configured" with the stored digits',
      (tester) async {
        tester.useTallSurface();
        final h = await openSettings(tester);
        await pickSegment(tester, 'Fixed');
        await saveFixed(tester, '654321');
        // One frame only: real file I/O cannot have finished in fake time.
        expect(
          find.text('PIN configured'),
          findsNothing,
          reason: 'S1: success must not be shown before put + read-back',
        );
        expect(
          tester
              .widget<ButtonStyleButton>(
                find.byKey(const Key('settings-pin-save')),
              )
              .onPressed,
          isNull,
          reason: 'S1: the Save button is disabled while saving',
        );
        await waitFor(
          tester,
          () => shown(find.text('PIN configured')),
          maxRounds: 100,
        );
        expect(find.text('PIN configured'), findsOneWidget);
        expect(await storedPin(tester, h.supportDir), '654321');
        await waitForMode(tester, h, PinMode.fixed);
        expect(engineModeOf(h), PinMode.fixed);
        expect(h.engine.pinGuard!.currentPin, '654321');
        expect(find.text(kCouldNotSave), findsNothing);
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: a failing write shows the error, changes nothing, keeps the field and rebuilds nothing; a retry then works',
      (tester) async {
        tester.useTallSurface();
        final h = await openSettings(tester);
        final engineBefore = engineOf(h);
        blockPinWrite(h.supportDir);
        await pickSegment(tester, 'Fixed');
        await saveFixed(tester, '333333');
        await waitFor(
          tester,
          () => shown(find.text(kCouldNotSave)),
          maxRounds: 60,
        );
        expect(
          find.text(kCouldNotSave),
          findsOneWidget,
          reason: 'S1: a failed save must say so',
        );
        expect(
          find.text('PIN configured'),
          findsNothing,
          reason: 'S1: a failed save must not look like a success',
        );
        expect(h.container.read(settingsProvider).pinMode, PinMode.off);
        expect(settingsJson(h), contains('"pinMode": "off"'));
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('settings-pin-input')))
              .controller!
              .text,
          '333333',
          reason: 'S1: the typed PIN is kept so the user can try again',
        );
        expect(
          identical(engineOf(h), engineBefore),
          isTrue,
          reason: 'S1: no engine rebuild after a failed save',
        );
        expect(engineModeOf(h), PinMode.off);
        expect(await storedPin(tester, h.supportDir), isNull);
        expect(tester.takeException(), isNull);

        // The cause goes away: the same field can be saved again.
        unblockPinWrite(h.supportDir);
        await tapSave(tester);
        await waitFor(
          tester,
          () => shown(find.text('PIN configured')),
          maxRounds: 100,
        );
        expect(find.text('PIN configured'), findsOneWidget);
        expect(find.text(kCouldNotSave), findsNothing);
        expect(await storedPin(tester, h.supportDir), '333333');
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );
  });

  group('S2 changing the PIN while Fixed enforces the new PIN', () {
    testWidgets(
      'positive twin: after Change + Save the old PIN is refused (pinInvalid) and the new one passes; stored bytes are the new PIN',
      (tester) async {
        tester.useTallSurface();
        final h = await openSettings(tester);
        await pickSegment(tester, 'Fixed');
        await saveFixed(tester, '111111');
        await waitForMode(tester, h, PinMode.fixed);
        await waitFor(tester, () => shown(find.text('Change')));
        expect(engineOf(h)!.pinGuard!.currentPin, '111111');

        await tester.tap(find.text('Change'));
        await tester.pump();
        await saveFixed(tester, '222222');
        await waitFor(
          tester,
          () => engineOf(h)?.pinGuard?.currentPin == '222222',
          maxRounds: 150,
        );
        final guard = engineOf(h)!.pinGuard!;
        expect(
          guard.currentPin,
          '222222',
          reason: 'S2: the engine must enforce the NEW PIN',
        );
        expect(
          () => guard.check(
            remoteAddress: '127.0.0.9',
            pin: '111111',
            exempt: false,
          ),
          throwsA(
            isA<LsException>().having(
              (e) => e.code,
              'code',
              LsErrorCode.pinInvalid,
            ),
          ),
          reason: 'S2: the old PIN must give pinInvalid',
        );
        guard.check(remoteAddress: '127.0.0.9', pin: '222222', exempt: false);
        expect(await storedPin(tester, h.supportDir), '222222');
        // The PIN sits in no provider state that has a toString.
        expect(
          h.container.read(settingsProvider).toString(),
          isNot(contains('222222')),
        );
        expect(
          h.container.read(engineProvider).toString(),
          isNot(contains('222222')),
        );
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: Change + an invalid PIN shows the validation message and the old PIN stays enforced on the same engine',
      (tester) async {
        tester.useTallSurface();
        final h = await openSettings(tester);
        await pickSegment(tester, 'Fixed');
        await saveFixed(tester, '111111');
        await waitForMode(tester, h, PinMode.fixed);
        await waitFor(tester, () => shown(find.text('Change')));
        final before = engineOf(h);
        await tester.tap(find.text('Change'));
        await tester.pump();
        await saveFixed(tester, '22');
        await tester.settle(ms: 100, rounds: 2);
        expect(find.textContaining('6 digits'), findsAtLeastNWidgets(1));
        expect(identical(engineOf(h), before), isTrue);
        expect(engineOf(h)!.pinGuard!.currentPin, '111111');
        expect(await storedPin(tester, h.supportDir), '111111');
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );
  });

  group(
    'S10 an unreadable or invalid stored PIN is never "PIN configured"',
    () {
      testWidgets(
        'unreadable store (file mode 000): no uncaught exception, the card asks for a PIN',
        (tester) async {
          tester.useTallSurface();
          final sandbox = (await tester.runAsync(
            () => seedSandbox(pin: kSeedPin),
          ))!;
          final slot = appPinFile(Directory(pj(sandbox.path, 'support')));
          Process.runSync('chmod', ['000', slot.path]);
          addTearDown(() => Process.runSync('chmod', ['600', slot.path]));
          final h = await openSettings(tester, sandbox: sandbox);
          await pickSegment(tester, 'Fixed');
          await tester.settle(ms: 100, rounds: 10);
          expect(tester.takeException(), isNull);
          expect(
            find.text('PIN configured'),
            findsNothing,
            reason: 'S10: an unreadable store is "not configured"',
          );
          expect(find.byKey(const Key('settings-pin-input')), findsOneWidget);
          Process.runSync('chmod', ['600', slot.path]);
          await tester.stopApp(h);
        },
        timeout: kSixtySeconds,
      );

      testWidgets(
        'invalid stored value ("abc" in a valid frame): not "PIN configured", the input is offered',
        (tester) async {
          tester.useTallSurface();
          final sandbox = (await tester.runAsync(
            () => seedSandbox(pin: 'abc'),
          ))!;
          final h = await openSettings(tester, sandbox: sandbox);
          await pickSegment(tester, 'Fixed');
          await tester.settle(ms: 100, rounds: 10);
          expect(
            find.text('PIN configured'),
            findsNothing,
            reason: 'S10: the stored value must be validated before it is shown as configured',
          );
          expect(find.byKey(const Key('settings-pin-input')), findsOneWidget);
          await tester.stopApp(h);
        },
        timeout: kSixtySeconds,
      );

      testWidgets(
        'positive twin: a valid stored PIN is shown as "PIN configured" when Fixed is picked',
        (tester) async {
          tester.useTallSurface();
          final sandbox = (await tester.runAsync(
            () => seedSandbox(pin: kSeedPin),
          ))!;
          final h = await openSettings(tester, sandbox: sandbox);
          await pickSegment(tester, 'Fixed');
          await waitFor(tester, () => shown(find.text('PIN configured')));
          expect(find.text('PIN configured'), findsOneWidget);
          expect(find.byKey(const Key('settings-pin-input')), findsNothing);
          await tester.stopApp(h);
        },
        timeout: kSixtySeconds,
      );
    },
  );

  group('D the Receive card shows the Window PIN, not the Fixed PIN', () {
    testWidgets(
      'negative twin: Fixed mode with Receive on shows no PIN on the card',
      (tester) async {
        tester.useTallSurface();
        final sandbox = (await tester.runAsync(
          () => seedSandbox(mode: PinMode.fixed, pin: kSeedPin),
        ))!;
        final h = await openSettings(tester, sandbox: sandbox);
        expect(engineModeOf(h), PinMode.fixed);
        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => h.engine.receive.state is On,
          what: 'receive on',
        );
        expect(
          find.byKey(const Key('receive-pin')),
          findsNothing,
          reason:
              'Additions D: a Fixed PIN is not displayed on the Receive card',
        );
        expect(find.textContaining(kSeedPin), findsNothing);
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'positive twin: Window mode with Receive on shows "PIN: <current PIN>"; with Receive off nothing',
      (tester) async {
        tester.useTallSurface();
        final sandbox = (await tester.runAsync(
          () => seedSandbox(mode: PinMode.window),
        ))!;
        final h = await openSettings(tester, sandbox: sandbox);
        expect(engineModeOf(h), PinMode.window);
        expect(find.byKey(const Key('receive-pin')), findsNothing);
        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => shown(find.byKey(const Key('receive-pin'))),
          what: 'window PIN on the card',
        );
        final pin = h.engine.pinGuard!.currentPin!;
        expect(pin, matches(RegExp(r'^[0-9]{6}$')));
        expect(find.text('PIN: $pin'), findsOneWidget);
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );
  });

  group('F3 narrow window (360x640) at text scale 1.3: no overflow', () {
    testWidgets(
      'PIN card: Fixed input, validation error, saved state, New each time',
      (tester) async {
        narrow(tester);
        final h = await openSettings(tester);
        await pickSegment(tester, 'Fixed');
        expect(tester.takeException(), isNull);
        await saveFixed(tester, '12');
        await scrollToText(
          tester,
          find.textContaining('6 digits'),
          'the validation message',
        );
        expect(tester.takeException(), isNull);
        await saveFixed(tester, '654321');
        await waitFor(
          tester,
          () => appPinFile(h.supportDir).existsSync(),
          maxRounds: 100,
        );
        // Two settings saves must not overlap (they share one temp file).
        await waitFor(
          tester,
          () => settingsJson(h).contains('"pinMode": "fixed"'),
          maxRounds: 100,
        );
        await waitForMode(tester, h, PinMode.fixed);
        await tester.settle(ms: 100, rounds: 3);
        expect(tester.takeException(), isNull);
        await scrollToText(
          tester,
          find.text('PIN configured'),
          'the saved state',
        );
        expect(tester.takeException(), isNull);
        await pickSegment(tester, 'New each time');
        await waitForMode(tester, h, PinMode.window);
        expect(tester.takeException(), isNull);
        await tester.settle(ms: 100, rounds: 3);
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets('PIN card: the failure message fits', (tester) async {
      narrow(tester);
      final h = await openSettings(tester);
      blockPinWrite(h.supportDir);
      await pickSegment(tester, 'Fixed');
      await saveFixed(tester, '333333');
      await tester.settle(ms: 100, rounds: 8);
      await scrollToText(
        tester,
        find.text(kCouldNotSave),
        'the save-failure message',
      );
      expect(tester.takeException(), isNull);
      unblockPinWrite(h.supportDir);
      await tester.stopApp(h);
    }, timeout: kSixtySeconds);

    testWidgets('PIN card: the "PIN needs to be set again" notice fits', (
      tester,
    ) async {
      narrow(tester);
      final sandbox = (await tester.runAsync(
        () => seedSandbox(mode: PinMode.fixed),
      ))!;
      final h = await openSettings(tester, sandbox: sandbox);
      await scrollToText(tester, find.text(kPinNeedsReset), 'the S5 notice');
      expect(tester.takeException(), isNull);
      await tester.stopApp(h);
    }, timeout: kSixtySeconds);

    testWidgets('Receive card: the PIN row fits (Window PIN, Receive on)', (
      tester,
    ) async {
      narrow(tester);
      final sandbox = (await tester.runAsync(
        () => seedSandbox(mode: PinMode.window),
      ))!;
      final h = await openSettings(tester, sandbox: sandbox, location: '/');
      await tester.tap(find.byKey(const Key('receive-switch')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('receive-pin'))),
        what: 'window PIN on the card',
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('receive-pin')), findsOneWidget);
      await tester.stopApp(h);
    }, timeout: kSixtySeconds);
  });
}

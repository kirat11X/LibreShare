// Verifier test V12 (delta mutations db2/de2/de3-text): after a failed mode
// save the selector must show the mode that is really active, an error must be
// visible somewhere, and the later flow must still work.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/router_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

Set<PinMode> selected(WidgetTester tester) => tester
    .widget<SegmentedButton<PinMode>>(
      find.byKey(const Key('settings-pin-selector')),
    )
    .selected;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'V12 a failed switch to Fixed snaps the selector back to the active mode (Off)',
    (tester) async {
      tester.useTallSurface();
      final sandbox = await tester.runAsync(
        () => seedSandbox(mode: PinMode.off, pin: kSeedPin),
      );
      final h = (await tester.runAsync(
        () => AppHarness.create(
          reuseSandbox: sandbox,
          initialLocation: '/settings',
        ),
      ))!;
      await bootApp(tester, h);
      await waitFor(tester, () => false, maxRounds: 40);
      final slot = Directory(pj(h.supportDir.path, 'app_settings.json.tmp'))
        ..createSync(recursive: true);
      File(pj(slot.path, 'keep')).writeAsStringSync('x');
      await pickSegment(tester, 'Fixed');
      await waitFor(tester, () => false, maxRounds: 40);
      expect(h.container.read(settingsProvider).pinMode, PinMode.off);
      expect(selected(tester), {
        PinMode.off,
      }, reason: 'the selector must show what is really active');
      await tester.stopApp(h);
    },
    timeout: kSixtySeconds,
  );

  testWidgets(
    'V12b a failed switch from Fixed to Off keeps the selector on Fixed (the mode that is still active)',
    (tester) async {
      tester.useTallSurface();
      final sandbox = await tester.runAsync(
        () => seedSandbox(mode: PinMode.fixed, pin: kSeedPin),
      );
      final h = (await tester.runAsync(
        () => AppHarness.create(
          reuseSandbox: sandbox,
          initialLocation: '/settings',
        ),
      ))!;
      await bootApp(tester, h);
      await waitForMode(tester, h, PinMode.fixed);
      await waitFor(tester, () => shown(find.text('PIN configured')));
      final slot = Directory(pj(h.supportDir.path, 'app_settings.json.tmp'))
        ..createSync(recursive: true);
      File(pj(slot.path, 'keep')).writeAsStringSync('x');
      final sel = find.byKey(const Key('settings-pin-selector'));
      await centre(tester, sel);
      await tester.tap(find.descendant(of: sel, matching: find.text('Off')));
      await tester.pump();
      await waitFor(tester, () => false, maxRounds: 40);
      expect(h.container.read(settingsProvider).pinMode, PinMode.fixed);
      expect(selected(tester), {PinMode.fixed});
      expect(
        engineOf(h)?.pinGuard?.enforced,
        isTrue,
        reason: 'the PIN is still enforced',
      );
      await tester.stopApp(h);
    },
    timeout: kSixtySeconds,
  );

  testWidgets(
    'V13 leaving Settings while the mode save fails raises no error (no setState after dispose)',
    (tester) async {
      tester.useTallSurface();
      final sandbox = await tester.runAsync(
        () => seedSandbox(mode: PinMode.off, pin: kSeedPin),
      );
      final h = (await tester.runAsync(
        () => AppHarness.create(
          reuseSandbox: sandbox,
          initialLocation: '/settings',
        ),
      ))!;
      await bootApp(tester, h);
      await waitFor(tester, () => false, maxRounds: 40);
      final slot = Directory(pj(h.supportDir.path, 'app_settings.json.tmp'))
        ..createSync(recursive: true);
      File(pj(slot.path, 'keep')).writeAsStringSync('x');
      await pickSegment(tester, 'Fixed');
      h.container.read(routerProvider).go('/my-qr');
      await tester.pump();
      await waitFor(tester, () => false, maxRounds: 60);
      expect(tester.takeException(), isNull);
      expect(h.container.read(settingsProvider).pinMode, PinMode.off);
      await tester.stopApp(h);
    },
    timeout: kSixtySeconds,
  );
}

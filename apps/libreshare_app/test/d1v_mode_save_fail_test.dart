// Verifier test V2 (finding P1-03): choosing "Fixed" with a valid stored PIN
// while the settings file cannot be written. setPinMode rolls the mode back
// (provider says Off, no PIN guard) but the selector keeps showing Fixed with
// "PIN configured": a false assurance. Either the selector must go back to Off
// (or an error must be shown), or the mode must really be Fixed.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'V2 UI never claims Fixed + "PIN configured" while the mode really is Off after a failed save',
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
      // Let the card finish reading the stored PIN (its async check).
      await waitFor(tester, () => false, maxRounds: 40);
      // Block the next settings write: its temp slot is a non-empty directory.
      final slot = Directory(pj(h.supportDir.path, 'app_settings.json.tmp'))
        ..createSync(recursive: true);
      File(pj(slot.path, 'keep')).writeAsStringSync('x');

      await pickSegment(tester, 'Fixed');
      await waitFor(tester, () => false, maxRounds: 40);
      final selected = tester
          .widget<SegmentedButton<PinMode>>(
            find.byKey(const Key('settings-pin-selector')),
          )
          .selected;
      final uiClaimsFixed =
          selected.contains(PinMode.fixed) &&
          shown(find.text('PIN configured'));
      final mode = h.container.read(settingsProvider).pinMode;
      final enforced = engineOf(h)?.pinGuard?.enforced ?? false;
      expect(
        !uiClaimsFixed || (mode == PinMode.fixed && enforced),
        isTrue,
        reason:
            'UI claims "Fixed" and "PIN configured" but provider mode is $mode '
            'and the engine enforces a PIN: $enforced',
      );
      await tester.stopApp(h);
    },
    timeout: kSixtySeconds,
  );
}

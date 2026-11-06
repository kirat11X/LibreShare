// Verifier test V1 (finding P1-02): Change PIN while Fixed, then leave the
// Settings screen before the save finished. The stored PIN is the NEW one, so
// the engine must enforce the new one too (S2): the old PIN must not stay
// enforced just because the card was unmounted during the write.
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/router_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'V1 S2: leaving Settings during the save of a changed PIN still makes the engine enforce the new PIN',
    (tester) async {
      tester.useTallSurface();
      final sandbox = await tester.runAsync(
        () => seedSandbox(mode: PinMode.fixed, pin: '111111'),
      );
      final h = (await tester.runAsync(
        () => AppHarness.create(
          reuseSandbox: sandbox,
          initialLocation: '/settings',
        ),
      ))!;
      await bootApp(tester, h);
      await waitForMode(tester, h, PinMode.fixed);
      await waitFor(tester, () => shown(find.text('Change')));
      expect(engineOf(h)!.pinGuard!.currentPin, '111111');

      await tester.tap(find.text('Change'));
      await tester.pump();
      await saveFixed(tester, '222222');
      // Leave the screen at once: the card (and its State) is disposed while
      // the write / read-back are still running.
      h.container.read(routerProvider).go('/my-qr');
      await tester.pump();
      // Let the write finish (real time) and the rebuild, if any, run.
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        await storedPin(tester, h.supportDir),
        '222222',
        reason: 'precondition: the new PIN was stored',
      );
      await waitFor(
        tester,
        () => engineOf(h)?.pinGuard?.currentPin == '222222',
        maxRounds: 200,
      );
      final guard = engineOf(h)?.pinGuard;
      expect(
        guard?.currentPin,
        '222222',
        reason:
            'S2: the stored PIN is new, the engine must not keep the old one',
      );
      await tester.stopApp(h);
    },
    timeout: kSixtySeconds,
  );
}

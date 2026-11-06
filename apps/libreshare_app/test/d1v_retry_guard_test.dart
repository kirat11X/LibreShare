// Verifier tests V8 / V9 (survivor z7 and finding P1-07): retryWithPin must
// not start a second send for the same key while the first retry runs, and
// should not resend a transfer that is not waiting for a PIN.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/router_provider.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

const String correctPin = '381920';

Future<(AppHarness, SecureBob, String)> rig(
  WidgetTester tester,
  String ip,
) async {
  tester.useTallSurface();
  final h = (await tester.runAsync(AppHarness.create))!;
  final bob = (await tester.runAsync(
    () => SecureBob.start(h.sandbox, ip, pin: correctPin),
  ))!;
  await bootApp(tester, h);
  final file = h.makeFile('document.txt', 256);
  final key = h.container.read(transfersProvider.notifier).startSend(
    bob.device,
    [h.pick(file)],
  );
  unawaited(h.container.read(routerProvider).push('/transfer/$key'));
  await tester.pump();
  await tester.settleUntil(
    () => shown(find.byKey(const Key('pin-dialog'))),
    what: 'the PIN dialog',
  );
  return (h, bob, key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'V8 a second retryWithPin for the same key while the first runs is refused and Bob sees one file',
    (tester) async {
      final (h, bob, key) = await rig(tester, '127.0.0.33');
      final n = h.container.read(transfersProvider.notifier);
      expect(n.retryWithPin(key, correctPin), isTrue);
      expect(
        n.retryWithPin(key, correctPin),
        isFalse,
        reason: 'double submit must not start a second send',
      );
      await tester.settleUntil(
        () => h.container
            .read(transfersProvider)
            .any((v) => v.phase == TransferPhase.completed),
        what: 'completion',
        maxRounds: 400,
      );
      expect(bob.received, hasLength(1));
      await tester.stopApp(h);
      await tester.runAsync(bob.close);
    },
    timeout: kSixtySeconds,
  );

  testWidgets(
    'V9 retryWithPin on an already COMPLETED transfer is refused (nothing is sent twice)',
    (tester) async {
      final (h, bob, key) = await rig(tester, '127.0.0.34');
      final n = h.container.read(transfersProvider.notifier);
      expect(n.retryWithPin(key, correctPin), isTrue);
      await tester.settleUntil(
        () => h.container
            .read(transfersProvider)
            .any((v) => v.phase == TransferPhase.completed),
        what: 'completion',
        maxRounds: 400,
      );
      // _drive's own tail (stream close, _sends cleanup) runs a little later.
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(
        n.retryWithPin(key, correctPin),
        isFalse,
        reason: 'a completed transfer is not waiting for a PIN',
      );
      await tester.stopApp(h);
      await tester.runAsync(bob.close);
    },
    timeout: kSixtySeconds,
  );
}

// D1 round-2: the second tester's probe tests X1-X5, X9, X10 adopted as
// repo tests (docs/plans/d1-fixes.md Additions B). Every action that rebuilds
// the engine waits for the rebuild (settle helpers); every test has an
// explicit 60 s timeout. Changes against the probe file are listed in
// docs/plans/d1b-tests.md (X4: failure injection; X5: S5 decision).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

Future<void> toMode(WidgetTester tester, AppHarness h, PinMode m) =>
    tester.settleUntil(
      () => h.container.read(engineOrNullProvider)?.pinGuard?.policy.mode == m,
      what: 'engine rebuilt with pin mode $m',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'X1 fixed save: enforced, stored, not in JSON, survives restart, not logged',
    (tester) async {
      tester.useTallSurface();
      final logs = LogCapture();
      addTearDown(logs.stop);
      final h1 = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h1);
      await pickSegment(tester, 'Fixed');
      await saveFixed(tester, '654321');
      await toMode(tester, h1, PinMode.fixed);
      expect(find.text('PIN configured'), findsOneWidget);
      final g1 = h1.engine.pinGuard!;
      expect(g1.enforced, isTrue);
      expect(g1.currentPin, '654321');
      final stored = await tester.runAsync<Uint8List?>(
        () =>
            FileSecretStore(Directory(pj(h1.supportDir.path, 'security')))
                .get('app-pin'),
      );
      expect(utf8.decode(stored!), '654321');
      // let the settings file be written
      await tester.settle(ms: 100);
      final json = File(pj(h1.supportDir.path, 'app_settings.json'));
      expect(json.readAsStringSync(), contains('"pinMode": "fixed"'));
      expect(json.readAsStringSync().contains('654321'), isFalse);
      final sandbox = h1.sandbox;
      await tester.stopApp(h1, deleteSandbox: false);
      final h2 = (await tester.runAsync(
        () => AppHarness.create(
          reuseSandbox: sandbox,
          initialLocation: '/settings',
        ),
      ))!;
      await tester.startApp(h2);
      expect(h2.engine.pinGuard!.enforced, isTrue);
      expect(h2.engine.pinGuard!.currentPin, '654321');
      expect(
        logs.lines.where((l) => l.contains('654321')),
        isEmpty,
        reason: 'PIN must never be logged',
      );
      expect(
        File(pj(h2.supportDir.path, 'app_settings.json'))
            .readAsStringSync()
            .contains('654321'),
        isFalse,
      );
      logs.stop(); // debugPrint is restored before the test ends
      await tester.stopApp(h2);
    },
    timeout: kSixtySeconds,
  );

  testWidgets('X2 window: PIN on card only while Receive on; rotates', (
    tester,
  ) async {
    tester.useTallSurface();
    final h = (await tester.runAsync(
      () => AppHarness.create(initialLocation: '/settings'),
    ))!;
    await tester.startApp(h);
    await pickSegment(tester, 'New each time');
    await toMode(tester, h, PinMode.window);
    final guard = h.engine.pinGuard!;
    // Receive off: the guard has a PIN but the card must not show it.
    expect(guard.currentPin, isNotNull);
    expect(find.byKey(const Key('receive-pin')), findsNothing);
    Future<void> sw() => tester.tap(find.byKey(const Key('receive-switch')));
    await sw();
    await tester.settleUntil(
      () => find.byKey(const Key('receive-pin')).evaluate().isNotEmpty,
      what: 'pin on card',
    );
    final pin1 = h.engine.pinGuard!.currentPin!;
    expect(find.text('PIN: $pin1'), findsOneWidget);
    await sw();
    await tester.settleUntil(
      () => h.engine.receive.state is Off,
      what: 'receive off',
    );
    expect(find.byKey(const Key('receive-pin')), findsNothing);
    await sw();
    await tester.settleUntil(
      () => h.engine.receive.state is On,
      what: 'receive on again',
    );
    final pin2 = h.engine.pinGuard!.currentPin!;
    expect(pin2, isNot(pin1));
    await tester.stopApp(h);
  }, timeout: kSixtySeconds);

  testWidgets('X3 fixed mode: Change PIN while already fixed takes effect', (
    tester,
  ) async {
    tester.useTallSurface();
    final h = (await tester.runAsync(
      () => AppHarness.create(initialLocation: '/settings'),
    ))!;
    await tester.startApp(h);
    await pickSegment(tester, 'Fixed');
    await saveFixed(tester, '111111');
    await toMode(tester, h, PinMode.fixed);
    expect(h.engine.pinGuard!.currentPin, '111111');
    await tester.tap(find.text('Change'));
    await tester.pump();
    await saveFixed(tester, '222222');
    String? stored;
    for (var i = 0; i < 20; i++) {
      await tester.settle(ms: 200);
      stored = await storedPin(tester, h.supportDir);
      if (stored == '222222') break;
    }
    expect(stored, '222222');
    // The read-back, the revision bump and the engine rebuild need more
    // rounds after the file is written (round 2b: wait, do not weaken).
    await tester.settleUntil(
      () =>
          h.container.read(engineOrNullProvider)?.pinGuard?.currentPin ==
          '222222',
      what: 'the engine enforcing the new PIN 222222',
    );
    expect(
      h.container.read(engineOrNullProvider)!.pinGuard!.currentPin,
      '222222',
      reason: 'the engine must enforce the new PIN, not the old one',
    );
    await tester.stopApp(h);
  }, timeout: kSixtySeconds);

  testWidgets('X4 save failure must not show PIN configured', (tester) async {
    tester.useTallSurface();
    final h = (await tester.runAsync(
      () => AppHarness.create(initialLocation: '/settings'),
    ))!;
    await tester.startApp(h);
    // The store cannot write (see blockPinWrite: chmod would be undone by
    // the store itself, so the probe's chmod 500 is replaced).
    blockPinWrite(h.supportDir);
    await pickSegment(tester, 'Fixed');
    await saveFixed(tester, '333333');
    // The failing put needs real time before the error is on screen.
    await tester.settleUntil(
      () => find.text(kCouldNotSave).evaluate().isNotEmpty,
      what: 'the save-failure message',
    );
    expect(
      find.text('PIN configured'),
      findsNothing,
      reason: 'the PIN was not saved, so it must not be shown as configured',
    );
    expect(
      find.text(kCouldNotSave),
      findsOneWidget,
      reason: 'the failure must be visible (docs/plans/d1-fixes.md S1)',
    );
    unblockPinWrite(h.supportDir);
    await tester.stopApp(h);
  }, timeout: kSixtySeconds);

  testWidgets(
    'X5 fixed policy in settings but app-pin missing: window fallback, never a hidden random fixed PIN',
    (tester) async {
      tester.useTallSurface();
      final sandbox = await tester.runAsync(
        () => seedSandbox(mode: PinMode.fixed),
      );
      final h = (await tester.runAsync(
        () => AppHarness.create(
          reuseSandbox: sandbox,
          initialLocation: '/settings',
        ),
      ))!;
      await bootApp(tester, h);
      final g = h.engine.pinGuard;
      expect(g, isNotNull);
      expect(
        g!.policy.mode,
        PinMode.window,
        reason:
            'no usable stored PIN: fall back to a temporary window PIN (S5)',
      );
      expect(g.enforced, isTrue);
      expect(
        find.text(kPinNeedsReset),
        findsOneWidget,
        reason: 'Settings must say that the PIN needs to be set again',
      );
      await tester.stopApp(h);
    },
    timeout: kSixtySeconds,
  );

  test('X9 plaintext peer via host:port is refused (allowInsecurePeers default false)', () async {
    final h = await AppHarness.create();
    addTearDown(() => h.dispose());
    await h.boot();
    final peer = await h.startPeer(
      'LegacyBob',
      mode: const ReceiveAlways(),
      discover: false,
    );
    final f = h.makeFile('plain.txt', 128);
    await expectLater(
      h.engine.sendFiles([f], host: peer.ip, port: peer.engine.port),
      throwsA(isA<InsecurePeerException>()),
    );
    expect(
      peer.rx.existsSync() ? peer.rx.listSync() : const [],
      isEmpty,
      reason: 'nothing may reach a plaintext peer',
    );
  }, timeout: kSixtySeconds);

  test('X10 shutdown order: engine closed first, then SecurityWiring (trust store)', () async {
    final h = await AppHarness.create();
    await h.boot();
    final order = <String>[];
    final engine = h.engine;
    final sec = engine.security!;
    engine.events.listen((_) {}, onDone: () => order.add('engine'));
    sec.trust.changes.listen((_) {}, onDone: () => order.add('security'));
    final notifier = h.container.read(engineProvider.notifier);
    h.container.dispose();
    await notifier.closed;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(order, ['engine', 'security']);
    for (final pr in h.peers) {
      await pr.engine.dispose(force: true);
    }
    try {
      h.sandbox.deleteSync(recursive: true);
    } on Object {
      // best effort
    }
  }, timeout: kSixtySeconds);
}

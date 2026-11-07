import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/receive_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';
import 'helpers/port_blocker.dart';

String status(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('receive-status'))).data!;

bool switchValue(WidgetTester tester) => tester
    .widget<SwitchListTile>(find.byKey(const Key('receive-switch')))
    .value;

void main() {
  group('Receive card on Home', () {
    testWidgets('starts Off: nothing listens until the user turns it on', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      expect(switchValue(tester), isFalse);
      expect(status(tester), contains('Not receiving'));
      expect(h.engine.isListening, isFalse);
      expect(h.engine.receive.state, const Off(OffReason.neverEnabled));
      expect(h.engine.myPeerLink, isNull);

      await tester.stopApp(h);
    });

    testWidgets('the switch turns Receive on (Always) and off again', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('receive-switch')));
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'receive on',
      );
      expect(h.engine.isListening, isTrue);
      expect(switchValue(tester), isTrue);
      expect(status(tester), 'Visible to everyone until you turn it off');
      expect(h.engine.port, greaterThan(0));

      await tester.tap(find.byKey(const Key('receive-switch')));
      await tester.settleUntil(
        () => h.engine.receive.state is Off,
        what: 'receive off',
      );
      expect(h.engine.isListening, isFalse);
      expect(status(tester), 'Not receiving');
      expect(switchValue(tester), isFalse);

      await tester.stopApp(h);
    });

    testWidgets('offers 15 min, 1 h, 6 h and Always on desktop', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      for (final k in ['15m', '60m', '360m', 'always']) {
        expect(find.byKey(Key('receive-choice-$k')), findsOneWidget, reason: k);
      }
      expect(find.text('15 min'), findsOneWidget);
      expect(find.text('1 h'), findsOneWidget);
      expect(find.text('6 h'), findsOneWidget);
      expect(find.text('Always'), findsOneWidget);
      // Always is the default and is highlighted.
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('receive-choice-always')))
            .selected,
        isTrue,
      );

      await tester.stopApp(h);
    });

    testWidgets('a duration shows the end time and the time left', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('receive-choice-60m')));
      await tester.settleUntil(
        () =>
            h.engine.receive.settings.defaultMode ==
            const ReceiveFor(Duration(hours: 1)),
        what: 'duration saved',
      );
      await tester.tap(find.byKey(const Key('receive-switch')));
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'receive on',
      );

      final state = h.engine.receive.state as On;
      expect(state.until, h.clock.now().add(const Duration(hours: 1)));
      expect(status(tester), startsWith('Visible to everyone until '));
      expect(status(tester), endsWith('(1 h left)'));

      // Time passes: the tick refreshes the label.
      h.clock.advance(const Duration(minutes: 20));
      await tester.pump(const Duration(seconds: 6));
      expect(status(tester), endsWith('(40 min left)'));

      await tester.stopApp(h);
    });

    testWidgets('choosing a duration while receiving extends the window', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);
      await tester.runAsync(
        () => h.engine.receive.turnOn(const ReceiveFor(Duration(minutes: 15))),
      );
      await tester.settle();
      expect(
        (h.engine.receive.state as On).until,
        h.clock.now().add(const Duration(minutes: 15)),
      );

      await tester.tap(find.byKey(const Key('receive-choice-360m')));
      await tester.settleUntil(
        () =>
            (h.engine.receive.state as On).until ==
            h.clock.now().add(const Duration(hours: 6)),
        what: 'window extended',
      );
      expect(h.engine.isListening, isTrue);

      await tester.stopApp(h);
    });

    testWidgets('Android-like caps: no Always, 6 h maximum, note shown', (
      tester,
    ) async {
      final services = PlatformServices(
        autostart: FakeAutostart(supported: false),
        tray: FakeTray(),
        window: FakeWindow(),
        multicastLock: FakeMulticastLock(),
        environment: FakeEnvironment(),
        caps: const ReceivePlatformCaps(
          maxContinuous: Duration(hours: 6),
          resumeAfterCrash: false,
        ),
      );
      final h = (await tester.runAsync(
        () => AppHarness.create(services: services),
      ))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('receive-choice-always')), findsNothing);
      expect(find.byKey(const Key('receive-choice-360m')), findsOneWidget);
      expect(find.textContaining('Android limits'), findsOneWidget);
      // The saved default "Always" folds into the longest window offered.
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('receive-choice-360m')))
            .selected,
        isTrue,
      );
      expect(h.container.read(receiveChoicesProvider), [
        const ReceiveFor(Duration(minutes: 15)),
        const ReceiveFor(Duration(hours: 1)),
        const ReceiveFor(Duration(hours: 6)),
      ]);

      await tester.tap(find.byKey(const Key('receive-switch')));
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'receive on',
      );
      expect(
        (h.engine.receive.state as On).until,
        h.clock.now().add(const Duration(hours: 6)),
      );

      await tester.stopApp(h);
    });

    testWidgets('network loss pauses with Resume; coming back resumes', (
      tester,
    ) async {
      final env = FakeEnvironment();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: PlatformServices.fake(environment: env),
        ),
      ))!;
      await tester.startApp(h);
      await tester.runAsync(() => h.engine.receive.turnOn());
      await tester.settle();

      env.emit(const NetworkDown());
      await tester.settleUntil(
        () => h.engine.receive.state is Paused,
        what: 'paused',
      );
      await tester.pump();
      expect(status(tester), contains('Waiting for Wi-Fi'));
      expect(find.byKey(const Key('receive-resume')), findsOneWidget);
      expect(h.engine.isListening, isFalse);

      env.emit(const NetworkUp());
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'resumed by the network',
      );
      await tester.pump();
      expect(find.byKey(const Key('receive-resume')), findsNothing);
      expect(h.engine.isListening, isTrue);

      await tester.stopApp(h);
    });

    testWidgets('an ended window shows Resume, which opens a fresh one', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);
      await tester.runAsync(
        () => h.engine.receive.turnOn(const ReceiveFor(Duration(minutes: 15))),
      );
      await tester.settle();

      h.clock.advance(const Duration(minutes: 15));
      await tester.settleUntil(
        () => h.engine.receive.state is Off,
        what: 'window ended',
      );
      await tester.pump();
      expect(h.engine.receive.state, const Off(OffReason.expired));
      expect(status(tester), contains('Receiving ended'));
      expect(h.engine.isListening, isFalse);

      await tester.tap(find.byKey(const Key('receive-resume')));
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'resumed',
      );
      expect(h.engine.isListening, isTrue);
      expect(
        (h.engine.receive.state as On).until,
        h.clock.now().add(const Duration(minutes: 15)),
      );

      await tester.stopApp(h);
    });

    testWidgets('a port that cannot be bound shows Failed and Try again', (
      tester,
    ) async {
      // Occupy the only port the engine may use (a preferred port above 53327
      // has no fallback range), so the bind fails.
      final blocker = await tester.runAsync(() async {
        for (var p = 59871; ; p++) {
          try {
            return PortBlocker.bind(p, address: '127.0.0.2');
          } on SocketException {
            continue;
          }
        }
      });
      final port = blocker!.port;
      final h = (await tester.runAsync(
        () => AppHarness.create(preferredPort: port),
      ))!;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('receive-switch')));
      await tester.settleUntil(
        () => h.engine.receive.state is Failed,
        what: 'bind failure',
      );
      await tester.pump();
      expect(status(tester), contains('Could not start receiving'));
      expect(find.text('Try again'), findsOneWidget);

      await tester.runAsync(() => blocker.close());
      await tester.tap(find.byKey(const Key('receive-resume')));
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'receive on after the port is free',
      );
      expect(h.engine.port, port);

      await tester.stopApp(h);
    });

    testWidgets('engine rebuild keeps the Receive mode (rename while on)', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);
      await tester.runAsync(() => h.engine.receive.turnOn());
      await tester.settle();
      final before = h.engine;

      await tester.runAsync(() async {
        await h.container.read(settingsProvider.notifier).setAlias('Renamed');
        await h.container.read(engineProvider.future);
      });
      await tester.settleUntil(
        () =>
            !identical(h.container.read(engineOrNullProvider), before) &&
            h.container.read(engineOrNullProvider) != null,
        what: 'new engine',
      );
      expect(h.engine.self.alias, 'Renamed');
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'receive restored',
      );
      expect(h.engine.isListening, isTrue);

      await tester.stopApp(h);
    });
  });
}

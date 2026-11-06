// How the app uses the desktop/Android platform adapters (design 01 sections
// 2.2, 3 and 4): close-to-tray, --hidden start, the tray menu, the multicast
// lock and a graceful quit. The OS side is fake (PlatformServices); the engine
// is a real LibreShareEngine.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';
import 'helpers/shell_fakes.dart';

bool shown(Finder f) => f.evaluate().isNotEmpty;

/// A Home with Receive as the test wants it.
Future<void> receiveOn(WidgetTester tester, AppHarness h) async {
  await tester.runAsync(() => h.engine.receive.turnOn());
  await tester.settle();
}

Future<void> receiveOff(WidgetTester tester, AppHarness h) async {
  await tester.runAsync(() => h.engine.receive.turnOff());
  await tester.settle();
}

void main() {
  // Plaintext fixture peers against the app's secure engine (see the harness).
  setUpAll(() => AppHarness.legacyPlaintextPeers = true);
  tearDownAll(() => AppHarness.legacyPlaintextPeers = false);

  group('Closing the window', () {
    testWidgets('hides to the tray while Receive is on, quits when it is off', (
      tester,
    ) async {
      final backend = RecordingWindowBackend();
      final tray = CapturingTray(available: true);
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(backend: backend, tray: tray),
        ),
      ))!;
      await tester.startApp(h);
      expect(tray.initCalls, 1);

      // Receive is Off: nothing needs the app, so the close button closes.
      expect(backend.userClicksClose(), isFalse);
      expect(backend.actions, isEmpty);

      await receiveOn(tester, h);
      expect(backend.userClicksClose(), isTrue, reason: 'vetoed');
      expect(backend.actions, ['hide']);
      expect(backend.visible, isFalse);

      // Switching Receive off makes the next close real again.
      backend.clear();
      await receiveOff(tester, h);
      expect(backend.userClicksClose(), isFalse);
      expect(backend.actions, isEmpty);

      await tester.stopApp(h);
    });

    testWidgets('without a tray the close button only minimizes', (
      tester,
    ) async {
      final backend = RecordingWindowBackend();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(
            backend: backend,
            tray: CapturingTray(available: false),
          ),
        ),
      ))!;
      await tester.startApp(h);
      await receiveOn(tester, h);

      expect(backend.userClicksClose(), isTrue);
      expect(backend.actions, ['minimize']);

      await tester.stopApp(h);
    });

    testWidgets(
      'a running transfer keeps the app alive even if Receive is off',
      (tester) async {
        final backend = RecordingWindowBackend();
        final h = (await tester.runAsync(
          () => AppHarness.create(
            services: desktopShellServices(
              backend: backend,
              tray: CapturingTray(available: true),
            ),
          ),
        ))!;
        // The other device never answers, so the transfer stays active.
        final peer = (await tester.runAsync(
          () => h.startPeer('Pixel 8', autoAccept: false),
        ))!;
        h.picker.files = [h.pick(h.makeFile('a.txt', 500))];
        await tester.startApp(h);
        await tester.settleUntil(
          () => shown(find.byKey(Key('device-${peer.id}'))),
          what: 'peer listed',
        );

        await tester.tap(find.byKey(Key('device-${peer.id}')));
        await tester.settleUntil(
          () => shown(find.byKey(const Key('transfer-waiting'))),
          what: 'waiting for the other device',
          maxRounds: 400,
        );
        expect(h.container.read(transfersProvider).single.isActive, isTrue);
        expect(backend.userClicksClose(), isTrue);
        expect(backend.actions, ['hide']);

        // Once it is over, closing quits again.
        backend.clear();
        await tester.tap(find.byKey(const Key('transfer-cancel')));
        await tester.settleUntil(
          () => shown(find.byKey(const Key('transfer-failed'))),
          what: 'cancelled',
          maxRounds: 400,
        );
        expect(backend.userClicksClose(), isFalse);
        expect(backend.actions, isEmpty);

        await tester.stopApp(h);
      },
    );
  });

  group('Starting hidden (--hidden)', () {
    testWidgets('with a tray the window stays hidden; tray Open shows it', (
      tester,
    ) async {
      final backend = RecordingWindowBackend();
      final tray = CapturingTray(available: true);
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(backend: backend, tray: tray),
          overrides: [
            launchArgsProvider.overrideWithValue(const ['--hidden']),
          ],
        ),
      ))!;
      await tester.startApp(h);

      expect(backend.actions, ['hide']);
      expect(backend.visible, isFalse);
      // The app is up and working while nobody sees it.
      expect(h.engine.isStarted, isTrue);

      tray.onOpen!();
      await tester.pump();
      expect(backend.visible, isTrue);
      expect(backend.actions, ['hide', 'show']);

      await tester.stopApp(h);
    });

    testWidgets('without a tray it starts minimized, never out of reach', (
      tester,
    ) async {
      final backend = RecordingWindowBackend();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(
            backend: backend,
            tray: CapturingTray(available: false),
          ),
          overrides: [
            launchArgsProvider.overrideWithValue(const ['--hidden']),
          ],
        ),
      ))!;
      await tester.startApp(h);

      expect(backend.actions, ['show', 'minimize']);

      await tester.stopApp(h);
    });

    testWidgets('a normal start (no flag) leaves the window alone', (
      tester,
    ) async {
      final backend = RecordingWindowBackend();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(
            backend: backend,
            tray: CapturingTray(available: true),
          ),
        ),
      ))!;
      await tester.startApp(h);

      expect(backend.actions, isEmpty);
      expect(backend.visible, isTrue);

      await tester.stopApp(h);
    });

    testWidgets('the fake window follows startHidden too', (tester) async {
      final services = PlatformServices.fake();
      final window = services.window as FakeWindow;
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: services,
          overrides: [
            launchArgsProvider.overrideWithValue(const ['--hidden']),
          ],
        ),
      ))!;
      await tester.startApp(h);
      expect(window.visible, isFalse);
      await tester.stopApp(h);
    });

    testWidgets('"Start minimized" off: --hidden still shows the window', (
      tester,
    ) async {
      final backend = RecordingWindowBackend();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(
            backend: backend,
            tray: CapturingTray(available: true),
          ),
          overrides: [
            launchArgsProvider.overrideWithValue(const ['--hidden']),
          ],
        ),
      ))!;
      await tester.runAsync(
        () => FileReceiveSettingsStore(h.supportDir).save(
          const ReceivePersisted(settings: ReceiveSettings(startHidden: false)),
        ),
      );
      await tester.startApp(h);
      await tester.settleUntil(
        () => backend.visible,
        what: 'window shown at start',
      );

      // The runner left the window unmapped for --hidden; the app maps it.
      expect(backend.actions.last, 'show');
      expect(h.engine.receive.settings.startHidden, isFalse);

      await tester.stopApp(h);
    });
  });

  group('Tray menu', () {
    testWidgets('Receive toggles the mode and the tray shows it', (
      tester,
    ) async {
      final tray = CapturingTray(available: true);
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: PlatformServices(
            autostart: FakeAutostart(),
            tray: tray,
            window: FakeWindow(),
            multicastLock: FakeMulticastLock(),
            environment: FakeEnvironment(),
          ),
        ),
      ))!;
      await tester.startApp(h);
      expect(tray.lastReceiving, isFalse);
      expect(tray.lastTooltip, 'LibreShare: not receiving');

      tray.onToggleReceive!();
      await tester.settleUntil(
        () => h.engine.receive.isReceiving,
        what: 'Receive on from the tray',
      );
      await tester.settleUntil(() => tray.lastReceiving, what: 'tray icon on');
      expect(tray.lastTooltip, 'LibreShare: receiving until turned off');

      tray.onToggleReceive!();
      await tester.settleUntil(
        () => !h.engine.receive.isReceiving,
        what: 'Receive off from the tray',
      );
      await tester.settleUntil(() => !tray.lastReceiving, what: 'tray off');

      await tester.stopApp(h);
    });

    testWidgets('Quit stops the engine, releases the lock, then exits', (
      tester,
    ) async {
      final tray = CapturingTray(available: true);
      final lock = FakeMulticastLock();
      final order = <String>[];
      late final LibreShareEngine engine;
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(
            backend: RecordingWindowBackend(),
            tray: tray,
            lock: lock,
          ),
          overrides: [
            quitHandlerProvider.overrideWithValue(() async {
              order.add(
                'exit(engineStarted=${engine.isStarted}, '
                'listening=${engine.isListening}, lock=${lock.held}, '
                'trayDisposed=${tray.disposed})',
              );
            }),
          ],
        ),
      ))!;
      await tester.startApp(h);
      engine = h.engine;
      await receiveOn(tester, h);
      expect(engine.isListening, isTrue);
      expect(lock.held, 1);
      final running = await tester.runAsync(
        () => FileReceiveSettingsStore(h.supportDir).load(),
      );
      expect(running!.runtime.cleanStop, isFalse, reason: 'live, not stopped');

      await tester.runAsync(() async => tray.onQuit!());
      await tester.settleUntil(() => order.isNotEmpty, what: 'app exit');

      expect(order, [
        'exit(engineStarted=false, listening=false, lock=0, trayDisposed=true)',
      ]);

      // It was a clean stop: the stored record says so, and the next start
      // therefore does not mistake it for a crash and switch Receive back on.
      final saved = await tester.runAsync(
        () => FileReceiveSettingsStore(h.supportDir).load(),
      );
      expect(saved!.runtime.cleanStop, isTrue);

      await tester.stopApp(h);
    });

    testWidgets('Quit twice (double click) exits once', (tester) async {
      final tray = CapturingTray(available: true);
      var exits = 0;
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: desktopShellServices(
            backend: RecordingWindowBackend(),
            tray: tray,
          ),
          overrides: [
            quitHandlerProvider.overrideWithValue(() async => exits++),
          ],
        ),
      ))!;
      await tester.startApp(h);
      await tester.runAsync(() async {
        tray.onQuit!();
        tray.onQuit!();
      });
      await tester.settleUntil(() => exits > 0, what: 'app exit');
      await tester.settle(ms: 100);
      expect(exits, 1);

      await tester.stopApp(h);
    });
  });

  group('Multicast lock', () {
    testWidgets('held while the engine runs, released when it stops', (
      tester,
    ) async {
      final services = PlatformServices.fake();
      final lock = services.multicastLock as FakeMulticastLock;
      final h = (await tester.runAsync(
        () => AppHarness.create(services: services),
      ))!;
      expect(lock.held, 0, reason: 'nothing before the engine starts');

      await tester.startApp(h);
      // Listening for other devices needs it even while Receive is Off.
      expect(lock.held, 1);
      expect(h.engine.isListening, isFalse);

      // Turning Receive on and off does not take it twice or drop it.
      await receiveOn(tester, h);
      expect(lock.held, 1);
      await receiveOff(tester, h);
      expect(lock.held, 1);

      await tester.stopApp(h);
      expect(lock.held, 0);
    });

    testWidgets('a rebuilt engine takes the lock again without leaking one', (
      tester,
    ) async {
      final services = PlatformServices.fake();
      final lock = services.multicastLock as FakeMulticastLock;
      final h = (await tester.runAsync(
        () =>
            AppHarness.create(services: services, initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);
      expect(lock.held, 1);
      final first = h.engine;

      // Renaming the device rebuilds the engine.
      await tester.tap(find.byKey(const Key('settings-name')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(
        find.byKey(const Key('settings-name-field')),
        'Renamed',
      );
      await tester.tap(find.byKey(const Key('prompt-save')));
      await tester.settleUntil(
        () =>
            h.container.read(engineOrNullProvider) != null &&
            !identical(h.container.read(engineOrNullProvider), first),
        what: 'engine rebuilt',
        maxRounds: 400,
      );
      expect(lock.held, 1);

      await tester.stopApp(h);
      expect(lock.held, 0);
    });

    testWidgets('a lock that cannot be taken does not stop the app', (
      tester,
    ) async {
      final lock = FailingMulticastLock();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          services: PlatformServices(
            autostart: FakeAutostart(),
            tray: FakeTray(),
            window: FakeWindow(),
            multicastLock: lock,
            environment: FakeEnvironment(),
          ),
        ),
      ))!;
      await tester.startApp(h);

      expect(lock.acquireCalls, 1);
      expect(find.byKey(const Key('send-fab')), findsOneWidget);
      await receiveOn(tester, h);
      expect(h.engine.isListening, isTrue);

      await tester.stopApp(h);
      // What was never taken is not released.
      expect(lock.releaseCalls, 0);
    });
  });
}

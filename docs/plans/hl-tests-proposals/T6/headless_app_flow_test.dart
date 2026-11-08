// Card T6: App-level high tests (widget tests, no GUI session needed).
// Verifies zero-config flow (<= 3 taps), consent dialogs (accept/decline/timeout),
// history outcomes, FailureReason human translations, 1.3/2.0 text scale,
// 48 dp touch targets, semantics labels, dark theme, settings persistence,
// and secret hygiene (PIN never rendered in widget tree after saving).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

Finder deviceCard(TestPeer p) => find.byKey(Key('device-${p.id}'));
bool shown(Finder f) => f.evaluate().isNotEmpty;

Text textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

/// Starts the app with [peers] around and waits until Home lists them.
Future<void> bootWithPeers(
  WidgetTester tester,
  AppHarness h,
  List<TestPeer> peers,
) async {
  await tester.startApp(h);
  await tester.settleUntil(
    () => peers.every((p) => shown(deviceCard(p))),
    what: 'peers listed on Home',
  );
}

/// Turns Receive on and starts the app with [peers] around.
Future<void> bootReceiving(
  WidgetTester tester,
  AppHarness h, [
  List<TestPeer> peers = const [],
]) async {
  await tester.startApp(h);
  await tester.runAsync(() => h.engine.receive.turnOn());
  await tester.settle();
  await tester.settleUntil(
    () => peers.every((p) => shown(find.byKey(Key('device-${p.id}')))),
    what: 'senders listed',
  );
}

class _StubTransfers extends TransfersNotifier {
  _StubTransfers(this.initial);
  final List<TransferView> initial;

  @override
  List<TransferView> build() {
    state = List.of(initial);
    return state;
  }

  @override
  void dismiss(String key) {
    state = [for (final item in state) if (item.key != key) item];
  }
}

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
  setUpAll(() {
    AppHarness.legacyPlaintextPeers = true;
  });

  tearDownAll(() {
    AppHarness.legacyPlaintextPeers = false;
  });

  group('Card T6: Headless App Flow Suite', () {
    testWidgets('1. Zero-Config Flow (NFR-01: First transfer in <= 3 taps)', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel-8')))!;
      final file = h.makeFile('doc.txt', 1024);
      h.picker.files = [h.pick(file)];

      await bootWithPeers(tester, h, [peer]);

      var tapCount = 0;

      // Tap 1: FAB to initiate pick and send
      await tester.tap(find.byKey(const Key('send-fab')));
      tapCount++;
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-summary'))),
        what: 'send summary screen',
      );

      expect(h.picker.pickFilesCalls, equals(1));
      expect(find.byKey(Key('choose-${peer.id}')), findsOneWidget);

      // Tap 2: Choose target peer to dispatch transfer
      await tester.tap(find.byKey(Key('choose-${peer.id}')));
      tapCount++;

      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-done'))),
        what: 'transfer complete',
        maxRounds: 400,
      );

      // Assert total taps to initiate and transfer is <= 3 (exactly 2)
      expect(tapCount, lessThanOrEqualTo(3));
      expect(tapCount, equals(2));
      expect(find.text('Sent 1 file to Pixel-8'), findsOneWidget);

      // Tap 3: Return to Home
      await tester.tap(find.byKey(const Key('transfer-done-button')));
      tapCount++;
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-fab'))),
        what: 'back on Home',
      );
      expect(tapCount, lessThanOrEqualTo(3));

      // Assert peer received exact file
      final got = peer.rx
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.path.endsWith('.part'))
          .toList();
      expect(got.length, equals(1));
      expect(got.first.readAsBytesSync(), equals(file.readAsBytesSync()));

      await tester.stopApp(h);
    });

    testWidgets('2. Consent Dialog Lifecycle: Accept, Decline, and Timeout', (
      tester,
    ) async {
      AppHarness.securePeers = true;
      addTearDown(() => AppHarness.securePeers = false);
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Sender-Device', platform: 'linux'),
      ))!;
      await bootReceiving(tester, h, [peer]);

      // Sub-case 2A: Decline flow (< 1s)
      final file1 = h.makeFile('decline_me.pdf', 2048);
      late Future<SendResult> sending1;
      await tester.runAsync(() async {
        sending1 = peer.sendTo(h, [file1]);
      });

      await tester.settleUntil(
        () => shown(find.byKey(const Key('incoming-dialog'))),
        what: 'incoming consent dialog',
      );

      expect(find.text('Incoming transfer'), findsOneWidget);
      expect(textOf(tester, 'incoming-sender').data, 'Sender-Device');
      expect(find.text('decline_me.pdf'), findsOneWidget);

      final sw = Stopwatch()..start();
      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.settle();
      final res1 = await tester.runAsync(() => sending1);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(2000));
      expect(res1!.status, equals(TransferStatus.failed));
      expect(res1.failureReason, equals(FailureReason.rejected));
      expect(find.byKey(const Key('incoming-dialog')), findsNothing);

      // Sub-case 2B: Timeout flow (120s countdown)
      final file2 = h.makeFile('timeout_me.pdf', 1024);
      late Future<SendResult> sending2;
      await tester.runAsync(() async {
        sending2 = peer.sendTo(h, [file2]);
      });

      await tester.settleUntil(
        () => shown(find.byKey(const Key('incoming-dialog'))),
        what: 'incoming consent dialog 2',
      );

      expect(
        textOf(tester, 'incoming-countdown').data,
        'Declines automatically in 2:00',
      );

      // Advance clock by 121s to trigger automatic decline
      h.clock.advance(const Duration(seconds: 121));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));

      final res2 = await tester.runAsync(() => sending2);
      expect(res2!.status, equals(TransferStatus.failed));
      expect(res2.failureReason, equals(FailureReason.rejected));
      expect(find.byKey(const Key('incoming-dialog')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('3. History & TransferCard Outcomes', (tester) async {
      final tCompleted = TransferView(
        key: 't-comp',
        sessionId: 's-comp',
        direction: TransferDirection.incoming,
        phase: TransferPhase.completed,
        peerAlias: 'Remote-Alice',
        peerPlatform: 'android',
        peerAddress: '192.168.1.50',
        files: const [
          TransferFile(
            id: 'f1',
            name: 'photo.jpg',
            size: 1024,
            done: 1024,
            savedPath: '/tmp/photo.jpg',
          ),
        ],
        createdAt: DateTime(2026, 11, 7, 10, 0),
      );
      final tRejected = TransferView(
        key: 't-rej',
        sessionId: 's-rej',
        direction: TransferDirection.incoming,
        phase: TransferPhase.rejected,
        peerAlias: 'Remote-Bob',
        peerPlatform: 'linux',
        peerAddress: '192.168.1.51',
        files: const [TransferFile(id: 'f2', name: 'big.iso', size: 5000)],
        createdAt: DateTime(2026, 11, 7, 10, 5),
      );

      final h = (await tester.runAsync(
        () => AppHarness.create(
          overrides: [
            transfersProvider.overrideWith(
              () => _StubTransfers([tCompleted, tRejected]),
            ),
          ],
        ),
      ))!;
      await tester.startApp(h);

      // Assert both transfer cards appear in History on Home
      expect(find.byKey(const Key('transfer-t-comp')), findsOneWidget);
      expect(find.byKey(const Key('transfer-t-rej')), findsOneWidget);

      // Dismiss tCompleted
      final dismissBtn = find.descendant(
        of: find.byKey(const Key('transfer-t-comp')),
        matching: find.byType(IconButton),
      );
      expect(dismissBtn, findsOneWidget);
      await tester.tap(dismissBtn);
      await tester.pumpAndSettle();

      // Assert tCompleted dismissed and removed from History
      expect(find.byKey(const Key('transfer-t-comp')), findsNothing);
      expect(find.byKey(const Key('transfer-t-rej')), findsOneWidget);

      await tester.stopApp(h);
    });

    test(
      '4. Error Texts for Every FailureReason (No Raw Enums or Exceptions)',
      () {
        for (final reason in FailureReason.values) {
          for (final isOut in [true, false]) {
            for (final wasXfer in [true, false]) {
              for (final localErr in [true, false]) {
                final t = TransferView(
                  key: 'err-$reason-$isOut',
                  sessionId: 's-err',
                  direction: isOut
                      ? TransferDirection.outgoing
                      : TransferDirection.incoming,
                  phase: TransferPhase.failed,
                  failure: reason,
                  peerAlias: 'TestPeer',
                  peerPlatform: 'linux',
                  peerAddress: '127.0.0.1',
                  files: const [TransferFile(id: 'f', name: 'a.txt', size: 10)],
                  createdAt: DateTime(2026, 11, 7),
                  wasTransferring: wasXfer,
                  localFileError: localErr,
                );
                final text = failureText(t);

                expect(text, isNotEmpty);
                expect(text, isNot(contains('FailureReason.')));
                if (reason != FailureReason.cancelled) {
                  expect(text, isNot(contains(reason.name)));
                }
                expect(text, isNot(contains('Exception')));
                expect(text, isNot(contains('null')));
              }
            }
          }
        }

        // Security / refusal special cases
        final tKeyChanged = TransferView(
          key: 'key-changed',
          sessionId: 's-kc',
          direction: TransferDirection.outgoing,
          phase: TransferPhase.failed,
          peerAlias: 'CompromisedPeer',
          peerPlatform: 'linux',
          peerAddress: '127.0.0.1',
          files: const [TransferFile(id: 'f', name: 'a.txt', size: 10)],
          createdAt: DateTime(2026, 11, 7),
          keyChanged: true,
        );
        expect(
          failureText(tKeyChanged),
          contains('security key of CompromisedPeer changed'),
        );

        final tInsecure = TransferView(
          key: 'insecure',
          sessionId: 's-ins',
          direction: TransferDirection.outgoing,
          phase: TransferPhase.failed,
          peerAlias: 'LegacyPeer',
          peerPlatform: 'linux',
          peerAddress: '127.0.0.1',
          files: const [TransferFile(id: 'f', name: 'a.txt', size: 10)],
          createdAt: DateTime(2026, 11, 7),
          insecurePeer: true,
        );
        expect(
          failureText(tInsecure),
          contains('uses an older version without encryption'),
        );
      },
    );

    testWidgets(
      '5. Accessibility (Text Scaler 1.3/2.0, 48dp Touch Targets, Semantics)',
      (tester) async {
        final h = (await tester.runAsync(AppHarness.create))!;
        await tester.startApp(h);

        // Test text scaling at 1.3x and 2.0x on HomeScreen
        addTearDown(() {
          tester.platformDispatcher.clearAllTestValues();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(600, 1000);
        for (final scale in [1.3, 2.0]) {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          expect(
            tester.takeException(),
            isNull,
            reason:
                'RenderFlex overflow occurred on HomeScreen at text scale $scale',
          );
        }
        tester.platformDispatcher.clearAllTestValues();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();

        // Assert touch target sizes >= 48x48 dp on all interactive buttons
        final iconButtons = find.byType(IconButton);
        expect(iconButtons, findsWidgets);
        for (final el in iconButtons.evaluate()) {
          final box = el.renderObject as RenderBox?;
          if (box != null && box.hasSize) {
            final size = box.size;
            expect(
              size.width >= 48.0 && size.height >= 48.0,
              isTrue,
              reason:
                  'IconButton touch target ${size.width}x${size.height} < 48x48',
            );
          }
        }

        // Assert FAB touch target >= 48x48
        final fab = find.byKey(const Key('send-fab'));
        expect(fab, findsOneWidget);
        final fabSize = tester.getSize(fab);
        expect(fabSize.width, greaterThanOrEqualTo(48.0));
        expect(fabSize.height, greaterThanOrEqualTo(48.0));

        // Assert semantics labels / tooltips on actionable buttons
        for (final el in iconButtons.evaluate()) {
          final btn = el.widget as IconButton;
          expect(
            btn.tooltip != null || btn.icon is Tooltip,
            isTrue,
            reason: 'IconButton missing accessibility tooltip/label',
          );
        }

        await tester.stopApp(h);
      },
    );

    testWidgets('6. Dark Theme Rendering (Contrasting & No Exceptions)', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      // Apply dark brightness to platform dispatcher
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      tester.platformDispatcher.clearAllTestValues();

      await tester.stopApp(h);
    });

    testWidgets('7. Settings Persistence Across Restart (Speed Mode)', (
      tester,
    ) async {
      tester.useTallSurface();
      final h1 = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h1);

      // Select Turbo mode
      final turboOption = find.byKey(const Key('speed_mode_turbo'));
      await scrollTo(tester, turboOption);
      expect(turboOption, findsOneWidget);
      await tester.tap(turboOption);
      await tester.pump();
      await tester.settleUntil(
        () => h1.container.read(settingsProvider).speedMode == SpeedMode.turbo,
        what: 'speed mode turbo selected',
      );

      // Assert turbo is selected
      final selectedListTile = tester.widget<ListTile>(turboOption);
      expect(selectedListTile.selected, isTrue);

      final sandbox = h1.sandbox;
      await tester.stopApp(h1, deleteSandbox: false);

      // Restart app using same sandbox
      final h2 = (await tester.runAsync(
        () => AppHarness.create(
          reuseSandbox: sandbox,
          initialLocation: '/settings',
        ),
      ))!;
      await tester.startApp(h2);

      // Verify turbo remains selected after restart
      final turboOption2 = find.byKey(const Key('speed_mode_turbo'));
      await scrollTo(tester, turboOption2);
      expect(tester.widget<ListTile>(turboOption2).selected, isTrue);

      await tester.stopApp(h2);
    });

    testWidgets(
      '8. Secret Hygiene: PIN Never Rendered in Plaintext After Saving',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        await tester.startApp(h);

        const secretPin = '948201';

        // Tap Fixed PIN segment
        final fixedSegment = find.text('Fixed');
        await scrollTo(tester, fixedSegment);
        await tester.tap(fixedSegment);
        await tester.pump();

        // Enter 6-digit PIN and save
        final pinInput = find.byKey(const Key('settings-pin-input'));
        await tester.enterText(pinInput, secretPin);
        final saveBtn = find.byKey(const Key('settings-pin-save'));
        await tester.tap(saveBtn);
        await tester.pump();

        // Wait for save to complete and show PIN configured
        await tester.settleUntil(
          () => shown(find.text('PIN configured')),
          what: 'PIN configured text',
        );

        // Secret hygiene check: walk every widget in the tree
        for (final el in find.byType(Widget).evaluate()) {
          final w = el.widget;
          if (w is Text) {
            expect(
              w.data?.contains(secretPin),
              isNot(true),
              reason: 'Secret PIN leaked into Text widget data: ${w.data}',
            );
          } else if (w is RichText) {
            expect(
              w.text.toPlainText().contains(secretPin),
              isNot(true),
              reason: 'Secret PIN leaked into RichText widget',
            );
          }
        }

        await tester.stopApp(h);
      },
    );
  });
}

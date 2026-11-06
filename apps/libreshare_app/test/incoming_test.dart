// Receiving (design 01 section 5 and spec section 9, screen 3): the consent
// dialog over whatever screen is open, the 120 s countdown that declines on its
// own, and the result. Real engines on both sides.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

bool shown(Finder f) => f.evaluate().isNotEmpty;

Finder get dialog => find.byKey(const Key('incoming-dialog'));

Text textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

/// Turns Receive on and starts the app. [peers] are listed on Home first so
/// the dialog can show where each sender is.
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

List<File> savedFiles(Directory dir) => dir.existsSync()
    ? dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.path.endsWith('.part'))
          .toList()
    : [];

void main() {
  // The app's engine is secure: the senders in these tests must be too.
  setUpAll(() => AppHarness.securePeers = true);
  tearDownAll(() => AppHarness.securePeers = false);

  group('Incoming transfer', () {
    testWidgets('the dialog shows who sends what; Accept saves the file', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Work-Laptop', platform: 'linux'),
      ))!;
      await bootReceiving(tester, h, [peer]);
      final file = h.makeFile('report.pdf', 5000);

      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = peer.sendTo(h, [file]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');

      expect(find.text('Incoming transfer'), findsOneWidget);
      expect(textOf(tester, 'incoming-sender').data, 'Work-Laptop');
      expect(
        textOf(tester, 'incoming-sender-detail').data,
        // The address the announcement was heard from.
        'Linux  ·  ${h.engine.currentDevices.single.address}',
      );
      expect(
        textOf(tester, 'incoming-summary').data,
        'wants to send you 1 file (5.00 KB)',
      );
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.byKey(const Key('sas-placeholder')), findsOneWidget);
      expect(
        textOf(tester, 'incoming-countdown').data,
        'Declines automatically in 2:00',
      );
      // Nothing is written before the user agrees.
      expect(savedFiles(h.defaultDownloads), isEmpty);

      // A person needs far longer than this to decide. Wait for the sender's
      // long-poll to reach the receiver first: an Accept that lands before it
      // makes the core's long-poll wait out its 25 s on an already accepted
      // session (see the report: FileReceiver.getSession).
      await tester.settle(ms: 300);
      await tester.tap(find.byKey(const Key('incoming-accept')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-done'))),
        what: 'received',
        maxRounds: 400,
      );
      expect(dialog, findsNothing);
      expect(find.text('Received 1 file from Work-Laptop'), findsOneWidget);

      final saved = savedFiles(h.defaultDownloads);
      expect(saved, hasLength(1));
      expect(saved.single.uri.pathSegments.last, 'report.pdf');
      expect(saved.single.readAsBytesSync(), file.readAsBytesSync());

      // Open / Show in folder go through the launcher with the saved path.
      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('transfer-show-folder')));
      await tester.pump();
      expect(h.launcher.opened, [saved.single.path]);
      expect(h.launcher.shown, [saved.single.path]);

      final result = await tester.runAsync(() => sending);
      expect(result!.isSuccess, isTrue);
      await tester.stopApp(h);
    });

    testWidgets('Reject: nothing is saved and the sender is told', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Work-Laptop')))!;
      await bootReceiving(tester, h, [peer]);

      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = peer.sendTo(h, [h.makeFile('x.bin', 100)]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');
      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.settleUntil(() => !shown(dialog), what: 'dialog closed');

      final result = (await tester.runAsync(() => sending))!;
      expect(result.isSuccess, isFalse);
      expect(result.failureReason, FailureReason.rejected);
      expect(savedFiles(h.defaultDownloads), isEmpty);
      expect(find.byKey(const Key('transfer-done')), findsNothing);

      // Home keeps a note, worded from the receiver's side.
      await tester.settleUntil(
        () => shown(find.text('You declined the files from Work-Laptop')),
        what: 'note on Home',
      );
      final t = h.container.read(transfersProvider).single;
      expect(t.phase, TransferPhase.rejected);
      expect(t.direction, TransferDirection.incoming);

      await tester.stopApp(h);
    });

    testWidgets('the countdown follows the clock and declines at zero', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Work-Laptop')))!;
      await bootReceiving(tester, h, [peer]);

      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = peer.sendTo(h, [h.makeFile('x.bin', 100)]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');
      expect(
        textOf(tester, 'incoming-countdown').data,
        'Declines automatically in 2:00',
      );

      h.clock.advance(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
      expect(
        textOf(tester, 'incoming-countdown').data,
        'Declines automatically in 0:59',
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: dialog,
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(bar.value, closeTo(59 / 120, 0.001));

      h.clock.advance(const Duration(seconds: 58));
      await tester.pump(const Duration(seconds: 1));
      expect(
        textOf(tester, 'incoming-countdown').data,
        'Declines automatically in 0:01',
      );
      expect(dialog, findsOneWidget);

      h.clock.advance(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(dialog, findsNothing);

      // The request was declined on the user's behalf.
      final result = (await tester.runAsync(() => sending))!;
      expect(result.failureReason, FailureReason.rejected);
      expect(savedFiles(h.defaultDownloads), isEmpty);

      await tester.stopApp(h);
    });

    testWidgets('the countdown starts from the engine consent timeout', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(permissionTimeout: const Duration(seconds: 30)),
      ))!;
      final peer = (await tester.runAsync(() => h.startPeer('Work-Laptop')))!;
      await bootReceiving(tester, h, [peer]);

      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = peer.sendTo(h, [h.makeFile('x.bin', 100)]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');
      expect(
        textOf(tester, 'incoming-countdown').data,
        'Declines automatically in 0:30',
      );

      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.runAsync(() => sending);
      await tester.stopApp(h);
    });

    testWidgets('the sender gives up while the dialog is open', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Work-Laptop')))!;
      await bootReceiving(tester, h, [peer]);

      final client = ApiClient(
        host: '127.0.0.2',
        port: h.engine.port,
        security: peer.wiring!.config,
        expectedFingerprint: h.engine.ownFingerprint,
      );
      final senderEvents = <LsEvent>[];
      final sender = FileSender(
        client: client,
        self: peer.engine.deviceInfo,
        onEvent: senderEvents.add,
        security: peer.wiring!.config,
        pinnedReceiverFingerprint: h.engine.ownFingerprint,
      );
      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = sender.send([h.makeFile('x.bin', 100)]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');
      // The dialog can appear before the sender has read the reply to its
      // request; FileSender.cancel() can only tell the receiver about a session
      // it already knows (see the report: cancel before the reply is lost).
      await tester.settleUntil(
        () => senderEvents.whereType<SessionCreated>().isNotEmpty,
        what: 'sender knows its session',
      );

      await tester.runAsync(sender.cancel);
      await tester.settleUntil(() => !shown(dialog), what: 'dialog closed');
      final result = (await tester.runAsync(() => sending))!;
      expect(result.failureReason, FailureReason.cancelled);
      await tester.settleUntil(
        () => shown(find.text('Transfer cancelled')),
        what: 'cancelled note on Home',
      );
      expect(savedFiles(h.defaultDownloads), isEmpty);

      client.close();
      await tester.stopApp(h);
    });

    testWidgets('long lists show five names and the rest as a count', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Work-Laptop')))!;
      await bootReceiving(tester, h, [peer]);

      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = peer.sendTo(h, [
          for (var i = 1; i <= 7; i++) h.makeFile('f$i.txt', i * 10),
        ]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');
      expect(
        textOf(tester, 'incoming-summary').data,
        'wants to send you 7 files (280 B)',
      );
      for (var i = 1; i <= 5; i++) {
        expect(find.text('f$i.txt'), findsOneWidget, reason: 'f$i.txt');
      }
      expect(find.text('f6.txt'), findsNothing);
      expect(find.text('and 2 more'), findsOneWidget);

      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.runAsync(() => sending);
      await tester.stopApp(h);
    });

    testWidgets('requests are asked one at a time, in order', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final a = (await tester.runAsync(() => h.startPeer('Peer-A')))!;
      final b = (await tester.runAsync(() => h.startPeer('Peer-B')))!;
      await bootReceiving(tester, h, [a, b]);

      late Future<SendResult> sendA, sendB;
      await tester.runAsync(() async {
        sendA = a.sendTo(h, [h.makeFile('a.bin', 10)]);
        sendB = b.sendTo(h, [h.makeFile('b.bin', 10)]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'first dialog');
      final first = textOf(tester, 'incoming-sender').data!;
      expect(find.byKey(const Key('incoming-sender')), findsOneWidget);

      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.settleUntil(
        () => shown(dialog) && textOf(tester, 'incoming-sender').data != first,
        what: 'second dialog',
      );
      final second = textOf(tester, 'incoming-sender').data!;
      expect({first, second}, {'Peer-A', 'Peer-B'});

      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.settleUntil(() => !shown(dialog), what: 'no more dialogs');
      expect((await tester.runAsync(() => sendA))!.failureReason, isNotNull);
      expect((await tester.runAsync(() => sendB))!.failureReason, isNotNull);

      await tester.stopApp(h);
    });

    testWidgets('a request appears over Settings and brings the window up', (
      tester,
    ) async {
      final window = FakeWindow()..visible = false;
      final services = PlatformServices(
        autostart: FakeAutostart(),
        tray: FakeTray(),
        window: window,
        multicastLock: FakeMulticastLock(),
        environment: FakeEnvironment(),
      );
      final h = (await tester.runAsync(
        () =>
            AppHarness.create(services: services, initialLocation: '/settings'),
      ))!;
      final peer = (await tester.runAsync(() => h.startPeer('Work-Laptop')))!;
      await tester.startApp(h);
      await tester.runAsync(() => h.engine.receive.turnOn());
      await tester.settle();
      window.visible = false; // the window sits in the tray

      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = peer.sendTo(h, [h.makeFile('x.bin', 100)]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');
      expect(window.visible, isTrue);
      expect(find.text('Settings'), findsWidgets);

      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.runAsync(() => sending);
      await tester.stopApp(h);
    });

    testWidgets('the consent dialog meets the tap-target guidelines', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Work-Laptop')))!;
      await bootReceiving(tester, h, [peer]);

      late Future<SendResult> sending;
      await tester.runAsync(() async {
        sending = peer.sendTo(h, [h.makeFile('x.bin', 100)]);
      });
      await tester.settleUntil(() => shown(dialog), what: 'consent dialog');
      // The dialog's route transition is still running, and the semantics of
      // a route are only complete once it has finished; a guideline check
      // before that would pass on an empty tree.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.bySemanticsLabel('Accept'), findsOneWidget);
      expect(find.bySemanticsLabel('Reject'), findsOneWidget);

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expect(
        find.bySemanticsLabel('Declines automatically in 2:00'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('incoming-reject')));
      await tester.runAsync(() => sending);
      semantics.dispose();
      await tester.stopApp(h);
    });
  });
}

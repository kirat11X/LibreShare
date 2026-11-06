// The Send flow (spec section 9, screens 1, 2, 4, 5) against REAL engines:
// pick files, choose a device, wait for it to accept, see the result.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/send_flow_provider.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

Finder deviceCard(TestPeer p) => find.byKey(Key('device-${p.id}'));

bool shown(Finder f) => f.evaluate().isNotEmpty;

Text textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

/// Starts the app with [peer]s around and waits until Home lists them.
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

void main() {
  // Plaintext fixture peers against the app's secure engine (see the harness).
  setUpAll(() => AppHarness.legacyPlaintextPeers = true);
  tearDownAll(() => AppHarness.legacyPlaintextPeers = false);

  group('Send flow', () {
    testWidgets('pick files, choose a device: the files arrive intact', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
      final small = h.makeFile('a.txt', 1000);
      final big = h.makeFile('b.bin', 300000);
      h.picker.files = [h.pick(big), h.pick(small)];
      await bootWithPeers(tester, h, [peer]);

      // Home -> picker -> the Send screen with the choice.
      await tester.tap(find.byKey(const Key('send-fab')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-summary'))),
        what: 'send screen',
      );
      expect(h.picker.pickFilesCalls, 1);
      expect(
        textOf(tester, 'send-summary').data,
        '2 files selected (301.0 KB)',
      );
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.text('b.bin'), findsOneWidget);
      expect(find.byKey(Key('choose-${peer.id}')), findsOneWidget);

      await tester.tap(find.byKey(Key('choose-${peer.id}')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-done'))),
        what: 'transfer finished',
        maxRounds: 400,
      );
      expect(find.text('Sent 2 files to Pixel 8'), findsOneWidget);
      // The sender has nothing to open: the files went elsewhere.
      expect(find.byKey(const Key('transfer-open')), findsNothing);
      expect(find.byKey(const Key('transfer-show-folder')), findsNothing);

      // The other device really got the bytes.
      final got = peer.rx
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.path.endsWith('.part'))
          .toList();
      expect(got.map((f) => f.uri.pathSegments.last).toSet(), {
        'a.txt',
        'b.bin',
      });
      for (final f in got) {
        final name = f.uri.pathSegments.last;
        expect(
          f.readAsBytesSync(),
          (name == 'a.txt' ? small : big).readAsBytesSync(),
          reason: name,
        );
      }

      // Done goes back to Home, where the transfer stays listed until dismissed.
      await tester.tap(find.byKey(const Key('transfer-done-button')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-fab'))),
        what: 'back on Home',
      );
      expect(find.text('Sent 2 files to Pixel 8'), findsOneWidget);
      expect(h.container.read(pickedFilesProvider), isEmpty);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(find.text('Sent 2 files to Pixel 8'), findsNothing);
      expect(h.container.read(transfersProvider), isEmpty);

      await tester.stopApp(h);
    });

    testWidgets('a device card on Home picks files and sends straight away', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
      h.picker.files = [h.pick(h.makeFile('note.txt', 42))];
      await bootWithPeers(tester, h, [peer]);

      await tester.tap(deviceCard(peer));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-done'))),
        what: 'transfer finished',
        maxRounds: 400,
      );
      expect(h.picker.pickFilesCalls, 1);
      expect(find.text('Sent 1 file to Pixel 8'), findsOneWidget);
      expect(peer.rx.listSync(recursive: true).whereType<File>().length, 1);

      await tester.stopApp(h);
    });

    testWidgets('cancelling the picker leaves Home as it was', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
      await bootWithPeers(tester, h, [peer]);

      await tester.tap(find.byKey(const Key('send-fab')));
      await tester.settle();
      await tester.tap(deviceCard(peer));
      await tester.settle();

      expect(h.picker.pickFilesCalls, 2);
      expect(find.byKey(const Key('send-summary')), findsNothing);
      expect(find.byKey(const Key('transfer-done')), findsNothing);
      expect(h.container.read(transfersProvider), isEmpty);

      await tester.stopApp(h);
    });

    testWidgets('files can be removed; with none left nothing can be sent', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
      h.picker.files = [
        h.pick(h.makeFile('one.txt', 10)),
        h.pick(h.makeFile('two.txt', 20)),
      ];
      await bootWithPeers(tester, h, [peer]);
      await tester.tap(find.byKey(const Key('send-fab')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-summary'))),
        what: 'send screen',
      );

      await tester.tap(find.byTooltip('Remove one.txt'));
      await tester.pump();
      expect(textOf(tester, 'send-summary').data, '1 file selected (20 B)');
      expect(find.text('one.txt'), findsNothing);

      await tester.tap(find.byTooltip('Remove two.txt'));
      await tester.pump();
      expect(textOf(tester, 'send-summary').data, '0 files selected (0 B)');
      expect(find.byKey(const Key('send-no-files')), findsOneWidget);
      expect(find.byKey(Key('choose-${peer.id}')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('adding more files extends the selection without duplicates', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final first = h.pick(h.makeFile('one.txt', 10));
      final second = h.pick(h.makeFile('two.txt', 20));
      h.picker.files = [first];
      await tester.startApp(h);
      await tester.tap(find.byKey(const Key('send-fab')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-summary'))),
        what: 'send screen',
      );

      h.picker.files = [first, second];
      await tester.tap(find.byKey(const Key('send-add-more')));
      await tester.settle();
      expect(textOf(tester, 'send-summary').data, '2 files selected (30 B)');

      await tester.stopApp(h);
    });

    testWidgets('with nobody around the Send screen offers Add device', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      h.picker.files = [h.pick(h.makeFile('one.txt', 10))];
      await tester.startApp(h);
      await tester.tap(find.byKey(const Key('send-fab')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-no-devices'))),
        what: 'no devices hint',
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Add device'));
      await tester.settle();
      expect(find.byKey(const Key('add-address')), findsOneWidget);

      await tester.stopApp(h);
    });

    testWidgets('the Send screen back button forgets the selection', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      h.picker.files = [h.pick(h.makeFile('one.txt', 10))];
      await tester.startApp(h);
      await tester.tap(find.byKey(const Key('send-fab')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-summary'))),
        what: 'send screen',
      );
      expect(h.container.read(pickedFilesProvider), hasLength(1));

      await tester.tap(find.byType(BackButton));
      await tester.settle();
      expect(find.byKey(const Key('send-fab')), findsOneWidget);
      expect(h.container.read(pickedFilesProvider), isEmpty);

      await tester.stopApp(h);
    });
  });

  group('Send flow: when it does not go through', () {
    testWidgets('Cancel while the other device has not answered', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      // This device asks for consent and nobody answers.
      final peer = (await tester.runAsync(
        () => h.startPeer('Pixel 8', autoAccept: false),
      ))!;
      h.picker.files = [h.pick(h.makeFile('a.txt', 500))];
      await bootWithPeers(tester, h, [peer]);

      await tester.tap(deviceCard(peer));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-waiting'))),
        what: 'waiting for the other device',
        maxRounds: 400,
      );
      expect(find.text('Waiting for Pixel 8 to accept…'), findsOneWidget);
      expect(find.text('Sending to Pixel 8'), findsOneWidget);
      // The verification code arrives with Increment 3; its place is marked.
      expect(find.byKey(const Key('sas-placeholder')), findsOneWidget);
      expect(h.container.read(transfersProvider).single.isActive, isTrue);

      await tester.tap(find.byKey(const Key('transfer-cancel')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-failed'))),
        what: 'cancelled',
        maxRounds: 400,
      );
      expect(
        textOf(tester, 'failure-text').data,
        'The transfer was cancelled.',
      );
      expect(
        h.container.read(transfersProvider).single.phase,
        TransferPhase.cancelled,
      );
      // Nothing was saved on the other device.
      expect(
        peer.rx.existsSync()
            ? peer.rx.listSync(recursive: true).whereType<File>()
            : <File>[],
        isEmpty,
      );

      await tester.stopApp(h);
    });

    testWidgets('the other device declines', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Pixel 8', autoAccept: false),
      ))!;
      h.picker.files = [h.pick(h.makeFile('a.txt', 500))];
      await bootWithPeers(tester, h, [peer]);

      await tester.tap(deviceCard(peer));
      await tester.settleUntil(
        () => peer.incomingSessionId != null,
        what: 'the request reached the other device',
        maxRounds: 400,
      );
      await tester.runAsync(
        () => peer.engine.receiver.reject(peer.incomingSessionId!),
      );
      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-failed'))),
        what: 'declined',
        maxRounds: 400,
      );
      expect(
        textOf(tester, 'failure-text').data,
        'Pixel 8 declined the files.',
      );
      expect(
        h.container.read(transfersProvider).single.phase,
        TransferPhase.rejected,
      );

      // Back returns to Home, where the card says who declined.
      await tester.tap(find.byKey(const Key('transfer-back')));
      await tester.settle();
      expect(find.text('Pixel 8 declined the transfer'), findsOneWidget);

      await tester.stopApp(h);
    });

    testWidgets('a device that cannot be reached', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);
      // Listed, but nothing listens at that port.
      final ghost = DiscoveredDevice(
        info: DeviceInfo(
          deviceId: 'ghost-device',
          alias: 'Ghost',
          platform: 'linux',
          deviceType: 'desktop',
          port: 1,
        ),
        address: '127.0.0.9',
        lastSeen: h.clock.now(),
        source: DiscoverySource.manual,
      );
      final key = h.container.read(transfersProvider.notifier).startSend(
        ghost,
        [h.pick(h.makeFile('a.txt', 5))],
      );
      expect(key, startsWith('out-'));
      await tester.settleUntil(
        () =>
            h.container.read(transfersProvider).single.phase ==
            TransferPhase.failed,
        what: 'no connection',
        maxRounds: 400,
      );
      expect(
        h.container.read(transfersProvider).single.failure,
        FailureReason.noConnection,
      );

      await tester.stopApp(h);
    });

    testWidgets('a picked file that disappears before sending', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
      final file = h.makeFile('gone.txt', 100);
      h.picker.files = [h.pick(file)];
      await bootWithPeers(tester, h, [peer]);
      file.deleteSync();

      await tester.tap(deviceCard(peer));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('transfer-failed'))),
        what: 'local file error',
        maxRounds: 400,
      );
      expect(
        textOf(tester, 'failure-text').data,
        'A selected file could not be read. It may have been moved or deleted.',
      );

      await tester.stopApp(h);
    });
  });
}

// Home / Nearby (spec section 9, screen 1; FR-03): who is around, with name,
// platform and address, live; and the actions on the page. Other devices are
// real engines on the in-memory multicast bus.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/discovery_providers.dart';
import 'package:libreshare_app/screens/app_shell.dart';

import 'helpers/harness.dart';

bool shown(Finder f) => f.evaluate().isNotEmpty;

Finder deviceCard(TestPeer p) => find.byKey(Key('device-${p.id}'));

/// Text widgets under [of] (a card), in tree order.
List<String> textsIn(Finder of) => [
  for (final e
      in find.descendant(of: of, matching: find.byType(Text)).evaluate())
    (e.widget as Text).data!,
];

void main() {
  group('Nearby list', () {
    testWidgets('Home shows the empty state when nobody is around', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('no-devices')), findsOneWidget);
      expect(find.byKey(const Key('isolation-hint')), findsOneWidget);
      expect(find.byKey(const Key('send-fab')), findsOneWidget);

      await tester.stopApp(h);
    });

    testWidgets('a device already around is listed with name, system and IP', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Pixel 8', platform: 'android'),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(deviceCard(peer)),
        what: 'peer listed',
      );

      final device = h.engine.currentDevices.single;
      final texts = textsIn(deviceCard(peer));
      expect(texts[0], 'Pixel 8');
      expect(texts[1], 'Android  ·  ${device.address}:${peer.engine.port}');
      expect(texts[2], startsWith('just now  ·  '));
      expect(find.byKey(const Key('no-devices')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('a device that turns up later appears without a refresh', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);
      expect(find.byKey(const Key('no-devices')), findsOneWidget);

      final peer = (await tester.runAsync(
        () => h.startPeer('Work-PC', platform: 'windows'),
      ))!;
      await tester.settleUntil(
        () => shown(deviceCard(peer)),
        what: 'peer appears',
      );

      expect(find.byKey(const Key('no-devices')), findsNothing);
      expect(textsIn(deviceCard(peer))[1], startsWith('Windows  ·  '));

      await tester.stopApp(h);
    });

    testWidgets('several devices are listed in the order they were seen', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final first = (await tester.runAsync(
        () => h.startPeer('Alpha', platform: 'linux'),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(deviceCard(first)),
        what: 'first peer',
      );
      final second = (await tester.runAsync(() => h.startPeer('Zulu')))!;
      final third = (await tester.runAsync(() => h.startPeer('Beta')))!;
      await tester.settleUntil(
        () => shown(deviceCard(second)) && shown(deviceCard(third)),
        what: 'all peers',
      );

      double top(TestPeer p) => tester.getTopLeft(deviceCard(p)).dy;
      expect(top(first), lessThan(top(second)));
      expect(top(second), lessThan(top(third)), reason: 'not alphabetical');
      // Never this device itself.
      expect(find.byType(Card).evaluate().length, greaterThanOrEqualTo(3));
      expect(
        h.engine.currentDevices.map((d) => d.id),
        isNot(contains(h.engine.deviceInfo.deviceId)),
      );

      await tester.stopApp(h);
    });

    testWidgets('a device card is one labelled button for screen readers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Pixel 8', platform: 'android'),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(deviceCard(peer)),
        what: 'peer listed',
      );

      final node = tester.getSemantics(deviceCard(peer));
      expect(node.label, startsWith('Pixel 8, Android, '));
      expect(node.label, contains('seen just now'));
      expect(node.hint, 'Send files to this device');
      expect(
        node.getSemanticsData().flagsCollection.isButton,
        isTrue,
        reason: 'announced as a button',
      );

      semantics.dispose();
      await tester.stopApp(h);
    });
  });

  group('Home actions', () {
    testWidgets('the app bar scan button runs a scan and reports the count', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(deviceCard(peer)),
        what: 'peer listed',
      );

      await tester.tap(find.byKey(const Key('action-scan')));
      await tester.settleUntil(
        () => h.container.read(scanProvider).lastCount != null,
        what: 'scan finished',
      );

      expect(h.container.read(scanProvider).scanning, isFalse);
      expect(h.container.read(scanProvider).lastCount, 1);
      expect(find.byKey(const Key('scan-progress')), findsNothing);
      expect(shown(deviceCard(peer)), isTrue, reason: 'still listed');

      await tester.stopApp(h);
    });

    testWidgets('the empty state offers Scan, Add by IP or QR and My QR', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);
      // Make room for the three buttons under the explanation.
      tester.view.physicalSize = const Size(900, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pump();

      await tester.tap(find.byKey(const Key('empty-scan')));
      await tester.settleUntil(
        () => h.container.read(scanProvider).lastCount == 0,
        what: 'scan found nobody',
      );

      await tester.tap(find.byKey(const Key('empty-add')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('add-address'))),
        what: 'Add device screen',
      );
      await tester.tap(find.byType(BackButton));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('empty-qr'))),
        what: 'back on Home',
      );

      await tester.tap(find.byKey(const Key('empty-qr')));
      await tester.settleUntil(
        () => shown(find.text('No QR code yet')),
        what: 'My QR screen',
      );

      await tester.stopApp(h);
    });

    testWidgets('the app bar opens Add device and My QR code', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('action-add')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('add-address'))),
        what: 'Add device screen',
      );
      await tester.tap(find.byType(BackButton));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('action-qr'))),
        what: 'back on Home',
      );
      await tester.tap(find.byKey(const Key('action-qr')));
      await tester.settleUntil(
        () => shown(find.text('No QR code yet')),
        what: 'My QR screen',
      );

      await tester.stopApp(h);
    });

    testWidgets('the Receive card is on Home next to the list', (tester) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('receive-card')), findsOneWidget);
      expect(find.text('Nearby devices'), findsOneWidget);

      await tester.stopApp(h);
    });
  });

  group('Navigation frame', () {
    testWidgets('a narrow window has a bottom bar; Settings and back work', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('nav-bar')), findsOneWidget);
      expect(find.byKey(const Key('nav-rail')), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('nav-bar')),
          matching: find.text('Settings'),
        ),
      );
      await tester.settleUntil(
        () => shown(find.byKey(const Key('settings-name'))),
        what: 'Settings',
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('nav-bar')),
          matching: find.text('Nearby'),
        ),
      );
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-fab'))),
        what: 'Home',
      );

      await tester.stopApp(h);
    });

    testWidgets('a wide window has a side rail instead', (tester) async {
      tester.view.physicalSize = Size(kRailBreakpoint + 160, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = (await tester.runAsync(AppHarness.create))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('nav-rail')), findsOneWidget);
      expect(find.byKey(const Key('nav-bar')), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('nav-rail')),
          matching: find.text('Settings'),
        ),
      );
      await tester.settleUntil(
        () => shown(find.byKey(const Key('settings-name'))),
        what: 'Settings',
      );

      await tester.stopApp(h);
    });
  });
}

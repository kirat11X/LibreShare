import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/screens/add_device_screen.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

void main() {
  // Plaintext fixture peers against the app's secure engine (see the harness).
  setUpAll(() => AppHarness.legacyPlaintextPeers = true);
  tearDownAll(() => AppHarness.legacyPlaintextPeers = false);

  group('parseAddress', () {
    test('accepts ip, ip:port, [ipv6]:port and bare ipv6', () {
      expect(parseAddress('192.168.1.5').$1.toString(), '192.168.1.5:53318');
      expect(parseAddress(' 192.168.1.5:53320 ').$1!.port, 53320);
      expect(parseAddress('[::1]:4000').$1!.ip, '::1');
      expect(parseAddress('[::1]:4000').$1!.port, 4000);
      expect(parseAddress('fe80::1').$1!.port, kDefaultPort);
    });

    test('rejects empty input, bad addresses and bad ports', () {
      expect(parseAddress('').$2, 'add.errorEmpty');
      expect(parseAddress('   ').$2, 'add.errorEmpty');
      expect(parseAddress('not-an-ip').$2, 'add.errorIp');
      expect(parseAddress('300.1.1.1').$2, 'add.errorIp');
      expect(parseAddress('192.168.1.5:0').$2, 'add.errorPort');
      expect(parseAddress('192.168.1.5:70000').$2, 'add.errorPort');
      expect(parseAddress('192.168.1.5:abc').$2, 'add.errorPort');
      expect(parseAddress('[::1').$2, 'add.errorIp');
    });

    test('rejects addresses that cannot be a device', () {
      expect(parseAddress('0.0.0.0').$2, 'add.errorIpUnusable');
      expect(parseAddress('224.0.0.168').$2, 'add.errorIpUnusable');
      expect(parseAddress('192.168.001.005').$2, isNotNull);
    });
  });

  group('Add device screen', () {
    testWidgets('invalid input shows a message and asks nobody', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/add'),
      ))!;
      await tester.startApp(h);

      await tester.enterText(find.byKey(const Key('add-address')), 'nope');
      await tester.tap(find.byKey(const Key('add-lookup')));
      await tester.pump();
      expect(
        find.text('That does not look like a valid IP address.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('confirm-peer-dialog')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('add-address')),
        '1.2.3.4:99999',
      );
      await tester.tap(find.byKey(const Key('add-lookup')));
      await tester.pump();
      expect(
        find.text('The port must be a number from 1 to 65535.'),
        findsOneWidget,
      );

      await tester.stopApp(h);
    });

    testWidgets(
      'IP:port lookup, fingerprint dialog, then the device is listed',
      (tester) async {
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/add'),
        ))!;
        final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
        await tester.startApp(h);
        // Make sure discovery has not already listed it: use a scan-free path.
        h.engine; // the app engine is running

        await tester.enterText(
          find.byKey(const Key('add-address')),
          '${peer.ip}:${peer.engine.port}',
        );
        await tester.tap(find.byKey(const Key('add-lookup')));
        await tester.settleUntil(
          () => find
              .byKey(const Key('confirm-peer-dialog'))
              .evaluate()
              .isNotEmpty,
          what: 'confirmation dialog',
        );

        expect(find.text('Pixel 8'), findsOneWidget);
        expect(
          find.text('Android  ·  ${peer.ip}:${peer.engine.port}'),
          findsOneWidget,
        );
        // No TLS before Increment 3: the fingerprint line says so.
        expect(
          find.byKey(const Key('confirm-fingerprint-later')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('confirm-add')));
        await tester.settle();
        await tester.settle();

        final found = h.engine.currentDevices.where((d) => d.id == peer.id);
        expect(found, hasLength(1));
        expect(
          found.single.source,
          anyOf(
            DiscoverySource.manual,
            DiscoverySource.multicast,
            DiscoverySource.register,
          ),
        );
        // Back on Home with a confirmation and the card.
        expect(find.byKey(Key('device-${peer.id}')), findsOneWidget);

        await tester.stopApp(h);
      },
    );

    testWidgets('Cancel in the dialog adds nothing', (tester) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/add'),
      ))!;
      // A peer on a different bus, so discovery cannot find it by itself.
      final peer = (await tester.runAsync(
        () => h.startPeer('Quiet-PC', discover: false),
      ))!;
      await tester.startApp(h);

      await tester.enterText(
        find.byKey(const Key('add-address')),
        '${peer.ip}:${peer.engine.port}',
      );
      await tester.tap(find.byKey(const Key('add-lookup')));
      await tester.settleUntil(
        () =>
            find.byKey(const Key('confirm-peer-dialog')).evaluate().isNotEmpty,
        what: 'confirmation dialog',
      );
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.settle();

      expect(find.byKey(const Key('confirm-peer-dialog')), findsNothing);
      expect(h.engine.currentDevices, isEmpty);
      expect(find.byKey(const Key('add-address')), findsOneWidget);

      await tester.stopApp(h);
    });

    testWidgets('an address nobody answers at is reported', (tester) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/add'),
      ))!;
      await tester.startApp(h);

      await tester.enterText(
        find.byKey(const Key('add-address')),
        '127.0.0.9:9',
      );
      await tester.tap(find.byKey(const Key('add-lookup')));
      await tester.settleUntil(
        () => find
            .textContaining('No LibreShare device answered')
            .evaluate()
            .isNotEmpty,
        what: 'unreachable message',
      );
      expect(find.textContaining('127.0.0.9:9'), findsWidgets);

      await tester.stopApp(h);
    });

    testWidgets('pasting a libreshare://peer link adds the device', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/add'),
      ))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Linked-PC', discover: false),
      ))!;
      final link = peer.engine.myPeerLink!;
      mockClipboard(tester, text: link.toUri());
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('add-paste')));
      await tester.settle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('add-link')))
            .controller!
            .text,
        link.toUri(),
      );
      await tester.tap(find.byKey(const Key('add-link-submit')));
      await tester.settleUntil(
        () => h.engine.currentDevices.isNotEmpty,
        what: 'device added from the link',
      );
      final d = h.engine.currentDevices.single;
      expect(d.id, peer.id);
      expect(d.source, DiscoverySource.qr);

      await tester.stopApp(h);
    });

    testWidgets('bad links, other devices and wrong fingerprints are refused', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/add'),
      ))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Linked-PC', discover: false),
      ))!;
      await tester.startApp(h);

      Future<void> submit(String text) async {
        await tester.enterText(find.byKey(const Key('add-link')), text);
        await tester.tap(find.byKey(const Key('add-link-submit')));
        await tester.settle(ms: 60);
      }

      await submit('https://example.com');
      expect(
        find.text('That is not a valid LibreShare device link.'),
        findsOneWidget,
      );

      // Same address, but the link pins another device id.
      final wrongId = PeerLink(
        ip: peer.ip,
        port: peer.engine.port,
        deviceId: '11111111-1111-4111-8111-111111111111',
      );
      await submit(wrongId.toUri());
      await tester.settleUntil(
        () => find
            .text('A different device answered at that address.')
            .evaluate()
            .isNotEmpty,
        what: 'id mismatch',
      );

      // Same address, but the link pins a fingerprint the device cannot show.
      final wrongFp = PeerLink(
        ip: peer.ip,
        port: peer.engine.port,
        fingerprint: 'AB' * 32,
      );
      await submit(wrongFp.toUri());
      await tester.settleUntil(
        () => find
            .textContaining('does not match the link')
            .evaluate()
            .isNotEmpty,
        what: 'fingerprint mismatch',
      );
      expect(h.engine.currentDevices, isEmpty);

      await tester.stopApp(h);
    });

    testWidgets('desktop has no camera scan button', (tester) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/add'),
      ))!;
      await tester.startApp(h);
      expect(find.byKey(const Key('add-scan')), findsNothing);
      await tester.stopApp(h);
    });

    testWidgets('mobile: the scanner result is added like a pasted link', (
      tester,
    ) async {
      // Pretend to be a phone with a camera; the "camera" is a button that
      // "detects" whatever [scanned] holds.
      var scanned = '';
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/add',
          qrScanSupported: true,
          overrides: [
            qrScannerBuilderProvider.overrideWithValue(
              (context, onDetect) => Center(
                child: ElevatedButton(
                  key: const Key('fake-camera'),
                  onPressed: () => onDetect(scanned),
                  child: const Text('detect'),
                ),
              ),
            ),
          ],
        ),
      ))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Scanned-PC', discover: false),
      ))!;
      scanned = peer.engine.myPeerLink!.toUri();
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.settle();
      await tester.tap(find.byKey(const Key('fake-camera')));
      await tester.settleUntil(
        () => h.engine.currentDevices.isNotEmpty,
        what: 'device added from the scan',
      );
      expect(h.engine.currentDevices.single.id, peer.id);

      await tester.stopApp(h);
    });
  });
}

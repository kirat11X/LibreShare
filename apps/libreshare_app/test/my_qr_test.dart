// My QR (spec section 9, screen 8) and the QR scan screen. The link in the
// code is the engine's own `libreshare://peer` link, so these tests compare
// the screen with what a real engine reports.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'helpers/harness.dart';

bool shown(Finder f) => f.evaluate().isNotEmpty;

/// The link under the code (selectable text).
String linkText(WidgetTester tester) =>
    tester.widget<SelectableText>(find.byKey(const Key('qr-link-text'))).data!;

void main() {
  // Plaintext fixture peers against the app's secure engine (see the harness).
  setUpAll(() => AppHarness.legacyPlaintextPeers = true);
  tearDownAll(() => AppHarness.legacyPlaintextPeers = false);

  group('My QR code', () {
    testWidgets('Receive off: no code, and a button that turns Receive on', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/my-qr'),
      ))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('qr-unavailable')), findsOneWidget);
      expect(find.text('No QR code yet'), findsOneWidget);
      expect(find.byKey(const Key('qr-code')), findsNothing);
      expect(find.byType(PrettyQrView), findsNothing);
      expect(h.engine.myPeerLink, isNull);

      await tester.tap(find.byKey(const Key('qr-turn-on')));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('qr-code'))),
        what: 'QR code after turning Receive on',
      );
      expect(h.engine.receive.isReceiving, isTrue);
      expect(find.byKey(const Key('qr-unavailable')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('Receive on: the code, the link text, name and address', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/my-qr',
          alias: 'Kitchen-PC',
          initialMode: const ReceiveAlways(),
        ),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(find.byKey(const Key('qr-code'))),
        what: 'QR code',
      );

      final link = h.engine.myPeerLink!;
      expect(find.byType(PrettyQrView), findsOneWidget);
      expect(linkText(tester), link.toUri());
      expect(find.text('Kitchen-PC'), findsOneWidget);
      expect(find.text('${link.ip}:${link.port}'), findsOneWidget);

      // What is in the code is a valid link to this very device and listener.
      final parsed = PeerLink.tryParse(linkText(tester))!;
      expect(parsed.ip, link.ip);
      expect(parsed.port, h.engine.port);
      expect(parsed.alias, 'Kitchen-PC');

      await tester.stopApp(h);
    });

    testWidgets('the code has a text alternative for screen readers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/my-qr',
          alias: 'Kitchen-PC',
          initialMode: const ReceiveAlways(),
        ),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(find.byKey(const Key('qr-code'))),
        what: 'QR code',
      );
      await tester.pump(const Duration(milliseconds: 400));

      final link = h.engine.myPeerLink!;
      expect(
        find.bySemanticsLabel(
          'QR code to add Kitchen-PC at ${link.ip}:${link.port}',
        ),
        findsOneWidget,
      );

      semantics.dispose();
      await tester.stopApp(h);
    });

    testWidgets('Copy link puts the link on the clipboard', (tester) async {
      tester.useTallSurface();
      final written = <String>[];
      mockClipboard(tester, written: written);
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/my-qr',
          initialMode: const ReceiveAlways(),
        ),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(find.byKey(const Key('qr-copy'))),
        what: 'QR screen with a link',
      );

      await tester.tap(find.byKey(const Key('qr-copy')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(written, [h.engine.myPeerLink!.toUri()]);
      expect(find.text('Link copied'), findsOneWidget);

      await tester.stopApp(h);
    });

    testWidgets('the code goes away when Receive is turned off', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/my-qr',
          initialMode: const ReceiveAlways(),
        ),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(find.byKey(const Key('qr-code'))),
        what: 'QR code',
      );

      await tester.runAsync(() => h.engine.receive.turnOff());
      await tester.settleUntil(
        () => shown(find.byKey(const Key('qr-unavailable'))),
        what: 'code withdrawn',
      );
      expect(find.byKey(const Key('qr-code')), findsNothing);
      expect(find.byKey(const Key('qr-link-text')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('another device accepts the link from the code', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/my-qr',
          initialMode: const ReceiveAlways(),
        ),
      ))!;
      final other = (await tester.runAsync(
        () => h.startPeer('Phone', discover: false, secure: true),
      ))!;
      await tester.startApp(h);
      await tester.settleUntil(
        () => shown(find.byKey(const Key('qr-link-text'))),
        what: 'link text',
      );

      // The other device "scans" what is on screen.
      final scanned = PeerLink.parse(linkText(tester));
      await tester.runAsync(() => other.engine.addPeerLink(scanned));
      final listed = other.engine.currentDevices.single;
      expect(listed.id, h.engine.deviceInfo.deviceId);
      expect(listed.info.alias, h.engine.deviceInfo.alias);

      await tester.stopApp(h);
    });

    testWidgets('Done returns to Home', (tester) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/my-qr'),
      ))!;
      await tester.startApp(h);

      await tester.tap(find.text('Done'));
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-fab'))),
        what: 'Home',
      );

      await tester.stopApp(h);
    });
  });

  group('Scan QR screen', () {
    testWidgets('without a camera it says so and shows no scanner', (
      tester,
    ) async {
      var builds = 0;
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/scan',
          overrides: [
            qrScannerBuilderProvider.overrideWithValue((context, onDetect) {
              builds++;
              return const SizedBox();
            }),
          ],
        ),
      ))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('scan-unsupported')), findsOneWidget);
      expect(
        find.text(
          'Scanning needs a camera, which is not available here. '
          'Paste the link instead.',
        ),
        findsOneWidget,
      );
      expect(builds, 0, reason: 'the camera must not be opened');

      await tester.stopApp(h);
    });

    testWidgets('with a camera: the scanner is shown with a hint', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/scan',
          qrScanSupported: true,
          overrides: [
            qrScannerBuilderProvider.overrideWithValue(
              (context, onDetect) => const ColoredBox(
                key: Key('fake-camera-view'),
                color: Colors.black,
              ),
            ),
          ],
        ),
      ))!;
      await tester.startApp(h);

      expect(find.byKey(const Key('fake-camera-view')), findsOneWidget);
      expect(
        find.text('Point the camera at the QR code on the other device.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('scan-unsupported')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('a code seen twice is handed over once', (tester) async {
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
                  onPressed: () {
                    // A camera reports the same frame again and again.
                    onDetect(scanned);
                    onDetect(scanned);
                  },
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
      // One add, one confirmation, and Home again (not popped twice).
      await tester.settleUntil(
        () => shown(find.byKey(const Key('send-fab'))),
        what: 'Home after adding',
      );
      expect(find.text('Added Scanned-PC'), findsOneWidget);
      expect(h.engine.currentDevices, hasLength(1));

      await tester.stopApp(h);
    });
  });
}

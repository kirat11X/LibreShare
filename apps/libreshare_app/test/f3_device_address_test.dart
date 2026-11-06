// F3 defect 9: the address on a device card must not flip. A device added by
// IP / link keeps showing the address it was added with (the one that worked)
// when a weaker sighting (multicast announce, mDNS, register) names another
// address, e.g. a multi-homed peer's Docker or VPN address; only a newer
// confirmation (the user adds it again, a probe that answered) may change it.
// Devices that nobody added by hand keep following their latest sighting.
// The fix may live in the core registry (peer_registry.dart); the test goes
// through the real engine and the real device card.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

bool shown(Finder f) => f.evaluate().isNotEmpty;

Finder card(TestPeer p) => find.byKey(Key('device-${p.id}'));

/// "Android  ·  127.0.0.3:53318": the second line of the card.
String addressLine(WidgetTester tester, TestPeer p) {
  final texts = [
    for (final e
        in find.descendant(of: card(p), matching: find.byType(Text)).evaluate())
      (e.widget as Text).data!,
  ];
  return texts[1];
}

/// Makes [peer] look like it announced itself from [fromIp] (a second
/// interface) on the multicast bus.
Future<void> announceFrom(
  WidgetTester tester,
  AppHarness h,
  TestPeer peer,
  String fromIp,
) async {
  await tester.runAsync(() async {
    final t = h.bus.createTransport(address: fromIp);
    await t.start();
    final Uint8List datagram = encodeAnnounce(
      peer.engine.deviceInfo,
      announce: false,
    );
    t.sendMulticast(datagram);
  });
  await tester.settle(ms: 80, rounds: 2);
}

void main() {
  // Plaintext fixture peers against the app's secure engine (see the harness).
  setUpAll(() => AppHarness.legacyPlaintextPeers = true);
  tearDownAll(() => AppHarness.legacyPlaintextPeers = false);

  group('device card address', () {
    testWidgets('a manually added device keeps the address it was added with', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Pixel 8', discover: false),
      ))!;
      await tester.startApp(h);
      final port = peer.engine.port;
      await tester.runAsync(() => h.engine.addManualPeer(peer.ip, port));
      await tester.settleUntil(() => shown(card(peer)), what: 'card');
      expect(addressLine(tester, peer), 'Android  ·  ${peer.ip}:$port');

      await announceFrom(tester, h, peer, '127.0.0.77');

      expect(h.engine.currentDevices.single.address, peer.ip);
      expect(addressLine(tester, peer), 'Android  ·  ${peer.ip}:$port');
      expect(find.textContaining('127.0.0.77'), findsNothing);
      await tester.stopApp(h);
    });

    testWidgets('a second foreign sighting changes nothing either', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Pixel 8', discover: false),
      ))!;
      await tester.startApp(h);
      await tester.runAsync(
        () => h.engine.addManualPeer(peer.ip, peer.engine.port),
      );
      await tester.settleUntil(() => shown(card(peer)), what: 'card');

      await announceFrom(tester, h, peer, '127.0.0.77');
      await announceFrom(tester, h, peer, '127.0.0.78');

      expect(h.engine.currentDevices.single.address, peer.ip);
      await tester.stopApp(h);
    });

    testWidgets('adding it again at a new address is a newer confirmation', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(
        () => h.startPeer('Pixel 8', discover: false),
      ))!;
      await tester.startApp(h);
      final port = peer.engine.port;
      await tester.runAsync(() => h.engine.addManualPeer(peer.ip, port));
      await tester.settleUntil(() => shown(card(peer)), what: 'card');

      await tester.runAsync(
        () async => h.engine.addResolvedPeer(
          ResolvedPeer(
            info: peer.engine.deviceInfo,
            address: '127.0.0.88',
            port: port,
          ),
        ),
      );
      await tester.settle(ms: 50, rounds: 2);

      expect(h.engine.currentDevices.single.address, '127.0.0.88');
      expect(addressLine(tester, peer), 'Android  ·  127.0.0.88:$port');
      await tester.stopApp(h);
    });

    testWidgets('a device found by announcement follows its latest address', (
      tester,
    ) async {
      final h = (await tester.runAsync(AppHarness.create))!;
      final peer = (await tester.runAsync(() => h.startPeer('Pixel 8')))!;
      await tester.startApp(h);
      await tester.settleUntil(() => shown(card(peer)), what: 'card');
      expect(h.engine.currentDevices.single.address, peer.ip);

      await announceFrom(tester, h, peer, '127.0.0.77');

      expect(h.engine.currentDevices.single.address, '127.0.0.77');
      expect(
        addressLine(tester, peer),
        'Android  ·  127.0.0.77:${peer.engine.port}',
      );
      await tester.stopApp(h);
    });
  });
}

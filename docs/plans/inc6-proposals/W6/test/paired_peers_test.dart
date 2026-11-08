// Widget tests for PairedPeersCard, online/last-seen chips, channel badge and PairDialog (Increment 6 Wave 6).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/widgets/channel_badge.dart';
import 'package:libreshare_app/widgets/pair_dialog.dart';
import 'package:libreshare_app/widgets/paired_peers_card.dart';
import 'package:libreshare_core/libreshare_core.dart';

void main() {
  Widget buildTestableWidget(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
  }

  group('PairedPeersCard Widget Tests', () {
    testWidgets('renders online peer with Online chip and ChannelBadge', (
      tester,
    ) async {
      const peer = PairedPeerViewModel(
        deviceId: 'bob-device-id',
        alias: 'Bob Laptop',
        fingerprint:
            'B1B2B3B4B5B6B7B8C1C2C3C4C5C6C7C8D1D2D3D4D5D6D7D8E1E2E3E4E5E6E7E8',
        isOnline: true,
        candidateKind: CandidateKind.tunnel,
      );

      await tester.pumpWidget(
        buildTestableWidget(const PairedPeersCard(initialPeers: [peer])),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bob Laptop'), findsOneWidget);
      expect(
        find.byKey(const Key('peer_online_chip_bob-device-id')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('peer_channel_badge_bob-device-id')),
        findsOneWidget,
      );
      expect(find.byType(ChannelBadge), findsOneWidget);
    });

    testWidgets('renders offline peer with last seen minutes chip', (
      tester,
    ) async {
      const peer = PairedPeerViewModel(
        deviceId: 'alice-device-id',
        alias: 'Alice Phone',
        fingerprint:
            'A1A2A3A4A5A6A7A8B1B2B3B4B5B6B7B8C1C2C3C4C5C6C7C8D1D2D3D4D5D6D7D8',
        isOnline: false,
        lastSeenMinutes: 14,
        candidateKind: CandidateKind.manual,
      );

      await tester.pumpWidget(
        buildTestableWidget(const PairedPeersCard(initialPeers: [peer])),
      );
      await tester.pumpAndSettle();

      expect(find.text('Alice Phone'), findsOneWidget);
      expect(
        find.byKey(const Key('peer_last_seen_chip_alice-device-id')),
        findsOneWidget,
      );
      expect(find.text('Last seen 14m ago'), findsOneWidget);
    });

    testWidgets('unpair button removes peer from list', (tester) async {
      const peer = PairedPeerViewModel(
        deviceId: 'bob-device-id',
        alias: 'Bob Laptop',
        fingerprint:
            'B1B2B3B4B5B6B7B8C1C2C3C4C5C6C7C8D1D2D3D4D5D6D7D8E1E2E3E4E5E6E7E8',
        isOnline: true,
      );

      await tester.pumpWidget(
        buildTestableWidget(const PairedPeersCard(initialPeers: [peer])),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bob Laptop'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('peer_unpair_button_bob-device-id')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bob Laptop'), findsNothing);
      expect(find.textContaining('No paired devices'), findsOneWidget);
    });

    testWidgets('PairDialog shows SAS verification and completes pairing', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildTestableWidget(const PairedPeersCard(initialPeers: [])),
      );
      await tester.pumpAndSettle();

      // Tap pair button
      await tester.tap(find.byKey(const Key('pair_new_device_button')));
      await tester.pumpAndSettle();

      // PairDialog is open
      expect(find.byType(PairDialog), findsOneWidget);
      expect(find.byKey(const Key('pair_uri_input')), findsOneWidget);

      // Enter URI
      await tester.enterText(
        find.byKey(const Key('pair_uri_input')),
        'libreshare://pair?v=1&s=secret123&fp=ABCDEF',
      );
      await tester.tap(find.byKey(const Key('pair_connect_button')));
      await tester.pumpAndSettle();

      // Shows SAS code
      expect(find.byKey(const Key('pair_sas_code')), findsOneWidget);
      expect(find.text('742918'), findsOneWidget);

      // Confirm match
      await tester.tap(find.byKey(const Key('pair_confirm_button')));
      await tester.pumpAndSettle();

      // Dialog closed, new peer added
      expect(find.byType(PairDialog), findsNothing);
      expect(find.text('Carol Phone'), findsOneWidget);
    });
  });
}

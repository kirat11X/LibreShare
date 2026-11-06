import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/widgets/channel_badge.dart';
import 'package:libreshare_core/libreshare_core.dart';

void main() {
  group('ChannelBadge Widget Tests', () {
    testWidgets('renders WiFi badge correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ChannelBadge(kind: CandidateKind.wifi)),
        ),
      );

      expect(find.text('Wi-Fi'), findsOneWidget);
      expect(find.byIcon(Icons.wifi), findsOneWidget);
    });

    testWidgets('renders LAN badge correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ChannelBadge(kind: CandidateKind.lan)),
        ),
      );

      expect(find.text('LAN'), findsOneWidget);
      expect(find.byIcon(Icons.lan), findsOneWidget);
    });

    testWidgets('renders Loopback badge correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ChannelBadge(kind: CandidateKind.loopback)),
        ),
      );

      expect(find.text('Loopback'), findsOneWidget);
      expect(find.byIcon(Icons.loop), findsOneWidget);
    });

    testWidgets('renders falling back state correctly', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChannelBadge(kind: CandidateKind.wifi, isFallingBack: true),
          ),
        ),
      );

      expect(find.text('Switching tier...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}

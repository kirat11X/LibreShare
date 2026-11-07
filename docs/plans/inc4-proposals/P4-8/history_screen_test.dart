import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/screens/history_screen.dart';
import 'package:libreshare_core/libreshare_core.dart';

void main() {
  group('HistoryScreen Tests', () {
    testWidgets('shows empty state when no events', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [eventLogProvider.overrideWith((ref) async => const [])],
          child: const MaterialApp(home: HistoryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No transfer history yet'), findsOneWidget);
      expect(find.byIcon(Icons.history), findsOneWidget);
    });

    testWidgets('renders list of events correctly', (tester) async {
      final sampleEvents = [
        EventRecord.create(
          timestamp: DateTime.utc(2026, 11, 6, 12, 0, 0),
          level: EventLevel.info,
          type: 'transfer_completed',
          message: 'Received photo.jpg (2.5 MiB)',
        ),
        EventRecord.create(
          timestamp: DateTime.utc(2026, 11, 6, 12, 5, 0),
          level: EventLevel.warning,
          type: 'channel_fallback',
          message: 'Switched from wifi to lan',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            eventLogProvider.overrideWith((ref) async => sampleEvents),
          ],
          child: const MaterialApp(home: HistoryScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Received photo.jpg (2.5 MiB)'), findsOneWidget);
      expect(find.text('Switched from wifi to lan'), findsOneWidget);
      expect(find.text('transfer_completed'), findsOneWidget);
      expect(find.text('channel_fallback'), findsOneWidget);
    });
  });
}

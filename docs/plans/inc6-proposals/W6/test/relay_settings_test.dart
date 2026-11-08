// Widget tests for RelaySettingsCard and metadata privacy disclosure (Increment 6 Wave 6).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/widgets/relay_settings_card.dart';

void main() {
  Widget buildTestableWidget(Widget child) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
  }

  group('RelaySettingsCard Widget Tests', () {
    testWidgets('renders default relays and privacy disclosure notice', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestableWidget(const RelaySettingsCard()));
      await tester.pumpAndSettle();

      expect(find.text('Nostr Relays'), findsOneWidget);
      expect(
        find.textContaining('DISCLOSURE: Public relays see network timing'),
        findsOneWidget,
      );
      expect(find.text('wss://relay.damus.io'), findsOneWidget);
      expect(find.text('wss://nos.lol'), findsOneWidget);
      expect(find.text('wss://relay.primal.net'), findsOneWidget);
    });

    testWidgets('allows adding and removing custom relay endpoint', (
      tester,
    ) async {
      await tester.pumpWidget(buildTestableWidget(const RelaySettingsCard()));
      await tester.pumpAndSettle();

      // Enter new relay URL
      await tester.enterText(
        find.byKey(const Key('custom_relay_input')),
        'wss://custom-nostr-relay.example.com',
      );
      await tester.tap(find.byKey(const Key('add_relay_button')));
      await tester.pumpAndSettle();

      expect(find.text('wss://custom-nostr-relay.example.com'), findsOneWidget);

      // Remove the first relay
      await tester.tap(find.byKey(const Key('remove_relay_0')));
      await tester.pumpAndSettle();

      expect(find.text('wss://relay.damus.io'), findsNothing);
      expect(find.text('wss://custom-nostr-relay.example.com'), findsOneWidget);

      // Reset to defaults
      await tester.tap(find.byKey(const Key('reset_relays_button')));
      await tester.pumpAndSettle();

      expect(find.text('wss://relay.damus.io'), findsOneWidget);
      expect(find.text('wss://custom-nostr-relay.example.com'), findsNothing);
    });
  });
}

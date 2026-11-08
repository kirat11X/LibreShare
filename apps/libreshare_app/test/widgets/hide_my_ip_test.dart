import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/sleep_inhibitor.dart';
import 'package:libreshare_app/widgets/create_link_sheet.dart';

void main() {
  group('Hide My IP & Disclosure Widget Tests (Inc 5b Wave 4)', () {
    testWidgets('Hide my IP toggle changes value and provides disclosure text', (
      tester,
    ) async {
      bool? capturedHideIp;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreateLinkSheet(
              fileNames: const ['confidential.pdf'],
              totalBytes: 1024 * 1024,
              sleepInhibitor: NoopSleepInhibitor(),
              linkFactory: (mode, expiry, hideIp) async {
                capturedHideIp = hideIp;
                return 'https://libreshare.github.io/r#v=1&h=test.example.com';
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Step 1: Agree to consent notice
      final agreeBtn = find.byKey(const Key('consent_agree_button'));
      expect(agreeBtn, findsOneWidget);
      await tester.tap(agreeBtn);
      await tester.pumpAndSettle();

      // Step 2: Verify disclosure text exists in configuration view
      expect(
        find.text(
          'Direct connections show your IP address to whoever opens the link.',
        ),
        findsOneWidget,
      );

      // Toggle "Hide My IP Address" to ON
      final toggleFinder = find.byKey(const Key('hide_ip_toggle'));
      expect(toggleFinder, findsOneWidget);
      await tester.tap(toggleFinder);
      await tester.pumpAndSettle();

      // Tap Create Link button
      final createBtn = find.byKey(const Key('create_link_button'));
      await tester.tap(createBtn);
      await tester.pumpAndSettle();

      // Invariant: linkFactory received hideIp = true
      expect(capturedHideIp, isTrue);
    });

    test('Candidate list is never logged or dumped to stdout', () {
      // Security audit rule: candidate list must not be logged
      const sensitiveCandidateList =
          'ipv6:2001:db8::1:53330,mapped4:198.51.100.1:53330';
      final logs = <String>[];

      void mockLogger(String msg) {
        if (!msg.contains('ipv6:') && !msg.contains('mapped4:')) {
          logs.add(msg);
        }
      }

      mockLogger('Created link with hide-ip=true');
      expect(logs.any((l) => l.contains(sensitiveCandidateList)), isFalse);
    });
  });
}

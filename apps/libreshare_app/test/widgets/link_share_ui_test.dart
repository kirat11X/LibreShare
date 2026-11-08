import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/sleep_inhibitor.dart';
import 'package:libreshare_app/services/deep_link_handler.dart';
import 'package:libreshare_app/widgets/create_link_sheet.dart';
import 'package:libreshare_app/widgets/receive_link_dialog.dart';
import 'package:libreshare_core/libreshare_core.dart';

void main() {
  group('SleepInhibitor Tests', () {
    test('acquires and releases sleep inhibitor state cleanly', () async {
      final inhibitor = NoopSleepInhibitor();
      expect(inhibitor.isAcquired, isFalse);

      await inhibitor.acquire(reason: 'Active link share');
      expect(inhibitor.isAcquired, isTrue);

      await inhibitor.release();
      expect(inhibitor.isAcquired, isFalse);
    });
  });

  group('DeepLinkHandler Tests', () {
    test('parses libreshare://r deep link into ShareLink', () {
      final tokenB64 = b64urlEncode(Uint8List(16));
      final keyB64 = b64urlEncode(Uint8List(32));
      final uri = Uri.parse(
        'libreshare://r?v=1&h=relay.example.com&t=$tokenB64&k=$keyB64&m=1',
      );

      final link = DeepLinkHandler.parse(uri);
      expect(link, isNotNull);
      expect(link!.host, 'relay.example.com');
      expect(link.maxReceivers, 1);
    });

    test('rejects invalid scheme or malformed deep link', () {
      final uri = Uri.parse('ftp://invalid.example.com');
      expect(DeepLinkHandler.parse(uri), isNull);
    });
  });

  group('CreateLinkSheet Widget Tests', () {
    testWidgets(
      'shows consent card first, then allows configuring and starting share',
      (tester) async {
        final sleepInhibitor = NoopSleepInhibitor();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CreateLinkSheet(
                fileNames: const ['document.pdf'],
                totalBytes: 1024 * 1024,
                sleepInhibitor: sleepInhibitor,
                // Inject immediate mock link creator
                linkFactory: (mode, expiry, hideIp) async =>
                    'https://libreshare.github.io/r#v=1&h=test.trycloudflare.com&t=${b64urlEncode(Uint8List(16))}&k=${b64urlEncode(Uint8List(32))}&m=1',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Step 1: Consent card visible
        expect(find.byKey(const Key('consent_card')), findsOneWidget);
        expect(find.textContaining('Cloudflare Quick Tunnel'), findsOneWidget);

        // Agree to consent
        final agreeBtn = find.byKey(const Key('consent_agree_button'));
        expect(agreeBtn, findsOneWidget);
        await tester.tap(agreeBtn);
        await tester.pumpAndSettle();

        // Step 2: Configuration controls visible
        expect(find.byKey(const Key('expiry_selector')), findsOneWidget);
        expect(find.byKey(const Key('receivers_selector')), findsOneWidget);
        expect(find.byKey(const Key('hide_ip_toggle')), findsOneWidget);

        final createBtn = find.byKey(const Key('create_link_button'));
        expect(createBtn, findsOneWidget);
        await tester.tap(createBtn);
        await tester.pumpAndSettle();

        // Step 3: Active share view
        expect(sleepInhibitor.isAcquired, isTrue);
        expect(find.byKey(const Key('link_display_text')), findsOneWidget);
        expect(find.byKey(const Key('copy_link_button')), findsOneWidget);
        expect(find.byKey(const Key('expiry_countdown_text')), findsOneWidget);
        expect(find.byKey(const Key('receiver_row_0')), findsOneWidget);

        // Stop sharing
        final stopBtn = find.byKey(const Key('stop_sharing_button'));
        expect(stopBtn, findsOneWidget);
        await tester.tap(stopBtn);
        await tester.pumpAndSettle();

        expect(sleepInhibitor.isAcquired, isFalse);
      },
    );

    testWidgets('displays error text when tunnel creation fails', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreateLinkSheet(
              fileNames: const ['test.txt'],
              totalBytes: 500,
              linkFactory: (mode, expiry, hideIp) async {
                throw Exception('Tunnel provider unavailable (429)');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Bypass consent
      await tester.tap(find.byKey(const Key('consent_agree_button')));
      await tester.pumpAndSettle();

      // Tap create link
      await tester.tap(find.byKey(const Key('create_link_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('error_text')), findsOneWidget);
      expect(
        find.textContaining('Tunnel provider unavailable'),
        findsOneWidget,
      );
    });
  });

  group('ReceiveLinkDialog Widget Tests', () {
    testWidgets(
      'shows input, validates link and reports error on invalid link',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: ReceiveLinkDialog())),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('link_input_field')), findsOneWidget);
        expect(find.byKey(const Key('paste_link_button')), findsOneWidget);
        expect(find.byKey(const Key('download_link_button')), findsOneWidget);

        // Enter invalid link
        await tester.enterText(
          find.byKey(const Key('link_input_field')),
          'https://not-a-valid-link.com',
        );
        await tester.tap(find.byKey(const Key('download_link_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('receive_error_text')), findsOneWidget);
      },
    );

    testWidgets('shows progress indicator when valid link download begins', (
      tester,
    ) async {
      final tokenB64 = b64urlEncode(Uint8List(16));
      final keyB64 = b64urlEncode(Uint8List(32));
      final validLink =
          'https://libreshare.github.io/r#v=1&h=relay.example.com&t=$tokenB64&k=$keyB64&m=1';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReceiveLinkDialog(
              onDownload: (link) async {
                // Return delayed future to simulate active download
                await Future<void>.delayed(const Duration(seconds: 1));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('link_input_field')),
        validLink,
      );
      await tester.tap(find.byKey(const Key('download_link_button')));
      await tester.pump(); // Start download without settling

      expect(
        find.byKey(const Key('receive_progress_indicator')),
        findsOneWidget,
      );

      // Settle simulated download timer
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    });
  });
}

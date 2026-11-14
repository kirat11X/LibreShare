import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'helpers/harness.dart';

void main() {
  group('Web Portal Screen', () {
    testWidgets('Renders Web Portal screen and toggles service', (tester) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/web-portal'),
      ))!;
      await tester.startApp(h);

      expect(find.text('Web Portal (Browser Share)'), findsOneWidget);
      expect(find.text('Web Share Portal'), findsOneWidget);
      expect(find.byType(PrettyQrView), findsNothing);

      // Toggle switch to start Web Portal
      final switchFinder = find.byKey(const Key('web-portal-switch'));
      expect(switchFinder, findsOneWidget);
      await tester.tap(switchFinder);
      await tester.settleUntil(
        () => tester.any(find.byType(PrettyQrView)),
        what: 'Web portal QR view',
      );

      // Now it should be running with QR code and PWA notice
      expect(find.byType(PrettyQrView), findsOneWidget);
      expect(find.textContaining('Web App (PWA) Ready'), findsOneWidget);
      expect(find.text('Copy URL'), findsOneWidget);

      // Stop portal
      await tester.tap(switchFinder);
      await tester.settleUntil(
        () => !tester.any(find.byType(PrettyQrView)),
        what: 'Web portal stopped',
      );
      expect(find.byType(PrettyQrView), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('Home screen action bar navigates to Web Portal', (tester) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/'),
      ))!;
      await tester.startApp(h);

      final portalBtn = find.byKey(const Key('action-web-portal'));
      expect(portalBtn, findsOneWidget);

      await tester.tap(portalBtn);
      await tester.pumpAndSettle();

      expect(find.text('Web Portal (Browser Share)'), findsOneWidget);

      await tester.stopApp(h);
    });
  });
}

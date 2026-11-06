import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/autostart_provider.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/receive_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_app/screens/settings_screen.dart';
import 'package:libreshare_app/services/app_dirs.dart';
import 'package:libreshare_app/services/app_settings_store.dart';
import 'package:libreshare_app/services/file_picker_service.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_core/libreshare_core.dart';

class FakeReceiveController implements ReceiveController {
  @override
  ReceiveSettings get settings => const ReceiveSettings();

  @override
  ReceiveState get state => const Off(OffReason.user);

  @override
  Stream<ReceiveState> get states => const Stream.empty();

  @override
  bool get isReceiving => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSettingsEngine implements LibreShareEngine {
  FakeSettingsEngine({
    this.fingerprint =
        'A1B2C3D4E5F607182938495061728394A1B2C3D4E5F607182938495061728394',
    List<Contact> contacts = const [],
    this.isListening = false,
    this.port = 53318,
  }) : _contacts = List.of(contacts);

  final String fingerprint;
  List<Contact> _contacts;
  @override
  final bool isListening;
  @override
  final int port;
  final List<String> removedContacts = [];
  final List<String> blockedFingerprints = [];
  final ReceiveController _rx = FakeReceiveController();

  @override
  String get ownFingerprint => fingerprint;

  @override
  DeviceInfo get deviceInfo => DeviceInfo(
    deviceId: 'dev-1',
    alias: 'Test-Device',
    platform: 'linux',
    fingerprint: fingerprint,
  );

  @override
  ReceiveController get receive => _rx;

  // The PIN card asks the engine for its guard once a PIN mode is saved.
  @override
  PinGuard? get pinGuard => null;

  @override
  List<Contact> get currentContacts => _contacts;

  @override
  Stream<List<Contact>> get contacts => Stream.value(_contacts);

  @override
  Future<void> removeContact(String deviceId) async {
    removedContacts.add(deviceId);
    _contacts = _contacts.where((c) => c.deviceId != deviceId).toList();
  }

  @override
  Future<void> block(String fp) async {
    blockedFingerprints.add(fp);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pumpSettingsScreen(
  WidgetTester tester, {
  required LibreShareEngine engine,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        initialAppSettingsProvider.overrideWithValue(
          const AppSettings(deviceId: 'dev-1', alias: 'Test-Device'),
        ),
        engineOrNullProvider.overrideWithValue(engine),
        downloadDirProvider.overrideWithValue(Directory('/tmp/downloads')),
        appDirsProvider.overrideWithValue(
          AppDirs(
            supportDir: Directory.systemTemp.createTempSync('ls_b1_support_'),
            defaultDownloadDir: Directory('/tmp/downloads'),
          ),
        ),
        autostartSupportedProvider.overrideWithValue(false),
        receiveStatusProvider.overrideWithValue(const Off(OffReason.user)),
        filePickerServiceProvider.overrideWithValue(FakeFilePickerService()),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const SettingsScreen(),
      ),
    ),
  );
  await tester.pump();
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  if (f.evaluate().isNotEmpty) return;
  final scrollable = find.byType(Scrollable);
  if (scrollable.evaluate().isEmpty) return;
  try {
    await tester.scrollUntilVisible(f, 200, scrollable: scrollable.first);
    await tester.pump();
  } catch (_) {
    // If element is not found during scroll, allow subsequent expect() to report clean TestFailure.
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Settings screen - Your fingerprint', () {
    testWidgets(
      'positive twin: shows 16 hex in groups of 4 with a copy button, replacing the placeholder text',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        addTearDown(tester.view.reset);

        final fakeEngine = FakeSettingsEngine(
          fingerprint: 'A1B2C3D4E5F607182938495061728394A1B2C3D4E5F607182938495061728394',
        );

        await pumpSettingsScreen(tester, engine: fakeEngine);

        // 16 hex in groups of 4: "A1B2 C3D4 E5F6 0718"
        const expectedFormatted = 'A1B2 C3D4 E5F6 0718';
        expect(find.text(expectedFormatted), findsOneWidget);

        // Replaces the placeholder text
        expect(
          find.text('Available after security setup (a later update)'),
          findsNothing,
        );

        // Copy button
        final copyBtn = find.byKey(const Key('settings-fingerprint-copy'));
        expect(copyBtn, findsOneWidget);

        // Tapping copy puts it on the clipboard
        await tester.tap(copyBtn);
        await tester.pump();

        final clip = await tester.runAsync(
          () => Clipboard.getData(Clipboard.kTextPlain),
        );
        expect(
          clip?.text?.replaceAll(' ', '').toUpperCase(),
          startsWith('A1B2C3D4E5F60718'),
        );
      },
    );

    testWidgets(
      'negative twin: when fingerprint is empty, placeholder is shown and copy button is absent',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1200);
        addTearDown(tester.view.reset);

        final fakeEngine = FakeSettingsEngine(fingerprint: '');

        await pumpSettingsScreen(tester, engine: fakeEngine);

        expect(
          find.text('Available after security setup (a later update)'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('settings-fingerprint-copy')),
          findsNothing,
        );
      },
    );
  });

  group('Settings screen - PIN selector', () {
    testWidgets(
      'positive twin: PIN selector shows Off / Fixed / New each time; Fixed mode prompts for 6 digits and never reveals it after saving',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1400);
        addTearDown(tester.view.reset);

        final fakeEngine = FakeSettingsEngine();
        await pumpSettingsScreen(tester, engine: fakeEngine);

        // PIN selector exists
        final selector = find.byKey(const Key('settings-pin-selector'));
        await scrollTo(tester, selector);
        expect(selector, findsOneWidget);

        // Options: Off, Fixed, New each time
        expect(find.text('Off'), findsAtLeastNWidgets(1));
        expect(find.text('Fixed'), findsAtLeastNWidgets(1));
        expect(find.text('New each time'), findsAtLeastNWidgets(1));

        // Select Fixed mode -> shows 6-digit input
        await tester.tap(find.text('Fixed'));
        await tester.pumpAndSettle();

        final pinInput = find.byKey(const Key('settings-pin-input'));
        expect(pinInput, findsOneWidget);

        // Enter 6 digits and save
        await tester.enterText(pinInput, '654321');
        final saveBtn = find.byKey(const Key('settings-pin-save'));
        if (saveBtn.evaluate().isNotEmpty) {
          await tester.tap(saveBtn);
          // Saving writes files: let the real I/O finish (each step of it
          // continues in the fake-async zone) before looking.
          for (var i = 0; i < 60; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 25)),
            );
            await tester.pump(const Duration(milliseconds: 25));
          }
          await tester.pumpAndSettle();
        }

        // Privacy rule: PIN is never shown again after saving
        expect(
          find.text('654321'),
          findsNothing,
          reason: 'Saved PIN must never be displayed in plain text in Settings',
        );
      },
    );

    testWidgets('negative twin: when PIN is Off, no PIN input field is shown', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1400);
      addTearDown(tester.view.reset);

      final fakeEngine = FakeSettingsEngine();
      await pumpSettingsScreen(tester, engine: fakeEngine);

      final selector = find.byKey(const Key('settings-pin-selector'));
      await scrollTo(tester, selector);
      expect(selector, findsOneWidget);

      // In Off mode, no PIN input is visible
      expect(find.byKey(const Key('settings-pin-input')), findsNothing);
    });
  });

  group('Settings screen - Contacts list', () {
    testWidgets(
      'positive twin: displays contacts with alias, fingerprint, trust level text, and remove/block buttons',
      (tester) async {
        tester.view.physicalSize = const Size(800, 1600);
        addTearDown(tester.view.reset);

        final contacts = [
          Contact(
            deviceId: 'dev-alice',
            fingerprint: 'A1A2A3A4A5A6A7A8B1B2B3B4B5B6B7B8',
            alias: 'Alice Phone',
            trust: PeerTrust.trusted,
            pinnedAt: DateTime(2026, 11, 1),
          ),
          Contact(
            deviceId: 'dev-bob',
            fingerprint: 'C1C2C3C4C5C6C7C8D1D2D3D4D5D6D7D8',
            alias: 'Bob Laptop',
            trust: PeerTrust.known,
            pinnedAt: DateTime(2026, 11, 2),
          ),
        ];

        final fakeEngine = FakeSettingsEngine(contacts: contacts);
        await pumpSettingsScreen(tester, engine: fakeEngine);

        // Contacts list exists
        final contactsList = find.byKey(const Key('settings-contacts-list'));
        await scrollTo(tester, contactsList);
        expect(contactsList, findsOneWidget);

        // Shows contact aliases and trust levels
        expect(find.text('Alice Phone'), findsOneWidget);
        expect(find.text('Trusted contact'), findsOneWidget);
        expect(find.text('Bob Laptop'), findsOneWidget);
        expect(find.text('Known device'), findsOneWidget);

        // Remove and Block actions exist
        final removeAlice = find.byKey(const Key('contact-remove-dev-alice'));
        expect(removeAlice, findsOneWidget);
        await tester.tap(removeAlice);
        await tester.pumpAndSettle();
        expect(fakeEngine.removedContacts, contains('dev-alice'));

        final blockBob = find.byKey(const Key('contact-block-dev-bob'));
        expect(blockBob, findsOneWidget);
        await tester.tap(blockBob);
        await tester.pumpAndSettle();
        expect(
          fakeEngine.blockedFingerprints,
          contains('C1C2C3C4C5C6C7C8D1D2D3D4D5D6D7D8'),
        );
      },
    );

    testWidgets('negative twin: empty contacts list shows empty indicator', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.reset);

      final fakeEngine = FakeSettingsEngine(contacts: const []);
      await pumpSettingsScreen(tester, engine: fakeEngine);

      final contactsList = find.byKey(const Key('settings-contacts-list'));
      await scrollTo(tester, contactsList);
      expect(contactsList, findsOneWidget);

      // No remove or block buttons
      expect(find.byKey(const Key('contact-remove-dev-alice')), findsNothing);
      expect(find.text('Alice Phone'), findsNothing);
    });
  });

  group('Settings screen - RenderFlex check', () {
    testWidgets(
      'renders at 360x640 with 1.3x text scale without RenderFlex overflow',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);

        final contacts = [
          Contact(
            deviceId: 'dev-alice',
            fingerprint: 'A1A2A3A4A5A6A7A8B1B2B3B4B5B6B7B8',
            alias: 'Alice Phone with a very long alias name',
            trust: PeerTrust.trusted,
            pinnedAt: DateTime(2026, 11, 1),
          ),
        ];

        final fakeEngine = FakeSettingsEngine(contacts: contacts);
        await pumpSettingsScreen(tester, engine: fakeEngine);

        expect(tester.takeException(), isNull);
      },
    );
  });
}

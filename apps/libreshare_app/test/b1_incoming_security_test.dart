import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_app/widgets/incoming_transfer_dialog.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

class StubTransfers extends TransfersNotifier {
  StubTransfers(this.initial);

  final List<TransferView> initial;
  final List<String> accepted = [];
  final List<String> rejected = [];

  @override
  List<TransferView> build() => initial;

  @override
  Future<void> acceptIncoming(String key) async => accepted.add(key);

  @override
  Future<void> rejectIncoming(String key) async => rejected.add(key);
}

class FakeEngine implements LibreShareEngine {
  FakeEngine({this.info});

  final IncomingSessionInfo? info;

  @override
  IncomingSessionInfo? incomingInfo(String sessionId) => info;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TransferView incomingView({
  String key = 'session-1',
  String peer = 'Laptop',
  TransferPhase phase = TransferPhase.awaitingConsent,
  List<TransferFile>? files,
}) => TransferView(
  key: key,
  sessionId: key,
  direction: TransferDirection.incoming,
  phase: phase,
  peerAlias: peer,
  peerPlatform: 'linux',
  peerAddress: '192.168.1.100',
  files:
      files ?? const [TransferFile(id: 'f1', name: 'photo.jpg', size: 2000000)],
  createdAt: DateTime(2026, 11, 5, 12),
);

Future<void> pumpDialog(
  WidgetTester tester, {
  required TransferView transfer,
  IncomingSessionInfo? sessionInfo,
}) async {
  final store = StubTransfers([transfer]);
  final fakeEngine = FakeEngine(info: sessionInfo);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        transfersProvider.overrideWith(() => store),
        engineOrNullProvider.overrideWithValue(fakeEngine),
        clockProvider.overrideWithValue(ManualClock()),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: IncomingTransferDialog(transferKey: transfer.key)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('Incoming transfer dialog - SAS verification code', () {
    testWidgets(
      'positive twin: when sasRequired is true and sasCode is set, shows heading, grouped digits, instruction, and enables Accept',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          sasRequired: true,
          sasCode: '482913',
          trust: PeerTrust.unknown,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        // Heading "Verification code"
        expect(find.text('Verification code'), findsOneWidget);

        // Digits grouped "482 913" in large font
        final codeFinder = find.text('482 913');
        expect(codeFinder, findsOneWidget);
        final codeWidget = tester.widget<Text>(codeFinder);
        final fontSize = codeWidget.style?.fontSize ?? 14.0;
        expect(
          fontSize,
          greaterThanOrEqualTo(20.0),
          reason: 'Verification code must be shown in a large font',
        );

        // Sentence: "Ask {sender} to read the code on their screen. Accept only if it is the same."
        expect(
          find.text(
            'Ask Laptop to read the code on their screen. Accept only if it is the same.',
          ),
          findsOneWidget,
        );

        // Accept button is enabled when sasCode is non-null
        final acceptBtn = tester.widget<FilledButton>(
          find.byKey(const Key('incoming-accept')),
        );
        expect(
          acceptBtn.onPressed,
          isNotNull,
          reason: 'Accept must be enabled when sasCode is available',
        );
      },
    );

    testWidgets(
      'negative twin: when sasRequired is true and sasCode is null, Accept is disabled until code arrives',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          sasRequired: true,
          sasCode: null,
          trust: PeerTrust.unknown,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        expect(find.text('Verification code'), findsOneWidget);
        expect(find.text('482 913'), findsNothing);

        // Accept disabled until sasCode != null
        final acceptBtn = tester.widget<FilledButton>(
          find.byKey(const Key('incoming-accept')),
        );
        expect(
          acceptBtn.onPressed,
          isNull,
          reason: 'Accept must be disabled until sasCode != null',
        );
      },
    );

    testWidgets(
      'negative twin: when sasRequired is false, verification code heading is not shown and Accept is enabled immediately',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          sasRequired: false,
          sasCode: null,
          trust: PeerTrust.known,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        expect(find.text('Verification code'), findsNothing);
        expect(find.text('482 913'), findsNothing);

        final acceptBtn = tester.widget<FilledButton>(
          find.byKey(const Key('incoming-accept')),
        );
        expect(
          acceptBtn.onPressed,
          isNotNull,
          reason: 'Accept must be enabled immediately when SAS is not required',
        );
      },
    );
  });

  group('Incoming transfer dialog - PeerTrust badge', () {
    testWidgets(
      'positive twin: shows "New device" badge when trust is PeerTrust.unknown',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          trust: PeerTrust.unknown,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        expect(find.text('New device'), findsOneWidget);
      },
    );

    testWidgets(
      'positive twin: shows "Known device" badge when trust is PeerTrust.known',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          trust: PeerTrust.known,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        expect(find.text('Known device'), findsOneWidget);
      },
    );

    testWidgets(
      'positive twin: shows "Trusted contact" badge when trust is PeerTrust.trusted',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          trust: PeerTrust.trusted,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        expect(find.text('Trusted contact'), findsOneWidget);
      },
    );
  });

  group('Incoming transfer dialog - Key changed red banner', () {
    testWidgets(
      'positive twin: when keyChanged is true, shows red banner, NO Accept button, and link to Contacts',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          keyChanged: true,
          trust: PeerTrust.known,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        // Red banner with exact text
        const bannerText =
            "This device's security key changed. It may be a new phone, or someone pretending to be it.";
        final bannerFinder = find.text(bannerText);
        expect(bannerFinder, findsOneWidget);

        // NO Accept button (Reject only)
        expect(
          find.byKey(const Key('incoming-accept')),
          findsNothing,
          reason: 'Accept button must be absent when keyChanged is true',
        );
        expect(find.byKey(const Key('incoming-reject')), findsOneWidget);

        // Link to Contacts
        final contactsLink = find.textContaining('Contacts');
        expect(
          contactsLink,
          findsAtLeastNWidgets(1),
          reason: 'Must show a link to Contacts on key change',
        );
      },
    );

    testWidgets(
      'negative twin: when keyChanged is false, no red banner is shown and Accept button is present',
      (tester) async {
        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          keyChanged: false,
          trust: PeerTrust.known,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        expect(
          find.text(
            "This device's security key changed. It may be a new phone, or someone pretending to be it.",
          ),
          findsNothing,
        );
        expect(find.byKey(const Key('incoming-accept')), findsOneWidget);
        expect(find.byKey(const Key('incoming-reject')), findsOneWidget);
      },
    );
  });

  group('Incoming transfer dialog - RenderFlex check', () {
    testWidgets(
      'renders at 360x640 with 1.3x text scale without RenderFlex overflow',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);

        final t = incomingView();
        const info = IncomingSessionInfo(
          sessionId: 'session-1',
          sasRequired: true,
          sasCode: '482913',
          trust: PeerTrust.unknown,
        );
        await pumpDialog(tester, transfer: t, sessionInfo: info);

        // Ensure no RenderFlex overflow exception
        expect(tester.takeException(), isNull);
      },
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_app/widgets/incoming_transfer_dialog.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

class _StubTransfers extends TransfersNotifier {
  _StubTransfers(this.initial);

  final List<TransferView> initial;

  @override
  List<TransferView> build() => initial;

  @override
  Future<void> acceptIncoming(String key) async {}

  @override
  Future<void> rejectIncoming(String key) async {}
}

class _FakeEngine implements LibreShareEngine {
  _FakeEngine(this.info);

  final IncomingSessionInfo info;

  @override
  IncomingSessionInfo? incomingInfo(String sessionId) => info;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _transfer = TransferView(
  key: 'session-1',
  sessionId: 'session-1',
  direction: TransferDirection.incoming,
  phase: TransferPhase.awaitingConsent,
  peerAlias: 'Laptop',
  peerPlatform: 'linux',
  peerAddress: '192.168.1.100',
  files: const [TransferFile(id: 'f1', name: 'photo.jpg', size: 2000000)],
  createdAt: DateTime(2026, 11, 5, 12),
);

const _keyChanged = IncomingSessionInfo(
  sessionId: 'session-1',
  keyChanged: true,
  trust: PeerTrust.known,
);

const _normal = IncomingSessionInfo(
  sessionId: 'session-1',
  keyChanged: false,
  trust: PeerTrust.known,
);

class _Harness {
  _Harness(this.router);

  final GoRouter router;
  bool dialogDone = false;
  IncomingDecision? result;

  String get location => router.routeInformationProvider.value.uri.path;

  void open(BuildContext context) {
    showDialog<IncomingDecision>(
      context: context,
      barrierDismissible: false,
      builder: (_) => IncomingTransferDialog(transferKey: _transfer.key),
    ).then((value) {
      dialogDone = true;
      result = value;
    });
  }
}

/// Pumps a real GoRouter app: '/' has a button that opens the dialog the way
/// the app does (showDialog of IncomingTransferDialog, result is an
/// IncomingDecision); '/settings' is a placeholder page.
Future<_Harness> _pumpApp(WidgetTester tester, IncomingSessionInfo info) async {
  late final _Harness h;
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-dialog'),
              onPressed: () => h.open(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) =>
            const Scaffold(body: SizedBox(key: Key('settings-placeholder'))),
      ),
    ],
  );
  h = _Harness(router);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        transfersProvider.overrideWith(() => _StubTransfers([_transfer])),
        engineOrNullProvider.overrideWithValue(_FakeEngine(info)),
        clockProvider.overrideWithValue(ManualClock()),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const Key('open-dialog')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return h;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  group('B5: key-changed banner "Open Contacts"', () {
    testWidgets(
      'tapping Open Contacts rejects the transfer and navigates to /settings',
      (tester) async {
        final h = await _pumpApp(tester, _keyChanged);
        expect(find.byType(IncomingTransferDialog), findsOneWidget);
        expect(h.location, '/');

        await tester.tap(find.text('Open Contacts'));
        await _settle(tester);

        expect(h.dialogDone, isTrue, reason: 'dialog must close');
        expect(h.result, IncomingDecision.reject);
        expect(find.byType(IncomingTransferDialog), findsNothing);
        expect(h.location, '/settings');
        expect(find.byKey(const Key('settings-placeholder')), findsOneWidget);
      },
    );

    testWidgets(
      'twin: tapping Reject rejects and does NOT navigate (stays on /)',
      (tester) async {
        final h = await _pumpApp(tester, _keyChanged);

        await tester.tap(find.byKey(const Key('incoming-reject')));
        await _settle(tester);

        expect(h.dialogDone, isTrue);
        expect(h.result, IncomingDecision.reject);
        expect(find.byType(IncomingTransferDialog), findsNothing);
        expect(h.location, '/');
        expect(find.byKey(const Key('settings-placeholder')), findsNothing);
      },
    );

    testWidgets('keyChanged dialog has Open Contacts and no Accept button', (
      tester,
    ) async {
      await _pumpApp(tester, _keyChanged);

      expect(find.text('Open Contacts'), findsOneWidget);
      expect(find.byKey(const Key('incoming-accept')), findsNothing);
      expect(find.byKey(const Key('incoming-reject')), findsOneWidget);
    });

    testWidgets('twin: a dialog without keyChanged has no Open Contacts', (
      tester,
    ) async {
      await _pumpApp(tester, _normal);

      expect(find.byType(IncomingTransferDialog), findsOneWidget);
      expect(find.text('Open Contacts'), findsNothing);
      expect(find.byKey(const Key('incoming-accept')), findsOneWidget);
    });
  });
}

import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_app/services/file_launcher.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_core/libreshare_core.dart';

class StubTransfers extends TransfersNotifier {
  StubTransfers(this.initial);

  final List<TransferView> initial;
  final List<String> cancelled = [];

  @override
  List<TransferView> build() => initial;

  @override
  Future<void> cancel(String key) async => cancelled.add(key);
}

TransferView senderView({
  String key = 't1',
  TransferPhase phase = TransferPhase.waiting,
  String peer = 'Pixel 8',
  String? sasCode,
  bool keyChanged = false,
  bool insecurePeer = false,
  LsErrorCode? refusal,
  bool pinRequired = false,
  FailureReason? failure,
}) => TransferView(
  key: key,
  sessionId: 's-$key',
  direction: TransferDirection.outgoing,
  phase: phase,
  peerAlias: peer,
  peerPlatform: 'android',
  peerAddress: '192.168.1.20',
  files: const [
    TransferFile(id: 'f1', name: 'document.pdf', size: 1048576, done: 0),
  ],
  createdAt: DateTime(2026, 11, 5, 12),
  failure: failure,
  sasCode: sasCode,
  keyChanged: keyChanged,
  insecurePeer: insecurePeer,
  refusal: refusal,
  pinRequired: pinRequired,
);

Future<GoRouter> pumpTransferScreen(
  WidgetTester tester,
  StubTransfers store, {
  String key = 't1',
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('placeholder home')),
      ),
      GoRoute(
        path: '/transfer/:key',
        builder: (_, state) =>
            TransferScreen(transferKey: state.pathParameters['key']!),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        transfersProvider.overrideWith(() => store),
        fileLauncherProvider.overrideWithValue(FakeFileLauncher()),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildTheme(Brightness.light),
      ),
    ),
  );
  unawaited(router.push('/transfer/$key'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return router;
}

void main() {
  group('Sender progress - SAS code display', () {
    testWidgets(
      'positive twin: after SasReady(outgoing: true) shows verification code, comparison instruction, and Cancel',
      (tester) async {
        final store = StubTransfers([
          senderView(
            phase: TransferPhase.waiting,
            sasCode: '482913',
            peer: 'Pixel 8',
          ),
        ]);
        await pumpTransferScreen(tester, store);

        // Verification code 482 913. Tell {peer} to compare it, then wait for them to accept.
        const expectedText =
            'Verification code 482 913. Tell Pixel 8 to compare it, then wait for them to accept.';
        expect(find.text(expectedText), findsOneWidget);

        // Cancel button present
        expect(find.byKey(const Key('transfer-cancel')), findsOneWidget);
      },
    );

    testWidgets(
      'negative twin: before SasReady or when sasCode is null, verification code text is not shown',
      (tester) async {
        final store = StubTransfers([
          senderView(
            phase: TransferPhase.waiting,
            sasCode: null,
            peer: 'Pixel 8',
          ),
        ]);
        await pumpTransferScreen(tester, store);

        expect(find.textContaining('482 913'), findsNothing);
        expect(find.textContaining('Tell Pixel 8 to compare it'), findsNothing);
      },
    );
  });

  group('Sender progress - PeerKeyChanged failure mapping', () {
    testWidgets(
      'positive twin: PeerKeyChanged maps to "The security key of {peer} changed. Nothing was sent."',
      (tester) async {
        final t = senderView(
          phase: TransferPhase.failed,
          failure: FailureReason.protocolError,
          keyChanged: true,
          peer: 'Pixel 8',
        );
        final store = StubTransfers([t]);
        await pumpTransferScreen(tester, store);

        const expected =
            'The security key of Pixel 8 changed. Nothing was sent.';
        expect(find.text(expected), findsOneWidget);
        expect(failureText(t), expected);
      },
    );

    testWidgets(
      'negative twin: normal failure does not show key changed message',
      (tester) async {
        final t = senderView(
          phase: TransferPhase.failed,
          failure: FailureReason.noConnection,
          keyChanged: false,
          peer: 'Pixel 8',
        );
        final store = StubTransfers([t]);
        await pumpTransferScreen(tester, store);

        expect(find.textContaining('The security key of'), findsNothing);
      },
    );
  });

  group('Sender progress - InsecurePeerException failure mapping', () {
    testWidgets(
      'positive twin: InsecurePeerException maps to "{peer} uses an older version without encryption. Nothing was sent."',
      (tester) async {
        final t = senderView(
          phase: TransferPhase.failed,
          failure: FailureReason.protocolError,
          insecurePeer: true,
          peer: 'Pixel 8',
        );
        final store = StubTransfers([t]);
        await pumpTransferScreen(tester, store);

        const expected =
            'Pixel 8 uses an older version without encryption. Nothing was sent.';
        expect(find.text(expected), findsOneWidget);
        expect(failureText(t), expected);
      },
    );

    testWidgets(
      'negative twin: normal failure does not show older version message',
      (tester) async {
        final t = senderView(
          phase: TransferPhase.failed,
          failure: FailureReason.protocolError,
          insecurePeer: false,
          peer: 'Pixel 8',
        );
        final store = StubTransfers([t]);
        await pumpTransferScreen(tester, store);

        expect(
          find.textContaining('uses an older version without encryption'),
          findsNothing,
        );
      },
    );
  });

  group('Sender progress - PIN required dialog', () {
    testWidgets(
      'positive twin: when PIN is required, shows 6-digit PIN dialog',
      (tester) async {
        final store = StubTransfers([
          senderView(
            phase: TransferPhase.waiting,
            pinRequired: true,
            peer: 'Pixel 8',
          ),
        ]);
        await pumpTransferScreen(tester, store);

        // PIN dialog and 6-digit input
        expect(find.byKey(const Key('pin-dialog')), findsOneWidget);
        expect(find.byKey(const Key('pin-field')), findsOneWidget);
      },
    );

    testWidgets(
      'negative twin: when pinRequired is false, no PIN dialog is shown',
      (tester) async {
        final store = StubTransfers([
          senderView(
            phase: TransferPhase.waiting,
            pinRequired: false,
            peer: 'Pixel 8',
          ),
        ]);
        await pumpTransferScreen(tester, store);

        expect(find.byKey(const Key('pin-dialog')), findsNothing);
      },
    );
  });

  group('Sender progress - Wrong PIN mapping', () {
    testWidgets(
      'positive twin: wrong PIN maps to "That PIN was not accepted." without attempt counts',
      (tester) async {
        final t = senderView(
          phase: TransferPhase.failed,
          failure: FailureReason.protocolError,
          refusal: LsErrorCode.pinInvalid,
          peer: 'Pixel 8',
        );
        final store = StubTransfers([t]);
        await pumpTransferScreen(tester, store);

        const expected = 'That PIN was not accepted.';
        expect(find.text(expected), findsOneWidget);
        expect(failureText(t), expected);

        // Security requirement: NEVER show attempt counts
        final lower = failureText(t).toLowerCase();
        for (final forbidden in [
          'attempt',
          'tries',
          'remaining',
          'left',
          'strike',
        ]) {
          expect(
            lower.contains(forbidden),
            isFalse,
            reason:
                'Security: attempt count must never be shown ("$forbidden" found)',
          );
        }
      },
    );

    testWidgets('negative twin: other failures do not show wrong PIN message', (
      tester,
    ) async {
      final t = senderView(
        phase: TransferPhase.failed,
        failure: FailureReason.timeout,
        refusal: null,
        peer: 'Pixel 8',
      );
      final store = StubTransfers([t]);
      await pumpTransferScreen(tester, store);

      expect(find.text('That PIN was not accepted.'), findsNothing);
    });
  });

  group('Sender progress - RenderFlex check', () {
    testWidgets(
      'renders at 360x640 with 1.3x text scale without RenderFlex overflow',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);

        final store = StubTransfers([
          senderView(
            phase: TransferPhase.waiting,
            sasCode: '482913',
            peer: 'Pixel 8',
          ),
        ]);
        await pumpTransferScreen(tester, store);

        expect(tester.takeException(), isNull);
      },
    );
  });
}

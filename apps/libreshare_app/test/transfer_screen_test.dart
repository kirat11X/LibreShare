// Transfer screen (spec section 9, screens 2, 4, 5) and the Home transfer
// card, driven by a stub store so every phase can be shown deterministically.
// The same screens against real transfers are in send_flow_test.dart and
// incoming_test.dart.
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_app/services/file_launcher.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_app/widgets/transfer_card.dart';
import 'package:libreshare_core/libreshare_core.dart';

/// A transfer store that holds a fixed list and records what the UI asks of it.
class StubTransfers extends TransfersNotifier {
  StubTransfers(this.initial);

  final List<TransferView> initial;
  final List<String> cancelled = [];
  final List<String> accepted = [];
  final List<String> rejected = [];
  final List<String> dismissed = [];

  @override
  List<TransferView> build() => initial;

  void replace(List<TransferView> next) => state = next;

  @override
  Future<void> cancel(String key) async => cancelled.add(key);

  @override
  Future<void> acceptIncoming(String key) async => accepted.add(key);

  @override
  Future<void> rejectIncoming(String key) async => rejected.add(key);

  @override
  void dismiss(String key) {
    dismissed.add(key);
    state = [
      for (final t in state)
        if (t.key != key) t,
    ];
  }
}

final DateTime t0 = DateTime(2026, 11, 3, 12);

TransferView view({
  String key = 't1',
  TransferDirection direction = TransferDirection.outgoing,
  TransferPhase phase = TransferPhase.transferring,
  String peer = 'Pixel 8',
  List<TransferFile>? files,
  FailureReason? failure,
  bool localFileError = false,
  double speed = 0,
}) => TransferView(
  key: key,
  sessionId: 's-$key',
  direction: direction,
  phase: phase,
  peerAlias: peer,
  peerPlatform: 'android',
  peerAddress: '192.168.1.20',
  files:
      files ??
      const [
        TransferFile(id: 'f1', name: 'a.txt', size: 1048576, done: 524288),
        TransferFile(id: 'f2', name: 'b.bin', size: 1048576, done: 524288),
      ],
  createdAt: t0,
  failure: failure,
  localFileError: localFileError,
  speed: speed,
);

/// Shows [TransferScreen] for `/transfer/<key>` on top of a placeholder Home.
Future<GoRouter> pumpTransfer(
  WidgetTester tester,
  StubTransfers store, {
  String key = 't1',
  FakeFileLauncher? launcher,
  List<Override> overrides = const [],
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
        fileLauncherProvider.overrideWithValue(launcher ?? FakeFileLauncher()),
        ...overrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildTheme(Brightness.light),
      ),
    ),
  );
  unawaited(router.push('/transfer/$key'));
  // Not pumpAndSettle: the waiting phases spin forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return router;
}

Text textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

void main() {
  group('Transfer screen', () {
    testWidgets('an unknown transfer says so and leads back', (tester) async {
      await pumpTransfer(tester, StubTransfers(const []), key: 'nope');
      expect(
        find.text('This transfer is no longer available.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('placeholder home'), findsOneWidget);
    });

    testWidgets('preparing shows no verification code, Cancel works', (
      tester,
    ) async {
      final store = StubTransfers([view(phase: TransferPhase.preparing)]);
      await pumpTransfer(tester, store);
      expect(find.byKey(const Key('transfer-preparing')), findsOneWidget);
      expect(find.text('Preparing files…'), findsOneWidget);
      expect(find.text('Sending to Pixel 8'), findsOneWidget);
      expect(find.text('2 files, 2.10 MB'), findsOneWidget);
      expect(find.byKey(const Key('sas-placeholder')), findsNothing);

      await tester.tap(find.byKey(const Key('transfer-cancel')));
      expect(store.cancelled, ['t1']);
    });

    testWidgets('waiting marks the place of the verification code', (
      tester,
    ) async {
      await pumpTransfer(
        tester,
        StubTransfers([view(phase: TransferPhase.waiting)]),
      );
      expect(find.text('Waiting for Pixel 8 to accept…'), findsOneWidget);
      expect(find.byKey(const Key('sas-placeholder')), findsOneWidget);
      expect(
        find.textContaining('Verification code: available after security'),
        findsOneWidget,
      );
    });

    testWidgets('progress: percent, bytes, speed, ETA and a bar per file', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final store = StubTransfers([view(speed: 1048576)]);
      await pumpTransfer(tester, store);

      expect(textOf(tester, 'overall-percent').data, '50%');
      expect(textOf(tester, 'overall-bytes').data, '1.05 MB / 2.10 MB');
      expect(textOf(tester, 'overall-speed').data, '1.05 MB/s  ·  1 s left');
      final overall = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('overall-bar')),
      );
      expect(overall.value, 0.5);
      for (final id in ['f1', 'f2']) {
        final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(Key('file-bar-$id')),
        );
        expect(bar.value, 0.5, reason: id);
      }
      expect(find.text('524.3 KB / 1.05 MB'), findsNWidgets(2));
      expect(
        find.bySemanticsLabel('Overall progress, 50 percent'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('a.txt, 50 percent'), findsOneWidget);

      // The numbers follow the store.
      store.replace([
        view(
          files: const [
            TransferFile(id: 'f1', name: 'a.txt', size: 1048576, done: 1048576),
            TransferFile(id: 'f2', name: 'b.bin', size: 1048576, done: 786432),
          ],
          speed: 524288,
        ),
      ]);
      await tester.pump();
      expect(textOf(tester, 'overall-percent').data, '87%');
      expect(textOf(tester, 'overall-speed').data, '524.3 KB/s  ·  1 s left');
      semantics.dispose();
    });

    testWidgets('a long wait shows minutes in the ETA, no speed yet is blank', (
      tester,
    ) async {
      final store = StubTransfers([
        view(
          files: const [
            TransferFile(id: 'f1', name: 'big.iso', size: 6442450944),
          ],
          speed: 10485760,
        ),
      ]);
      await pumpTransfer(tester, store);
      expect(textOf(tester, 'overall-speed').data, '10.5 MB/s  ·  10 min left');

      store.replace([view(speed: 0)]);
      await tester.pump();
      expect(textOf(tester, 'overall-speed').data, isEmpty);
    });

    testWidgets('Cancel during progress asks the store to cancel', (
      tester,
    ) async {
      final store = StubTransfers([view()]);
      await pumpTransfer(tester, store);
      await tester.tap(find.byKey(const Key('transfer-cancel')));
      expect(store.cancelled, ['t1']);
    });

    testWidgets('a request waiting for you offers Accept and Reject', (
      tester,
    ) async {
      final store = StubTransfers([
        view(
          direction: TransferDirection.incoming,
          phase: TransferPhase.awaitingConsent,
        ),
      ]);
      await pumpTransfer(tester, store);
      expect(find.text('Receiving from Pixel 8'), findsOneWidget);
      expect(
        find.text('Pixel 8 wants to send you files. Accept or reject.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Accept'));
      await tester.tap(find.text('Reject'));
      expect(store.accepted, ['t1']);
      expect(store.rejected, ['t1']);
    });

    testWidgets('received single file: Open and Show in folder', (
      tester,
    ) async {
      final launcher = FakeFileLauncher();
      final store = StubTransfers([
        view(
          direction: TransferDirection.incoming,
          phase: TransferPhase.completed,
          files: const [
            TransferFile(
              id: 'f1',
              name: 'photo.jpg',
              size: 2048,
              done: 2048,
              savedPath: '/home/me/Downloads/LibreShare/photo.jpg',
            ),
          ],
        ),
      ]);
      await pumpTransfer(tester, store, launcher: launcher);
      expect(find.text('Received 1 file from Pixel 8'), findsOneWidget);

      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('transfer-show-folder')));
      await tester.pump();
      expect(launcher.opened, ['/home/me/Downloads/LibreShare/photo.jpg']);
      expect(launcher.shown, ['/home/me/Downloads/LibreShare/photo.jpg']);
    });

    testWidgets('received several files: only Show in folder', (tester) async {
      final launcher = FakeFileLauncher();
      final store = StubTransfers([
        view(
          direction: TransferDirection.incoming,
          phase: TransferPhase.completed,
          files: const [
            TransferFile(
              id: 'f1',
              name: 'a.txt',
              size: 10,
              done: 10,
              savedPath: '/d/a.txt',
            ),
            TransferFile(
              id: 'f2',
              name: 'b.txt',
              size: 20,
              done: 20,
              savedPath: '/d/b.txt',
            ),
          ],
        ),
      ]);
      await pumpTransfer(tester, store, launcher: launcher);
      expect(find.text('Received 2 files from Pixel 8'), findsOneWidget);
      expect(find.byKey(const Key('transfer-open')), findsNothing);
      await tester.tap(find.byKey(const Key('transfer-show-folder')));
      await tester.pump();
      expect(launcher.shown, ['/d/a.txt']);
    });

    testWidgets('sent files: no Open, Done returns to Home', (tester) async {
      final store = StubTransfers([view(phase: TransferPhase.completed)]);
      await pumpTransfer(tester, store);
      expect(find.text('Sent 2 files to Pixel 8'), findsOneWidget);
      expect(find.byKey(const Key('transfer-open')), findsNothing);
      expect(find.byKey(const Key('transfer-show-folder')), findsNothing);

      await tester.tap(find.byKey(const Key('transfer-done-button')));
      await tester.pumpAndSettle();
      expect(find.text('placeholder home'), findsOneWidget);
    });

    testWidgets('when the system cannot open it, the path is shown', (
      tester,
    ) async {
      final store = StubTransfers([
        view(
          direction: TransferDirection.incoming,
          phase: TransferPhase.completed,
          files: const [
            TransferFile(
              id: 'f1',
              name: 'a.txt',
              size: 10,
              done: 10,
              savedPath: '/d/a.txt',
            ),
          ],
        ),
      ]);
      await pumpTransfer(
        tester,
        store,
        launcher: FakeFileLauncher(succeeds: false),
      );
      await tester.tap(find.byKey(const Key('transfer-open')));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Could not open it here. The file is saved at /d/a.txt'),
        findsOneWidget,
      );
    });

    testWidgets('every failure reason has its own plain-language text', (
      tester,
    ) async {
      final texts = <FailureReason, String>{
        FailureReason.rejected: 'Pixel 8 declined the files.',
        FailureReason.timeout: 'There was no answer in time. Try again.',
        FailureReason.cancelled: 'The transfer was cancelled.',
        FailureReason.verifyFailed:
            'A file arrived damaged and was discarded. Try sending it again.',
        FailureReason.noConnection:
            'Could not reach Pixel 8. Check that you are on the same network '
            'and that Receive is on.',
        FailureReason.diskFull:
            'There is not enough free space on the receiving device.',
        FailureReason.protocolError:
            'Something went wrong during the transfer.',
      };
      expect(texts.keys.toSet(), FailureReason.values.toSet());
      for (final entry in texts.entries) {
        final store = StubTransfers([
          view(phase: TransferPhase.failed, failure: entry.key),
        ]);
        await pumpTransfer(tester, store);
        expect(textOf(tester, 'failure-text').data, entry.value);
        expect(failureText(store.initial.single), entry.value);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });

    testWidgets('a vanished local file is not blamed on the network', (
      tester,
    ) async {
      final store = StubTransfers([
        view(
          phase: TransferPhase.failed,
          failure: FailureReason.protocolError,
          localFileError: true,
        ),
      ]);
      await pumpTransfer(tester, store);
      expect(
        textOf(tester, 'failure-text').data,
        'A selected file could not be read. It may have been moved or deleted.',
      );
      await tester.tap(find.byKey(const Key('transfer-back')));
      await tester.pumpAndSettle();
      expect(find.text('placeholder home'), findsOneWidget);
    });

    testWidgets('a cancelled transfer shows the cancel icon', (tester) async {
      final store = StubTransfers([
        view(phase: TransferPhase.cancelled, failure: FailureReason.cancelled),
      ]);
      await pumpTransfer(tester, store);
      expect(find.byIcon(Icons.cancel), findsOneWidget);
      expect(find.byIcon(Icons.error), findsNothing);
    });
  });

  group('Transfer card on Home', () {
    String statusOf(TransferView v) => transferStatusText(v);

    test('status line for every phase and direction', () {
      TransferView v(
        TransferPhase p, {
        TransferDirection d = TransferDirection.outgoing,
      }) => view(phase: p, direction: d);
      expect(statusOf(v(TransferPhase.preparing)), 'Preparing files…');
      expect(
        statusOf(v(TransferPhase.waiting)),
        'Waiting for Pixel 8 to accept…',
      );
      expect(
        statusOf(v(TransferPhase.transferring)),
        'Sending to Pixel 8, 50%',
      );
      expect(
        statusOf(v(TransferPhase.transferring, d: TransferDirection.incoming)),
        'Receiving from Pixel 8, 50%',
      );
      expect(
        statusOf(
          v(TransferPhase.awaitingConsent, d: TransferDirection.incoming),
        ),
        'Pixel 8 wants to send you files. Accept or reject.',
      );
      expect(statusOf(v(TransferPhase.completed)), 'Sent 2 files to Pixel 8');
      expect(
        statusOf(v(TransferPhase.completed, d: TransferDirection.incoming)),
        'Received 2 files from Pixel 8',
      );
      expect(statusOf(v(TransferPhase.cancelled)), 'Transfer cancelled');
      expect(
        statusOf(v(TransferPhase.rejected)),
        'Pixel 8 declined the transfer',
      );
      expect(statusOf(v(TransferPhase.failed)), 'Transfer failed');
    });

    testWidgets('running transfers can be cancelled, finished ones dismissed', (
      tester,
    ) async {
      final store = StubTransfers([
        view(key: 'run'),
        view(key: 'end', phase: TransferPhase.completed),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [transfersProvider.overrideWith(() => store)],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: Column(
                  children: [
                    for (final t in ref.watch(transfersProvider))
                      TransferCard(key: Key('card-${t.key}'), transfer: t),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Sending to Pixel 8, 50%'), findsOneWidget);
      expect(find.text('Sent 2 files to Pixel 8'), findsOneWidget);
      // Only the running one has a progress bar.
      expect(
        find.descendant(
          of: find.byKey(const Key('card-run')),
          matching: find.byType(LinearProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('card-end')),
          matching: find.byType(LinearProgressIndicator),
        ),
        findsNothing,
      );

      await tester.tap(find.byTooltip('Cancel'));
      expect(store.cancelled, ['run']);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pump();
      expect(store.dismissed, ['end']);
      expect(find.byKey(const Key('card-end')), findsNothing);
    });
  });

  group('TransferView', () {
    test('fraction, bytes and ETA', () {
      final v = view(speed: 1048576);
      expect(v.bytesTotal, 2097152);
      expect(v.bytesDone, 1048576);
      expect(v.fraction, 0.5);
      expect(v.eta, const Duration(seconds: 1));
      expect(v.isActive, isTrue);
      expect(view(phase: TransferPhase.completed).isFinished, isTrue);
    });

    test('an empty file set does not divide by zero', () {
      final v = view(files: const [], phase: TransferPhase.completed);
      expect(v.fraction, 1);
      expect(view(files: const []).fraction, 0);
    });

    test('progress never exceeds the size and the ETA needs a speed', () {
      final v = view(
        files: const [TransferFile(id: 'f1', name: 'a', size: 10, done: 99)],
      );
      expect(v.bytesDone, 10);
      expect(v.eta, isNull);
    });

    test('the saved folder is the parent of the first saved file', () {
      final v = view(
        files: const [
          TransferFile(id: 'f1', name: 'a', size: 1, savedPath: '/x/y/a'),
        ],
      );
      expect(v.savedFolder, '/x/y');
      expect(view().savedFolder, isNull);
    });
  });
}

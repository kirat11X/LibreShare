// Card K1: "Not Enough Free Space" Phone Error
// App tests for failure reason display and SettingsScreen download folder writability validation.

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_app/services/file_launcher.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';

class StubTransfers extends TransfersNotifier {
  StubTransfers(this.initial);

  final List<TransferView> initial;

  @override
  List<TransferView> build() => initial;
}

final DateTime t0 = DateTime(2026, 11, 3, 12);

TransferView view({
  String key = 't1',
  TransferDirection direction = TransferDirection.outgoing,
  TransferPhase phase = TransferPhase.failed,
  String peer = 'Pixel 8',
  FailureReason? failure,
}) => TransferView(
  key: key,
  sessionId: 's-$key',
  direction: direction,
  phase: phase,
  peerAlias: peer,
  peerPlatform: 'android',
  peerAddress: '192.168.1.20',
  files: const [
    TransferFile(id: 'f1', name: 'photo.jpg', size: 1048576, done: 0),
  ],
  createdAt: t0,
  failure: failure,
);

Future<GoRouter> pumpTransfer(
  WidgetTester tester,
  StubTransfers store, {
  String key = 't1',
  List<Override> overrides = const [],
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('home')),
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
        ...overrides,
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: buildTheme(Brightness.light),
      ),
    ),
  );
  unawaited(router.push('/transfer/$key'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return router;
}

Text textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

void main() {
  group('FailureReason.storageUnusable string formatting', () {
    test(
      'failureText formats FailureReason.storageUnusable to distinct message',
      () {
        final t = view(failure: FailureReason.storageUnusable);
        expect(
          failureText(t),
          'The download folder on the receiving device is not usable or unwritable.',
        );
      },
    );

    testWidgets(
      'TransferScreen displays distinct message for FailureReason.storageUnusable',
      (tester) async {
        final store = StubTransfers([
          view(failure: FailureReason.storageUnusable),
        ]);
        await pumpTransfer(tester, store);
        expect(
          find.text(
            'The download folder on the receiving device is not usable or unwritable.',
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('SettingsScreen folder picking writability validation', () {
    testWidgets(
      'when picked folder is not writable, settings does NOT update download directory and displays error SnackBar',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        final initialDir = h.defaultDownloads.path;

        final unwritableDir = Directory('${h.sandbox.path}/unwritable_dir')
          ..createSync();
        Process.runSync('chmod', ['555', unwritableDir.path]);
        addTearDown(() {
          try {
            Process.runSync('chmod', ['755', unwritableDir.path]);
          } catch (_) {}
        });

        h.picker.directory = unwritableDir.path;
        await tester.startApp(h);

        await tester.tap(find.byKey(const Key('settings-folder')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Settings should NOT update the download directory
        expect(textOf(tester, 'settings-folder-value').data, initialDir);
        expect(
          h.container.read(engineOrNullProvider)?.downloadDir.path,
          initialDir,
        );

        // Error SnackBar should be displayed
        expect(find.byType(SnackBar), findsOneWidget);
        expect(
          find.text(
            'The selected folder cannot be written to. Please choose another location.',
          ),
          findsOneWidget,
        );

        await tester.stopApp(h);
      },
    );

    testWidgets(
      'when picked folder is writable, settings updates the download directory',
      (tester) async {
        tester.useTallSurface();
        final h = (await tester.runAsync(
          () => AppHarness.create(initialLocation: '/settings'),
        ))!;
        final writableDir = Directory('${h.sandbox.path}/writable_dir')
          ..createSync();
        h.picker.directory = writableDir.path;
        await tester.startApp(h);

        await tester.tap(find.byKey(const Key('settings-folder')));
        await tester.settleUntil(
          () =>
              h.container.read(engineOrNullProvider)?.downloadDir.path ==
              writableDir.path,
          what: 'engine uses the new folder',
        );

        expect(textOf(tester, 'settings-folder-value').data, writableDir.path);
        expect(find.byType(SnackBar), findsNothing);

        await tester.stopApp(h);
      },
    );
  });
}

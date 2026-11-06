// Shared by the F3 tests (Android usability fixes): a stub transfer store for
// the completion / failure screens, a launcher that throws, a counting folder
// picker and a recorder for a mocked platform channel.
import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/transfers_provider.dart';
import 'package:libreshare_app/screens/transfer_screen.dart';
import 'package:libreshare_app/services/file_launcher.dart';
import 'package:libreshare_app/widgets/app_theme.dart';
import 'package:libreshare_core/libreshare_core.dart';

/// A transfer store that holds a fixed list.
class F3StubTransfers extends TransfersNotifier {
  F3StubTransfers(this.initial);

  final List<TransferView> initial;

  @override
  List<TransferView> build() => initial;
}

final DateTime f3T0 = DateTime(2026, 11, 3, 12);

/// A finished incoming transfer whose files were saved at [paths].
TransferView f3Received(List<String> paths, {String peer = 'Fedora-PC'}) =>
    TransferView(
      key: 't1',
      sessionId: 's-t1',
      direction: TransferDirection.incoming,
      phase: TransferPhase.completed,
      peerAlias: peer,
      peerPlatform: 'linux',
      peerAddress: '192.168.1.20',
      files: [
        for (var i = 0; i < paths.length; i++)
          TransferFile(
            id: 'f${i + 1}',
            name: paths[i].split('/').last,
            size: 2048,
            done: 2048,
            savedPath: paths[i],
          ),
      ],
      createdAt: f3T0,
    );

/// An outgoing transfer in [phase] with [files] (default: two 1 MiB files at
/// half way). Set [failure] for failed phases.
TransferView f3Outgoing({
  TransferPhase phase = TransferPhase.transferring,
  String peer = 'Pixel 8',
  List<TransferFile>? files,
  FailureReason? failure,
}) => TransferView(
  key: 't1',
  sessionId: 's-t1',
  direction: TransferDirection.outgoing,
  phase: phase,
  peerAlias: peer,
  peerPlatform: 'android',
  peerAddress: '192.168.1.20',
  files:
      files ??
      const [
        TransferFile(id: 'f1', name: 'a.txt', size: 1000000, done: 500000),
        TransferFile(id: 'f2', name: 'b.bin', size: 1000000, done: 500000),
      ],
  createdAt: f3T0,
  failure: failure,
);

/// Shows [TransferScreen] for the one transfer in [store] on top of a
/// placeholder Home (same pattern as transfer_screen_test.dart).
Future<void> f3PumpTransfer(
  WidgetTester tester,
  F3StubTransfers store, {
  FileLauncher? launcher,
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
  unawaited(router.push('/transfer/t1'));
  // Not pumpAndSettle: the waiting phases spin forever.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// A launcher whose platform call blows up.
class ThrowingFileLauncher implements FileLauncher {
  @override
  Future<bool> open(String path) async => throw StateError('no viewer');

  @override
  Future<bool> showInFolder(String path) async => throw StateError('no files');
}

/// Installs a mock handler on the platform channel [name] for the length of
/// the test. Returns the calls it received. [handler] answers each call; a
/// thrown [PlatformException] reaches the Dart caller like a native error.
List<MethodCall> f3MockChannel(
  String name,
  Future<Object?> Function(MethodCall call) handler,
) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(MethodChannel(name), (call) {
    calls.add(call);
    return handler(call);
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
  );
  return calls;
}

/// Every Text widget's data, in tree order.
List<String> f3AllTexts() => [
  for (final e in find.byType(Text).evaluate())
    if ((e.widget as Text).data != null) (e.widget as Text).data!,
];

final RegExp hex64 = RegExp(r'[0-9a-fA-F]{64}');

/// Strings that must never reach a person.
void f3ExpectPlain(String text, {String? reason}) {
  expect(text.trim(), isNotEmpty, reason: reason);
  for (final bad in [
    'Exception',
    'Error',
    'error:',
    'Instance of',
    'dart:',
    'package:',
    '#0',
    'SocketException',
    'null',
    'NO_CONNECTION',
    '{',
    '}',
  ]) {
    expect(text, isNot(contains(bad)), reason: '$reason: "$text"');
  }
  expect(hex64.hasMatch(text), isFalse, reason: '$reason: no fingerprint');
  expect(text.contains('\n'), isFalse, reason: '$reason: one line');
}

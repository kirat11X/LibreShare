// F3 defect 3 (a): on Android the first time Receive is turned on while the
// download folder is still the app-private default, a one-time dialog/sheet
// explains where files will go and offers "Choose a folder" (the existing
// folder picker) and "Keep default". The choice is remembered for good.
//
// New symbols:
//   providers/platform_providers.dart:
//     final isAndroidProvider = Provider<bool>((ref) => Platform.isAndroid);
//       (NOT defaultTargetPlatform: flutter_test reports Android everywhere)
//   AppSettings (services/app_settings_store.dart): one new persisted bool,
//     default false, "the storage question was answered" (name is the coder's).
// Widget contract (keys): root `storage-prompt`; buttons `storage-prompt-choose`
// ("Choose a folder") and `storage-prompt-keep` ("Keep default"). The prompt
// comes BEFORE Receive is switched on (choosing a folder rebuilds the engine);
// it names the default folder's path. Receive then turns on either way.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/platform_providers.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_app/services/app_settings_store.dart';
import 'package:libreshare_core/libreshare_core.dart';
import 'package:uuid/uuid.dart';

import 'helpers/harness.dart';

const prompt = Key('storage-prompt');
const choose = Key('storage-prompt-choose');
const keep = Key('storage-prompt-keep');
const rxSwitch = Key('receive-switch');

bool shown(Finder f) => f.evaluate().isNotEmpty;

bool receiveOn(AppHarness h) =>
    h.container.read(engineOrNullProvider)?.receive.state is On;

bool receiveOff(AppHarness h) =>
    h.container.read(engineOrNullProvider)?.receive.state is Off;

Future<AppHarness> create(
  WidgetTester tester, {
  bool android = true,
  String? pickDirectory,
  String? initialLocation,
  Directory? sandbox,
}) async {
  final h = (await tester.runAsync(
    () => AppHarness.create(
      initialLocation: initialLocation,
      reuseSandbox: sandbox,
      overrides: [isAndroidProvider.overrideWithValue(android)],
    ),
  ))!;
  // What the (fake) system folder picker answers.
  h.picker.directory = pickDirectory;
  return h;
}

Future<void> turnOffAndWait(WidgetTester tester, AppHarness h) async {
  await tester.tap(find.byKey(rxSwitch));
  await tester.settleUntil(() => receiveOff(h), what: 'receive off');
}

void main() {
  group('first Receive on Android', () {
    testWidgets('asks where files go before turning Receive on', (
      tester,
    ) async {
      final h = await create(tester);
      await tester.startApp(h);
      expect(shown(find.byKey(prompt)), isFalse, reason: 'not at start-up');

      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => shown(find.byKey(prompt)),
        what: 'the storage prompt',
      );
      expect(
        find.descendant(
          of: find.byKey(prompt),
          matching: find.text('Choose a folder'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(prompt),
          matching: find.text('Keep default'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(choose), findsOneWidget);
      expect(find.byKey(keep), findsOneWidget);
      // It says where files will be saved right now.
      expect(
        find.descendant(
          of: find.byKey(prompt),
          matching: find.textContaining(h.defaultDownloads.path),
        ),
        findsOneWidget,
      );
      // Nothing has been decided yet.
      expect(receiveOn(h), isFalse);
      expect(h.container.read(engineOrNullProvider)!.isListening, isFalse);

      await tester.tap(find.byKey(keep));
      await tester.settleUntil(() => receiveOn(h), what: 'receive on');
      await tester.stopApp(h);
    });

    testWidgets('Keep default: Receive turns on, the folder stays, no picker', (
      tester,
    ) async {
      final h = await create(tester, pickDirectory: '/never/used');
      await tester.startApp(h);

      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => shown(find.byKey(prompt)),
        what: 'the storage prompt',
      );
      await tester.tap(find.byKey(keep));
      await tester.settleUntil(() => receiveOn(h), what: 'receive on');
      await tester.pump();

      expect(shown(find.byKey(prompt)), isFalse);
      expect(h.container.read(settingsProvider).downloadDir, isNull);
      expect(
        h.container.read(downloadDirProvider).path,
        h.defaultDownloads.path,
      );
      await tester.stopApp(h);
    });

    testWidgets('it never asks again: off and on in the same run', (
      tester,
    ) async {
      final h = await create(tester);
      await tester.startApp(h);
      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => shown(find.byKey(prompt)),
        what: 'the storage prompt',
      );
      await tester.tap(find.byKey(keep));
      await tester.settleUntil(() => receiveOn(h), what: 'receive on');

      await turnOffAndWait(tester, h);
      expect(shown(find.byKey(prompt)), isFalse, reason: 'turning off');
      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(() => receiveOn(h), what: 'receive on again');
      expect(shown(find.byKey(prompt)), isFalse, reason: 'second time on');
      await tester.stopApp(h);
    });

    testWidgets('it never asks again after the app restarts', (tester) async {
      final h = await create(tester);
      await tester.startApp(h);
      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => shown(find.byKey(prompt)),
        what: 'the storage prompt',
      );
      await tester.tap(find.byKey(keep));
      await tester.settleUntil(() => receiveOn(h), what: 'receive on');
      final sandbox = h.sandbox;
      await tester.stopApp(h, deleteSandbox: false);

      // A new run on the same data folders.
      final again = await create(tester, sandbox: sandbox);
      await tester.startApp(again);
      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => receiveOn(again) || shown(find.byKey(prompt)),
        what: 'receive on or the prompt',
      );
      expect(shown(find.byKey(prompt)), isFalse);
      expect(receiveOn(again), isTrue);
      await tester.stopApp(again);
    });

    testWidgets(
      'Choose a folder: opens the picker, saves the folder, Receive on',
      (tester) async {
        final sandbox = Directory.systemTemp.createTempSync('ls_f3_choose_');
        final custom = '${sandbox.path}/Download/LibreShareRx';
        Directory(custom).createSync(recursive: true);
        final h = await create(tester, pickDirectory: custom, sandbox: sandbox);
        await tester.startApp(h);

        await tester.tap(find.byKey(rxSwitch));
        await tester.settleUntil(
          () => shown(find.byKey(prompt)),
          what: 'the storage prompt',
        );
        await tester.tap(find.byKey(choose));
        await tester.settleUntil(
          () => receiveOn(h),
          what: 'receive on with the chosen folder',
          maxRounds: 400,
        );
        await tester.pump();

        expect(h.container.read(settingsProvider).downloadDir, custom);
        expect(h.container.read(downloadDirProvider).path, custom);
        expect(shown(find.byKey(prompt)), isFalse);

        // And it is settled for good.
        await turnOffAndWait(tester, h);
        await tester.tap(find.byKey(rxSwitch));
        await tester.settleUntil(() => receiveOn(h), what: 'receive on again');
        expect(shown(find.byKey(prompt)), isFalse);
        await tester.stopApp(h);
      },
    );

    testWidgets('the same prompt comes from the Settings Receive card', (
      tester,
    ) async {
      final h = await create(tester, initialLocation: '/settings');
      await tester.startApp(h);
      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => shown(find.byKey(prompt)),
        what: 'the storage prompt in Settings',
      );
      expect(receiveOn(h), isFalse);
      await tester.tap(find.byKey(keep));
      await tester.settleUntil(() => receiveOn(h), what: 'receive on');
      await tester.stopApp(h);
    });
  });

  group('when the question does not apply', () {
    testWidgets('not on Android: Receive turns on straight away', (
      tester,
    ) async {
      final h = await create(tester, android: false);
      await tester.startApp(h);
      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => receiveOn(h) || shown(find.byKey(prompt)),
        what: 'receive on or the prompt',
      );
      expect(shown(find.byKey(prompt)), isFalse);
      expect(receiveOn(h), isTrue);
      await tester.stopApp(h);
    });

    testWidgets('a folder was already chosen: no prompt', (tester) async {
      final sandbox = Directory.systemTemp.createTempSync('ls_f3_prompt_');
      final custom = '${sandbox.path}/Download/Mine';
      Directory(custom).createSync(recursive: true);
      await tester.runAsync(
        () => AppSettingsStore(Directory('${sandbox.path}/support')).save(
          AppSettings(
            deviceId: const Uuid().v4(),
            alias: 'My phone',
            downloadDir: custom,
          ),
        ),
      );
      final h = await create(tester, sandbox: sandbox);
      await tester.startApp(h);
      expect(h.container.read(settingsProvider).downloadDir, custom);

      await tester.tap(find.byKey(rxSwitch));
      await tester.settleUntil(
        () => receiveOn(h) || shown(find.byKey(prompt)),
        what: 'receive on or the prompt',
      );
      expect(shown(find.byKey(prompt)), isFalse);
      expect(receiveOn(h), isTrue);
      await tester.stopApp(h);
    });

    testWidgets('on Android the default state alone shows nothing', (
      tester,
    ) async {
      final h = await create(tester);
      await tester.startApp(h);
      await tester.settle(ms: 100);
      expect(shown(find.byKey(prompt)), isFalse);
      expect(receiveOff(h), isTrue);
      await tester.stopApp(h);
    });
  });
}

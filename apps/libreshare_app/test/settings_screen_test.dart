import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/autostart/autostart_windows.dart';
import 'package:libreshare_app/platform/autostart/registry_access.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_app/services/app_settings_store.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/harness.dart';
import 'helpers/shell_fakes.dart';

Text textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key)));

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void main() {
  group('Settings screen', () {
    testWidgets('shows name, folder, port and the fingerprint placeholder', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);

      expect(textOf(tester, 'settings-name-value').data, 'Test-Laptop');
      expect(
        textOf(tester, 'settings-folder-value').data,
        h.defaultDownloads.path,
      );
      expect(
        textOf(tester, 'settings-port-value').data,
        contains('Not listening'),
      );
      expect(
        textOf(tester, 'settings-fingerprint-value').data,
        matches(RegExp(r'^([0-9A-F]{4} ){3}[0-9A-F]{4}$')),
      );

      await tester.stopApp(h);
    });

    testWidgets('the port line shows the bound port while receiving', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);
      await tester.runAsync(() => h.engine.receive.turnOn());
      await tester.settle();
      await tester.pump();

      expect(
        textOf(tester, 'settings-port-value').data,
        startsWith('Listening on port ${h.engine.port}'),
      );

      await tester.stopApp(h);
    });

    testWidgets('renaming saves to disk and rebuilds the engine', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('settings-name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('settings-name-field')),
        'Kirat Desktop',
      );
      await tester.tap(find.byKey(const Key('prompt-save')));
      await tester.settleUntil(
        () =>
            h.container.read(engineOrNullProvider)?.self.alias ==
            'Kirat Desktop',
        what: 'engine rebuilt with the new name',
      );

      expect(textOf(tester, 'settings-name-value').data, 'Kirat Desktop');
      final json = jsonDecode(
        File('${h.supportDir.path}/app_settings.json').readAsStringSync(),
      ) as Map<String, Object?>;
      expect(json['alias'], 'Kirat Desktop');

      await tester.stopApp(h);
    });

    testWidgets('an empty name is refused', (tester) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('settings-name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('settings-name-field')),
        '   ',
      );
      await tester.tap(find.byKey(const Key('prompt-save')));
      await tester.pump();

      expect(find.text('Enter a name.'), findsOneWidget);
      expect(h.container.read(settingsProvider).alias, 'Test-Laptop');

      await tester.stopApp(h);
    });

    testWidgets('the download folder can be changed and reset', (tester) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      final custom = '${h.sandbox.path}/MyFiles';
      h.picker.directory = custom;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('settings-folder')));
      await tester.settleUntil(
        () =>
            h.container.read(engineOrNullProvider)?.downloadDir.path == custom,
        what: 'engine uses the new folder',
      );
      expect(textOf(tester, 'settings-folder-value').data, custom);
      expect(find.byKey(const Key('settings-folder-reset')), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings-folder-reset')));
      await tester.settleUntil(
        () =>
            h.container.read(engineOrNullProvider)?.downloadDir.path ==
            h.defaultDownloads.path,
        what: 'engine back on the default folder',
      );
      expect(find.byKey(const Key('settings-folder-reset')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('the preferred port is validated and saved', (tester) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/settings',
          preferredPort: 53400,
        ),
      ))!;
      await tester.startApp(h);

      await tester.tap(find.byKey(const Key('settings-port')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('settings-port-field')),
        '80',
      );
      await tester.tap(find.byKey(const Key('prompt-save')));
      await tester.pump();
      expect(find.text('Enter a port from 1024 to 65535.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('settings-port-field')),
        '53420',
      );
      await tester.tap(find.byKey(const Key('prompt-save')));
      await tester.settleUntil(
        () => h.container.read(settingsProvider).preferredPort == 53420,
        what: 'port saved',
      );
      expect(textOf(tester, 'settings-port-value').data, contains('53420'));

      await tester.stopApp(h);
    });

    testWidgets('Contacts only is disabled with a "later update" note', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);

      final control = tester.widget<SegmentedButton<dynamic>>(
        find.byKey(const Key('visibility-control')),
      );
      final contacts = control.segments.firstWhere(
        (s) => (s.label! as Text).data == 'Contacts only',
      );
      expect(contacts.enabled, isFalse);
      expect(find.byKey(const Key('contacts-soon')), findsOneWidget);
      expect(find.textContaining('later update'), findsWidgets);

      await tester.stopApp(h);
    });

    testWidgets('the visibility control turns Receive on and off', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);
      final control = find.byKey(const Key('visibility-control'));
      await scrollTo(tester, control);

      await tester.tap(
        find.descendant(of: control, matching: find.text('Everyone')),
      );
      await tester.settleUntil(
        () => h.engine.receive.state is On,
        what: 'receive on',
      );
      expect(h.engine.isListening, isTrue);

      await tester.tap(
        find.descendant(of: control, matching: find.text('Off')),
      );
      await tester.settleUntil(
        () => h.engine.receive.state is Off,
        what: 'receive off',
      );
      expect(h.engine.isListening, isFalse);

      await tester.stopApp(h);
    });

    testWidgets('Start-with-system toggles the OS entry and is remembered', (
      tester,
    ) async {
      final autostart = FakeAutostart();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/settings',
          services: PlatformServices.fake(autostart: autostart),
        ),
      ))!;
      await tester.startApp(h);
      await scrollTo(tester, find.byKey(const Key('settings-autostart')));

      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('settings-autostart')))
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('settings-autostart')));
      await tester.settleUntil(() => autostart.enabled, what: 'autostart on');
      await tester.settleUntil(
        () => h.engine.receive.settings.autostart,
        what: 'receive settings remember it',
      );
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('settings-autostart')))
            .value,
        isTrue,
      );

      await tester.stopApp(h);
    });

    testWidgets('Start-with-system is hidden where the OS cannot do it', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/settings',
          services: PlatformServices.fake(
            autostart: FakeAutostart(supported: false),
          ),
        ),
      ))!;
      await tester.startApp(h);
      await tester.scrollUntilVisible(
        find.byKey(const Key('help-card')),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      expect(find.byKey(const Key('settings-autostart')), findsNothing);
      expect(find.byKey(const Key('settings-start-hidden')), findsNothing);

      await tester.stopApp(h);
    });

    testWidgets('a failed autostart write shows a message and the switch '
        'goes back', (tester) async {
      final autostart = FailingAutostart();
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/settings',
          services: servicesWithAutostart(autostart),
        ),
      ))!;
      await tester.startApp(h);
      await scrollTo(tester, find.byKey(const Key('settings-autostart')));

      await tester.tap(find.byKey(const Key('settings-autostart')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(autostart.attempts, 1);
      expect(find.text('Could not change this setting.'), findsOneWidget);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('settings-autostart')))
            .value,
        isFalse,
        reason: 'the OS state is what the switch shows',
      );
      // Nothing was remembered about a change that did not happen.
      expect(h.engine.receive.settings.autostart, isFalse);

      await tester.stopApp(h);
    });

    testWidgets('a failed switch-off leaves the switch on', (tester) async {
      final autostart = FailingAutostart(enabled: true);
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/settings',
          services: servicesWithAutostart(autostart),
        ),
      ))!;
      await tester.startApp(h);
      await scrollTo(tester, find.byKey(const Key('settings-autostart')));
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('settings-autostart')))
            .value,
        isTrue,
      );

      await tester.tap(find.byKey(const Key('settings-autostart')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Could not change this setting.'), findsOneWidget);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('settings-autostart')))
            .value,
        isTrue,
      );

      await tester.stopApp(h);
    });

    testWidgets('Windows: an entry the user disabled in Windows says so', (
      tester,
    ) async {
      // The Run value exists but Task Manager / Settings > Apps > Startup
      // recorded "disabled" (odd first byte) under StartupApproved.
      final registry = FakeRegistryAccess()
        ..writeString(
          WindowsAutostart.runKey,
          WindowsAutostart.valueName,
          r'"C:\Program Files\LibreShare\libreshare.exe" --hidden',
        )
        ..binaries[WindowsAutostart.startupApprovedKey.toLowerCase()] = {
          WindowsAutostart.valueName.toLowerCase(): Uint8List.fromList([
            3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
          ]),
        };
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/settings',
          services: servicesWithAutostart(
            WindowsAutostart(
              registry: registry,
              executable: r'C:\Program Files\LibreShare\libreshare.exe',
            ),
          ),
        ),
      ))!;
      await tester.startApp(h);
      await scrollTo(tester, find.byKey(const Key('settings-autostart')));

      expect(
        textOf(tester, 'autostart-os-disabled').data,
        'Disabled in Windows Startup settings.',
      );
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('settings-autostart')))
            .value,
        isFalse,
        reason: 'Windows will not start it, so the switch must not say on',
      );

      // The hint leads to the right Windows page.
      await tester.tap(find.text('Open Windows settings'));
      await tester.pump();
      expect(h.launcher.opened, ['ms-settings:startupapps']);

      await tester.stopApp(h);
    });

    testWidgets('Windows: an entry that is on shows no hint', (tester) async {
      final registry = FakeRegistryAccess()
        ..writeString(
          WindowsAutostart.runKey,
          WindowsAutostart.valueName,
          r'"C:\Program Files\LibreShare\libreshare.exe" --hidden',
        )
        ..binaries[WindowsAutostart.startupApprovedKey.toLowerCase()] = {
          WindowsAutostart.valueName.toLowerCase(): Uint8List.fromList([
            2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
          ]),
        };
      final h = (await tester.runAsync(
        () => AppHarness.create(
          initialLocation: '/settings',
          services: servicesWithAutostart(
            WindowsAutostart(
              registry: registry,
              executable: r'C:\Program Files\LibreShare\libreshare.exe',
            ),
          ),
        ),
      ))!;
      await tester.startApp(h);
      await scrollTo(tester, find.byKey(const Key('settings-autostart')));

      expect(find.byKey(const Key('autostart-os-disabled')), findsNothing);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('settings-autostart')))
            .value,
        isTrue,
      );

      await tester.stopApp(h);
    });

    testWidgets('the Start minimized switch is saved', (tester) async {
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.startApp(h);
      await scrollTo(tester, find.byKey(const Key('settings-start-hidden')));
      expect(h.engine.receive.settings.startHidden, isTrue);

      bool switchValue() => tester
          .widget<SwitchListTile>(
            find.byKey(const Key('settings-start-hidden')),
          )
          .value;
      expect(switchValue(), isTrue);

      await tester.tap(find.byKey(const Key('settings-start-hidden')));
      await tester.settleUntil(() => !switchValue(), what: 'switch off');
      expect(h.engine.receive.settings.startHidden, isFalse);

      await tester.stopApp(h);
    });

    testWidgets('"Can\'t see devices?" explains and runs a scan', (
      tester,
    ) async {
      tester.useTallSurface();
      final h = (await tester.runAsync(
        () => AppHarness.create(initialLocation: '/settings'),
      ))!;
      await tester.runAsync(() => h.startPeer('Pixel 8'));
      await tester.startApp(h);
      await scrollTo(tester, find.byKey(const Key('help-card')));

      await tester.tap(find.text("Can't see devices?"));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('help-body')), findsOneWidget);
      expect(
        find.textContaining('AP / client isolation').evaluate().isEmpty,
        isTrue,
      );
      expect(find.textContaining('isolates devices'), findsOneWidget);
      expect(
        find.textContaining('sudo ufw allow 53318:53327/tcp'),
        findsOneWidget,
      );

      await scrollTo(tester, find.byKey(const Key('help-scan')));
      await tester.tap(find.byKey(const Key('help-scan')));
      await tester.settleUntil(
        () => find.byKey(const Key('help-result')).evaluate().isNotEmpty,
        what: 'scan result',
      );
      expect(textOf(tester, 'help-result').data, '1 device found.');

      await tester.stopApp(h);
    });
  });

  group('Persistence', () {
    testWidgets('name, folder, port and Receive settings survive a restart', (
      tester,
    ) async {
      final sandbox = Directory.systemTemp.createTempSync('ls_persist_');
      addTearDown(() {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });

      var h = (await tester.runAsync(
        () => AppHarness.create(reuseSandbox: sandbox),
      ))!;
      await tester.startApp(h);
      final id = h.container.read(settingsProvider).deviceId;
      await tester.runAsync(() async {
        final s = h.container.read(settingsProvider.notifier);
        await s.setAlias('Persisted');
        await s.setDownloadDir('${sandbox.path}/inbox');
        await s.setPreferredPort(0);
      });
      // Each change rebuilds the engine; wait for the one that has all of them
      // (the engine is null while one is starting).
      await tester.settleUntil(() {
        final e = h.container.read(engineOrNullProvider);
        return e != null &&
            e.self.alias == 'Persisted' &&
            e.downloadDir.path == '${sandbox.path}/inbox';
      }, what: 'engine rebuilt');
      // Change the Receive setting on the new engine, then stop for good.
      await tester.runAsync(
        () => h.engine.receive.updateSettings(
          h.engine.receive.settings.copyWith(startHidden: false),
        ),
      );
      await tester.stopApp(h, deleteSandbox: false);

      // "Restart": a new app on the same data directories.
      h = (await tester.runAsync(
        () => AppHarness.create(reuseSandbox: sandbox),
      ))!;
      await tester.startApp(h);
      expect(h.container.read(settingsProvider).deviceId, id);
      expect(h.engine.self.alias, 'Persisted');
      expect(h.engine.self.deviceId, id);
      expect(h.engine.downloadDir.path, '${sandbox.path}/inbox');
      expect(h.engine.receive.settings.startHidden, isFalse);
      await tester.stopApp(h);
    });

    test('AppSettingsStore round-trips and keeps the device id', () async {
      final dir = Directory.systemTemp.createTempSync('ls_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = AppSettingsStore(dir);

      final first = await store.loadOrCreate(defaultAlias: 'Box');
      expect(first.alias, 'Box');
      expect(first.downloadDir, isNull);
      expect(first.preferredPort, kDefaultPort);

      await store.save(
        first.copyWith(
          alias: 'Renamed',
          downloadDir: '/x/y',
          preferredPort: 53444,
        ),
      );
      final again = await AppSettingsStore(dir)
          .loadOrCreate(defaultAlias: 'Other');
      expect(again.deviceId, first.deviceId);
      expect(again.alias, 'Renamed');
      expect(again.downloadDir, '/x/y');
      expect(again.preferredPort, 53444);
      expect(File('${dir.path}/app_settings.json.tmp').existsSync(), isFalse);
    });

    test('a corrupt settings file falls back to defaults', () async {
      final dir = Directory.systemTemp.createTempSync('ls_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/app_settings.json').writeAsStringSync('{not json');

      final s = await AppSettingsStore(dir).loadOrCreate(defaultAlias: 'Fresh');
      expect(s.alias, 'Fresh');
      expect(s.deviceId.length, greaterThanOrEqualTo(32));
      expect(s.preferredPort, kDefaultPort);
    });

    test('out-of-range or wrongly typed members are ignored', () async {
      final dir = Directory.systemTemp.createTempSync('ls_store_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/app_settings.json').writeAsStringSync(
        jsonEncode({
          'deviceId': 'abcdef0123456789',
          'alias': 42,
          'preferredPort': 99999,
          'downloadDir': '',
        }),
      );
      final s = await AppSettingsStore(dir).loadOrCreate(defaultAlias: 'Fresh');
      expect(s.deviceId, 'abcdef0123456789');
      expect(s.alias, 'Fresh');
      expect(s.preferredPort, kDefaultPort);
      expect(s.downloadDir, isNull);
    });
  });
}

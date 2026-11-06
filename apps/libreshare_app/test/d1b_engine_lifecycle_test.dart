// D1 round-2 (docs/plans/d1-fixes.md): engine start-up behaviour.
//   S4  a settings change while a build is in flight leaves at most one engine
//       running, with the NEW policy; the stale build's port and lock are freed
//   S5  Fixed mode without a usable stored PIN falls back to Window mode
//   S6  a lost security key has its own message and creates no new identity
//   S9  identity id differs from the settings id: start with the stored id,
//       no uncaught error, at most two builds
// Observed through the UI (keys / visible texts), the engine's public API and
// the OS (listening ports on the loopback alias); no new Dart symbols.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/providers/engine_provider.dart';
import 'package:libreshare_app/providers/settings_provider.dart';
import 'package:libreshare_core/libreshare_core.dart';

import 'helpers/d1b_helpers.dart';
import 'helpers/harness.dart';

/// Multicast lock whose FIRST acquire() waits for [gate].
class GateLock implements MulticastLockService {
  final Completer<void> gate = Completer<void>();
  int acquires = 0;
  int releases = 0;

  @override
  Future<void> acquire() async {
    acquires++;
    if (acquires == 1) await gate.future;
  }

  @override
  Future<void> release() async {
    releases++;
  }
}

PlatformServices servicesWith(MulticastLockService lock) {
  final base = PlatformServices.fake();
  return PlatformServices(
    autostart: base.autostart,
    tray: base.tray,
    window: base.window,
    multicastLock: lock,
    environment: base.environment,
  );
}

const String appIp = '127.0.0.2'; // the harness' bind address

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S4 a settings change during a build', () {
    test('stale build (lock blocked): one engine left, NEW policy, stale port and lock released', () async {
      final lock = GateLock();
      final h = await AppHarness.create(
        services: servicesWith(lock),
        initialMode: const ReceiveAlways(),
      );
      var disposed = false;
      addTearDown(() async {
        if (!disposed) await h.dispose();
      });
      final sub = h.container.listen(engineProvider, (_, _) {});
      addTearDown(sub.close);
      await waitForReal(() => lock.acquires >= 1);
      expect(lock.acquires, 1, reason: 'build 1 reached the lock');

      await h.container
          .read(settingsProvider.notifier)
          .setPinMode(PinMode.window);
      await waitForReal(() => lock.acquires >= 2);
      lock.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      final value = h.container.read(engineProvider);
      expect(value.hasValue, isTrue, reason: 'the second build succeeded');
      final engine = value.requireValue;
      expect(
        engine.pinGuard?.policy.mode,
        PinMode.window,
        reason: 'S4: the running engine has the NEW policy',
      );
      expect(engine.isStarted, isTrue, reason: 'S4: the live engine runs');
      if (kHasProcNet) {
        expect(listeningPorts(appIp), {
          engine.port,
        }, reason: 'S4: no stale engine listens; only the live one does');
      }
      final notifier = h.container.read(engineProvider.notifier);
      h.container.dispose();
      disposed = true;
      await notifier.closed;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        lock.releases,
        lock.acquires,
        reason: 'S4: every multicast lock taken was released',
      );
      if (kHasProcNet) {
        expect(
          listeningPorts(appIp),
          isEmpty,
          reason: 'S4: nothing listens after shutdown',
        );
      }
      try {
        h.sandbox.deleteSync(recursive: true);
      } on Object {
        // best effort
      }
    }, timeout: kSixtySeconds);

    test('negative twin: a change after the build finished: one engine, new policy, ports and locks balanced', () async {
      final lock = GateLock()..gate.complete();
      final h = await AppHarness.create(
        services: servicesWith(lock),
        initialMode: const ReceiveAlways(),
      );
      var disposed = false;
      addTearDown(() async {
        if (!disposed) await h.dispose();
      });
      await h.boot();
      expect(engineModeOf(h), PinMode.off);
      if (kHasProcNet) {
        expect(listeningPorts(appIp), {h.engine.port});
      }
      await h.container
          .read(settingsProvider.notifier)
          .setPinMode(PinMode.window);
      await h.container.read(engineProvider.future);
      await waitForReal(() => engineModeOf(h) == PinMode.window);
      expect(engineModeOf(h), PinMode.window);
      if (kHasProcNet) {
        expect(listeningPorts(appIp), {h.engine.port});
      }
      final notifier = h.container.read(engineProvider.notifier);
      h.container.dispose();
      disposed = true;
      await notifier.closed;
      expect(lock.releases, lock.acquires);
      try {
        h.sandbox.deleteSync(recursive: true);
      } on Object {
        // best effort
      }
    }, timeout: kSixtySeconds);
  });

  group('S5 Fixed mode without a usable stored PIN falls back to Window', () {
    Future<Directory> sandboxFor(WidgetTester tester, String variant) async {
      final sandbox = (await tester.runAsync(() async {
        final s = await seedSandbox(
          mode: PinMode.fixed,
          pin: variant == 'abc'
              ? 'abc'
              : (variant == 'flipped' || variant == 'unreadable'
                    ? kSeedPin
                    : null),
        );
        return s;
      }))!;
      final slot = appPinFile(Directory(pj(sandbox.path, 'support')));
      switch (variant) {
        case 'flipped':
          final b = Uint8List.fromList(slot.readAsBytesSync());
          b[10] = b[10] ^ 0x01;
          slot.writeAsBytesSync(b);
        case 'directory':
          slot.createSync(recursive: true);
          slot.deleteSync();
          Directory(slot.path).createSync();
        case 'unreadable':
          Process.runSync('chmod', ['000', slot.path]);
          addTearDown(() => Process.runSync('chmod', ['600', slot.path]));
      }
      return sandbox;
    }

    for (final variant in const [
      'missing',
      'abc',
      'flipped',
      'directory',
      'unreadable',
    ]) {
      testWidgets(
        'case "$variant": the engine builds in Window mode, Settings shows the notice and the PIN input',
        (tester) async {
          tester.useTallSurface();
          final sandbox = await sandboxFor(tester, variant);
          final h = (await tester.runAsync(
            () => AppHarness.create(
              reuseSandbox: sandbox,
              initialLocation: '/settings',
            ),
          ))!;
          await bootApp(tester, h);
          final guard = h.engine.pinGuard;
          expect(guard, isNotNull);
          expect(
            guard!.policy.mode,
            PinMode.window,
            reason: 'S5: never a hidden random Fixed PIN',
          );
          expect(guard.enforced, isTrue);
          expect(guard.currentPin, matches(RegExp(r'^[0-9]{6}$')));
          expect(
            find.byKey(const Key('settings-pin-selector')),
            findsOneWidget,
            reason: 'Settings is reachable',
          );
          expect(find.text(kPinNeedsReset), findsOneWidget);
          expect(find.byKey(const Key('settings-pin-input')), findsOneWidget);
          expect(find.text('PIN configured'), findsNothing);
          if (variant == 'unreadable') {
            Process.runSync('chmod', ['600', appPinFile(h.supportDir).path]);
          }
          await tester.stopApp(h);
        },
        timeout: kSixtySeconds,
      );
    }

    testWidgets(
      'the temporary PIN is shown on the Receive card (case "missing")',
      (tester) async {
        tester.useTallSurface();
        final sandbox = await sandboxFor(tester, 'missing');
        final h = (await tester.runAsync(
          () => AppHarness.create(
            reuseSandbox: sandbox,
            initialLocation: '/settings',
          ),
        ))!;
        await bootApp(tester, h);
        await tester.tap(find.byKey(const Key('receive-switch')));
        await tester.settleUntil(
          () => shown(find.byKey(const Key('receive-pin'))),
          what: 'the temporary PIN on the Receive card',
        );
        expect(
          find.text('PIN: ${h.engine.pinGuard!.currentPin}'),
          findsOneWidget,
        );
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'recovery: setting a new PIN ends the fallback (Fixed enforced, notice gone)',
      (tester) async {
        tester.useTallSurface();
        final sandbox = await sandboxFor(tester, 'missing');
        final h = (await tester.runAsync(
          () => AppHarness.create(
            reuseSandbox: sandbox,
            initialLocation: '/settings',
          ),
        ))!;
        await bootApp(tester, h);
        expect(find.text(kPinNeedsReset), findsOneWidget);
        await saveFixed(tester, '654321');
        await waitFor(
          tester,
          () => engineOf(h)?.pinGuard?.currentPin == '654321',
          maxRounds: 150,
        );
        expect(engineOf(h)!.pinGuard!.policy.mode, PinMode.fixed);
        expect(engineOf(h)!.pinGuard!.currentPin, '654321');
        expect(find.text(kPinNeedsReset), findsNothing);
        expect(await storedPin(tester, h.supportDir), '654321');
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: a valid stored PIN keeps Fixed mode and shows no notice',
      (tester) async {
        tester.useTallSurface();
        final sandbox = (await tester.runAsync(
          () => seedSandbox(mode: PinMode.fixed, pin: kSeedPin),
        ))!;
        final h = (await tester.runAsync(
          () => AppHarness.create(
            reuseSandbox: sandbox,
            initialLocation: '/settings',
          ),
        ))!;
        await bootApp(tester, h);
        expect(h.engine.pinGuard!.policy.mode, PinMode.fixed);
        expect(h.engine.pinGuard!.currentPin, kSeedPin);
        expect(find.text(kPinNeedsReset), findsNothing);
        await tester.stopApp(h);
      },
      timeout: kSixtySeconds,
    );
  });

  group('S6 start failure messages', () {
    Future<(Directory, Map<String, List<int>>)> damagedKeySandbox(
      WidgetTester tester,
    ) async {
      final out = await tester.runAsync(() async {
        final h1 = await AppHarness.create();
        await h1.boot();
        await h1.dispose(deleteSandbox: false);
        final sec = Directory(pj(h1.supportDir.path, 'security'));
        for (final f in sec.listSync().whereType<File>()) {
          if (f.path.endsWith('.secret')) {
            f.writeAsStringSync('corrupt-private-key-bytes');
          }
        }
        final snap = <String, List<int>>{
          for (final f in sec.listSync().whereType<File>())
            baseName(f.path): f.readAsBytesSync(),
        };
        return (h1.sandbox, snap);
      });
      return out!;
    }

    testWidgets(
      'a lost security key: own message ("security key", not "data folder"), no new identity, no secrets in logs',
      (tester) async {
        tester.useTallSurface();
        final (sandbox, before) = await damagedKeySandbox(tester);
        expect(before.keys, contains('identity.json'));
        final logs = LogCapture();
        addTearDown(logs.stop);
        final h = (await tester.runAsync(
          () => AppHarness.create(reuseSandbox: sandbox),
        ))!;
        await showAppUnbooted(tester, h);
        await tester.settleUntil(
          () => shown(find.byKey(const Key('engine-failed'))),
          what: 'the start-failed page',
        );
        final text = tester
            .widget<Text>(find.byKey(const Key('engine-failed')))
            .data!;
        expect(
          text,
          contains('security key'),
          reason: 'S6: IdentityLostException has its own message',
        );
        expect(text, isNot(contains('data folder')));
        final sec = Directory(pj(h.supportDir.path, 'security'));
        final after = <String, List<int>>{
          for (final f in sec.listSync().whereType<File>())
            baseName(f.path): f.readAsBytesSync(),
        };
        expect(
          after.keys.toSet(),
          before.keys.toSet(),
          reason: 'S6: no automatic new identity (no new files)',
        );
        for (final name in before.keys) {
          expect(
            after[name],
            before[name],
            reason: 'S6: $name must be byte-identical',
          );
        }
        expect(
          logs.lines.where((l) => RegExp(r'[0-9a-fA-F]{64}').hasMatch(l)),
          isEmpty,
          reason: 'no key or fingerprint-sized hex in logs',
        );
        expect(logs.contains('corrupt-private-key-bytes'), isFalse);
        logs.stop();
        await tester.runAsync(() => h.dispose());
      },
      timeout: kSixtySeconds,
    );

    testWidgets(
      'negative twin: any other start failure keeps the "data folder" message',
      (tester) async {
        tester.useTallSurface();
        final sandbox = (await tester.runAsync(seedSandbox))!;
        // "security" is a regular file: the directory cannot be created.
        File(pj(sandbox.path, 'support', 'security'))
            .writeAsStringSync('not a directory');
        final h = (await tester.runAsync(
          () => AppHarness.create(reuseSandbox: sandbox),
        ))!;
        await showAppUnbooted(tester, h);
        await tester.settleUntil(
          () => shown(find.byKey(const Key('engine-failed'))),
          what: 'the start-failed page',
        );
        final text = tester
            .widget<Text>(find.byKey(const Key('engine-failed')))
            .data!;
        expect(text, contains('data folder'));
        expect(text, isNot(contains('security key')));
        await tester.runAsync(() => h.dispose());
      },
      timeout: kSixtySeconds,
    );
  });

  group('S9 identity id differs from the settings id', () {
    const stored = 'd1b-stored-identity-A1';
    const other = 'd1b-settings-device-B2';

    Future<(AppHarness, List<Object>, int Function())> boot(
      Directory sandbox,
    ) async {
      final errors = <Object>[];
      var loading = 0;
      late AppHarness h;
      await runZonedGuarded(() async {
        h = await AppHarness.create(
          reuseSandbox: sandbox,
          initialMode: const ReceiveAlways(),
        );
        h.container.listen<AsyncValue<LibreShareEngine>>(engineProvider, (
          _,
          next,
        ) {
          if (next.isLoading) loading++;
        }, fireImmediately: true);
        await h.boot();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await h.container.read(engineProvider.future);
      }, (e, _) => errors.add(e));
      return (h, errors, () => loading);
    }

    test('the engine starts with the stored id, settings follow it, no uncaught error, at most two builds, one port', () async {
      final sandbox = await seedSandbox(
        deviceId: other,
        identityDeviceId: stored,
      );
      final (h, errors, builds) = await boot(sandbox);
      addTearDown(() => h.dispose());
      expect(errors, isEmpty, reason: 'S9: no uncaught zone error');
      expect(h.engine.self.deviceId, stored);
      expect(h.container.read(settingsProvider).deviceId, stored);
      expect(builds(), lessThanOrEqualTo(2), reason: 'S9: at most two builds');
      if (kHasProcNet) {
        expect(listeningPorts(appIp), {h.engine.port});
      }
      await waitForReal(
        () =>
            File(pj(h.supportDir.path, 'app_settings.json'))
                .readAsStringSync()
                .contains(stored),
      );
      expect(
        File(pj(h.supportDir.path, 'app_settings.json')).readAsStringSync(),
        contains(stored),
      );
    }, timeout: kSixtySeconds);

    test('the settings file cannot be written (read-only folder): still the stored id, no uncaught error, at most two builds', () async {
      final sandbox = await seedSandbox(
        deviceId: other,
        identityDeviceId: stored,
      );
      final support = Directory(pj(sandbox.path, 'support'));
      // Read-only AFTER the settings were loaded; the security folder keeps
      // its own mode, so only the settings save fails.
      final errors = <Object>[];
      var loading = 0;
      late AppHarness h;
      await runZonedGuarded(() async {
        h = await AppHarness.create(
          reuseSandbox: sandbox,
          initialMode: const ReceiveAlways(),
        );
        Process.runSync('chmod', ['500', support.path]);
        h.container.listen<AsyncValue<LibreShareEngine>>(engineProvider, (
          _,
          next,
        ) {
          if (next.isLoading) loading++;
        }, fireImmediately: true);
        await h.boot();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await h.container.read(engineProvider.future);
      }, (e, _) => errors.add(e));
      addTearDown(() => h.dispose());
      addTearDown(() => Process.runSync('chmod', ['700', support.path]));
      expect(
        errors,
        isEmpty,
        reason: 'S9: a failing settings save is caught, not uncaught',
      );
      expect(h.engine.self.deviceId, stored);
      expect(loading, lessThanOrEqualTo(2));
      if (kHasProcNet) {
        expect(listeningPorts(appIp), {h.engine.port});
      }
      Process.runSync('chmod', ['700', support.path]);
    }, timeout: kSixtySeconds);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/platform_log.dart';
import 'package:libreshare_app/platform/tray/linux_tray_host_probe.dart';
import 'package:libreshare_app/platform/tray/tray_service_impl.dart';

class FakeTrayDriver implements TrayDriver {
  bool supported = true;
  Object? supportedThrows;
  Object? createFailure;
  Object? updateFailure;
  final List<TrayMenuModel> created = [];
  final List<TrayMenuModel> updates = [];
  int destroyCalls = 0;
  TrayCallbacks? callbacks;

  @override
  bool get isSupported {
    final failure = supportedThrows;
    if (failure != null) throw failure;
    return supported;
  }

  @override
  Future<void> create(TrayMenuModel model, TrayCallbacks callbacks) async {
    final failure = createFailure;
    if (failure != null) throw failure;
    created.add(model);
    this.callbacks = callbacks;
  }

  @override
  Future<void> update(TrayMenuModel model) async {
    final failure = updateFailure;
    if (failure != null) throw failure;
    updates.add(model);
  }

  @override
  Future<void> destroy() async => destroyCalls++;
}

class FakeProbe implements TrayHostProbe {
  FakeProbe({this.present = true, this.polling = true});
  bool present;
  bool polling;
  int checks = 0;
  bool disposed = false;

  @override
  Future<bool> isHostPresent() async {
    checks++;
    return present;
  }

  @override
  bool get needsPolling => polling;

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late FakeTrayDriver driver;
  late FakeProbe probe;
  late TrayServiceImpl tray;
  late List<String> calls;

  Future<void> init() => tray.init(
    onOpen: () => calls.add('open'),
    onToggleReceive: () => calls.add('toggle'),
    onQuit: () => calls.add('quit'),
  );

  setUp(() {
    driver = FakeTrayDriver();
    probe = FakeProbe();
    calls = [];
    // Manual polling only.
    tray = TrayServiceImpl(driver: driver, probe: probe, pollInterval: null);
  });

  tearDown(() async {
    await tray.dispose();
    PlatformLog.sink = null;
  });

  group('TrayMenuModel', () {
    test('idle and receiving presentations', () {
      const idle = TrayMenuModel(receiving: false, tooltip: '');
      expect(idle.statusLabel, 'Not receiving');
      expect(idle.toggleLabel, 'Turn Receive on');
      expect(idle.iconAsset, 'assets/tray/tray_idle.png');

      const on = TrayMenuModel(
        receiving: true,
        tooltip: 'Receiving - visible to everyone',
      );
      expect(on.statusLabel, 'Receiving - visible to everyone');
      expect(on.toggleLabel, 'Turn Receive off');
      expect(on.iconAsset, 'assets/tray/tray_active.png');
      expect(TrayMenuModel.openLabel, 'Open LibreShare');
      expect(TrayMenuModel.quitLabel, 'Quit');
    });

    test('value equality', () {
      expect(
        const TrayMenuModel(receiving: true, tooltip: 'a'),
        const TrayMenuModel(receiving: true, tooltip: 'a'),
      );
      expect(
        const TrayMenuModel(receiving: true, tooltip: 'a'),
        isNot(const TrayMenuModel(receiving: false, tooltip: 'a')),
      );
    });
  });

  group('availability', () {
    test('not available before init', () {
      expect(tray.isAvailable, isFalse);
    });

    test('host present: icon created, available, change announced', () async {
      final changes = <bool>[];
      tray.availabilityChanges.listen(changes.add);
      await init();
      await pumpEventQueue();
      expect(tray.isAvailable, isTrue);
      expect(driver.created, hasLength(1));
      expect(driver.created.single.receiving, isFalse);
      expect(changes, [true]);
    });

    test('unsupported driver: no probe, no icon, no throw', () async {
      driver.supported = false;
      await init();
      expect(tray.isAvailable, isFalse);
      expect(probe.checks, 0);
      expect(driver.created, isEmpty);
    });

    test(
      'a driver whose native library is missing is treated as unsupported',
      () async {
        driver.supportedThrows = ArgumentError('Failed to lookup symbol');
        await init(); // must not throw
        expect(tray.isAvailable, isFalse);
        expect(driver.created, isEmpty);
      },
    );

    test('no tray host (GNOME without the extension): unavailable until one appears', () async {
      probe.present = false;
      final changes = <bool>[];
      tray.availabilityChanges.listen(changes.add);
      await init();
      expect(tray.isAvailable, isFalse);
      expect(driver.created, isEmpty);

      probe.present = true;
      await tray.checkHostNow();
      await pumpEventQueue();
      expect(tray.isAvailable, isTrue);
      expect(driver.created, hasLength(1));
      expect(changes, [true]);
    });

    test(
      'the host disappearing removes the icon and flips availability',
      () async {
        await init();
        final changes = <bool>[];
        tray.availabilityChanges.listen(changes.add);
        probe.present = false;
        await tray.checkHostNow();
        await pumpEventQueue();
        expect(tray.isAvailable, isFalse);
        expect(driver.destroyCalls, 1);
        expect(changes, [false]);

        // ... and coming back creates a fresh icon (the old registration is gone).
        probe.present = true;
        await tray.checkHostNow();
        expect(tray.isAvailable, isTrue);
        expect(driver.created, hasLength(2));
      },
    );

    test('repeated checks with an unchanged host do nothing', () async {
      await init();
      await tray.checkHostNow();
      await tray.checkHostNow();
      expect(driver.created, hasLength(1));
      expect(driver.destroyCalls, 0);
    });

    test(
      'icon creation failure is logged, cleaned up and never thrown',
      () async {
        final logs = <PlatformLogLevel>[];
        PlatformLog.sink = (_, level, _, _) => logs.add(level);
        driver.createFailure = StateError('no D-Bus');
        await init();
        expect(tray.isAvailable, isFalse);
        expect(driver.destroyCalls, 1);
        expect(logs, contains(PlatformLogLevel.warning));
      },
    );

    test(
      'polls the probe on a timer only when the probe asks for it',
      () async {
        probe.present = false;
        final polled = TrayServiceImpl(
          driver: driver,
          probe: probe,
          pollInterval: const Duration(milliseconds: 20),
        );
        await polled.init(onOpen: () {}, onToggleReceive: () {}, onQuit: () {});
        probe.present = true;
        await polled.availabilityChanges
            .firstWhere((a) => a)
            .timeout(const Duration(seconds: 3));
        expect(polled.isAvailable, isTrue);
        await polled.dispose();

        final still = FakeProbe(present: false, polling: false);
        final noPoll = TrayServiceImpl(
          driver: driver,
          probe: still,
          pollInterval: const Duration(milliseconds: 10),
        );
        await noPoll.init(onOpen: () {}, onToggleReceive: () {}, onQuit: () {});
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(still.checks, 1, reason: 'init only; no timer for static hosts');
        await noPoll.dispose();
      },
    );

    test('init is idempotent', () async {
      await init();
      await init();
      expect(driver.created, hasLength(1));
      expect(probe.checks, 1);
    });
  });

  group('status', () {
    test('setStatus updates the icon, tooltip and menu in place', () async {
      await init();
      await tray.setStatus(
        receiving: true,
        tooltip: 'Receiving - visible to everyone',
      );
      expect(driver.updates, hasLength(1));
      expect(driver.updates.single.receiving, isTrue);
      expect(driver.updates.single.tooltip, 'Receiving - visible to everyone');

      // The same status again is a no-op.
      await tray.setStatus(
        receiving: true,
        tooltip: 'Receiving - visible to everyone',
      );
      expect(driver.updates, hasLength(1));
    });

    test(
      'a status set before the icon exists is applied when it appears',
      () async {
        probe.present = false;
        await init();
        await tray.setStatus(receiving: true, tooltip: 'Receiving');
        expect(driver.updates, isEmpty);

        probe.present = true;
        await tray.checkHostNow();
        expect(driver.created.single.receiving, isTrue);
        expect(driver.created.single.tooltip, 'Receiving');
      },
    );

    test('setStatus without a tray is a silent no-op', () async {
      driver.supported = false;
      await init();
      await tray.setStatus(receiving: true, tooltip: 'x');
      expect(driver.updates, isEmpty);
    });

    test('a failing update never throws', () async {
      await init();
      driver.updateFailure = StateError('native gone');
      await tray.setStatus(receiving: true, tooltip: 'x'); // must not throw
      expect(tray.isAvailable, isTrue);
    });
  });

  group('menu callbacks', () {
    test('Open / Receive / Quit reach the app', () async {
      await init();
      driver.callbacks!.onOpen();
      driver.callbacks!.onToggleReceive();
      driver.callbacks!.onQuit();
      expect(calls, ['open', 'toggle', 'quit']);
    });

    test(
      'an app handler that throws does not escape into the native layer',
      () async {
        await tray.init(
          onOpen: () => throw StateError('ui bug'),
          onToggleReceive: () {},
          onQuit: () {},
        );
        driver.callbacks!.onOpen(); // must not throw
      },
    );
  });

  group('dispose', () {
    test('destroys the icon, disposes the probe, closes the stream; later calls are safe', () async {
      await init();
      var closed = false;
      tray.availabilityChanges.listen((_) {}, onDone: () => closed = true);

      await tray.dispose();
      await tray.dispose();
      await pumpEventQueue();

      expect(tray.isAvailable, isFalse);
      expect(driver.destroyCalls, greaterThanOrEqualTo(1));
      expect(probe.disposed, isTrue);
      expect(closed, isTrue);
      await tray.setStatus(receiving: true, tooltip: 'x'); // no throw
      await tray.checkHostNow();
      expect(driver.created, hasLength(1));
    });
  });

  group('LinuxTrayHostProbe', () {
    test('true when any StatusNotifierWatcher name has an owner', () async {
      final asked = <String>[];
      final probe = LinuxTrayHostProbe(
        nameHasOwner: (name) async {
          asked.add(name);
          return name == 'com.canonical.StatusNotifierWatcher';
        },
      );
      expect(await probe.isHostPresent(), isTrue);
      expect(asked, [
        'org.kde.StatusNotifierWatcher',
        'com.canonical.StatusNotifierWatcher',
      ]);
      expect(probe.needsPolling, isTrue);
    });

    test('false on a default GNOME session (no watcher)', () async {
      final probe = LinuxTrayHostProbe(nameHasOwner: (_) async => false);
      expect(await probe.isHostPresent(), isFalse);
    });

    test('stops at the first owner', () async {
      final asked = <String>[];
      final probe = LinuxTrayHostProbe(
        nameHasOwner: (name) async {
          asked.add(name);
          return true;
        },
      );
      expect(await probe.isHostPresent(), isTrue);
      expect(asked, ['org.kde.StatusNotifierWatcher']);
    });

    test('a broken session bus means "no host", never an exception', () async {
      final probe = LinuxTrayHostProbe(
        nameHasOwner: (_) => throw StateError('no session bus'),
      );
      expect(await probe.isHostPresent(), isFalse);
      expect(await probe.isHostPresent(), isFalse);
      await probe.dispose();
    });

    test('custom watcher names are honoured', () async {
      final asked = <String>[];
      final probe = LinuxTrayHostProbe(
        watcherNames: const ['x.Y'],
        nameHasOwner: (n) async {
          asked.add(n);
          return false;
        },
      );
      await probe.isHostPresent();
      expect(asked, ['x.Y']);
    });

    test('AlwaysPresentTrayHost (Windows/macOS) never needs polling', () async {
      const probe = AlwaysPresentTrayHost();
      expect(await probe.isHostPresent(), isTrue);
      expect(probe.needsPolling, isFalse);
      await probe.dispose();
    });
  });
}

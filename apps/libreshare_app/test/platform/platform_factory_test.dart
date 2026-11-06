import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/android/multicast_lock_android.dart';
import 'package:libreshare_app/platform/autostart/autostart_common.dart';
import 'package:libreshare_app/platform/autostart/autostart_linux.dart';
import 'package:libreshare_app/platform/autostart/autostart_none.dart';
import 'package:libreshare_app/platform/autostart/autostart_windows.dart';
import 'package:libreshare_app/platform/bonsoir_mdns_backend.dart';
import 'package:libreshare_app/platform/environment/polling_network_environment.dart';
import 'package:libreshare_app/platform/noop_platform.dart';
import 'package:libreshare_app/platform/platform_factory.dart';
import 'package:libreshare_app/platform/platform_services.dart';
import 'package:libreshare_app/platform/tray/tray_service_impl.dart';

class SelfHealingFake extends FakeAutostart implements SelfHealingAutostart {
  SelfHealingFake(this.log);
  int heals = 0;
  final List<String> log;

  @override
  Future<bool> selfHeal() async {
    heals++;
    log.add('heal');
    return true;
  }
}

class LoggingTray extends FakeTray {
  LoggingTray(this.log, {super.available});
  final List<String> log;
  @override
  Future<void> init({
    required void Function() onOpen,
    required void Function() onToggleReceive,
    required void Function() onQuit,
  }) async {
    log.add('tray.init');
    onOpen();
  }
}

class LoggingWindow extends FakeWindow {
  LoggingWindow(this.log);
  final List<String> log;
  bool? lastStartHidden;
  bool? lastHasTray;
  @override
  Future<void> init({required bool startHidden, required bool hasTray}) async {
    log.add('window.init');
    lastStartHidden = startHidden;
    lastHasTray = hasTray;
    await super.init(startHidden: startHidden, hasTray: hasTray);
  }

  @override
  Future<void> show() async {
    log.add('window.show');
    await super.show();
  }
}

void main() {
  group('adapter selection', () {
    test(
      'Linux: XDG autostart, tray + window controller, unlimited window',
      () {
        final s = createPlatformServicesFor(PlatformKind.linux);
        expect(s.autostart, isA<LinuxAutostart>());
        expect(s.tray, isA<TrayServiceImpl>());
        expect(s.window, isA<WindowControllerImpl>());
        expect(s.multicastLock, isA<NoopMulticastLock>());
        expect(s.environment, isA<PollingNetworkEnvironment>());
        expect(s.mdns, isA<BonsoirMdnsBackend>());
        expect(s.caps.maxContinuous, isNull);
        expect(s.caps.resumeAfterCrash, isTrue);
        expect(s.tray.isAvailable, isFalse, reason: 'nothing runs before init');
      },
    );

    test('Windows: registry autostart', () {
      final s = createPlatformServicesFor(PlatformKind.windows);
      expect(s.autostart, isA<WindowsAutostart>());
      expect(s.tray, isA<TrayServiceImpl>());
      expect(s.window, isA<WindowControllerImpl>());
      expect(s.caps.maxContinuous, isNull);
    });

    test(
      'Android: multicast lock, no tray/autostart, 6 h cap, no crash resume',
      () {
        final s = createPlatformServicesFor(PlatformKind.android);
        expect(s.autostart.isSupported, isFalse);
        expect(s.autostart, isA<NoAutostart>());
        expect(s.tray, isA<NoopTrayService>());
        expect(s.window, isA<NoopWindowController>());
        expect(s.multicastLock, isA<AndroidMulticastLock>());
        expect(s.environment, isA<PollingNetworkEnvironment>());
        expect(s.mdns, isA<BonsoirMdnsBackend>());
        expect(s.caps.maxContinuous, const Duration(hours: 6));
        expect(s.caps.resumeAfterCrash, isFalse);
      },
    );

    test('other platforms: no-ops with working discovery plumbing', () {
      final s = createPlatformServicesFor(PlatformKind.other);
      expect(s.autostart.isSupported, isFalse);
      expect(s.tray.isAvailable, isFalse);
      expect(s.multicastLock, isA<NoopMulticastLock>());
      expect(s.mdns, isA<BonsoirMdnsBackend>());
      expect(s.caps.maxContinuous, isNull);
    });

    test(
      'createPlatformServices works on this machine and touches nothing',
      () async {
        final s = createPlatformServices(args: const ['--hidden']);
        expect(s.autostart, isNotNull);
        await s.environment.dispose();
      },
    );

    test('the no-op adapters are really inert', () async {
      const tray = NoopTrayService();
      await tray.init(onOpen: () {}, onToggleReceive: () {}, onQuit: () {});
      await tray.setStatus(receiving: true, tooltip: 'x');
      await tray.dispose();
      expect(tray.isAvailable, isFalse);
      const window = NoopWindowController();
      await window.init(startHidden: true, hasTray: false);
      await window.show();
      await window.hide();
    });
  });

  group('runLaunchCommands', () {
    test(
      '--remove-autostart removes the entry and tells main to exit',
      () async {
        final autostart = FakeAutostart(enabled: true);
        final services = PlatformServices.fake(autostart: autostart);
        expect(
          await runLaunchCommands(services, const ['--remove-autostart']),
          isTrue,
        );
        expect(autostart.enabled, isFalse);
      },
    );

    test('other arguments leave the autostart entry alone', () async {
      final autostart = FakeAutostart(enabled: true);
      final services = PlatformServices.fake(autostart: autostart);
      expect(await runLaunchCommands(services, const ['--hidden']), isFalse);
      expect(autostart.enabled, isTrue);
    });
  });

  group('startPlatformShell', () {
    test(
      'heals autostart, then tray, then window with the real tray state',
      () async {
        final log = <String>[];
        final window = LoggingWindow(log);
        final services = PlatformServices(
          autostart: SelfHealingFake(log),
          tray: LoggingTray(log, available: true),
          window: window,
          multicastLock: FakeMulticastLock(),
          environment: FakeEnvironment(),
        );
        var toggled = 0;
        await startPlatformShell(
          services,
          args: const ['--hidden'],
          onToggleReceive: () => toggled++,
          onQuit: () {},
        );
        expect(log, ['heal', 'tray.init', 'window.show', 'window.init']);
        expect(window.lastStartHidden, isTrue);
        expect(window.lastHasTray, isTrue);
        expect(toggled, 0);
      },
    );

    test(
      'the default onOpen shows the window; an explicit onOpen wins',
      () async {
        final log = <String>[];
        final services = PlatformServices(
          autostart: FakeAutostart(),
          tray: LoggingTray(log),
          window: LoggingWindow(log),
          multicastLock: FakeMulticastLock(),
          environment: FakeEnvironment(),
        );
        await startPlatformShell(
          services,
          args: const [],
          onToggleReceive: () {},
          onQuit: () {},
        );
        // LoggingTray.init calls onOpen immediately.
        expect(log, contains('window.show'));

        final log2 = <String>[];
        final services2 = PlatformServices(
          autostart: FakeAutostart(),
          tray: LoggingTray(log2),
          window: LoggingWindow(log2),
          multicastLock: FakeMulticastLock(),
          environment: FakeEnvironment(),
        );
        var opened = 0;
        await startPlatformShell(
          services2,
          args: const [],
          onToggleReceive: () {},
          onQuit: () {},
          onOpen: () => opened++,
        );
        expect(opened, 1);
        expect(log2, isNot(contains('window.show')));
      },
    );

    test('a normal launch passes startHidden false', () async {
      final log = <String>[];
      final window = LoggingWindow(log);
      final services = PlatformServices(
        autostart: FakeAutostart(),
        tray: LoggingTray(log),
        window: window,
        multicastLock: FakeMulticastLock(),
        environment: FakeEnvironment(),
      );
      await startPlatformShell(
        services,
        args: const [],
        onToggleReceive: () {},
        onQuit: () {},
      );
      expect(window.lastStartHidden, isFalse);
      expect(window.lastHasTray, isFalse);
    });
  });
}

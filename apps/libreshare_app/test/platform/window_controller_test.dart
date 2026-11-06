import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:libreshare_app/platform/window/window_controller_impl.dart';

class FakeWindowBackend implements WindowBackend {
  bool attachResult = true;
  Object? attachThrows;
  Object? actionThrows;
  bool closeResult = true;
  bool visible = true;
  final List<String> calls = [];
  bool Function()? handler;
  bool disposed = false;

  @override
  bool attach() {
    final failure = attachThrows;
    if (failure != null) throw failure;
    calls.add('attach');
    return attachResult;
  }

  void _act(String name) {
    final failure = actionThrows;
    if (failure != null) throw failure;
    calls.add(name);
  }

  @override
  bool get isVisible => visible;

  @override
  void show() {
    _act('show');
    visible = true;
  }

  @override
  void hide() {
    _act('hide');
    visible = false;
  }

  @override
  void minimize() => _act('minimize');

  @override
  bool close() {
    calls.add('close');
    // A real window asks its close handler first.
    final veto = handler?.call() ?? false;
    return closeResult && !veto;
  }

  @override
  set onCloseRequested(bool Function()? value) => handler = value;

  @override
  void dispose() => disposed = true;

  /// What the OS does when the user presses the close button.
  bool userClicksClose() => handler?.call() ?? false;
}

void main() {
  late FakeWindowBackend backend;
  late StreamController<bool> tray;
  late List<int> exits;
  late WindowControllerImpl controller;

  setUp(() {
    backend = FakeWindowBackend();
    tray = StreamController<bool>.broadcast();
    exits = [];
    controller = WindowControllerImpl(
      backend: backend,
      trayAvailability: tray.stream,
      exitProcess: exits.add,
    );
  });

  tearDown(() async {
    await controller.dispose();
    await tray.close();
  });

  group('launch flags', () {
    test('startHidden parses --hidden', () {
      expect(startHidden(const []), isFalse);
      expect(startHidden(const ['--hidden']), isTrue);
      expect(startHidden(const ['--foo', '--hidden']), isTrue);
      expect(startHidden(const ['--hiddenx']), isFalse);
      expect(startHidden(const ['hidden']), isFalse);
    });

    test('wantsRemoveAutostart parses --remove-autostart', () {
      expect(wantsRemoveAutostart(const ['--remove-autostart']), isTrue);
      expect(wantsRemoveAutostart(const ['--hidden']), isFalse);
    });
  });

  group('start', () {
    test('a normal start leaves the window to the runner', () async {
      await controller.init(startHidden: false, hasTray: true);
      expect(backend.calls, ['attach']);
      expect(backend.handler, isNotNull);
    });

    test('--hidden with a tray: stay hidden', () async {
      await controller.init(startHidden: true, hasTray: true);
      expect(backend.calls, ['attach', 'hide']);
      expect(backend.visible, isFalse);
    });

    test(
      '--hidden without a tray: start minimized so the app stays reachable',
      () async {
        await controller.init(startHidden: true, hasTray: false);
        expect(backend.calls, ['attach', 'show', 'minimize']);
      },
    );
  });

  group('close button', () {
    test('with a tray the window hides and the close is vetoed', () async {
      await controller.init(startHidden: false, hasTray: true);
      expect(backend.userClicksClose(), isTrue);
      expect(backend.calls.last, 'hide');
    });

    test(
      'without a tray the window minimizes and the close is vetoed',
      () async {
        await controller.init(startHidden: false, hasTray: false);
        expect(backend.userClicksClose(), isTrue);
        expect(backend.calls.last, 'minimize');
      },
    );

    test('when nothing needs to keep running, close really closes', () async {
      controller.keepRunningOnClose = () => false;
      await controller.init(startHidden: false, hasTray: true);
      expect(backend.userClicksClose(), isFalse);
      expect(backend.calls, ['attach']);

      controller.keepRunningOnClose = () => true;
      expect(backend.userClicksClose(), isTrue);
    });

    test('a failing close handler never traps the user', () async {
      await controller.init(startHidden: false, hasTray: true);
      backend.actionThrows = StateError('native hide failed');
      expect(backend.userClicksClose(), isFalse);
    });

    test('quit closes for real, even with a tray', () async {
      await controller.init(startHidden: false, hasTray: true);
      await controller.quit();
      expect(backend.calls.last, 'close');
      expect(exits, isEmpty);
    });

    test(
      'quit falls back to ending the process when the window cannot be closed',
      () async {
        await controller.init(startHidden: false, hasTray: true);
        backend.closeResult = false;
        await controller.quit();
        expect(exits, [0]);
      },
    );
  });

  group('show / hide', () {
    test('delegate to the backend', () async {
      await controller.init(startHidden: false, hasTray: true);
      await controller.hide();
      expect(backend.visible, isFalse);
      await controller.show();
      expect(backend.visible, isTrue);
    });

    test('a throwing backend never throws into the UI', () async {
      await controller.init(startHidden: false, hasTray: true);
      backend.actionThrows = StateError('native');
      await controller.show();
      await controller.hide();
    });
  });

  group('native side missing', () {
    test('attach returning false: everything is a no-op', () async {
      backend.attachResult = false;
      await controller.init(startHidden: true, hasTray: false);
      await controller.show();
      await controller.hide();
      expect(controller.isAttached, isFalse);
      expect(backend.calls, ['attach']);
      expect(backend.handler, isNull);
    });

    test('attach throwing (library not loadable): no-op, no throw', () async {
      backend.attachThrows = ArgumentError('Failed to lookup symbol');
      await controller.init(startHidden: true, hasTray: false);
      await controller.show();
      expect(controller.isAttached, isFalse);
      await controller.quit();
      expect(exits, [0], reason: 'quit still ends the process');
    });
  });

  group('tray appears or vanishes after start', () {
    test('losing the tray while hidden reveals the window', () async {
      await controller.init(startHidden: true, hasTray: true);
      expect(backend.visible, isFalse);
      tray.add(false);
      await pumpEventQueue();
      expect(backend.visible, isTrue);
      // and close now minimizes instead of hiding
      expect(backend.userClicksClose(), isTrue);
      expect(backend.calls.last, 'minimize');
    });

    test('gaining a tray switches close to hide-to-tray', () async {
      await controller.init(startHidden: false, hasTray: false);
      tray.add(true);
      await pumpEventQueue();
      expect(backend.userClicksClose(), isTrue);
      expect(backend.calls.last, 'hide');
    });

    test(
      'losing the tray while the window is visible leaves it alone',
      () async {
        await controller.init(startHidden: false, hasTray: true);
        tray.add(false);
        await pumpEventQueue();
        expect(backend.calls, ['attach']);
      },
    );
  });

  test('dispose detaches the handler and the backend', () async {
    await controller.init(startHidden: false, hasTray: true);
    await controller.dispose();
    expect(backend.handler, isNull);
    expect(backend.disposed, isTrue);
  });
}

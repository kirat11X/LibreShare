/// [WindowBackend] over `window_manager` 0.6 (native API on top of nativeapi).
///
/// UNVERIFIED at runtime (no GUI may be opened by the build agents); compiled
/// into the Linux bundle and type-checked against 0.6.0.
library;

import 'package:window_manager/window_manager.dart' as wm;

import 'window_controller_impl.dart';

class NativeWindowBackend implements WindowBackend {
  wm.Window? _window;
  wm.ListenerId? _listener;
  bool Function()? _onCloseRequested;

  @override
  set onCloseRequested(bool Function()? handler) => _onCloseRequested = handler;

  @override
  bool attach() {
    final window = wm.WindowManager.instance.getCurrent();
    if (window == null) return false;
    _window = window;
    _listener ??= window.addListener(_onEvent);
    return true;
  }

  void _onEvent(wm.WindowEvent event) {
    if (event is wm.WindowCloseRequestedEvent) {
      final veto = _onCloseRequested?.call() ?? false;
      if (veto) event.request.cancel();
    }
  }

  @override
  bool get isVisible => _window?.isVisible ?? false;

  @override
  void show() {
    final window = _window;
    if (window == null) return;
    window.show();
    if (window.isMinimized) window.restore();
    window.focus();
  }

  @override
  void hide() => _window?.hide();

  @override
  void minimize() => _window?.minimize();

  @override
  bool close() => _window?.close() ?? false;

  @override
  void dispose() {
    final window = _window;
    final id = _listener;
    _listener = null;
    _window = null;
    if (window != null && id != null) window.removeListener(id);
  }
}

/// [TrayDriver] over `tray_manager` 0.8 (native API on top of nativeapi).
///
/// UNVERIFIED at runtime on every OS: the dev box (GNOME 50 / Fedora 44) has no
/// StatusNotifier host, and no GUI may be opened by the build agents. It is
/// type-checked against the 0.8.2 API and compiled into the Linux bundle.
/// Wrapped behind [TrayDriver] so API churn (0.7/0.8 moved to nativeapi) stays
/// in this one file.
library;

import 'package:tray_manager/tray_manager.dart' as tm;

import '../platform_log.dart';
import 'tray_service_impl.dart';

class NativeTrayDriver implements TrayDriver {
  static const PlatformLog _log = PlatformLog('tray');

  tm.TrayIcon? _icon;
  tm.Menu? _menu;
  tm.Image? _image;
  String? _imageAsset;
  tm.MenuItem? _status;
  tm.MenuItem? _toggle;
  final List<tm.MenuItem> _items = [];
  final List<(tm.MenuItem, tm.ListenerId)> _itemListeners = [];
  tm.ListenerId? _trayListener;

  @override
  bool get isSupported => tm.TrayManager.instance.isSupported();

  @override
  Future<void> create(TrayMenuModel model, TrayCallbacks callbacks) async {
    await destroy();
    final icon = tm.TrayIcon.create();
    if (icon == null) throw StateError('tray_manager could not create an icon');
    _icon = icon;

    final status = _item(model.statusLabel)..isEnabled = false;
    final open = _item(TrayMenuModel.openLabel);
    final toggle = _item(model.toggleLabel);
    final quit = _item(TrayMenuModel.quitLabel);
    _status = status;
    _toggle = toggle;
    _items.addAll([status, open, toggle, quit]);
    _listen(open, callbacks.onOpen);
    _listen(toggle, callbacks.onToggleReceive);
    _listen(quit, callbacks.onQuit);

    final menu = tm.Menu.create();
    if (menu == null) throw StateError('tray_manager could not create a menu');
    _menu = menu;
    menu
      ..addItem(status)
      ..addSeparator()
      ..addItem(open)
      ..addItem(toggle)
      ..addSeparator()
      ..addItem(quit);

    _setImage(icon, model.iconAsset);
    icon.setTooltip(model.tooltip);
    icon.setContextMenu(menu);
    // Linux panels display the exported menu themselves and need a trigger;
    // Windows opens it on right click.
    icon.setContextMenuTrigger(tm.ContextMenuTrigger.rightClicked);
    // Windows / macOS report clicks (Linux never does): left click opens.
    _trayListener = icon.addListener((event) {
      if (event is tm.TrayIconClickedEvent) callbacks.onOpen();
    });
    icon.setVisible(true);
  }

  tm.MenuItem _item(String label) {
    final item = tm.MenuItem.createWithLabelAndType(
      label,
      tm.MenuItemType.normal,
    );
    if (item == null) {
      throw StateError('tray_manager could not create "$label"');
    }
    return item;
  }

  void _listen(tm.MenuItem item, void Function() action) {
    final id = item.addListener((event) {
      if (event is tm.MenuItemClickedEvent) action();
    });
    _itemListeners.add((item, id));
  }

  void _setImage(tm.TrayIcon icon, String asset) {
    if (_imageAsset == asset && _image != null) return;
    final image = tm.ImageAsset.fromAsset(asset);
    if (image == null) {
      _log.warning('tray icon asset missing: $asset');
      return;
    }
    icon.icon = image;
    _image?.dispose();
    _image = image;
    _imageAsset = asset;
  }

  @override
  Future<void> update(TrayMenuModel model) async {
    final icon = _icon;
    if (icon == null) return;
    _status?.label = model.statusLabel;
    _toggle?.label = model.toggleLabel;
    _setImage(icon, model.iconAsset);
    icon.setTooltip(model.tooltip);
  }

  @override
  Future<void> destroy() async {
    final icon = _icon;
    _icon = null;
    void quietly(void Function() f) {
      try {
        f();
      } on Object catch (e) {
        _log.fine('tray cleanup step failed', e);
      }
    }

    for (final (item, id) in _itemListeners) {
      quietly(() => item.removeListener(id));
    }
    _itemListeners.clear();
    final trayListener = _trayListener;
    _trayListener = null;
    if (icon != null) {
      if (trayListener != null) {
        quietly(() => icon.removeListener(trayListener));
      }
      quietly(() => icon.setVisible(false));
      quietly(icon.dispose);
    }
    quietly(() => _menu?.dispose());
    _menu = null;
    for (final item in _items) {
      quietly(item.dispose);
    }
    _items.clear();
    _status = null;
    _toggle = null;
    quietly(() => _image?.dispose());
    _image = null;
    _imageAsset = null;
  }
}

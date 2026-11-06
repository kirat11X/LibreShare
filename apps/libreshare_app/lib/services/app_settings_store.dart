/// App-level settings that are not part of Receive mode (those live in the
/// core's `receive_settings.json`): device identity, name, download folder and
/// preferred port. One small JSON file, written atomically (tmp + rename).
library;

import 'dart:convert';
import 'dart:io';

import 'package:libreshare_core/libreshare_core.dart';
import 'package:uuid/uuid.dart';

import 'device_identity.dart';
import 'paths.dart';

class AppSettings {
  const AppSettings({
    required this.deviceId,
    required this.alias,
    this.downloadDir,
    this.preferredPort = kDefaultPort,
    this.storageAsked = false,
    this.pinMode = PinMode.off,
    this.hardwareHashingEnabled = false,
  });

  /// Stable UUID of this installation.
  final String deviceId;

  /// Name other devices see.
  final String alias;

  /// Null means "the default folder" (`~/Downloads/LibreShare`).
  final String? downloadDir;

  /// First port tried; the engine falls back upwards if it is taken.
  final int preferredPort;

  /// The one-time "where should received files go" question was answered.
  final bool storageAsked;

  /// PIN policy mode for incoming transfers (off, fixed, window).
  final PinMode pinMode;

  /// Whether hardware-accelerated SHA-256 is enabled (Option 2).
  final bool hardwareHashingEnabled;

  AppSettings copyWith({
    String? deviceId,
    String? alias,
    String? downloadDir,
    bool clearDownloadDir = false,
    int? preferredPort,
    bool? storageAsked,
    PinMode? pinMode,
    bool? hardwareHashingEnabled,
  }) => AppSettings(
    deviceId: deviceId ?? this.deviceId,
    alias: alias ?? this.alias,
    downloadDir: clearDownloadDir ? null : (downloadDir ?? this.downloadDir),
    preferredPort: preferredPort ?? this.preferredPort,
    storageAsked: storageAsked ?? this.storageAsked,
    pinMode: pinMode ?? this.pinMode,
    hardwareHashingEnabled:
        hardwareHashingEnabled ?? this.hardwareHashingEnabled,
  );

  Map<String, Object?> toJson() => {
    'v': 1,
    'deviceId': deviceId,
    'alias': alias,
    'downloadDir': downloadDir,
    'preferredPort': preferredPort,
    'storageAsked': storageAsked,
    'pinMode': pinMode.name,
    if (hardwareHashingEnabled) 'hardwareHashing': true,
  };

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.deviceId == deviceId &&
      other.alias == alias &&
      other.downloadDir == downloadDir &&
      other.preferredPort == preferredPort &&
      other.storageAsked == storageAsked &&
      other.pinMode == pinMode &&
      other.hardwareHashingEnabled == hardwareHashingEnabled;

  @override
  int get hashCode => Object.hash(
    deviceId,
    alias,
    downloadDir,
    preferredPort,
    storageAsked,
    pinMode,
    hardwareHashingEnabled,
  );
}

class AppSettingsStore {
  AppSettingsStore(this.directory);

  static const String fileName = 'app_settings.json';

  final Directory directory;

  File get file => File(joinPath(directory.path, fileName));

  /// Loads the settings; a missing or damaged file yields fresh defaults with
  /// a new device id (persisted on the next [save]).
  Future<AppSettings> loadOrCreate({String? defaultAlias}) async {
    Map<String, Object?> j = const {};
    try {
      if (await file.exists()) {
        final Object? root = jsonDecode(await file.readAsString());
        if (root is Map) j = root.cast<String, Object?>();
      }
    } on Object {
      j = const {};
    }
    final id = j['deviceId'];
    final alias = j['alias'];
    final dir = j['downloadDir'];
    final port = j['preferredPort'];
    final asked = j['storageAsked'];
    final modeStr = j['pinMode'];
    final hw = j['hardwareHashing'] is bool && (j['hardwareHashing'] as bool);
    PinMode mode = PinMode.off;
    if (modeStr is String) {
      for (final m in PinMode.values) {
        if (m.name == modeStr) {
          mode = m;
          break;
        }
      }
    }
    final settings = AppSettings(
      deviceId: id is String && id.length >= 8 ? id : const Uuid().v4(),
      alias: alias is String && alias.trim().isNotEmpty
          ? alias.trim()
          : (defaultAlias ?? defaultDeviceAlias()),
      downloadDir: dir is String && dir.isNotEmpty ? dir : null,
      preferredPort: port is int && port >= 0 && port <= 65535
          ? port
          : kDefaultPort,
      storageAsked: asked is bool && asked,
      pinMode: mode,
      hardwareHashingEnabled: hw,
    );
    if (id is! String) await save(settings);
    return settings;
  }

  Future<void> _last = Future<void>.value();

  /// Saves one after the other: overlapping saves would share the same
  /// `.tmp` file. The last call wins.
  Future<void> save(AppSettings settings) {
    final run = _last
        .then<void>((_) {}, onError: (Object _) {})
        .then((_) => _write(settings));
    _last = run;
    return run;
  }

  Future<void> _write(AppSettings settings) async {
    await directory.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

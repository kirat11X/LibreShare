/// What this device calls itself and what it is, for the engine's `DeviceInfo`.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:libreshare_core/libreshare_core.dart';

/// `linux`, `windows`, `android`, `macos`, `ios` (the wire `platform` value).
String currentPlatformName() => Platform.operatingSystem;

/// `mobile` on phones/tablets, else `desktop`.
String currentDeviceType() =>
    Platform.isAndroid || Platform.isIOS ? 'mobile' : 'desktop';

/// Hostname, cleaned the way peers will clean it; 'LibreShare' if unusable.
String defaultDeviceAlias({String Function()? hostname}) {
  String host;
  try {
    host = (hostname ?? () => Platform.localHostname)();
  } on Object {
    host = '';
  }
  final cleaned = host.replaceAll(RegExp(r'\.local$'), '').trim();
  return sanitizeAlias(cleaned.isEmpty ? 'LibreShare' : cleaned);
}

/// Trims to the protocol's alias limit and drops control characters.
String sanitizeAlias(String alias) {
  final runes = alias.runes.where((c) => c >= 0x20 && c != 0x7f).toList();
  final text = String.fromCharCodes(runes.take(kPeerLinkMaxAliasLength)).trim();
  return text.isEmpty ? 'LibreShare' : text;
}

/// Native channel that answers the user-visible device name (Android).
const String kDeviceInfoChannel = 'dev.libreshare/device_info';

/// Used on Android when the system gives no usable name.
const String kAndroidFallbackAlias = 'Android phone';

/// The name this device shows to others. Android: the device name from the
/// platform (`deviceName`), because the host name there is just "localhost".
/// Elsewhere: the cleaned host name, as [defaultDeviceAlias].
Future<String> resolveDeviceAlias({
  bool? isAndroid,
  MethodChannel? channel,
  String Function()? hostname,
}) async {
  if (!(isAndroid ?? Platform.isAndroid)) {
    return defaultDeviceAlias(hostname: hostname);
  }
  try {
    final answer = await (channel ?? const MethodChannel(kDeviceInfoChannel))
        .invokeMethod<Object?>('deviceName');
    if (answer is String) {
      final clean = String.fromCharCodes(
        answer.runes.where((c) => c >= 0x20 && c != 0x7f),
      ).trim();
      if (clean.isNotEmpty && clean.toLowerCase() != 'localhost') {
        return sanitizeAlias(clean);
      }
    }
  } on Object {
    // MissingPluginException, PlatformException: use the fallback
  }
  return kAndroidFallbackAlias;
}

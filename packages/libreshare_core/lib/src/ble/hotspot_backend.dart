import 'dart:async';

/// An active local hotspot reservation.
abstract class HotspotReservation {
  String get ssid;
  String get psk;
  String get hostIp;
  int get port;

  /// Stops the hotspot and releases system resources.
  Future<void> stop();
}

/// The result of joining a Wi-Fi hotspot.
abstract class HotspotJoinResult {
  String get clientIp;
  String get gatewayIp;

  /// Disconnects from the hotspot and restores previous network profiles.
  Future<void> disconnect();
}

/// Abstraction for platform-specific Wi-Fi hotspot creation and association.
abstract class HotspotBackend {
  /// Whether this device can host an ad-hoc or local hotspot.
  bool get canHost;

  /// Whether this device can join an external Wi-Fi hotspot programmatically.
  bool get canJoin;

  /// Whether hosting a hotspot preserves the current internet uplink (STA+AP / cellular).
  bool get hostKeepsUplink;

  /// Starts a local-only hotspot (e.g. Android LocalOnlyHotspot or Linux NetworkManager hotspot).
  Future<HotspotReservation> startHotspot({
    required String ssid,
    required String psk,
    int port = 53318,
  });

  /// Joins a specified Wi-Fi hotspot.
  Future<HotspotJoinResult> joinHotspot({
    required String ssid,
    required String psk,
    Duration timeout = const Duration(seconds: 90),
  });
}

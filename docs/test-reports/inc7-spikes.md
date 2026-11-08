# Increment 7 Spikes Report: S7-A, S7-B, S7-C

Date: 2026-11-07
Author: Antigravity Lead
Status: VERIFIED (Read-only analysis per inc7.md Section 3)

---

## Spike S7-A: Package Ecosystem (`universal_ble`, `dbus`, `bluez`)

### 1. `dbus`
- **Source & Cache:** Cached in `.toolchain/pub-cache/hosted/pub.dev/dbus-0.8.0/`.
- **License:** MPL-2.0 (Canonical Ltd.).
- **Fit:** Pure Dart client and object exporter. Fully compatible with Linux D-Bus `org.bluez.LEAdvertisingManager1`, `org.bluez.GattManager1`, and NetworkManager `org.freedesktop.NetworkManager`.
- **Verdict:** **ADOPT** for Linux headless/desktop leg. No external binaries or Flutter dependencies required in `packages/libreshare_core`.

### 2. `bluez`
- **License:** MPL-2.0 (Canonical Ltd.).
- **Fit:** BlueZ D-Bus client library (discovery, adapter introspection, GATT client). Does not support object export for advertising (`LEAdvertisement1`) or GATT server (`GattService1`), which require exporting D-Bus interfaces.
- **Verdict:** Use `dbus` directly for peripheral/advertiser export, with `bluez` as an optional reference.

### 3. `universal_ble`
- **License:** BSD-3-Clause (navideck).
- **Fit:** Cross-platform BLE abstraction supporting Android, Windows, macOS, iOS, Linux, and Web. Supports peripheral role (advertising and GATT server) on Android and Windows; connectionless manufacturer-data adverts fit within the 27-byte legacy limit.
- **Verdict:** **ADOPT** behind `BleBackend` interface for Flutter app integration (Android/Windows).

### 4. Rejected Packages
- `flutter_blue_plus`: Rejected due to non-free commercial license and lack of peripheral/advertiser support.
- `flutter_reactive_ble`: Rejected (Android/iOS only, no desktop support).
- `winrt` / `windows_devices`: Discontinued on pub.dev.

---

## Spike S7-B: Inc 4 `Candidate` Capabilities and Gaps

### Current Capabilities (`packages/libreshare_core/lib/src/connection/candidate.dart`)
- Defines `CandidateKind` (direct, lan, tunnel, rendezvous).
- Implements `Comparable<Candidate>` with cost metrics, RTT, and last-success weighting.
- Implements strict certificate fingerprint pinning via `matchesFingerprint()`.

### Gaps Required for Increment 7 ("LS-BLE/1" Hotspot)
1. **Asynchronous Setup / Teardown Hooks:**
   Hotspot candidates require establishing a physical or soft-AP network before TCP/TLS socket connection (`joinHotspot`, `startHotspot`). The current `Candidate` has no lifecycle hooks (`setup()` and `teardown()`).
2. **Per-Candidate Budgets:**
   Standard LAN candidates connect in $\le 3$ s. Joining a Wi-Fi hotspot on Android/Linux may require user interaction (system dialog) taking up to 90 s (`setupBudget`), while hosting takes up to 10 s.
3. **`CandidateKind.hotspot`:**
   Wire enumeration and classification for Wi-Fi hotspot paths.

### Wave 0 Action
Propose `HotspotCandidate` extending `Candidate` with:
- `HotspotRole` (host vs join)
- `setupBudget` (default 90 s for join, 10 s for host)
- `setup()` and `teardown()` hooks wired through `ConnectionManager`.

---

## Spike S7-C: Android Manifest and Permissions Diff by API Level

| API Level | BLE Permissions | Hotspot / Wi-Fi Permissions | Foreground Service Types |
|---|---|---|---|
| **API 29-30** (Android 10-11) | `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` (`maxSdkVersion=30`) | `CHANGE_WIFI_STATE`, `CHANGE_NETWORK_STATE`, `ACCESS_FINE_LOCATION` | `dataSync` |
| **API 31-32** (Android 12-12L) | `BLUETOOTH_SCAN` (`usesPermissionFlags="neverForLocation"`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` | `CHANGE_WIFI_STATE`, `CHANGE_NETWORK_STATE`, `ACCESS_FINE_LOCATION` (for LOHS) | `connectedDevice`, `dataSync` |
| **API 33-36** (Android 13-16) | `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT` | `NEARBY_WIFI_DEVICES` (`neverForLocation`), `CHANGE_WIFI_STATE` | `connectedDevice`, `dataSync` |
| **API 37+** (Future Android 17) | Same as 36 | `ACCESS_LOCAL_NETWORK` (implicit under Target SDK 36) | `connectedDevice`, `dataSync` |

### Required Manifest Additions (when packaging Android BLE/hotspot)
```xml
<!-- BLE permissions -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Hotspot and Wi-Fi handoff permissions -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
```

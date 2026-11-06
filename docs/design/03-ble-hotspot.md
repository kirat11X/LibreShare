# Design 03: BLE discovery + hotspot handoff ("LS-BLE/1")

| | |
|---|---|
| Status | Proposal (design only, no code). Stretch feature NFR-08. Needs a plan `docs/plans/inc6.md` before any code (CLAUDE.md rule). |
| Date | 2026-11-03. Every URL below was read on this date; "UNVERIFIED" = not confirmed by a primary source or by a test in this session. |
| Related | spec sections 2, 5, 6, 15, 16; `docs/protocol/LSP-1.md`; `docs/adr/0002-connection-ladder-as-candidates.md` |
| Rule kept | LSP/1 above the transport is unchanged except two additive 1.1 fields (section 3.7). BLE never carries file data. |

## 0. Verdict and decisions

| Pair | Verdict | Why |
|---|---|---|
| Linux <-> Android | **Feasible, best first target** | BlueZ can broadcast and serve GATT; Android LocalOnlyHotspot (LOHS) hosts with no per-use prompt; Linux joins with `nmcli`. Android keeps mobile data. |
| Windows <-> Android | **Feasible, medium risk** | Windows is BLE central + beacon sender; Android hosts the LOHS; Windows joins with the Native Wifi API. Risks: Windows 11 24H2 location gating, adapter quirks. |
| Linux <-> Windows | **Lab-grade, experimental** | One side must host with no router. Linux hosts (NM), Windows joins. Windows hosting offline needs the Wi-Fi Direct legacy AP, driver-dependent and unproven here. |
| any <-> macOS/iOS | Out of scope | Section 2.5. |

Decisions (each is argued below):

| # | Decision |
|---|---|
| D1 | BLE is a **control plane only** (wake, identify, consent, hotspot credentials, LAN address exchange). Files always move over LSP/1 on an IP path. |
| D2 | Beacon = **manufacturer-specific data** (company id `0xFFFF`, magic `LS`), because Windows cannot publish service UUID/service data in a connectionless advert. Max 27 bytes. |
| D3 | Rotating 8-byte ephemeral id (EID) derived with HMAC from a per-device `advKey` shared at trust time; unpaired devices use random EIDs. No names, no fingerprints in beacons. |
| D4 | Credentials travel only inside an AEAD channel over GATT (ephemeral X25519 + signed transcript). QR is the no-BLE fallback. Never in an advert. |
| D5 | **Receiver consent precedes any hotspot action.** Idle devices are scan-only; advertising is time-boxed (Quick Share style). |
| D6 | Host preference: Android LOHS > Linux NM > Windows legacy AP. Joiner pays the internet interruption, copy says so. |
| D7 | Integrate as `HotspotCandidate` / `WifiDirectCandidate` with a setup phase; ConnectionManager gains per-candidate budgets, nothing radio-specific. |
| D8 | Packages: `universal_ble` (Android/Windows), own `dbus` code (Linux peripheral), own Kotlin and C++/WinRT for hotspot. **Reject `flutter_blue_plus`** (central only; custom licence that restricts commercial use, section 2.3). |
| D9 | Build order: core + fakes, then Linux <-> Android, then Windows <-> Android, then Linux <-> Windows. Ship "Phase A" (BLE discovery + LAN address exchange) before "Phase B" (hotspot). |

## 1. Data points from this machine (read-only probes, 2026-11-03)

| Probe | Result | Meaning |
|---|---|---|
| `rfkill list` | `hci0` **soft blocked: yes**, `phy0` unblocked | Fresh Linux installs may have Bluetooth off; app must show "turn on Bluetooth", it cannot unblock itself. |
| `bluetoothctl show` | BlueZ **5.87**, Intel AX201 BT, `Roles: central, peripheral`, `Powered: no (off-blocked)` | Both BLE roles supported by this controller. |
| `busctl ... LEAdvertisingManager1` | `SupportedInstances 12`, `MaxAdvLen 251`, features `CanSetTxPower`, `HardwareOffload`, secondary channels 1M/2M/Coded | Legacy and extended advertising both possible here. |
| `busctl ... AdvertisementMonitorManager1` | **absent** on hci0 | Do not depend on BlueZ advertisement monitors; filter in Dart. |
| `/etc/bluetooth/main.conf` | `Privacy` commented out, default **off** [S1] | BlueZ advertises with the static public address; app cannot change this without root. |
| `nmcli --version`, polkit | NM **1.56.1**; `wifi.share.protected` and `network-control` are `allow_active=yes` | A logged-in desktop user can create a protected hotspot with no admin prompt (not executed here, so end-to-end UNVERIFIED). |
| `nmcli -t device` | `wlp0s20f3` connected, `p2p-dev-wlp0s20f3` (wifi-p2p) present | NM exposes a Wi-Fi P2P device; not used (section 4). |
| `iw list` (Intel CNVi, `phy0`) | `#{ managed } <= 1, #{ AP, P2P-client, P2P-GO } <= 1, #{ P2P-device } <= 1, total <= 3, #channels <= 1`; STA currently on 5 GHz ch 157 | The radio **can** do STA + AP, but only on **one shared channel**. |
| NM concurrency | No NM release note found that adds STA + AP on one interface; NM issue #58 describes the existing connection dropping when a hotspot starts [S22] | `nmcli device wifi hotspot` will **drop the laptop's Wi-Fi internet** even though the chip could do both. Concurrency needs a virtual `__ap` interface + hostapd (root). |
| `dnsmasq`, `nft`, `firewalld` | present; zone `nm-shared` has `target: ACCEPT`, services dhcp/dns/ssh | NM "shared" mode works and LSP port 53318 is reachable on the hotspot on Fedora. Ubuntu/ufw differs, UNVERIFIED. |
| `/usr/share/dbus-1/system.d/bluetooth.conf` | default context may `send_destination="org.bluez"` | Unprivileged apps may register advertisements and GATT apps over D-Bus (common practice; not exercised here). |
| `iw reg get` | `country IN` | Hotspot channel/band must be legal in the host's regdomain; DFS channels are unusable for an AP without radar wait. |

## 2. Platform capabilities

### 2.1 Capability matrix

| Capability | Linux (BlueZ 5.87, NM 1.56) | Windows 10 / 11 (extended adverts need 2004+) | Android 10-16 (API 29-36) |
|---|---|---|---|
| BLE central / scan | Yes. `Adapter1.SetDiscoveryFilter`, `Device1.ManufacturerData`. | Yes. `BluetoothLEAdvertisementWatcher`, filter on data sections, `AllowExtendedAdvertisements` (2004+) [S4] | Yes. `BluetoothLeScanner`; filtered scans keep running with screen off; unfiltered stop [S19] |
| BLE beacon (connectionless) | Yes. `LEAdvertisement1` `Type=broadcast`, `ManufacturerData`, `Min/MaxInterval`, `Duration`, `Timeout` [S2] | Yes, **manufacturer data only**. Flags, UUID lists, service data, local name are reserved and rejected [S3]. 27-byte payload (universal_ble README). | Yes. `BluetoothLeAdvertiser`; extended adverts if `isLeExtendedAdvertisingSupported()` (API 26) [S20] |
| GATT server (peripheral) | Yes via D-Bus `GattManager1.RegisterApplication` (own code; no Dart package does it) | Yes `GattServiceProvider`, **only if** adapter reports `IsPeripheralRoleSupported` [S5, S6]. Discoverable+connectable puts the 128-bit UUID in the advert and cannot carry manufacturer data [S5] | Yes `BluetoothGattServer` (needs `BLUETOOTH_ADVERTISE` + `BLUETOOTH_CONNECT`) |
| BLE address privacy | **Static public address** unless root sets `Privacy` [S1] | `IsAnonymous` hides the address but needs extended adverts (2004+) [S3]; default behaviour UNVERIFIED | Platform uses resolvable private addresses by default, UNVERIFIED |
| Create hotspot (no internet needed) | `nmcli device wifi hotspot` / D-Bus `AddAndActivateConnection` with `ipv4.method=shared`. Needs dnsmasq (NM spawns it) | **Mobile Hotspot** (`NetworkOperatorTetheringManager`, capability `wiFiControl`) needs an upstream connection profile [S7, S10]. **Wi-Fi Direct legacy AP** (`WiFiDirectAdvertisementPublisher` + `LegacySettings` Ssid/Passphrase, "does not serve as a general-purpose access point") works offline in principle [S8]; a Rust port of the sample exists, so unpackaged use looks plausible [S28]; the two cannot run together [S9] | `startLocalOnlyHotspot` (API 26): no internet by design; credentials from the reservation (`getSoftApConfiguration`, API 30) [S15, S17]. Fails with `ERROR_INCOMPATIBLE_MODE`, `_NO_CHANNEL`, `_TETHERING_DISALLOWED`, `_GENERIC` [S16] |
| Join a hotspot programmatically | `nmcli device wifi connect <ssid> password <psk>` or D-Bus `AddAndActivateConnection` (`network-control` allow_active=yes) | Native Wifi API (`WlanSetProfile` user profile + `WlanConnect`) from the Flutter runner. WinRT `WiFiAdapter.ConnectAsync` probably needs the restricted `wiFiControl` capability (UNVERIFIED). 24H2 gates Wi-Fi scan results behind location [S11] | `WifiNetworkSpecifier` + `requestNetwork`: system dialog, no internet, app-scoped network; approval is **remembered per app+SSID/BSSID for specific requests**, not for patterns [S14] |
| STA + AP concurrency | Chip may allow (same channel); NM does not do it on one interface [S22] | Mobile Hotspot can share Wi-Fi over the same adapter on supporting drivers (public = profile, private = Wi-Fi) [S7]; Wi-Fi Direct is not allowed alongside it [S9] | `WifiManager.isStaApConcurrencySupported()` (API 30) [S17]; mobile data is unaffected either way |
| Background | Tray app or systemd user service scanning; no OS limit | Same. Win32 app may use these WinRT APIs (UNVERIFIED for unpackaged + `wiFiControl`) | Filtered `PendingIntent` scan survives process death [S19]; it **cannot start a foreground service** (not in the exemption list), but can post a notification, and a tap can [S18]. OEM battery killers make this best effort |

### 2.2 Android permissions by API level

| API | BLE | Hotspot / join | Notes |
|---|---|---|---|
| 29-30 | `BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` (scan); background scan also `ACCESS_BACKGROUND_LOCATION` [S13] | LOHS: `ACCESS_FINE_LOCATION` + `CHANGE_WIFI_STATE`. Specifier: `CHANGE_WIFI_STATE`, `CHANGE_NETWORK_STATE` (UNVERIFIED) | Location **services** must be on for scans |
| 31-32 | `BLUETOOTH_SCAN` (+ `neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`; location only if not asserted away [S13] | LOHS still `ACCESS_FINE_LOCATION` | `neverForLocation` "filters some BLE beacons"; iBeacon-like frames only is our assumption, **test our `0xFFFF` beacon with the flag** |
| 33-35 | same | `NEARBY_WIFI_DEVICES` replaces location for LOHS; `usesPermissionFlags=neverForLocation` [S15]; spec manifest already has it | FGS type `connectedDevice` if a service must hold a GATT link (UNVERIFIED); transfer stays `dataSync` (6 h cap, spec 4) |
| 36 | same | Android 16 adds `SoftApCallback#onClientsDisconnected` (useful for teardown) [S29]; LNP opt-in uses `NEARBY_WIFI_DEVICES` [S12] | Target 36 until the next row is handled. The Android 17 "all apps" page lists no BLE-advertising or LOHS change (only autonomous bond re-pairing); its target-37 page was not read [S27] |
| 37 | same | Targeting 37 needs `ACCESS_LOCAL_NETWORK` (NEARBY_DEVICES group, so BT grant pre-approves it) for every LAN/hotspot socket, TCP and UDP [S12] | Not BLE-specific: affects LSP/1 on all Android builds. Apps targeting <37 keep an implicit grant |

Briar's tracker shows LOHS needs the Location setting on even with Nearby devices granted ("Android 12 - hotspot error when nearby devices = ON and location = OFF") [S21]. Treat "Location services off" as a first-class error with a copy string (section 4.4).

### 2.3 Dart / Flutter packages (pub.dev pages read 2026-11-03; pub.dev shows relative ages only) [S23]

| Package | Version | Fit | Verdict |
|---|---|---|---|
| `bluez` (canonical, MPL-2.0) | 0.9.0, "19 days ago" | BlueZ **client** (adapters, devices, GATT client). No advertising or GATT server (downstream packages cite this; bluez README itself silent) | Use for scan/connect on Linux |
| `dbus` (canonical, MPL-2.0) | 0.8.0, "46 days ago", 8.6M downloads | Pure Dart, can **export objects** | **Required** for Linux `LEAdvertisement1` + GATT server + NM hotspot |
| `nm` (canonical, MPL-2.0) | 0.6.0, "39 days ago" | NM client; Wi-Fi AP/activation API coverage not confirmed | Evaluate; else raw `dbus` |
| `flutter_blue_plus` | 2.3.14 | "BLE Central Role only"; Windows via third-party `flutter_blue_plus_winrt`; license "FlutterBluePlus License": free for personal, nonprofit, education; commercial needs a paid licence | **Reject** (no peripheral; custom licence, not freely usable commercially) |
| `universal_ble` (BSD-3, navideck) | 3.2.0, "3 days ago" | Android/iOS/macOS/Windows/Linux/Web client; **peripheral** on Android/iOS/macOS/Windows, Linux WIP; Windows connectionless adverts = manufacturer data, 27 B, no name | **Adopt** behind `BleBackend`; spike first (section 7) |
| `bluetooth_low_energy` (MIT) | 6.2.1 (7.0.0-dev.0 exists), ~9 months old | Central + peripheral on Android/iOS/macOS/Windows; Linux central only | Fallback if `universal_ble` spike fails |
| `flutter_ble_peripheral` (BSD-3) | 3.1.0, ~60 days | Advertise + GATT server on Android/iOS/macOS/Windows; no Linux | Fallback (advertise only) |
| `flutter_reactive_ble` (BSD-3) | 5.6.0 | Android + iOS only | Reject |
| `win_ble` (MIT) | 1.1.1, ~2 years | Windows client via helper `BleServer.exe` | Reject (stale, extra exe) |
| `winrt` 0.0.1, `windows_devices` 0.2.0, `windows_networking` 0.2.0 | all "discontinued" | Dart WinRT projections | **Dead**; use C++/WinRT. `win32` 6.4.0 projects Win32/COM, not WinRT |
| `bonsoir` 7.1.6 (MIT) | Android, Linux, Windows | mDNS only | Already in spec; unrelated to BLE |
| `nsd` 5.0.1 | no Linux | mDNS | Not used |

### 2.4 Native code that must be written

| Platform | Needed | Form |
|---|---|---|
| Linux | `LEAdvertisement1` object, GATT application objects, `Adapter1` discovery filter handling, NM activation of an AP profile (volatile) and join | Pure Dart over `package:dbus`; no Flutter import, so it could be extracted to a package for CLI reuse (needs an ADR: CLAUDE.md puts platform code under `apps/.../platform/`) |
| Windows | Publisher/Watcher/GattServiceProvider (if `universal_ble` falls short), Native Wifi join, optional Wi-Fi Direct legacy AP | C++/WinRT in a Flutter Windows plugin (C++/WinRT headers ship with the Windows SDK) exposed by MethodChannel/EventChannel |
| Android | Hotspot (LOHS reservation lifecycle), `WifiNetworkSpecifier` + `bindProcessToNetwork`, `PendingIntent` scan receiver + notification, extended advertising set, permission flow | Kotlin plugin, ~600 lines |

### 2.5 macOS / iOS limits (3 lines)

1. CoreBluetooth peripherals advertise only local name and service UUIDs (no manufacturer data), and background iOS moves UUIDs to an overflow area, so our beacon cannot be emitted; they can still scan and run a GATT client.
2. Neither OS can create a hotspot or Wi-Fi Direct group programmatically; joining a given SSID needs NEHotspotConfiguration/CoreWLAN with entitlement requirements (paid-account need UNVERIFIED).
3. Hence Apple devices join as BLE-less LAN peers or via QR only; out of scope here (spec 0 puts macOS at MVP+ and iOS at stretch).

## 3. Protocol "LS-BLE/1"

### 3.1 Rules

1. Advertise little, say nothing stable: no name, no fingerprint, no static id. Identity appears only after an encrypted channel exists.
2. Everything privileged happens inside the LS-BLE/1 AEAD channel; adverts only say "a LibreShare is here, maybe you know me".
3. The existing trust anchors are reused: ECDSA P-256 identity cert, uppercase SHA-256 fingerprint, SAS formula of LSP-1 section 5.
4. A BLE failure must degrade to today's behaviour (multicast, mDNS, subnet scan, QR). No new weaker mode exists.

### 3.2 Beacon (manufacturer-specific AD: 2-byte company id + 14 bytes; 27 allowed after the id)

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | Company id `0xFFFF` (SIG test value; collisions possible, see open question 4), little-endian per BLE |
| 2 | 2 | Magic `4C 53` ("LS") |
| 4 | 1 | `ver<<4 | flags`: ver=1; bit0 RECV (visible, receives), bit1 SEND (wants to send, "wake"), bit2 OPEN (accepts unpaired), bit3 GATT (hosts the LS-BLE service, connectable) |
| 5 | 1 | `cap`: bit0 canHost, bit1 canJoin, bit2 hostKeepsUplink, bits3-5 platform (0 linux, 1 windows, 2 android, 3 macos, 4 ios, 5 other), bits6-7 reserved |
| 6 | 8 | EID |
| 14 | 2 | `seq` (random per start; lets scanners ignore replays within one run) |

Rules: legacy adverts only (works on every stack; Android connectable adverts spend 3 bytes on flags, so keep the payload after the company id <= 24 B). Extended adverts are not used in v1. Interval 500-1000 ms while visible. Detection latency target <= 5 s (to be measured; Android LOW_POWER scan duty is the limit). Scanners filter by company id + magic (Android `ScanFilter.setManufacturerData`, Windows `BluetoothLEAdvertisementFilter` data section, BlueZ: Dart-side because the monitor API is absent here).

GATT service (connectable advert, used when `GATT` flag is set; platforms that can advertise UUID + data together add the beacon too):
`fc7a9155-e024-4269-82a6-433dab94653e` (generated 2026-11-03; fixed forever). Two characteristics: `...653f` RX (write, write-without-response) and `...6540` TX (indicate). Frame: `1 byte (bit7 first, bit6 last, bits0-5 seq) + payload`, MTU-3 per write, message cap 2 KiB, reassembly timeout 5 s. A Windows peer without peripheral support cannot serve it: the other side serves it, or the Windows side connects back after seeing the peer's SEND beacon.

### 3.3 Rotating ephemeral id

`EID(t) = HMAC-SHA256(advKey, "LSBLE1-EID" || be64(floor(unixSeconds / 900)))[0..8]`

- `advKey` = 32 random bytes per device, generated at first run, stored in D3 (`SecretStore`), exchanged with each trusted peer (section 3.7). A scanner tests each trusted peer's key over epochs {t-1, t, t+1} (tolerates +-15 min clock skew); cost 3 x N HMACs.
- Test vector: `advKey = 00 01 02 ... 1f`, epoch 1993008 (2026-11-03T12:00:00Z, 1793707200 s): EID(1993007) = `1efb0334b7b6ecb8`, EID(1993008) = `6fa9eb55a49a9152`, EID(1993009) = `a42f3d6f2c801a6b`.
- Unpaired visibility ("OPEN"): EID = 8 random bytes, re-rolled every 15 min and at each visibility start. It identifies nothing.
- 64 bits: collision among 100 trusted peers x 3 epochs is about 2^-50 per scan result.
- Not hash-of-public-identifier: AirDrop's unsalted contact hashes were reversed with rainbow tables (AirCollect) [S24]. Keyed HMAC with a per-device secret avoids that class.
- Limits: the BLE address still identifies a device when the OS does not rotate it (BlueZ default, section 1). Mitigation is behavioural, not cryptographic: time-boxed advertising (3.4).

### 3.4 Visibility modes (modelled on Quick Share's Contacts / Everyone-for-10-minutes [S25])

| Mode | Advertises | Scans | Default |
|---|---|---|---|
| Hidden | nothing | nothing (BLE off for LibreShare) | Linux/Windows idle |
| Contacts | paired EID, `RECV`, only while the app window or tray "Receive" is active, and screen unlocked on Android | filtered, for SEND beacons of trusted peers | **Default when "Nearby" is enabled** |
| Everyone | random EID, `RECV|OPEN`, auto-off after **10 min** | filtered | Opt-in, user taps "Visible to everyone" |
| Sending | EID of the sender, `SEND`, from "Send" tap until connect or 60 s | scans for `RECV` beacons | Only while the Send screen is open |

Idle desktops are scan-only (they hear SEND beacons and offer a tray prompt). Android idle = filtered `PendingIntent` scan that only posts a "Ravi's laptop wants to share" notification; tapping starts the foreground service (permitted: user action on a notification [S18]). Fero (secondary source) uses a BLE advertisement from Linux so that Android reveals itself to Quick Share [S26].

### 3.5 Secure channel (after GATT connect)

| Step | From | Content |
|---|---|---|
| M1 hello | central | `{v:1, epk: X25519 pub, n: 16 random bytes, eidHint: first 2 bytes of the EID it matched or null}` |
| M2 hello | peripheral | `{epk, n, flags/cap echo}` |
| Keys | both | `ss = X25519`, `th = SHA256("LSBLE1" || M1 || M2)`, `HKDF-SHA256(ss, salt=th, info="LSBLE1-keys", 64)` -> kC2P, kP2C (AES-256-GCM, nonce = 4-byte direction || 8-byte counter, AAD = `th`) |
| AUTH | both, encrypted | `{cert: DER b64, sig: ECDSA-P256(identityKey, "LSBLE1-AUTH-<C|P>" || th), alias, platform, lanCands:[{ip,port,if}]}`; peer computes fingerprint = SHA-256(DER), checks the signature, and if it expected a trusted peer (EID match) requires that fingerprint |
| Result | | **Paired**: fingerprint in trust store D1, no SAS. **Unpaired**: SAS = LSP-1 formula over both fingerprints, shown on both screens (code identical on both or abort) |

Certificates stay encrypted from passive sniffers; an active relay that substitutes keys produces different fingerprints on each side, so SAS differs (MITM detected, same argument as spec section 5).
Application messages (JSON, AEAD): `OFFER`, `ACCEPT|REJECT`, `NET_PLAN`, `HOTSPOT`, `JOINED`, `NET_OK`, `ABORT`. `OFFER = {offerId(16 B b64), fileCount, totalSize, firstName (sanitised), lanCands, hostPref}`.

### 3.6 Flow and timers

1. Receiver visible (or paired) -> sender sees beacon, matches EID or shows "Nearby device" with platform icon and signal bars (no name).
2. Sender taps/auto-selects -> GATT connect (10 s) -> handshake (5 s) -> alias + SAS appear on both.
3. `OFFER` -> receiver prompt (spec screen 3, 120 s). `REJECT` ends it: **nothing was created on either machine**.
4. `ACCEPT` carries receiver `lanCands`. Sender races TCP `GET /api/v1/info` to all of them (2 s). Any success -> `NET_OK{lan}`: BLE is dropped and the normal Wi-Fi/LAN tier runs (this is the "BLE-only discovery + same router" case, solves multicast-blocked and mDNS-less networks).
5. Otherwise `NET_PLAN`: both compute `chooseHost()` (4.2) from `cap` bits; host starts (10 s), sends `HOTSPOT{offerId, ssid, psk, band, hostIp, port, certFp, validUntil <= now+120 s}`; joiner joins (30 s, 90 s if a system dialog appears), replies `JOINED{ip}`.
6. Sender runs LSP/1 (mTLS, fingerprint pinned from step 2, `offerId` in `SessionRequest`) -> receiver auto-accepts because it already consented. Chunks flow over the hotspot.
7. Teardown on COMPLETED/FAILED/cancel/timeout or 60 s idle: host releases, joiner leaves and restores its previous network. A state file `radio_state.json` is written before each change and replayed at next start to undo leftovers after a crash.
8. If the hotspot dies mid-transfer, the existing `fallbackToNext()` and `/state` resume apply unchanged.

QR fallback (no BLE adapter or denied permission): receiver screen shows `libreshare://handoff?ssid=..&psk=..&ip=..&port=..&fp=<64hex>&exp=<unix>`; sender scans it. Same `HotspotCandidate`, no BLE.

### 3.7 Pairing and LSP/1 additions (additive minor 1.1, per LSP-1 section 4.6)

Fingerprints are public (they are in the plaintext UDP announce, LSP-1 4.2), so a shared secret must be exchanged explicitly. After "Trust this device" each side calls `PUT /api/v1/peers/ble-key` over mTLS with `{"advKey":"<b64url 32 B>"}` and stores the peer's key. Removing a trusted device rotates the local `advKey` and re-sends it to the remaining peers.
Additions: `caps` token `ble1`; endpoint above; optional `SessionRequest.offerId`; handler rule "a session whose `offerId`, sender fingerprint and sizes match a live accepted offer returns 200 IN_PROGRESS". Update `LSP-1.md`, schemas, conformance tests together (CLAUDE.md rule); new `docs/protocol/LS-BLE-1.md` + `schemas/ble-*.schema.json` for the BLE messages.

### 3.8 Alternatives rejected

| Option | Why not |
|---|---|
| Encrypted credentials inside the advert | 27-byte payload; replayable; extended adverts are not scanned reliably on all stacks (Windows needs 2004+, flag) |
| Credentials in a readable GATT characteristic | Anyone nearby reads them |
| Service-UUID-only discovery | Windows cannot emit it from a connectionless publisher [S3] |
| Fixed public SSID/PSK per device | Linkable and guessable; evil-twin friendly |
| Wi-Fi Direct everywhere | No Apple support, Windows only via legacy AP, Linux P2P driver-dependent; kept only as `WifiDirectCandidate` for Android-hosted groups (WifiP2pManager), experimental |

### 3.9 Candidate kinds (ADR-0002 compliant)

```dart
// packages/libreshare_core/lib/src/connection/candidate.dart (Inc 4 contract, extended)
sealed class Candidate { String get kind; Duration get connectBudget => const Duration(seconds: 3); }
final class HotspotCandidate extends Candidate {
  final HotspotRole role;            // host | join
  final String ssid; final Secret psk;   // Secret never logged / toString-redacted
  final String hostIp; final int port; final String certFp;  // pinned for mTLS
  final DateTime validUntil; final String offerId;
  Duration get setupBudget => const Duration(seconds: 90);    // join may wait on a human
}
final class WifiDirectCandidate extends Candidate { /* Android WifiP2p GO credentials; experimental */ }
```

`HotspotConnection extends WiFiConnection`: `establish()` = `HotspotBackend.join/ensureHosting` (own budget, emits `ChannelPreparing`) then the identical mTLS connect; `close()` releases the network. Badge shows "Wi-Fi (direct hotspot)". **Change to request in Inc 4:** per-candidate budgets and a `setup()/teardown()` hook instead of the fixed 8 s tier timeout; everything else stays.

## 4. The STA + AP problem, UX and policy

### 4.1 What happens to the user's internet

| Role | Linux | Windows | Android |
|---|---|---|---|
| Hosts | Wi-Fi uplink **drops** (NM, one interface); Ethernet uplink survives (and NM "shared" will NAT it to guests, so keep the PSK secret and the session short) | Mobile Hotspot needs an upstream and may share it; legacy AP is offline; Mobile Hotspot and Wi-Fi Direct are exclusive [S9] | Mobile data unaffected; Wi-Fi uplink kept only if `isStaApConcurrencySupported()` (API 30+), else expected to drop |
| Joins | Wi-Fi uplink drops, previous profile restored when the hotspot profile goes down (NM autoconnect) | Leaves current Wi-Fi; Windows may auto-reconnect later | `WifiNetworkSpecifier` network is app-scoped and "does not provide internet" [S14]; the system dialog appears; we call `bindProcessToNetwork` so Dart sockets use it and **unbind afterwards** (otherwise the tunnel tier would break) |

### 4.2 `chooseHost(a, b)` (deterministic, both sides compute it from `cap`)

1. Only one side `canHost` -> it hosts.
2. Prefer a side with `hostKeepsUplink` (Ethernet, STA+AP, cellular).
3. Prefer Android LOHS (no join dialog on the other side, no internet loss for the phone), then Linux NM, then Windows legacy AP (experimental).
4. Tie -> the receiver hosts (LSP server and hotspot on one machine, no IP handoff step).
5. If the best choice would cost a desktop its only uplink, ask first (4.4); the user can decline, then the QR/tunnel path remains.

### 4.3 Which path when

| Situation | Path |
|---|---|
| Both on the same router, multicast fine | Normal discovery; BLE optional (only wake/identify) |
| Same router, AP isolation or multicast blocked | BLE address exchange (step 4); if TCP is also blocked by isolation, hotspot |
| No shared network | Hotspot via BLE |
| No BLE hardware / permission denied | QR (3.6) or manual IP |
| Hotspot fails to start or join | Tunnel offer if any internet exists, else clean `FAILED(NO_CONNECTION)` |

### 4.4 Honest copy (UX strings)

- Desktop joining: "To receive from Ravi's Pixel without a shared Wi-Fi, LibreShare will switch this computer to a temporary private network for about a minute. Your internet pauses and comes back automatically. [Continue] [Cancel]"
- Android hosting: "LibreShare will start a temporary hotspot for this transfer. Mobile data stays on. Android requires Location to be switched on for this; no location is read."
- Android joining: "Android will ask to connect to LS-7K2Q. This is a private link to Ravi's laptop, not an internet network."
- Failure: "Couldn't create the hotspot (Android code 3: another hotspot or tethering is active). Turn off tethering and retry, or use the QR code."
- Visibility: "Visible to everyone for 10 minutes. Anyone nearby can send you a request; you still approve every transfer."

## 5. Security and threat model (mirrors spec section 5)

| Threat | Mitigation | Test |
|---|---|---|
| Tracking by beacon content | Rotating HMAC EID or random EID, no names or fingerprints, 15-min epoch | `eid_unlinkability_test.dart` |
| Tracking by BLE address (Linux static address, Windows unknown) | Advertise only in time-boxed windows; document residual risk; use OS address rotation where available | manual matrix R7 |
| Rogue hotspot / evil twin | PSK and fingerprint arrive only inside the AEAD channel; LSP/1 mTLS pins the fingerprint, so a rogue AP can deny service but not read or alter data | `rogue_ap_test.dart` (FakeHotspot returning a different cert) |
| Passphrase sniffing | Never advertised; 100-bit random PSK per session; WPA2-PSK at least (WPA3-SAE where both support); host stops after COMPLETED/60 s idle/`validUntil` | `psk_policy_test.dart` (entropy, expiry, never logged) |
| Active MITM on unpaired BLE | Transcript-signed handshake; SAS over both fingerprints; no hotspot before explicit accept | `ble_mitm_test.dart` |
| Spam prompts / hotspot abuse | Offers only from paired or during OPEN window; 3 handshakes/min per BLE address, 10/min total; 1 live GATT session; 2 KiB pre-auth cap; per-fingerprint block list; receiver consent precedes any network change | `ble_spam_test.dart` |
| Downgrade (strip `ble1`, force hotspot over reachable LAN, force plaintext) | No plaintext mode exists; LAN is always tried first; tier order is local policy, not peer-controlled | `downgrade_test.dart` |
| Replay of OFFER / HOTSPOT | AEAD counters, `offerId` single use, `validUntil` | `ble_replay_test.dart` |
| Beacon forgery | Beacons confer no authority; EID forgery needs `advKey`; replay only shows a false "nearby" | `beacon_forgery_test.dart` |
| Relay (distance extension) | Not prevented (BLE has no distance bounding); consent screen shows alias + SAS | documented |
| Crash leaves a hotspot or a dead SSID | `radio_state.json` replayed at start; volatile NM profiles; Android reservation closed on service stop | `radio_recovery_test.dart` |
| Sensitive logs | psk, advKey, session keys, SSID suffix redacted (CLAUDE.md rule) | `log_redaction_test.dart` |

## 6. Interfaces, modules, tests

### 6.1 Core interfaces (pure Dart, no Flutter)

```dart
// packages/libreshare_core/lib/src/radio/ble_backend.dart
abstract interface class BleBackend {
  Future<BleCaps> capabilities();        // central, peripheral, gattServer, extAdv, platform
  Stream<BleBeacon> scan(BleScanSpec s); // filter: companyId + magic; returns payload, rssi, addr, at
  Future<BleAdvHandle> advertise(BleAdvSpec s); // payload<=27, connectable?, interval, ttl; handle.stop()
  Future<GattServerHandle> serve(GattServiceSpec s); // onFrame(peer), notify(peer, bytes), onDisconnect
  Future<BleLink> connect(BlePeer p, {Duration timeout}); // frames in/out, mtu
}
// packages/libreshare_core/lib/src/radio/hotspot_backend.dart
abstract interface class HotspotBackend {
  Future<HotspotCaps> capabilities();    // canHost, canJoin, keepsUplink, joinNeedsUserDialog, bands
  Future<HostedNetwork> startHosting(HostRequest r);  // ssid?/psk? hints; returns ssid, psk, hostIp, release()
  Future<JoinedNetwork> join(JoinRequest r);          // ssid, psk, bssid?, timeout; returns ip, leave()
  Stream<NetEvent> get events;           // clientCount, lost, restored
}
```
Orchestration lives in core: `radio/ble_handoff_service.dart` (state machine of 3.6), `radio/beacon_codec.dart`, `radio/eid.dart`, `radio/ble_channel.dart`, `radio/host_policy.dart`. It emits `LsEvent`s for the UI and produces `HotspotCandidate`s. The engine exposes `engine.nearby` (stream) and `engine.sendNearby(...)`; UI/CLI use only the engine.

### 6.2 Module paths

| Path | Content |
|---|---|
| `packages/libreshare_core/lib/src/radio/` | interfaces, codec, EID, channel, handoff service, `host_policy.dart`, `radio_state_store.dart` |
| `packages/libreshare_core/lib/src/connection/hotspot_connection.dart` | `HotspotCandidate`, `HotspotConnection` |
| `packages/libreshare_core/test/fakes/` | `fake_ble_bus.dart`, `fake_hotspot.dart` |
| `apps/libreshare_app/lib/platform/linux/` | `bluez_ble_backend.dart` (scan via `bluez`, advertise/GATT via `dbus`), `nm_hotspot_backend.dart` |
| `apps/libreshare_app/lib/platform/android/` | `android_ble_backend.dart` (universal_ble or Kotlin), `android_hotspot_backend.dart`, `android/app/src/main/kotlin/.../RadioPlugin.kt`, `ScanWakeReceiver.kt` |
| `apps/libreshare_app/lib/platform/windows/` | `winrt_ble_backend.dart`, `windows_hotspot_backend.dart`, `windows/runner/radio_plugin.cpp` |
| `packages/libreshare_cli/bin/ls.dart` | `ls nearby --radio-sim` driven by the fakes (the CLI cannot import `apps/`); real radios only in the app unless the Linux backend is extracted |
| `docs/protocol/LS-BLE-1.md`, `schemas/ble-*.schema.json` | normative wire spec + schemas |

### 6.3 Headless test plan (nothing hardware-dependent in CI)

- `FakeBleBus`: in-memory radio with range groups, per-device adv intervals, scan filters, address types, MTU, packet loss/latency, connection slots, `advertise` TTL expiry, controllable clock (epoch rollover). `FakeHotspot`: `startHosting` registers an SSID on a `FakeAir`; `join` checks ssid+psk, returns the host's address, and records every lease/release.
- Unit: beacon codec golden vectors; EID vector from 3.3 and epoch +-1 tolerance; frame fragmentation fuzz (random MTU, reorder, truncation); handshake with tampered M1/M2/AUTH, replayed frames, wrong fingerprint; SAS equality; `chooseHost` table (all 3x3 platform pairs, uplink flags); psk generator entropy; redaction; state-file recovery; rate limits.
- Conformance: JSON schemas for every BLE message, unknown-field tolerance, `ble1` cap, `offerId` handling in the REST handler (extends `api_conformance_test`).
- Integration (two engines, one process): paired send over fake BLE + fake hotspot -> byte-identical file; unpaired send requires SAS equality and accept; reject creates no hotspot (assert `FakeHotspot` untouched); hotspot cut at 40 % -> `fallbackToNext()` -> LAN or tunnel with no acked chunk re-sent (reuses FR-13 machinery); LAN-reachable case never starts a hotspot; teardown on every exit path.
- Docker e2e (`tools/docker/compose.yaml`): two nodes plus a `ble-bus` container (fake bus over TCP); `hotspot_net` starts blackholed with `tc netem` (as `cut_wifi.sh`) and `FakeHotspot.join` runs `restore.sh` on it. Needs `NET_ADMIN`, already required by Inc 4.
- Radio-dependent tests carry `@Tags(['radio'])` and run only with `LS_RADIO=1` on a developer machine (mirrors `LS_TUNNEL_LIVE=1`). CI also greps that `packages/libreshare_core/lib` imports neither Flutter nor `platform/`.

### 6.4 Manual device matrix (record in `docs/test-reports/`)

| ID | Setup | Checks |
|---|---|---|
| R1 | Fedora 44 (this laptop: AX201, BlueZ 5.87), unblock BT first | LEAdvertisement + GATT server register as normal user; STA drop and restore on `nmcli` hotspot |
| R2 | Ubuntu 24.04 + ufw, USB BT 5 dongle | NM shared mode + ufw; adapter without peripheral role |
| R3 | Windows 11 24H2, Intel AX2xx; Windows 10 22H2 older adapter | Beacon seen by Android; `IsPeripheralRoleSupported`; Wlan join with Location on and off; legacy AP start/abort |
| R4 | Android 10 (29), 12 (31), 14 (34), 15/16 (35/36); Pixel, Samsung, Xiaomi | permissions, LOHS errors, Location-off, screen-off PendingIntent scan, notification tap -> FGS, Specifier dialog and remembered approval for a stable SSID with a new PSK (UNVERIFIED), `neverForLocation` vs our beacon |
| R5 | STA+AP yes/no phones (`isStaApConcurrencySupported`) | Wi-Fi uplink kept or lost, copy accurate |
| R6 | Campus AP isolation, phone hotspot, home router | LAN-via-BLE address exchange, isolation fallback |
| R7 | Passive sniff with a second adapter (`btmon` or nRF sniffer) | Over two epochs no stable bytes besides company id/magic; Linux address stays static (expected) |
| R8 | Distance 1/5/10 m, walls, 2.4 GHz crowded | detection latency and handshake success rate |

## 7. Increments, effort, order, open questions

### 7.1 Increment mapping (after Inc 4 ladder; spec NFR-08 stretch)

| Step | Scope | Needs | Acceptance (headless unless stated) |
|---|---|---|---|
| 6.0 spike (2 days, real radios) | Four unknowns: Windows manufacturer beacon seen by Android with `neverForLocation`; BlueZ `broadcast` seen by a filtered Android scan with screen off; LOHS joined by `nmcli` on Fedora; `universal_ble` Windows+Android peripheral parity | Inc 2 done | Written result in `docs/test-reports/`; go/no-go for D8 |
| 6a core + fakes | codec, EID, channel, state machine, candidates, `host_policy`, LSP 1.1, schemas | Inc 4 Candidate hook, Inc 3 SAS/trust store | all unit/conformance/integration tests above green |
| 6b Linux <-> Android | Linux backends, Android LOHS + BLE, QR fallback, UI | 6a | R1, R4, R5 manual pass; Phase A and B demo |
| 6c Windows <-> Android | C++/WinRT plugin, Wlan join | 6b | R3 pass |
| 6d Linux <-> Windows (experimental flag) | Linux host, Windows join; optional legacy AP host | 6c | R3, R2; flag stays off if flaky |

### 7.2 Effort (person-weeks, one engineer who knows Dart; hardware access included)

| Item | Phase A (BLE discovery + LAN address exchange) | Phase B (hotspot) |
|---|---|---|
| Core + fakes + LSP 1.1 + docs | 2.0 | 1.0 |
| Linux (D-Bus advertise/GATT/scan; NM) | 1.5 | 1.5 |
| Android (BLE, permissions, wake notification; LOHS, Specifier) | 1.5 | 2.0 |
| Windows (C++/WinRT BLE; Wlan join, optional legacy AP) | 2.0 | 2.0 |
| UI/copy/settings | 0.5 | 1.0 |
| Manual matrix and hardening | 1.0 | 1.0 |
| **Subtotal** | **8.5** | **8.5** |

About 17 person-weeks total; two students in parallel is a 9-10 week stretch project. Cutting Windows hosting and Linux <-> Windows saves about 3 weeks.

### 7.3 What will not work reliably (be upfront in the SRS addendum)

- Apple platforms (section 2.5) and any device without BLE peripheral support acting as the GATT host.
- Windows hosting offline; Mobile Hotspot needs an upstream connection [S10]; legacy AP behaviour (DHCP, driver) is UNVERIFIED and exclusive with Mobile Hotspot [S9].
- Linux single-radio hosting always costs the Wi-Fi uplink; true concurrency needs root and hostapd.
- Android background wake: best effort (OEM battery managers, no FGS start from a scan callback); LOHS flakiness is documented by Briar users [S21]; Location services must be on.
- BLE privacy is only as good as the OS address rotation; Linux defaults to a static address.
- Android 17 `ACCESS_LOCAL_NETWORK` will add a prompt for all LAN/hotspot traffic once we target 37 [S12].
- BLE range (about 10 m, wall-dependent) and 2.4 GHz crowding; detection latency of several seconds.

### 7.4 Changes to the existing plan

1. Inc 4: make `Candidate` sealed-extensible with per-candidate budgets and a setup/teardown hook (section 3.9); reserve `ChannelActive.kind = hotspot`.
2. Inc 2/3 hooks: `caps` token `ble1`, trust-store field `peerAdvKey`, `offerId` pre-approval in the consent policy (LSP 1.1, additive).
3. Spec section 2 and 15 wording: Windows hotspot needs `wiFiControl` (not Proximity), Mobile Hotspot needs an upstream, offline hosting is the Wi-Fi Direct legacy AP; Android manifest gains `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `CHANGE_NETWORK_STATE`, optional `connectedDevice` FGS; keep `targetSdk 36` and open an issue for `ACCESS_LOCAL_NETWORK` (affects the whole app).
4. CLAUDE.md gotcha stays valid; add "radio tests need `LS_RADIO=1`".
5. Reject `flutter_blue_plus` in the tech table; add `universal_ble`, `dbus`, `bluez` (spec section 1).

### 7.5 Open questions for the user

1. **Default visibility.** Contacts-only plus an explicit 10-minute "Everyone" window (recommended), or an always-on "visible to everyone" toggle? The latter makes Linux's static BLE address a permanent beacon.
2. **Internet interruption.** May a desktop with a single Wi-Fi radio drop its internet for about a minute (with the copy in 4.4), or must hosting/joining be refused unless Ethernet, a second adapter or an Android host is available?
3. **Scope.** Ship Phase A only (about 8.5 pw: BLE discovery, consent, LAN address exchange, QR) and treat the hotspot as an experimental flag, or commit to Phase B (hotspot) for Linux <-> Android in this semester?
4. **Company id.** Use SIG test id `0xFFFF` (collision-prone, free), or pursue a real Bluetooth SIG assignment (membership terms UNVERIFIED), or accept a connectable-only 128-bit-UUID design that cannot beacon from Windows?
5. **Android target SDK.** Stay on target 36 (implicit local-network grant) until the university Play/F-Droid story demands 37, or adopt 37 now and ship the `ACCESS_LOCAL_NETWORK` prompt?

## 8. Sources (read 2026-11-03)

- S1 BlueZ `main.conf` (Privacy, Experimental): https://raw.githubusercontent.com/bluez/bluez/master/src/main.conf
- S2 BlueZ `org.bluez.LEAdvertisement`: https://raw.githubusercontent.com/bluez/bluez/master/doc/org.bluez.LEAdvertisement.rst
- S3 `BluetoothLEAdvertisementPublisher` (page updated 2025-11-21): https://learn.microsoft.com/en-us/uwp/api/windows.devices.bluetooth.advertisement.bluetoothleadvertisementpublisher
- S4 `BluetoothLEAdvertisementWatcher`: https://learn.microsoft.com/en-us/uwp/api/windows.devices.bluetooth.advertisement.bluetoothleadvertisementwatcher
- S5 GATT server (ms.date 2026-05-27): https://learn.microsoft.com/en-us/windows/apps/develop/devices-sensors/gatt-server
- S6 `BluetoothAdapter`: https://learn.microsoft.com/en-us/uwp/api/windows.devices.bluetooth.bluetoothadapter
- S7 `NetworkOperatorTetheringManager`: https://learn.microsoft.com/en-us/uwp/api/windows.networking.networkoperators.networkoperatortetheringmanager
- S8 `WiFiDirectLegacySettings`: https://learn.microsoft.com/en-us/uwp/api/windows.devices.wifidirect.wifidirectlegacysettings
- S9 `WiFiDirectAdvertisementPublisher`: https://learn.microsoft.com/en-us/uwp/api/windows.devices.wifidirect.wifidirectadvertisementpublisher
- S10 Windows 11 hotspot needs a connection (Q&A, secondary): https://learn.microsoft.com/en-us/answers/questions/1477390/how-to-activate-mobile-wireless-coverage-zone-in-w
- S11 Windows 11 24H2 Wi-Fi/location change (vendor KB, secondary): https://kb.devicetrust.com/changes-to-for-wi-fi-access-and-location-windows-11-24h2
- S12 Android local network permission (Android 16 opt-in, Android 17 enforcement): https://developer.android.com/privacy-and-security/local-network-permission
- S13 Android Bluetooth permissions: https://developer.android.com/develop/connectivity/bluetooth/bt-permissions
- S14 `WifiNetworkSpecifier` (peer-to-peer bootstrap): https://developer.android.com/develop/connectivity/wifi/wifi-bootstrap
- S15 LocalOnlyHotspot guide: https://developer.android.com/develop/connectivity/wifi/localonlyhotspot
- S16 `LocalOnlyHotspotCallback`: https://developer.android.com/reference/android/net/wifi/WifiManager.LocalOnlyHotspotCallback
- S17 `WifiManager` (`isStaApConcurrencySupported`, API 30): https://developer.android.com/reference/android/net/wifi/WifiManager
- S18 FGS background-start exemptions: https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- S19 `BluetoothLeScanner` (PendingIntent scan API 26; unfiltered scans stop on screen off): https://developer.android.com/reference/android/bluetooth/le/BluetoothLeScanner
- S20 `BluetoothAdapter` (extended advertising API 26): https://developer.android.com/reference/android/bluetooth/BluetoothAdapter
- S21 Briar tracker, hotspot vs location: https://code.briarproject.org/briar/briar/-/issues/2374
- S22 NetworkManager issue #58 (only seen via search snippet; page blocked on fetch): https://gitlab.freedesktop.org/NetworkManager/NetworkManager/issues/58
- S23 pub.dev: https://pub.dev/packages/bluez , /dbus , /nm , /flutter_blue_plus , /universal_ble , /bluetooth_low_energy , /flutter_ble_peripheral , /flutter_reactive_ble , /win_ble , /winrt , /windows_devices , /windows_networking , /win32 , /bonsoir , /nsd; universal_ble README https://github.com/Navideck/universal_ble
- S24 AirCollect (unsalted AirDrop contact hashes): https://eprint.iacr.org/2021/893
- S25 Quick Share visibility behaviour (Google support): https://support.google.com/files/answer/7577382
- S26 Fero / rquickshare (Linux Quick Share, secondary): https://github.com/Martichou/rquickshare
- S27 Android 17 behaviour changes, all apps: https://developer.android.com/about/versions/17/behavior-changes-all
- S28 Rust port of the Windows legacy-AP sample (shows desktop use is plausible, nothing about DHCP): https://docs.rs/wifidirect-legacy-ap/latest/wifidirect_legacy_ap/
- S29 Android 16 release notes (`SoftApCallback#onClientsDisconnected`; seen in search snippet, Spanish page): https://source.android.com/docs/whatsnew/android-16-release

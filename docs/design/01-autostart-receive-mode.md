# Design 01 - Auto-start, tray and background "Receive mode"

Status: proposal for orchestrator review. Date: 2026-11-03. Scope: docs only; no code or system state was changed.
Binding constraints: everything $0 for users and maintainers; Linux + Windows first-class; Android best effort.
Evidence tags: `[Sn]` = source list at the end (all fetched 2026-11-03). `UNVERIFIED` = not confirmed by a fetched source; test before relying on it.

## 0. Decisions at a glance

| # | Decision |
|---|---|
| D1 | A pure-Dart `ReceiveController` (new `receive/` module, no Flutter) owns Receive mode. Three orthogonal inputs: mode (`Off`, `For(N)`, `Always`), visibility (`Everyone`, `Contacts`), environment (network, battery, screen). UI, tray, notification, tile and CLI are thin views of it. |
| D2 | Off = listener closed AND nothing announced (a send-only "query" is still allowed while the UI is open). On = listener bound + announce policy by visibility. Paused = involuntary stop that the user can undo with one tap. |
| D3 | Linux auto-start = XDG autostart `.desktop` written by the app (`--hidden`). No systemd unit for the GUI app; an optional user unit is documented for the headless CLI only. |
| D4 | Tray is progressive enhancement. `tray_manager` 0.8.2 when a StatusNotifier host exists, else "close = minimize". GNOME needs an extension, and this dev box (Fedora 44, GNOME Shell 50.6) has none. |
| D5 | Windows auto-start = HKCU `Run` value `"...\libreshare.exe" --hidden`, written by the app itself from a first-run/Settings toggle (so it lands in the right user's hive). The installer only adds firewall rules. No Task Scheduler, no MSIX. |
| D6 | Android: foreground service of type **connectedDevice** (no OS time cap, allowed from `BOOT_COMPLETED`, prerequisite already met by `CHANGE_WIFI_MULTICAST_STATE`), plus an **app-level receive window, default 6 h**, so the user-visible behaviour matches the 6 h expectation and survives future OS caps. Fallback 1: `dataSync` with a 5 h 45 m window. Fallback 2: receive only while the app is visible. |
| D7 | Resume paths: persistent-notification action, post-timeout notification action, Quick Settings tile (via a transparent trampoline activity), and opening the app. Never rely on `START_STICKY` or a bare background `startForegroundService`. |
| D8 | Distribution = GitHub Releases + F-Droid/IzzyOnDroid. Google Play is out of scope (one-time US$25 fee [S26], violates the $0 rule; its FGS review is also a poor fit [S7]). |
| D9 | Android keeps `targetSdk` 36 until a deliberate bump to 37; at 37 the `ACCESS_LOCAL_NETWORK` runtime permission becomes mandatory [S5][S6] and maps to `Paused(permissionMissing)`. |

## 1. ReceiveMode state machine (packages/libreshare_core, no Flutter imports)

### 1.1 Model

- **Mode** (what the user asked for, persisted): `ReceiveOff`, `ReceiveFor(Duration)` (10 min, 1 h, 6 h, custom), `ReceiveAlways`. `ReceiveAlways` is clamped by `ReceivePlatformCaps.maxContinuous` (Android default 6 h, desktop null).
- **Visibility** (persisted): `everyone` | `contacts`. The UI's three-way control (Everyone / Contacts only / Off) maps "Off" to mode `ReceiveOff`, so there is one source of truth. Apple's AirDrop uses the same three receiving states, and "Everyone for 10 Minutes" reverts automatically [S29].
- **State** (runtime): `Off(reason)`, `Starting`, `On(since, until?, visibility)`, `Draining(deadline)`, `Paused(reason)`, `Failed(error)`.
  - `OffReason`: `user`, `expired` (chosen window ended), `neverEnabled`.
  - `PauseReason`: `platformTimeout` (OS FGS timeout; the "Paused(timeout)" of the brief), `osStopped` (process killed), `noNetwork`, `permissionMissing`, `batteryLow`.
  - `Draining`: the window ended while a transfer is active. New `POST /sessions` get `409 BUSY`; the listener closes when sessions reach 0 or at `deadline = min(until + 5 min, hardStop)`, where `hardStop` = OS timeout minus 8 s when the platform reports one.
- `Off(expired)` and `Paused(*)` both render a one-tap **Resume**. They differ for recovery: `Paused` auto-resumes when the cause clears (network back, app foregrounded after a platform timeout); `Off` never does.

### 1.2 Transitions (all pure; time only via `Clock` + `ReceiveScheduler`)

| From | Event | To | Effects |
|---|---|---|---|
| Off, Paused | `turnOn(mode)` | Starting -> On | `gate.openListener()`, `gate.setAnnounce(policy)`, arm expiry timer, arm warn timer (T-15 min), persist |
| On | expiry timer, `activeSessions==0` | Off(expired) | `closeListener`, announce none, persist, emit |
| On | expiry timer, `activeSessions>0` | Draining | announce none, new sessions BUSY, arm drain timer |
| Draining | sessions idle or drain timer | Off(expired) | `closeListener(graceful:false)` if sessions remain |
| On | `turnOff()` | Off(user) | as above, any state |
| On | `platformTimeout()` | Paused(platformTimeout) | persist partial state first (`.lspart` bitmaps already persistent), close listener |
| On | env: network lost | Paused(noNetwork) | close listener; window timer keeps running |
| Paused(noNetwork) | env: network back, window left | On | reopen listener |
| On | `setVisibility(v)` | On | `setAnnounce` only; listener and port unchanged |
| Starting | bind throws | Failed | no timers armed |

### 1.3 What stays bound vs. what is announced

| State / visibility | HTTP(S) listener | Multicast announce | mDNS registration | Replies to `announce:true` probes | Unknown senders |
|---|---|---|---|---|---|
| Off | closed | none | none | none | connection refused |
| On / everyone | bound (port fallback, FR-01) | periodic (30 s + events) | registered | all | consent prompt (spec s5) |
| On / contacts | bound | none | none (mDNS is public by nature) | only fingerprints in the trust store | TLS handshake rejected (Inc 3); before Inc 3 this mode is disabled |
| Draining | bound | none | none | none | `409 BUSY` |
| Paused | closed | none | none | none | refused |

- Send-only discovery while Off: the app multicasts `announce:true` with `port:0` and listens for replies, so the device list fills in about 1 s instead of waiting up to 30 s. **Protocol change (one):** `discovery-announce.port` minimum becomes 0, and "port 0 = not receiving, do not `POST /register` back". Update `LSP-1.md`, the schema and a conformance test in the same PR, per `CLAUDE.md`. The `ls send` client already reports port 0 in `DeviceInfo` (inc1 s8).
- The listener is never bound "just in case": binding only happens inside `On`/`Draining`.

### 1.4 Dart sketch (new files under `lib/src/receive/`)

```dart
sealed class ReceiveMode { const ReceiveMode(); }
final class ReceiveOff extends ReceiveMode { const ReceiveOff(); }
final class ReceiveFor extends ReceiveMode { const ReceiveFor(this.duration); final Duration duration; }
final class ReceiveAlways extends ReceiveMode { const ReceiveAlways(); }
enum ReceiveVisibility { everyone, contacts }
enum AnnouncePolicy { none, replyToTrusted, replyToAll, periodic }   // periodic = multicast + mDNS

sealed class ReceiveState { const ReceiveState(); }
final class Off extends ReceiveState { const Off(this.reason); final OffReason reason; }
final class Starting extends ReceiveState { const Starting(); }
final class On extends ReceiveState { const On(this.since, this.until, this.visibility); /* until==null => Always */ }
final class Draining extends ReceiveState { const Draining(this.deadline); final DateTime deadline; }
final class Paused extends ReceiveState { const Paused(this.reason); final PauseReason reason; }
final class Failed extends ReceiveState { const Failed(this.error); final Object error; }

/// Implemented by LibreShareEngine (the only edit to existing code, orchestrator-owned).
abstract interface class ReceiveGate {
  Future<int> openListener();                        // ApiServer.start(); returns bound port
  Future<void> closeListener({required bool graceful});
  void setAnnounce(AnnouncePolicy policy);           // discovery announcer + mDNS backend
  int get activeSessions;
  Stream<int> get activeSessionCount;                // for Draining
}
abstract interface class ReceiveScheduler { Timer once(Duration d, void Function() f); }  // monotonic
final class ReceivePlatformCaps {
  const ReceivePlatformCaps({this.maxContinuous, this.hardStopMargin = const Duration(seconds: 8)});
  final Duration? maxContinuous;                     // Android 6 h, desktop null
  final Duration hardStopMargin;
}
sealed class ReceiveEvent { }                        // StateChanged(prev,next,cause), ExpiringSoon(remaining), ExpiredWhileBusy

class ReceiveController {
  ReceiveController({required ReceiveGate gate, required ReceiveSettingsStore store, required Clock clock,
      required ReceiveScheduler scheduler, ReceivePlatformCaps caps = const ReceivePlatformCaps(),
      Stream<EnvEvent>? env});                       // EnvEvent: NetworkUp/Down, ScreenOn/Off, BatteryLow/Ok, PermissionLost/Granted
  ReceiveState get state;           Stream<ReceiveState> get states;      Stream<ReceiveEvent> get events;
  ReceiveSettings get settings;     // defaultMode, visibility, autostart, startHidden, androidWindow, receiveOnBoot
  Future<void> restore({ExitHint hint = ExitHint.unknown});   // after process start; see 1.5
  Future<void> turnOn([ReceiveMode? mode]);  Future<void> turnOff();  Future<void> resume();
  Future<void> setVisibility(ReceiveVisibility v);
  Future<void> platformTimeout();                    // Android onTimeout / onDestroy(isTimeout:true)
  Future<void> dispose();
}
```

`ReceiveEvent`s are a separate stream, not `LsEvent` subclasses: `LsEvent` is sealed in `model/events.dart` (orchestrator-owned) and the controller must stay testable without an engine. `LibreShareEngine` gains a `receive` getter and implements `ReceiveGate`; `start()` is split so that constructing the engine does not bind (the CLI keeps today's behaviour via `turnOn(const ReceiveAlways())`).

### 1.5 Persistence and crash recovery

`receive_settings.json` in the app-support dir, atomic tmp+rename like D2: `{v:1, defaultMode, visibility, autostart, startHidden, androidWindowMinutes:360, receiveOnBoot:false, runtime:{state, mode, until, cleanStop}}`. `cleanStop` is written `false` on entering On and `true` on a clean exit.
`restore()`: runtime On, `until` in the future (or Always) and not `cleanStop` -> desktop re-enters On with the remaining time; Android enters `Paused(osStopped)` unless the host passes `ExitHint.userStopped`. `until` in the past -> `Off(expired)`. Android's Task Manager "Stop" kills the process with no callback [S9], so the Android host reads `ApplicationExitInfo.REASON_USER_REQUESTED` at start and passes the hint. Expiry uses the monotonic scheduler; `until` is for display and persistence only, so moving the wall clock cannot extend a window.

### 1.6 Headless test plan (fake clock, no sockets unless stated)

Helper `test/helpers/manual_clock.dart`: `ManualClock implements Clock, ReceiveScheduler` with `advance(Duration)` firing due timers in order; `FakeGate` records calls; `FakeStore` in memory.

| Test (`test/unit/receive_controller_test.dart` unless noted) | Asserts |
|---|---|
| `off_to_always_binds_and_announces` | `openListener` once, policy `periodic`, state `On(until:null)` |
| `for_10m_expires_exactly` | On at 9:59, `Off(expired)` at 10:00, listener closed, persisted |
| `expiring_soon_fires_once_at_t_minus_15m` | one event; none for windows shorter than 15 min |
| `expiry_with_active_session_drains` | `Draining`, new session -> BUSY, finishes -> Off; drain deadline forces close |
| `platform_timeout_pauses_then_resume_gets_fresh_window` | `Paused(platformTimeout)`, `resume()` re-arms a full window |
| `visibility_change_does_not_rebind` | `setAnnounce` called, `openListener` not |
| `always_is_clamped_on_android_caps` | `ReceiveAlways` + `maxContinuous: 6h` -> `until = since + 6h` |
| `network_loss_pauses_and_auto_resumes_within_window` | `Paused(noNetwork)` -> `On`; after window end stays Off |
| `restore_after_crash_in_window / after_window / with_userStopped_hint` | three outcomes of 1.5 |
| `bind_failure_is_failed_and_leaks_no_timer` | `Failed`, `scheduler.pending == 0` |
| `turn_on_twice_and_off_during_starting_are_idempotent` | one bind, final Off |
| `wall_clock_jump_backwards_does_not_extend_window` | window ends at scheduler time |
| `test/unit/receive_settings_store_test.dart` | round-trip, atomic write, corrupt file -> defaults |
| `test/integration/receive_mode_engine_test.dart` (real engine) | Off: `GET /info` refused; On: 200; Off again: refused; Draining mid-transfer: transfer completes, next session 409 |
| Docker e2e (Inc 2 acceptance add-on) | container B Off -> A does not list B; B On -> listed within 3 s; B contacts-only (Inc 3) -> A lists B only after pairing |

## 2. Linux

### 2.1 Auto-start

- **Chosen: XDG autostart.** The app writes `~/.config/autostart/libreshare.desktop` (`Type=Application`, `Exec=<path> --hidden`, `Terminal=false`, `Icon`, `Name`; GNOME-specific keys such as `X-GNOME-Autostart-Delay` were not found in the fetched spec and are skipped). A same-named user file overrides a system one; `Hidden=true` disables; `TryExec` guards a missing binary [S19]. Works in GNOME, KDE, XFCE sessions and under Wayland (no display-server API involved).
- **Not chosen: systemd --user for the GUI.** The systemd XDG-autostart generator already turns these `.desktop` files into user units in systemd-managed sessions [S19], so a hand-written unit adds nothing and loses the per-desktop `OnlyShowIn` handling. A GUI app also needs `WAYLAND_DISPLAY`/`DISPLAY` imported into the user manager.
- **Optional, documented only:** `systemd --user` unit for the headless CLI (`ls receive --always --auto-accept`) for servers/Raspberry Pis; with `loginctl enable-linger` it needs no GUI. No GUI prompts exist in that mode, so trusted-only (Inc 3).
- **AppImage:** `Exec` must be the absolute `$APPIMAGE` path (the runtime sets it with symlinks resolved [S20]), not the mount path. On every start with autostart enabled the app rewrites the file if the path changed (self-heal after the user moves the AppImage). **.deb:** `Exec=/usr/bin/libreshare --hidden`, nothing is installed into `/etc/xdg/autostart` (opt-in only).
- Own implementation (~60 lines, `dart:io`) behind `Autostart` interface; `launch_at_startup` 0.5.1 is 19 months old and documents no argument support [S14].

### 2.2 Tray on Wayland/GNOME (verified locally)

- **Package: `tray_manager` 0.8.2** (leanflutter, MIT, Linux/macOS/Windows, needs Flutter 3.47/Dart 3.13 which matches our pin). Since 0.7.0 the Linux icon is a StatusNotifierItem over D-Bus and no longer needs `libayatana-appindicator3`; stable Id since 0.8.0; clicks are not reported on Linux, the panel opens the menu itself [S12]. Window control: `window_manager` 0.6.0 (new native API; legacy bridge deprecated) [S13]. Wrap both behind `TrayService` / `WindowController` in `apps/libreshare_app/lib/platform/` to absorb API churn.
- **GNOME reality:** GNOME has no tray; it needs the "AppIndicator and KStatusNotifierItem Support" extension (v66 lists Shell 45-51 [S18]); Ubuntu ships it enabled [S12], Fedora does not, and Fedora's packaged build lagged: v61 did not declare GNOME 50, so Shell silently disabled it [S18]. Local probe: Fedora 44, GNOME Shell 50.6, Wayland, extension not installed, no `org.kde.StatusNotifierWatcher` on the session bus [S31]. A default Fedora user therefore has **no tray**.
- **Decision:** detect a host at runtime (`NameHasOwner("org.kde.StatusNotifierWatcher")` via `dbus` 0.8.0, Canonical, MPL-2.0 [S16]; the NameOwnerChanged API was not confirmed, so poll every 10 s and create the icon when a host appears; autostart can win the race against the shell extension). Host present: tray menu + hide-to-tray on close. Absent: close button **minimizes** (the app stays reachable in the dash/Alt+Tab), `--hidden` becomes "start minimized", and Settings shows a one-time hint linking the extension. Incoming-transfer prompts also fire a freedesktop notification (`flutter_local_notifications` 22.3.3 supports Linux actions, capability depends on the notification server [S17]).
- Tray menu: `Receive: Everyone (till 18:20)` toggle, `Visibility >`, `Open LibreShare`, `Quit`.

### 2.3 Firewall, avahi

- This box: firewalld, zone `FedoraWorkstation` with `1025-65535/tcp+udp` open [S31], which is Fedora's documented default [S30], so 53318 and the multicast announce work with no prompt. avahi-daemon is active here [S31].
- Ubuntu/Debian with `ufw` enabled: inbound multicast to 224.0.0.168:53318 and TCP 53318 are dropped until allowed (UNVERIFIED on a live box; the spec s15 already says `ufw allow 53318/tcp|udp`). Packaging: the .deb ships `/etc/ufw/applications.d/libreshare` (profile "LibreShare": `53318:53327/tcp|53318/udp`) so users run `sudo ufw allow LibreShare` (UNVERIFIED mechanism, standard ufw feature); the rpm/.deb also ship a firewalld service XML. AppImage cannot install either; the in-app **"Can't see devices?"** screen prints the exact commands with a Copy button and never runs `sudo`.
- avahi missing or stopped: `bonsoir` degrades silently; multicast UDP stays the primary path.

## 3. Windows

- **Auto-start: HKCU `...\CurrentVersion\Run` value `LibreShare` = `"C:\Program Files\LibreShare\libreshare.exe" --hidden`.** Per-user, no admin, runs at logon, command line <= 260 chars, ignored in Safe Mode, and Windows may delay it [S21]; do not promise instant start. Written and removed in-app via `win32_registry` 3.0.3 [S15], not by the installer: an elevated installer run with another admin's credentials would write the wrong user's HKCU. The uninstaller calls `libreshare.exe --remove-autostart` (`[UninstallRun]`). The Startup folder is equivalent but needs a shortcut; Task Scheduler and MSIX StartupTask add elevation/cert requirements for no benefit here (elevation need for logon tasks UNVERIFIED).
- **Honest toggle state:** Task Manager / Settings > Apps > Startup record user disables under `...\Explorer\StartupApproved\Run` while leaving the Run value [community reports only, no Microsoft doc found; UNVERIFIED]. The toggle reads both and shows "Disabled in Windows Startup settings" with a button opening `ms-settings:startupapps` (UNVERIFIED URI).
- **Start minimized:** `--hidden` makes the runner skip `Show()` on the first-frame callback (edit `windows/runner/flutter_window.cpp`; avoids the flash), then `tray_manager` creates the icon (supports .ico/.png; 0.8.1 fixed clicks for elevated apps [S12]). Close button -> `window_manager` prevent-close -> hide to tray. Explorer restarts are handled by the plugin (0.5.2 fix).
- **Firewall timing:** if no allow rule exists, Windows prompts the user the first time the app tries to communicate [S22]; creating rules needs admin. Therefore: (1) the installer runs elevated (Inno default `PrivilegesRequired=admin` [S23]) and adds `netsh advfirewall firewall add rule ... profile=private,domain` for TCP 53318-53327 and UDP 53318 (spec s15), so **no prompt ever appears** and autostart at logon is silent; (2) portable zip or per-user install: the prompt appears at the first `openListener`. We make that first bind happen only from the visible first-run "Turn on Receive" button (never from an autostart-hidden launch), then store `firewallPrimed`. On Public networks the private/domain-only rule blocks us by design; diagnostics explains "network is Public".
- **Notifications:** `flutter_local_notifications` supports Windows buttons, but cancel/retrieve work only with package identity (MSIX) and init needs an AUMID + GUID [S17]. Unpackaged builds therefore cannot withdraw a stale toast: the in-app dialog is the source of truth, toasts are best effort.
- **Signing ($0):** SignPath Foundation offers free signing for OSS (OSI license, public repo, MFA for team members) [S28]; apply before the first public release to avoid SmartScreen warnings. Eligibility UNVERIFIED for 2026.

## 4. Android (best effort)

### 4.1 Verified platform facts

- `dataSync` (and `mediaProcessing`) may run 6 h per 24 h for apps targeting 35+; then `onTimeout(int,int)` fires and `stopSelf()` is due within seconds or the app crashes; new `dataSync` starts throw `ForegroundServiceStartNotAllowedException` until the user brings the app to the foreground (timer reset). "Currently this restriction only applies to dataSync and mediaProcessing" [S1].
- `BOOT_COMPLETED` may not start `dataSync, camera, mediaPlayback, phoneCall, mediaProjection, microphone` FGS [S4]. `connectedDevice` and `specialUse` are not on that list.
- `connectedDevice` needs one of: manifest `CHANGE_NETWORK_STATE`, `CHANGE_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `NFC`, `TRANSMIT_IR`, or a granted Bluetooth/UWB runtime permission [S2]. Spec s15 already declares `CHANGE_WIFI_MULTICAST_STATE`. Its stated use is "interactions with external devices that require a Bluetooth, NFC, IR, USB, or network connection" [S2].
- Background FGS start is allowed from: a visible activity, a user action on a notification/widget/activity, `BOOT_COMPLETED`, battery-optimization exemption, exact alarm, and a few others [S3]. A Quick Settings tile is **not** in the list. The tile docs say `onClick` can "launch a dialog or activity, trigger background work" and offer `startActivityAndCollapse(PendingIntent)` [S10].
- Doze suspends network and ignores wake locks for non-exempt apps; the exemption list is user-managed (Settings > Battery optimization) or via `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, which Play prohibits unless core function breaks [S8]. Whether a running FGS keeps network in Doze is **not stated** there: UNVERIFIED, measure (s6).
- Task Manager "Stop" (Android 13+) removes the whole app, no callbacks [S9]. Multicast reception requires holding a `MulticastLock`; releasing it restores the filter [S32]. Reports that multicast is dropped with the screen off are secondhand (UNVERIFIED).
- LocalSend 1.18.2 (F-Droid, Aug 2026) ships `FOREGROUND_SERVICE_DATA_SYNC`, `BIND_QUICK_SETTINGS_TILE`, `ACCESS_LOCAL_NETWORK`, "Run at startup" and "Prevent phone from sleeping" permissions (presumably boot and wake lock), and no battery-exemption permission [S24]: a tile + dataSync FGS is proven practice for this product class.
- Google Play requires a per-type FGS declaration with a video; `dataSync` must be user-initiated, `connectedDevice` means continuous transfer to an external device, `specialUse` is "limited scenarios", all reviewed [S7]. Play also now requires target API 36 for updates [S27].

### 4.2 Options compared

| Option | OS cap | From boot | Needs | Fit |
|---|---|---|---|---|
| `dataSync` | 6 h / 24 h, resets when app visible [S1] | **No** [S4] | `FOREGROUND_SERVICE_DATA_SYNC` | LocalSend's choice; restarts only with app visible |
| **`connectedDevice`** | none today [S1] | yes | `FOREGROUND_SERVICE_CONNECTED_DEVICE` + `CHANGE_WIFI_MULTICAST_STATE` | closest semantic fit (LAN peer devices); **chosen** |
| `specialUse` | none today | yes | `FOREGROUND_SERVICE_SPECIAL_USE` + `<property ..._SUBTYPE>` text | fine off-Play; free-form justification; spare option |
| Plain notification + `MulticastLock`, no FGS | n/a | n/a | `MulticastLock` | process becomes cacheable when backgrounded; only valid while the activity is visible = fallback 2 |
| WorkManager / user-initiated jobs | n/a | n/a | n/a | wrong tool: no inbound listener [S33] |

### 4.3 Recommended design

- **Service:** one `ReceiveService` declared `foregroundServiceType="connectedDevice|dataSync"`; started with `serviceTypes:[connectedDevice]` through `flutter_foreground_task` 11.0.3 (MIT, `ForegroundServiceTypes.connectedDevice/specialUse` exist, Flutter >= 3.44, Kotlin >= 2.2.20 [S11]). The plugin passes `isTimeout` to `onDestroy`, which suggests it implements `onTimeout` (UNVERIFIED); implement our own `onTimeout(startId, fgsType)` override if not: `stopSelf()` immediately, then `ReceiveController.platformTimeout()`.
- **Window:** `androidWindow` default **6 h** (choices 1 h, 6 h, 12 h, "Until I stop"). With `connectedDevice` nothing forces the stop; the window is a battery/UX guard and matches the user's 6 h expectation. At expiry: `Off(expired)` + notification **"Receiving ended - Resume"**.
- **Where the engine lives:** the plugin's `TaskHandler` runs in a separate isolate (README implies it; UNVERIFIED), so on Android `LibreShareEngine` + `ReceiveController` run inside the task isolate and the UI isolate talks to them through a `ReceiveHost` interface (in-process on desktop, port proxy on Android). This is the largest Android risk: spike it first in Inc 3; fallback is a ~150-line custom Kotlin service plus a cached `FlutterEngine`.
- **Fallback 1 (`connectedDevice` start throws, or an OEM rejects it):** start with `dataSync`, window capped at 5 h 45 m, no boot start, resume only with the app visible [S1][S4].
- **Fallback 2 (no FGS possible):** receive only while the activity is visible, `MulticastLock` held in `onResume`, banner "Receiving only while LibreShare is open".

### 4.4 Foreground-restart rules

| Trigger | `connectedDevice` | `dataSync` fallback |
|---|---|---|
| User taps the toggle in the app (activity visible) | allowed | allowed, resets the 6 h timer [S1] |
| Persistent-notification action `Extend 6 h` (service already running) | allowed, only re-arms the window | cannot extend past the OS limit |
| Post-timeout/expiry notification action `Resume` as `PendingIntent.getForegroundService` | allowed: user action on a notification [S3] | **throws** when the limit is exhausted [S1]; use `PendingIntent.getActivity` to `ResumeActivity` instead |
| Quick Settings tile tap | `onClick` -> `startActivityAndCollapse(PendingIntent)` to a transparent `ResumeActivity` that calls `startForegroundService` and finishes (visible-activity exemption) | same, and the visible activity also resets the timer |
| `BOOT_COMPLETED` (opt-in `receiveOnBoot`, default off) | allowed [S4] | **forbidden** [S4] |
| `START_STICKY` restart after process death | do not rely: UNVERIFIED that restarts are exempt; use `START_NOT_STICKY`, record `Paused(osStopped)`, surface it on next open | same |

Persistent FGS notification disappears with the service, so expiry/timeouts also post a separate, normal-importance notification (channel "Receive status") that stays until acted on.

### 4.5 Manifest delta against spec s15

Add: `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `RECEIVE_BOOT_COMPLETED`, a `BootReceiver`, `ReceiveTileService` (permission `BIND_QUICK_SETTINGS_TILE`, `ACTIVE_TILE`, `TOGGLEABLE_TILE` [S10]), `ResumeActivity` (transparent, `excludeFromRecents`). Keep `FOREGROUND_SERVICE_DATA_SYNC` for fallback 1. At target 37 add `ACCESS_LOCAL_NETWORK` and request it at runtime; at target <= 36 do not declare or request it [S5]. `NEARBY_WIFI_DEVICES`, `CAMERA` stay as in s15. Do **not** declare `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (Play policy [S8], LocalSend omits it [S24]); open the system battery-optimization list instead ("Most apps can invoke" `ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS` [S8]).

### 4.6 Reliability: Doze, OEM killers, screen state

- Settings > Receive > **"Keep receiving reliably"** card: (1) opens battery-optimization list (exempt apps keep network and partial wake locks in Doze [S8]); (2) shows a vendor tip with a link to dontkillmyapp.com; its current worst list starts Huawei, Xiaomi, OnePlus, Samsung [S25]; (3) shows `Receiving paused by the system` when `restore()` finds `Paused(osStopped)`.
- **Screen policy:** default = keep listening with the screen off for the whole window (that is the feature); `MulticastLock` stays held. Option "Only while screen is on or charging" releases the lock on `ScreenOff` (env event) and re-acquires on `ScreenOn`. Auto `Paused(batteryLow)` at < 15 % and not charging. Measure drain in the manual matrix before changing defaults.
- Never expose "Always" on Android; the toggle label is the window ("Receive for 6 h").

## 5. UX

### 5.1 Settings > Receive (desktop; Android shows the same card)

```
+--------------------------------------------------------------+
| Receive                                          [ ON  (o) ] |
| Visible to everyone on this network - until 18:20 (5 h 12 m)  |
|                                                              |
| Who can see this device                                      |
|   ( Everyone )  [ Contacts only ]  [ Off ]                   |
|   Contacts only: just devices you have paired. (needs pairing)|
|                                                              |
| Receive for         [ 10 min | 1 h | 6 h | Always ]          |
|   (Android: 1 h / 6 h / 12 h / Until I stop; no "Always")     |
|                                                              |
| Start LibreShare when I sign in              [ off ]         |
| Start minimized to tray                      [ on  ]         |
| Keep running when the window is closed       [ on  ]  (tray)  |
|                                                              |
| Android only                                                 |
|   Keep receiving reliably        [ Open battery settings ]   |
|   Receive while screen is off    [ on ]                      |
|   Resume receiving after reboot  [ off ]                     |
|   Quick Settings tile            [ Add tile ]                |
+--------------------------------------------------------------+
| Can't see devices?  [ Run network check ]                    |
+--------------------------------------------------------------+
```

Home/Nearby header: a chip `Receiving - Everyone - 5 h 12 m` (tap = this card); when `Off`/`Paused`: `Not receiving [Resume]`.

### 5.2 Notification texts

| Situation | Title | Body | Actions |
|---|---|---|---|
| Receiving (ongoing, FGS, low importance) | Receiving as "Ravi-Pixel" | Visible to everyone until 18:20 | Extend 6 h, Stop |
| 15 min before end | Receiving ends soon | Ends at 18:20. Extend to stay visible. | Extend 6 h |
| Window ended | Receiving ended | LibreShare is no longer visible to nearby devices. | Resume |
| OS timeout (`platformTimeout`) | Receiving paused by Android | Android limits background transfer services. Tap to resume. | Resume |
| Killed by system/OEM | Receiving was stopped | Your phone's battery manager stopped LibreShare. | Resume, Fix |
| No network | Waiting for Wi-Fi | Receiving resumes when you reconnect. | Stop |
| Incoming (Inc 3, high importance) | "Ravi-ThinkPad" wants to send 3 files (12 MB) | Code 482 913 | Accept, Reject |
| Desktop autostarted hidden | LibreShare is running | Receiving is on. Open it from the tray. (no tray: "Open it from the app list.") | none |

## 6. Mapping to increments

### Inc 2 (Flutter app + discovery)

- Core: `lib/src/receive/{receive_state,receive_settings,receive_controller,receive_gate,receive_scheduler}.dart`, `lib/src/storage/receive_settings_store.dart`, engine hook (`ReceiveGate` impl, split of `start()`), announcer honours `AnnouncePolicy`, `port:0` send-only probes. Tests: s1.6 (unit + `receive_mode_engine_test`), `discovery_packet_test` gains the port-0 case, Docker e2e Off/On visibility.
- CLI: `ls receive --for 10m | --always | --visibility everyone`.
- App (`apps/libreshare_app/lib/`): `providers/receive_provider.dart`, `widgets/receive_toggle.dart`, `screens/settings/receive_section.dart`, Home chip; `platform/autostart/{autostart,autostart_linux,autostart_windows}.dart`, `platform/tray/tray_service.dart`, `platform/window/window_controller.dart`, `platform/linux/tray_host_probe.dart`; runner edits `linux/runner/my_application.cc` and `windows/runner/flutter_window.cpp` for `--hidden`. Android in Inc 2 is **foreground-only** (fallback 2): `platform/android/multicast_lock` channel from the spec.
- Tests: autostart file content/idempotence/AppImage path under a temp `XDG_CONFIG_HOME`; Windows registry round-trip on `windows-latest`; widget tests for the toggle states; `xvfb-run` integration: `--hidden` start, tray absent -> close minimizes.

### Inc 3 (security, permission)

- Contacts-only visibility (needs TOFU/trust store and mTLS rejection), incoming-transfer notifications with Accept/Reject (s5.2), **Android `ReceiveService` + notification + tile + boot receiver** (`platform/android/receive_service_host.dart`, `android/app/src/main/kotlin/.../{ReceiveService,ReceiveTileService,ResumeActivity,BootReceiver}.kt`, manifest delta s4.5), the isolate spike (s4.3), `ReceiveHost` proxy.
- Tests: `ExitHint` mapping, notification-action routing unit tests, instrumented/manual `adb` checks in s6.

### Inc 5 change

Spec s12 Inc 5 says "Android FGS (`flutter_foreground_task`, dataSync) with `onTimeout`". Replace by: the Inc 3 service gains tunnel-pull support only; `dataSync` remains fallback 1.

### Sprint 6 (packaging)

`installer/windows/libreshare.iss` (admin install, firewall rules, `[UninstallRun] --remove-autostart`; the Run value is app-written, s3), `installer/linux/{libreshare.desktop,ufw/libreshare,firewalld/libreshare.xml}`, AppImage `$APPIMAGE` self-heal, "Can't see devices?" diagnostics, SignPath application, F-Droid metadata, manual matrix: Pixel Android 15/16 and one Xiaomi/Samsung; `adb shell am compat enable FGS_INTRODUCE_TIME_LIMITS <pkg>` + `adb shell device_config put activity_manager data_sync_fgs_timeout_duration 60000` (fallback 1 path) [S1]; `adb shell dumpsys deviceidle force-idle` with screen off for 30 min, with and without battery exemption (resolves the Doze UNVERIFIED) [S8]; `adb shell cmd activity stop-app <pkg>` [S9]; Windows 11 with firewall rule present/absent; GNOME with and without the extension.

### Changes the orchestrator must make to the existing plan

1. Spec s12 Inc 5 and `CLAUDE.md` Gotchas ("dataSync FGS must handle onTimeout"): Android FGS moves to Inc 3, type `connectedDevice` primary, `dataSync` fallback; every FGS type handles `onTimeout`.
2. Spec s15 Android manifest and s1 stack table: manifest delta of s4.5; add `tray_manager` 0.8.2, `window_manager` 0.6.0, `win32_registry` 3.0.3, `dbus` 0.8.0 (app only); do not add `launch_at_startup`. Re-check pins with `dart pub outdated` (versions are 2026-11-03 snapshots).
3. Shared contracts (orchestrator-owned): `LibreShareEngine` implements `ReceiveGate` and no longer binds in `start()`; `LSP-1.md` discovery section + `discovery-announce.schema.json` + conformance test for `port:0` (s1.3).
4. `docs/traceability.md`: add FR-18 "Receive mode (Off / timed / always, visibility, platform pause/resume)" -> `receive/*`, tests of s1.6, Inc 2 (Contacts-only part Inc 3); add NFR-09 "Auto-start per OS" -> `platform/autostart/*`, Sprint 6 manual matrix.
5. Spec s9 UI list: add the Receive card and chip (s5.1) to Settings and Home; spec s16 risk row "Android 6 h dataSync cap" becomes the risk table below.
6. Spec s15 Windows installer: firewall rules stay; add the `--remove-autostart` uninstall step and the first-run priming rule (s3).

### Risks

| Risk | Mitigation |
|---|---|
| Plugin isolate model or `onTimeout` handling differs from README | Inc 3 spike first; custom Kotlin service fallback |
| `tray_manager`/`window_manager` just moved to a new native API (0.7.0 / 0.6.0) | wrap behind interfaces, pin exact versions |
| No tray on default GNOME | minimize-on-close fallback is the default behaviour, tested under `xvfb` |
| OEM killers defeat the FGS | `Paused(osStopped)` surfaced; vendor guidance; document as best effort |
| Doze may suspend network despite FGS | measure; battery-exemption card |
| Windows unpackaged toasts cannot be cancelled | in-app dialog is authoritative |
| Always-on listener widens attack surface | consent prompt for strangers (spec s5), 120 s timeout, rate limits, contacts-only (Inc 3), default visibility prompts only |

### Open questions for the user

1. Android "Until I stop" (no window): allow it behind a battery warning (recommended), or hard-cap every window at 12 h?
2. Desktop auto-start default: opt-in at first run (recommended: an always-listening device should be a conscious choice) or on by default?
3. Windows installer: require admin so the firewall rule is silent (recommended), or offer a per-user install where the first Receive shows the Windows firewall prompt?
4. Confirm Google Play is out of scope (US$25 fee, FGS review) so Android ships via GitHub Releases + F-Droid/IzzyOnDroid only.
5. Which OSI license will the project use? SignPath free Windows signing and F-Droid inclusion both require one [S28].

## Sources (fetched 2026-11-03)

- [S1] https://developer.android.com/develop/background-work/services/fgs/timeout
- [S2] https://developer.android.com/develop/background-work/services/fgs/service-types
- [S3] https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- [S4] https://developer.android.com/about/versions/15/behavior-changes-15
- [S5] https://developer.android.com/privacy-and-security/local-network-permission
- [S6] https://developer.android.com/about/versions/17/behavior-changes-17
- [S7] https://support.google.com/googleplay/android-developer/answer/13392821
- [S8] https://developer.android.com/training/monitoring-device-state/doze-standby
- [S9] https://developer.android.com/develop/background-work/services/fgs/handle-user-stopping
- [S10] https://developer.android.com/develop/ui/views/quicksettings-tiles
- [S11] https://pub.dev/packages/flutter_foreground_task (11.0.3, published about 56 days before 2026-11-03) and /changelog; enum: https://raw.githubusercontent.com/Dev-hwang/flutter_foreground_task/master/lib/models/foreground_service_types.dart
- [S12] https://pub.dev/packages/tray_manager (0.8.2, published about 36 h before fetch) and /changelog
- [S13] https://pub.dev/packages/window_manager (0.6.0)
- [S14] https://pub.dev/packages/launch_at_startup (0.5.1, about 19 months old)
- [S15] https://pub.dev/packages/win32_registry (3.0.3)
- [S16] https://pub.dev/packages/dbus (0.8.0)
- [S17] https://pub.dev/packages/flutter_local_notifications (22.3.3)
- [S18] https://extensions.gnome.org/extension/615/appindicator-support/ ; https://github.com/ublue-os/bluefin/discussions/4574 (v61 lacked GNOME 50; secondary)
- [S19] https://specifications.freedesktop.org/autostart-spec/latest/ar01s02.html ; https://man.archlinux.org/man/systemd-xdg-autostart-generator.8.ar.txt
- [S20] https://docs.appimage.org/packaging-guide/environment-variables.html
- [S21] https://learn.microsoft.com/en-us/windows/win32/setupapi/run-and-runonce-registry-keys
- [S22] https://learn.microsoft.com/windows/security/operating-system-security/network-security/windows-firewall/rules (via search snippet)
- [S23] https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm
- [S24] https://f-droid.org/packages/org.localsend.localsend_app
- [S25] https://dontkillmyapp.com/
- [S26] https://support.google.com/googleplay/android-developer/answer/6112435
- [S27] https://developer.android.com/google/play/requirements/target-sdk
- [S28] https://signpath.io/product/open-source (via search snippet)
- [S29] https://support.apple.com/en-au/119857 (AirDrop receiving options, via search snippet; "awake and unlocked" is third-party only, UNVERIFIED)
- [S30] https://fedoramagazine.org/control-the-firewall-at-the-command-line/ (FedoraWorkstation zone opens 1025+)
- [S31] Local read-only probes on this box: `gnome-shell --version` (50.6), `busctl --user` (no StatusNotifierWatcher), `rpm -q` (appindicator absent), `firewall-cmd --list-all`, `systemctl is-active avahi-daemon firewalld`.
- [S32] https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock (via search snippet)
- [S33] https://developer.android.com/about/versions/15/changes/datasync-migration (WorkManager/UIDT for transfers; `connectedDevice` for local-device data transfer)

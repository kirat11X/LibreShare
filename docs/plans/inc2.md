# Increment 2 — Discovery + cross-platform (Sprint 2)

Source: spec §4.2, §12 Increment 2. Linux-first (user priority: Linux & Windows first-class, Android best-effort).

## Phase 1 (core, headless) — parallel subagents
- **A1** `discovery/{announce_codec,multicast_transport,multicast_discovery,peer_registry}.dart`: UDP multicast 224.0.0.168:53318 announce/listen, self-filter, 90 s expiry, 20 pkt/s/IP limit, `PeerRegistry implements PeerSink`.
- **A2** `discovery/{subnet_scanner,manual_peer,peer_registrar}.dart`: /24 scan via `GET /api/v1/info` (64 concurrent, 800 ms), `libreshare://peer?...` parse/build, `PeerRegistrar` (POST /register).
## Phase 2
- Engine + CLI integration (`ls devices`), `/info` reports bound port (bug found in Inc 1), Docker two-container e2e (`tools/docker`), Flutter app (Home/Nearby, Send flow, Settings, Receive toggle), bonsoir `MdnsBackend`, Android MulticastLock channel, CI builds.
## Acceptance (spec)
FR-01 port fallback + announced port is the bound port · FR-02 two Docker containers discover ≤3 s; UDP 53318 dropped → subnet scan ≤10 s · FR-03 name/IP/platform shown · FR-04 selecting a device starts a session · NFR-01 zero config · NFR-05 CI artifacts (Linux built+tested here; Windows/APK in CI only).
## Known limits
No Android SDK / xvfb on dev box: APK + `xvfb-run` integration tests deferred to CI. Windows `FileMode.append`+`setPosition` to re-verify in Windows CI.

## Outcome / deviations — Phase 2 stage 1 (engine, Receive mode, CLI)

Done and proven (all by real exit codes on the dev box): `dart format --output=none --set-exit-if-changed .` 0; `dart analyze --fatal-infos` 0; core `dart test` 0 (**975 passed, 1 skipped**: the 5 GiB test; was 856 before Inc 2); CLI `dart test` 0 (**41 passed**; was 12); `tools/loopback_smoke.sh 100 <free port>` 0 (5.20 s = 19.2 MiB/s, no regression). The new test files were run three times each with no flake.

- **Receive mode** (pure Dart, design 01 section 1): `receive/{receive_state,receive_gate,receive_scheduler,receive_settings,receive_controller}.dart` and `storage/receive_settings_store.dart` (atomic JSON). Off / For(N) / Always, visibility, drain, platform pauses, crash restore. Tests: `unit/receive_controller_test.dart` (37, injectable clock and scheduler), `unit/receive_settings_store_test.dart` (11), `integration/receive_mode_engine_test.dart` (13, real sockets and a real clock).
- **Engine** is the `ReceiveGate`. New API: `receive`, `devices`, `currentDevices`, `refresh()`, `scanNetwork()`, `addManualPeer(ip, port)`, `addPeerLink(PeerLink)`, `myPeerLink`, `sendTo(device, files)`. `sendFiles` is unchanged. Discovery (multicast, subnet scan, register-back, optional `MdnsBackend`) is configured by `DiscoveryConfig`; the transport is injectable. Tests: `integration/engine_discovery_test.dart` (31), `unit/multicast_probe_test.dart` (9), `unit/startup_test.dart` (7).
- **Inc 1 bug fixed:** `GET /info`, `POST /register` and outgoing sessions reported the *requested* port. The engine builds `DeviceInfo` after binding (`FileReceiver.selfProvider`).
- **Port 0 = send-only probe** (LSP-1 section 4.2 rules 2 and 8, `discovery-announce.schema.json`, `announce_codec_test.dart`, `schema_conformance_test.dart` together). A device that is not receiving announces port 0 so receivers answer it; receivers never record, register with or list a probe.
- **CLI:** `ls devices [--timeout 5] [--json] [--scan] [--listen]`, `ls receive [--for 30m | --always] [--visibility everyone] [--no-discovery]`, `ls info` (no `--to`: this device), `ls send --device NAME|ID-PREFIX|LINK`, `ls peer-link [LINK]`. `runCli(args, {hooks})` takes a `CliHooks` (output, discovery, bind address, stop signal) so tests run several commands in one process. All Inc 1 output lines (`LISTENING`, `SESSION`, `RECEIVED`, `COMPLETED`, `FAILED`, `SENT`) and exit codes are unchanged; new lines: `PEER-LINK`, `WINDOW until=`, `EXPIRING`, `EXPIRED`, `DEVICE`, `DEVICES n`, `FOUND`/`LOST` (listen mode).

Deviations from the plan, and why:
1. **New behaviour is opt-in where an existing test encodes the old one.** `encodeAnnounce(probe:)`, `decodeAnnounce(allowProbe:)` and `MulticastDiscovery(probes:)` default to the Inc 1 behaviour (port 0 invalid); the engine turns them on. `LibreShareEngine(...)` defaults to `DiscoveryConfig.disabled` and `ReceiveAlways`, so a plain engine still binds in `start()` and touches no network beyond its listener. `start()` returns 0 when Receive is Off.
2. **One existing assertion was replaced, as instructed:** "port=0 invalid" in `conformance/schema_conformance_test.dart`. Port 0 is now valid for `announce:true` and still invalid for `announce:false`; the old cases and new probe cases are asserted there.
3. **Additive edits to shared files:** `FileReceiver` (optional `selfProvider`, `acceptingSessions` -> 409 `BUSY` while draining, `activeSessionCount` and its change stream) and `ApiServer` (optional `onRegister`). Nothing was removed or renamed.
4. **Contacts-only visibility** is refused (`UnsupportedError`; CLI exit 64) until pairing exists (Inc 3). `AnnouncePolicy.replyToTrusted` is therefore a probe for now.
5. **`myPeerLink` is nullable:** null while no listener is open or no address is usable.
6. **`restore()` / `cleanStop`:** a clean `stop()`/`dispose()` stores `cleanStop` and the next start stays Off(user); only a crash inside the window (or `ExitHint.unknown` with `resumeAfterCrash`) restores On with the time left. `ReceiveController.shutdown()` is reusable (stop then start); `dispose()` is final.
7. **CLI `receive` does not persist settings** (in-memory store): every run states its mode on the command line.

Bugs / limits found, not fixed here (outside the owned files or the plan):
- `ApiServer.stop()` called a second time is a no-op, so the engine's "grace, then force" close never forces if the first call is still waiting.
- `PeerRegistry` cannot remove a peer on request: a device that goes Off still lingers in other devices' lists for up to 90 s (expiry only). An explicit "goodbye" datagram would fix it (protocol change, Inc 3).
- The subnet scan probes only the default port, so a peer on a fallback port (53319..) is found by multicast, `POST /register` or a link, not by the scan.
- Real multicast was delivered on the dev box, so the real-process test ran; on hosts without multicast it skips itself. The Docker two-container timings (<= 3 s, <= 10 s with UDP 53318 dropped) are still unmeasured.

Hand-over to the next agents (app, Docker, CI): build the app on `engine.devices`, `engine.receive.states` / `events` and `ReceiveConfig(store: FileReceiveSettingsStore(dir), env: <network/battery/permission stream>, caps: ...)`; pass a `DiscoveryConfig(mdns: <bonsoir backend>)`; use `engine.start()` only for the initial mode and drive Receive with `engine.receive.turnOn/turnOff/resume`. Tests of other packages that need several devices in one process can copy `test/helpers/discovery_rig.dart` (an in-memory multicast bus plus one loopback alias `127.0.0.N` per engine).

## Outcome / deviations — Phase 2 stage 2 (Flutter app, platform glue, Docker e2e), closed 2026-11-04

Done and proven by real exit codes on the dev box (orchestrator re-run, not only the agents' reports): `dart format --output=none --set-exit-if-changed .` 0; `dart analyze --fatal-infos` 0; `flutter analyze` 0; core `dart test` 0 (**1008 passed, 1 skipped**); CLI `dart test` 0 (**41 passed**); app `flutter test` 0 (**249 passed** = 128 platform + 121 UI/widget; 3 consecutive clean runs by the agent, 1 by the orchestrator); `tools/loopback_smoke.sh 100 53400` 0; `tools/docker/run_local.sh` 0 (PASS, 31 assertions, 97 s incl. image build, no containers left); `flutter build linux --debug` 0; `flutter build apk --debug` and `--release` 0 (project-local JDK 17 + Android SDK, see `docs/dev/android-toolchain.md`).

- **App** (`apps/libreshare_app`): Home/Nearby, Send flow, Add device (manual, pasted link, QR scan), My QR, Incoming-transfer dialog (Accept/Reject: consent is mandatory because `autoAccept=false` until Inc 3), Transfer progress/result, Settings with the Receive section and autostart. Built on `engine.devices`, `engine.receive`, `engine.beginSendTo`; real `LibreShareEngine`s over the in-memory multicast bus in the widget tests.
- **Platform glue** (`lib/platform/**`): XDG autostart `.desktop` (Linux), HKCU `Run` (Windows, behind a registry interface), tray + window show/hide/close-to-tray/`--hidden`, bonsoir mDNS backend, Android `MulticastLock` method channel (Kotlin), network environment polling.
- **Docker e2e** (`tools/docker/`): alice/bob/carol/tester on one /24 bridge; see `docs/test-reports/inc2-docker.md`.

Defects found while closing the increment, and fixed:
1. **`FileSender.cancel()` race (core).** A cancel arriving after the receiver created the session but before the sender read the `createSession` reply was lost; the receiver's prompt stayed up until the 120 s timeout. Fixed in `transfer/file_sender.dart` (a local cancel always tells the peer; cancel while the manifest is hashed is honoured; one `/cancel` per run), 12 new `file_sender_test.dart` tests, 6 of which failed before the fix.
2. **UI bypassed the engine for sending** (`OutgoingRun` used `FileSender`/`ApiClient`). Added `engine/outgoing_send.dart` (`OutgoingSend`: per-send events, `result`, idempotent `cancel()`) with `LibreShareEngine.beginSendFiles/beginSendTo`; `sendFiles`/`sendTo` are now thin wrappers. The app's `OutgoingRun` was deleted; `grep -rnE "FileSender|ApiClient|PeerClient" apps/libreshare_app/lib` is empty. 17 new engine tests.
3. **"Start minimized" was a dead switch**: `--hidden` always hid the window. `ShellBridge.start()` now honours the saved setting and always shows the window when the engine failed to start.
4. `PlatformLog.sink` was not connected to an app logger (`services/app_logging.dart`); `quit()` made idempotent.
5. Flakes in two UI tests were test-side races (route transition; engine rebuild) and were fixed in the tests without weakening assertions.

Known limits carried forward (not defects of this increment):
- **Never run on real hardware:** Windows registry autostart, tray and `window_manager`; the Android app (APK builds but has never been installed — no device/emulator here); the GNOME tray (no AppIndicator host on the dev box; the app shows a minimized window instead). The Linux bundle was launched once headless-safely (`--hidden`, 12 s, no crash) but no screenshot was taken.
- **Android release APK is signed with the debug key** (prototype only); `mobile_scanner` pulls Google ML Kit/Play-services components (QR scanning on GMS-less devices is unverified; Huawei is a target market).
- `PeerRegistry` cannot remove peers (a device switched Off lingers ≤ 90 s) — fixed in Inc 3 (`bye` datagram). The subnet scan probes only the default port and assumes /24.
- NFR-02 (≥ 300 MB/s loopback) is **not** met: AOT loopback is ≈ 30 MB/s (CPU-bound, hashing suspected). Inc 4 profiles first.
- Integration tests under `integration_test/` need `xvfb` (not installed here); they run in CI only.

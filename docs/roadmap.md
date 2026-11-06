# LibreShare roadmap (consolidated 2026-11-03)

Baseline: `docs/LIBRESHARE_BUILD_SPEC.md` (Inc 1–5 + Sprint 6). Extension designs: `docs/design/01…04`.
Binding product constraints: **everything free ($0)**; Linux + Windows first-class; Android best-effort; macOS best-effort; iOS/HarmonyOS not covered.
Increments stay strictly sequential (spec §12): N+1 starts only when N's acceptance tests pass.

## Order

| Inc | Scope | Source | Est. effort* | Status |
|---|---|---|---|---|
| 1 | Basic transfer: chunker, API server/client, sender/receiver, CLI | spec | — | **done** (551 core + 12 CLI tests; 100 MiB loopback byte-identical) |
| 2 | Discovery (multicast, subnet scan, QR/manual, mDNS), Flutter app (Home/Send/Settings), **Receive mode** (core `receive/`, engine `ReceiveGate`), desktop auto-start + tray, `/info` reports bound port | spec + design 01 | 1 sprint | **done 2026-11-04** (core 1008 + CLI 41 + app 249 tests; Docker e2e PASS; Linux build and Android APK build OK; Windows/macOS CI-only) |
| 3 | Security: mTLS, SAS, TOFU, PIN, rate limit, consent UI; **Android `ReceiveService` (type `connectedDevice`)**; pairing QR reserves `s=`; nullable `K_pair`; Contacts-only visibility | spec + 01 + 02 | 1 sprint | planned |
| 4 | Connection ladder + fallback + resume; `Candidate` made extensible (per-candidate budget, setup/teardown hook); **AOT/native hashing for NFR-02** | spec + 03 | 1 sprint | planned |
| 5 | Tunnel + share link/QR with **`tunnel_crypto` v2** (see amendments), Cloudflare Quick Tunnel, zrok, manual URL | spec + 04 | ~22 pd | planned |
| 5b | IPv6 + UPnP/NAT-PMP/PCP direct paths (ephemeral TLS, pinned in link), "Hide my IP" | design 04 | ~14 pd | planned (committed) |
| 6 | **Free internet rendezvous** for paired devices (Nostr public relays, ntfy backup), pairing by QR | design 02 | ~25 pd | planned |
| 7 | **BLE discovery + hotspot handoff**: 2-day real-radio spike → Phase A (BLE + LAN addr + QR) → Phase B (hotspot). Order: Linux↔Android, Windows↔Android, Linux↔Windows (experimental) | design 03 | ~8.5 + 8.5 pw | planned (committed; spike may cut to Phase A) |
| P | Polish + packaging (installers, AppImage/.deb, APK, release workflow, docs) | spec Sprint 6 | 1 sprint | planned |

*Estimates come from the design docs (one experienced dev); they are not measured. pd = person-days, pw = person-weeks.

## Defaults adopted (overturn any of these)

1. **"Free" = best-effort public relays + user-replaceable endpoints.** Nostr relays (primary) and ntfy.sh (backup) have no SLA; rendezvous is "last seen" presence, and manual link/QR always works without them. Relays see IP/timing of encrypted blobs; this is disclosed in-app.
2. **Android:** foreground service type `connectedDevice` (spike first in Inc 3; fallback `dataSync` with a 5 h 45 m window, then foreground-only). App-level receive window defaults to 6 h → Off; a Receive toggle / notification action / Quick Settings tile (via trampoline activity) resumes it. Distribution: GitHub Releases + F-Droid/IzzyOnDroid; **Google Play out of scope**. `targetSdk` 36.
3. **Desktop auto-start is opt-in at first run**; written by the app (XDG `.desktop` on Linux, HKCU `Run` on Windows).
4. **Windows installer runs as admin** (silent firewall rules).
5. **IP privacy:** share links to strangers are tunnel-first; direct (IPv6/UPnP) paths are opt-in for links and allowed for paired devices, with a one-line disclosure.
6. **cloudflared is downloaded on first use with a pinned SHA-256** (not bundled): smaller installers, fewer antivirus flags. Never pass `--allowed-mail`.
7. **BLE:** `flutter_blue_plus` rejected (central-only, restrictive licence); evaluate `universal_ble` behind a `BleBackend` interface after the spike. Windows hotspot/join needs C++/WinRT (Dart WinRT packages discontinued).
8. Rendezvous offers **never auto-accept**.

## Spec amendments to apply when each increment is reached

- **Inc 2:** `LibreShareEngine` implements `ReceiveGate` and `start()` stops binding; engine builds `DeviceInfo` after bind (fixes `/info` returning requested port). `discovery-announce.port` min 0 = "send-only probe, don't register back" (update LSP-1.md + schema + conformance test together). Add FR-18 (Receive mode), NFR-09 (auto-start).
- **Inc 3:** move Android FGS here from Inc 5; update the CLAUDE.md gotcha at that time. Manifest delta per design 01 §4.5. Add LSP/1.1 additive items from design 03 (`ble1` cap, optional `offerId`) only when Inc 7 starts.
- **Inc 5 (security-relevant):** replace the spec's deterministic `fileIndex‖chunkIndex` AES-GCM nonce with HKDF purpose subkeys + random 96-bit nonces + canonical AAD (design 04 §3.3: the spec leaves the ack nonce undefined, so keystream reuse is possible, and it is unsafe if a file changes mid-share or a session resumes after restart). "One-time link" = one authenticated completion, not GET count. Receivers reject private/loopback hosts in links (SSRF). Never log tokens (redacting logger). Widen Windows firewall range to 53318–53349.
- **Inc 6:** new `docs/protocol/LSP-R1.md` + schemas, ADR 0003 (no hole punching); FR-19–21, NFR-10 ($0), NFR-11 (works with every backend down); never log `S` or `K_pair`.
- **Spec §1/§15:** add `tray_manager`, `window_manager`, `win32_registry`, `dbus` (app only; re-check with `dart pub outdated`); replace `flutter_blue_plus`; Windows needs `wiFiControl` capability, not Proximity.

## Known risks carried forward

Cloudflare Quick Tunnel has no SLA and ambiguous large-file terms; campus networks may block port 7844; UPnP/IPv6 success rates unmeasured; **measured AOT loopback ≈30 MB/s (CPU-bound, 10× below the NFR-02 300 MB/s target; Docker run 2026-11-03, `docs/test-reports/inc2-docker.md`)**. Likely cause (hypothesis, not yet profiled): pure-Dart SHA-256 (≈70 MB/s JIT) is run several times per byte and partly serially — sender per-chunk hash then upload, receiver per-chunk verify plus a whole-file hash only after the last chunk. Inc 4 must profile first, then fix (hash while streaming/in order, overlap with I/O, native/FFI hashing in the app layer); Windows `FileMode.append`+`setPosition` unverified; Bluetooth is soft-blocked on the dev box so BLE cannot be tested here; no Android SDK / `xvfb` on the dev box (APK builds and `xvfb-run` tests run in CI only).

## Decisions made by the user (2026-11-03)

1. **Licence: MIT** (`LICENSE`, "LibreShare contributors" as holder; change the holder name if you prefer a personal/organisation name).
2. **Scope: Inc 5b, 6 and 7 are committed work** ("yeah lets try"), not stretch. They still follow the strict order above; Inc 7 starts with its 2-day real-radio spike and may be cut back to Phase A if the spike says no-go.

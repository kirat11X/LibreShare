# Increment 7 - BLE discovery + hotspot handoff ("LS-BLE/1"): Phase A (BLE + LAN address + QR) and Phase B (hotspot)

Status: **PLAN ONLY. Not started.** Written by the orchestrator, 2026-11-06 20:54:54 (real `date`). No code, tests or builds were run for this document except one read-only hardware look (section 0 item 1).
Sources: `docs/design/03-ble-hotspot.md` (main source; its step numbers "6.x" are renamed **7.x** here because the roadmap numbers this Inc 7), `docs/roadmap.md` (Inc 7 committed by the user 2026-11-03, "spike may cut to Phase A"), `docs/plans/inc4.md` (Candidate hook), `docs/plans/inc3.md` (SAS, trust store), `docs/design/01-autostart-receive-mode.md`.
Evidence tags: **UNVERIFIED** = not confirmed by a source I read or a run. Estimates are person-weeks for one engineer who knows Dart, hardware access included; they are not measured for agents.

## 0. Findings that shape the plan
1. **Hardware reality (read-only look 2026-11-06 20:54 by `date`):** this laptop has `hci0` (BlueZ 5.87, **soft blocked: yes**, so the user must unblock it: `rfkill unblock bluetooth`; I did not change it) and `phy0` (Wi-Fi, NetworkManager present). That covers the Linux leg of the spike. The Android leg is the user's phone (the screenshot showed a POCO X6 Neo 5G; Android version, LOHS support and STA+AP support **UNVERIFIED**). No Windows machine is known to exist: **every Windows item is blocked** until the Windows route (post-mvp D1) is decided.
2. **This container cannot test radios.** CLAUDE.md: no GUI/Wi-Fi radio here; never test Wi-Fi Direct/hotspot in the container. So Phase A/B split into (a) **headless core**: codecs, state machine, host policy, fakes, schemas, Docker e2e with a fake BLE bus; (b) **radio work**: runs only on the user's devices with `LS_RADIO=1`, results recorded by hand in `docs/test-reports/`.
3. **Order differs from the design on one point:** the design runs the 2-day real-radio spike first (go/no-go for the package choice D8). The pure core (7a) does not depend on that choice (it sits behind `BleBackend`), so **7a-core starts in parallel with waiting for the user's spike time**. Only 7b+ (platform backends) wait for the spike verdict.
4. **Inc 4's `Candidate` must support setup/teardown + per-candidate budget** (design 03 section 3.9, ADR 0002). The Lead's Inc 4 code defines `Candidate`/`ConnectionManager`; whether it already has the setup hook is unchecked (Inc 4 not accepted). Wave 0 of this increment starts with a read of that code and, if needed, an orchestrator-owned contract patch.
5. **Protocol:** additive LSP/1.1 only (`caps: ble1`, optional `offerId`, `peerAdvKey` field in the trust store, `ChannelActive.kind = hotspot`). BLE messages get their own JSON schemas.
6. **Security stance (design 03 D1/D4/D5):** BLE is a control plane only; files always move over LSP/1 on an IP path; hotspot credentials only inside an AEAD channel over GATT (QR as fallback), never in an advert; **receiver consent precedes any hotspot action**; idle devices are scan-only, advertising is time-boxed (10-minute "Everyone" window).

## 1. Scope
**Phase A (8.5 pw in the design):** `ble/` module (`beacon_codec` (manufacturer data, company id `0xFFFF`, magic `LS`, <= 27 bytes), rotating 8-byte EID from HMAC with per-device `advKey`, visibility modes (Contacts / Everyone-10-min / Off), GATT secure channel (ephemeral X25519 + signed transcript + AEAD), `ble_session` state machine, `BleBackend` interface, `FakeBleBus`), LAN address exchange (AP isolation/multicast-blocked case), QR fallback for no-BLE; LSP/1.1 additions + schemas; UI (nearby list, visibility switch, copy from design 03 4.4); Linux backend (`dbus` own code: advertise, GATT server, scan), Android backend (permissions by API level, scan with PendingIntent, wake notification).
**Phase B (8.5 pw):** `HotspotCandidate`/`WifiDirectCandidate` with setup phase; `host_policy.chooseHost`; `FakeHotspot`/`FakeAir`; Android LocalOnlyHotspot + `WifiNetworkSpecifier` join (`bindProcessToNetwork`), Linux NM hotspot + join via `nmcli`; honest-copy dialogs; teardown/restore; cut-and-fallback via the Inc 4 machinery.
**Out:** macOS/iOS (design 03 section 2.5); Windows hosting offline (legacy AP, UNVERIFIED); Linux<->Windows except as an experimental flag; Android 17 `ACCESS_LOCAL_NETWORK` target (stay on targetSdk 36, open an issue).

## 2. Decisions (defaults flagged; the user may overturn)
| # | Decision | Default |
|---|---|---|
| D1 | Scope | **Phase A is committed. Phase B only for Linux<->Android**, behind the spike verdict; Windows items parked until a Windows route and machine exist. |
| D2 | Default visibility | Contacts-only + explicit 10-minute "Everyone" window (a permanent "visible to everyone" would make Linux's static BLE address a permanent beacon). |
| D3 | Internet interruption | A desktop with one Wi-Fi radio may drop its internet for ~1 minute when hosting/joining, **after the honest-copy confirmation**; otherwise refuse unless Ethernet / second adapter / Android host. |
| D4 | Company id | SIG test id `0xFFFF` (free, collision-prone); real SIG assignment parked (terms UNVERIFIED). |
| D5 | Packages | `universal_ble` behind `BleBackend` (Android/Windows), own `dbus` code on Linux, own Kotlin (+ C++/WinRT later) for hotspot; **reject `flutter_blue_plus`**. Any new dependency = orchestrator edits `pubspec.yaml` after the spike; `dart pub outdated` re-check first. |
| D6 | Android target SDK | stay on 36. |
| D7 | Rotating EIDs | HMAC-derived, epoch +-1 tolerance; unpaired devices use random EIDs; no names/fingerprints in beacons. |

## 3. The spike (7.0, real radios, 2 days of the user's time; I cannot run it)
Four unknowns (design 03 7.1): (1) a manufacturer-data beacon from a desktop is seen by Android with `neverForLocation`; (2) BlueZ `broadcast` seen by a filtered Android scan with the screen off; (3) an Android LOHS joined by `nmcli` on this Fedora laptop; (4) `universal_ble` parity on Android (+ Windows later). **Needed from the user:** `rfkill unblock bluetooth`, the phone with developer mode, location on, ~2 hours per leg, and a written note of Android version/OEM. Output: `docs/test-reports/inc7-spike.md` with go/no-go per unknown. A "no" on (1)/(2) collapses Phase A to QR + LAN exchange; a "no" on (3) cuts Phase B.
Parallel read-only spikes I can do without hardware: S7-A `dart pub outdated` + pub.dev facts for `universal_ble`, `dbus`, `bluez`; S7-B what Inc 4's `Candidate` already offers (setup hook, budget); S7-C read the Android manifest/permissions diff needed per API level.

## 4. Waves (tester red -> coder green -> different verifier -> orchestrator gate; **security-critical, second tester: GATT secure channel, EID/advKey, consent-before-hotspot, credential handling**)
| Wave | Content | Gate |
|---|---|---|
| 0 (orchestrator) | `inc7-seams.md`, LSP/1.1 text + schemas (`ble1`, `offerId`, BLE messages), `BleBackend`/`HotspotBackend`/`Candidate`-setup contracts, CLAUDE.md gotcha "radio tests need `LS_RADIO=1`" | conformance tests; `INC7_WAVE0: APPLIED` |
| A1 | `beacon_codec`, EID derivation, visibility/time-box, `FakeBleBus` | golden vectors; EID +-1 epoch; fuzz of frame fragmentation (random MTU, reorder, truncation) |
| A2 | secure channel + `ble_session` state machine | tampered M1/M2/AUTH, replay, wrong fingerprint, SAS equality; rate limits; redaction test |
| A3 | engine integration: nearby list, LAN address exchange, consent, rejection path | two engines in one process over `FakeBleBus`: paired send, unpaired requires SAS + accept, **reject creates no hotspot/mapping side effect** |
| A4 | UI + copy + Linux backend (radio, `LS_RADIO=1`) | widget tests; manual rows R1, R6, R7 |
| A5 | Android backend (permissions per API 29/31/34/35-36, scan, wake notification) | manifest/permission tests; manual row R4 |
| B1 | `host_policy.chooseHost` (all 3x3 platform pairs + uplink flags), `FakeHotspot`/`FakeAir`, hotspot candidate lifecycle | table tests; hotspot cut at 40% -> `fallbackToNext()` with no acked chunk re-sent; LAN-reachable case never starts a hotspot; teardown asserted |
| B2 | Android LOHS + Specifier join, Linux NM host/join | manual R4, R5; failure copy per error code |
| B3 | Docker: `ble-bus` container (fake bus over TCP) + `hotspot_net` blackholed with `tc netem`, `FakeHotspot.join` runs restore | e2e, every assertion mutation-checked (the E1 lesson) |
| C (parked) | Windows C++/WinRT BLE + Wlan join; Linux<->Windows experimental | blocked on the Windows route |

## 5. Tests
Unit/conformance/integration as in design 03 6.3 (names to be fixed in `inc7-seams.md`); radio tests carry `@Tags(['radio'])` and run only with `LS_RADIO=1`; CI greps that `packages/libreshare_core/lib` imports neither Flutter nor `platform/`. Manual matrix (record each row in `docs/test-reports/inc7-matrix.md`): R1 this Fedora laptop, R4 Android (the user's phone first), R5 STA+AP yes/no, R6 AP-isolation network, R7 passive sniff (second adapter, optional), R8 range 1/5/10 m. R2, R3 (Ubuntu+ufw, Windows) are parked with the Windows route.

## 6. Effort (estimates, person-weeks)
Design: Phase A 8.5 + Phase B 8.5 = 17 pw including Windows and hardware time. With Windows parked (about 4 pw of the total) and Linux<->Android only: **~13 pw**, of which headless core + fakes + docs ~4 pw are agent-friendly and the rest is device time of the user. Add ~1 pw orchestrator (seams, protocol, gates). Agent wall-clock is dominated by the heavy lock and by the user's availability for radio rows.

## 7. Risks
Android background wake is OEM-dependent (HyperOS/MIUI battery managers kill FGS); LOHS flakiness (Briar reports); Location services must be on; BlueZ static address (no privacy without root); Windows 11 24H2 location gating; 2.4 GHz crowding; Linux hosting costs the Wi-Fi uplink; the Lead's history of untested claims (radio results must be pasted logs with timestamps, never summaries).

## 8. Free-tooling check
No paid service, no account, no cloud. BLE/hotspot are on-device OS APIs. Test tooling: `bluetoothctl`, `btmon`, `nmcli`, `iw` (all present or installable free). Optional nRF sniffer is hardware, not required.

## 9. Done criteria (real exit codes, alone)
Phase A done = headless suite green (counts >= Inc 6 closing + new; every new file 3x; mutation table for beacon/EID/secure channel/consent guards; analyze/format rc 0; no-Flutter grep rc 1; Docker `ble-bus` scenario mutation-checked) **and** manual rows R1, R4, R6 recorded with timestamps and pasted logs, else "done except radio". Phase B done = headless B1/B3 green and R4/R5 recorded. `INC7A_DONE` / `INC7B_DONE` flags are the orchestrator's alone.

## 10. Process notes
Same as inc6.md section 9: patch-only delivery by the Lead, orchestrator tripwire (`git status --short` before/after every wave), tests never edited after first red, heavy runs alone under the lock. Rule: no radio command is ever run by an agent without the user present (`rfkill`, `nmcli device wifi hotspot`, `bluetoothctl` change system state and drop the laptop's internet).

## 11. Questions for the user
1. Can you give ~2 hours per leg for the spike (laptop + your POCO phone), and run `rfkill unblock bluetooth` first? Which Android version does the phone report (Settings -> About)?
2. Scope: Phase A committed, Phase B only Linux<->Android (default), or Phase A only?
3. Is a Windows machine/VM available, and when is the Windows route decided? Until then all Windows items stay parked.
4. Default visibility Contacts-only + 10-minute Everyone window (default) or an always-on toggle?
5. Accept a ~1 minute internet pause on a single-radio desktop when hosting/joining (with the honest copy)?

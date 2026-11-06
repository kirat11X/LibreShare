# Post-MVP plan (written 2026-11-06 by the planner; owner of decisions: the user; gates: the orchestrator)

Scope: everything after the MVP. Documentation only; nothing here is started. All effort numbers are **estimates** (person-days, "pd", for one experienced developer, taken from the design docs or guessed by me; confidence low/med/high given per item). They are not measurements. Facts marked "measured" come from `docs/plans/STATUS.md`, `docs/test-reports/mvp-acceptance.md` or the other repo docs named next to them. Web facts carry a URL and the date fetched (2026-11-06) or the word "unverified".

## 1. Where we are, and what "MVP accepted" means

- Increments 1-2 (protocol, transfer, discovery, Linux/Windows/Android app) and the Increment 3 core (TLS 1.3 + pinning, SAS code, PIN, consent, key-change refusal, signed goodbye, Contacts-only) are done. Measured 2026-11-06 00:13-00:19: core +2583 ~1, CLI +75, app +405, all rc=0; emulator smoke 18/18 (STATUS.md).
- The Linux/Android **app builds are still plaintext** until module D finishes (D1 secure wiring + real PIN, C5 adversarial review, D4, D5 repackage). The `ls` CLI is already encrypted by default. Nothing is committed or pushed (`git log` has no commits).
- Windows: never compiled or run. `docs/test-reports/windows-readiness.md` lists code that will probably break (file rename over an existing file, `FileMode.append` + `setPosition`, `parentDir`, launcher quoting).
- Speed: 19.0 MiB/s loopback (measured, 100 MiB, `tools/loopback_smoke.sh`); the spec target NFR-02 is 300 MB/s loopback.
- **"MVP accepted" =** module D closed by the orchestrator re-running `docs/test-reports/mvp-acceptance.md` alone, by real exit codes, with STATUS flags `APP_SECURE_WIRED`, `P6A_GATE: DONE`, `MVP_APP_DONE`, `PACKAGING_DONE` all `YES`, the Linux + Android artifacts rebuilt from the secure app, and the manual emulator check that both screens show the same 6-digit code. **Nothing in this plan starts before that.** A Windows build is not part of "MVP accepted" in practice today (never built) and is the first item of Wave 1.

## 2. Principles and non-goals

Principles
1. $0 forever. If something needs money, it is written down as "NOT planned" with the free alternative.
2. Linux and Windows first-class (must be built, tested and documented). Android best-effort (emulator-verified, real phones are the user's job). macOS only if free CI makes it nearly free.
3. One increment/wave item at a time, tests first, protocol change = LSP-1.md + schemas + conformance tests in the same card, core never imports Flutter. Roles as in CLAUDE.md: tester (high) red -> coder (medium; low only for docs/scripts) green -> different verifier with mutation checks in a scratch clone -> orchestrator gate by real exit codes. Security-critical = medium coder + second tester review.
4. Say plainly what only real hardware can prove. The dev container has no GUI session, no Wi-Fi radio, no Bluetooth (soft-blocked), no `xvfb-run` (HANDOFF 3d). It does have Docker, an Android emulator with KVM (AVD `ls_test`, android-35) and the project-local Android toolchain.
5. Every wave ends with a short report in `docs/test-reports/` and an update of `docs/traceability.md`; nothing is called "verified" without a command and its rc.

Non-goals (see also section 7): iOS, HarmonyOS, Google Play, paid signing certificates, any server the project operates, hole punching, accounts, telemetry, a browser-only receiver in the first internet release.

## 3. Waves in recommended order

| Wave | Name | Contents | Est. pd (sum of section 4 items) |
|---|---|---|---|
| 1 | Ship | R1-R8: Windows fixes + Windows CI as the verification route, P10 Docker TLS e2e, known-limits clean-up, release packaging, user guide, repo hygiene | ~24 |
| 2 | Usable every day | U1-U5: P9 Android background receive, notifications with actions, QR pairing + Contacts-only UI, Windows secure key store | ~17 |
| 3 | Reliable and fast | Increment 4: hashing/throughput (NFR-02), resume, connection ladder, History/badge | ~22 |
| 4 | Reach 1: internet link | Increment 5: tunnel + share link/QR (Cloudflare Quick Tunnel, zrok, manual URL) | ~22 |
| 5 | Reach 2: paired devices anywhere | Increment 6 free rendezvous, then Increment 5b (IPv6/UPnP direct paths) | ~25 + 14 |
| 6 | Radios | Increment 7: 2-day real-radio spike, Phase A (BLE), Phase B (hotspot) | ~42 + ~42 |
| 7 | Polish | accessibility, second language, final polish, macOS best-effort, final docs | ~14 |

Why this order (one paragraph each; reorderings are marked **changed**):

- **Wave 1 Ship first.** Windows is first-class yet has never been compiled; every later wave adds code that must also work there, so the Windows route (GitHub Actions on `windows-latest`, which can run core and CLI tests and a real two-process TLS transfer) must exist before more code lands. Packaging and a user guide come now because the MVP is only useful if a person other than the developers can install and use it. The known-limits items (connection cap, one-shot Contacts-only greeting, forged-bye budget) are cheap, security-relevant and sit in files that later waves (Inc 4 ladder, Inc 5 origin server) will touch, so they are cleaner to fix first. **Changed:** P10 (Docker TLS e2e) and the CI split move here from the "quality" wave, because they are the regression net for everything after; the a11y/i18n/polish part of "quality" stays last, after the UI has stopped moving.
- **Wave 2 Usable second.** The biggest real-world complaint is "the app must stay open" (emulator report: backgrounding blocks the network after about 5 s). P9, notifications and the QR/Contacts-only UI use the security core that already exists and need no protocol change, so they are the cheapest large gain in user value. The Windows secure key store belongs here because it is the last security gap for a first-class platform.
- **Wave 3 Reliable and fast third.** Resume and the ladder matter most once people move real files over real, flaky Wi-Fi; Increment 4 also carries the receiver idle timeout and the hashing work. It must precede Increments 5 and 6, which both build on `Candidate`/`ConnectionManager`. Speed is not first because real Wi-Fi is often slower than the measured 19-30 MB/s anyway (hypothesis; check with the Wave 1 Windows/Android numbers); resume is.
- **Wave 4 Internet link.** Increment 5 is the only internet path that works for most sender/receiver pairs (design 04 table 1.4), needs Increment 3 (identity) and 4 (ladder), and is the foundation for 5b and 6. After it, **stop and ask the user** whether Waves 5-6 are still wanted (go/no-go gate), because their value depends on how Quick Tunnel behaves in practice.
- **Wave 5 Paired devices anywhere. Changed:** Increment 6 before 5b. Both need Increment 5. Rendezvous (see a paired device online anywhere, send it an offer) is a user-visible feature; 5b (IPv6/UPnP) is opportunistic with unmeasurable success rates (design 04 says "UNVERIFIED") and mostly helps speed and independence from Cloudflare. The roadmap lists 5b as committed and before 6; swapping is a **user decision (D5 in section 6)**. If the user prefers the roadmap order nothing else changes.
- **Wave 6 Radios last of the features.** About 17 person-weeks (design 03) and the only wave that cannot be tested in this container at all (no Bluetooth, no Wi-Fi radio). It starts with the 2-day spike so that a "no-go" costs 2 days, not 8 weeks. The spike itself needs the user's hardware, not the dev container, so it may be scheduled earlier as a user-run activity (it changes no product code), but Phase A/B follow the sequential rule.
- **Wave 7 Polish.** Accessibility and the second language are applied once, to the final UI. macOS is added only if the free GitHub macOS runner builds it without effort (free for public repos only, see D1).

## 4. Items

Format per item: scope in/out; depends on; acceptance tests (named, measurable); risks; effort (estimate, confidence); verifiable here vs only on hardware; free-tooling check. Test file names below are **proposed names for new files** (they do not exist yet) unless stated.

### Wave 1: Ship

**R1. Windows code fixes (from windows-readiness.md "Summary of Actionable Risk Items").**
- In: (a) `FileMode.append`+`setPosition` in `transfer/file_receiver.dart` (lines ~702/713) -> a mode that honours positions; (b) one shared "atomic replace" helper used by `transfer/resume_store.dart`, `storage/receive_settings_store.dart`, `storage/file_secret_store.dart`, `apps/libreshare_app/lib/services/app_settings_store.dart` and the final `partial.rename` in `file_receiver.dart` (Windows `rename` over an existing file fails); (c) `services/paths.dart` `parentDir("C:\\x")` returns `C:`; (d) `services/file_launcher.dart` quoting for `explorer.exe /select,` and `rundll32`; (e) `isWithin` with the `\\?\` prefix in `transfer/filename_sanitizer.dart`; (f) free-space check on Windows (currently skipped); (g) path joins via `package:path`. Out: long-path (>260) support beyond a clear error text; symlink behaviour on Windows (documented, not changed).
- Depends on: MVP accepted. File owners: `transfer/file_receiver.dart`, `filename_sanitizer.dart`, `file_secret_store.dart` are security-critical frozen files: **ESCALATE-SECURITY**, orchestrator approves each edit, medium coder + second tester.
- Acceptance (new tests, all must also pass on Linux): `test/unit/atomic_replace_test.dart` (replace existing file, crash between tmp write and rename leaves the old file intact); `test/unit/receiver_resume_offset_test.dart` (write chunk 3, then chunk 1, then chunk 2 into one `.lspart`: file byte-identical; if the O_APPEND hypothesis is right this also fails on Linux today, which makes it a real red test here); `apps/libreshare_app/test/windows_paths_test.dart` (`parentDir('C:\\a')=='C:\\'`, `parentDir('C:\\')=='C:\\'`, UNC `\\\\h\\s\\f`); `launcher_args_test.dart` (path with spaces, `#`, `&`, comma, non-ASCII produces a single correctly quoted argv). The same files run green on `windows-latest` in R2.
- Risks: touching the receiver can regress the 2583 core tests; the append hypothesis may be wrong (then only the Windows runner shows it). Effort: 3.5 pd (confidence med). Here: all of it except the real Win32 behaviour; real behaviour = R2 runner. Free tooling: `package:path` (already a dependency), GitHub Actions (R2).

**R2. Windows verification route = GitHub Actions on `windows-latest`.**
- In: a workflow job that runs on Windows: `dart pub get`, `dart analyze`, core `dart test`, CLI `dart test`, app `flutter test`, `flutter build windows --release`, a scripted two-process TLS loopback transfer (the CLI `receive` + `send`, byte compare with `certutil -hashfile` or `fc /b`), zip + SHA256 as artifact. Existing `.github/workflows/prototype.yml` already has a Windows build leg; `ci.yml` has a Windows matrix entry. Out: GUI automation on the runner (no interactive desktop), mDNS/tray/registry behaviour (needs a real PC, R3).
- Depends on: user decision D1 (a GitHub repo exists), R1 tests present. Only the orchestrator edits workflows (propose, then orchestrator applies); the docs/plans/ci-proposal.md split of jobs is the starting point.
- Acceptance: the run's job `windows` finishes green; log shows core `+N` equal to the Linux count minus tests explicitly tagged Linux-only (the list of such tags is part of the report); artifact `libreshare-<ver>-windows-x64.zip` plus `SHA256SUMS` downloaded and `sha256sum -c` rc=0 on Linux; a deliberately broken run (R1 fix reverted in a scratch branch) turns the job red.
- Risks: first Windows build "needs a fix or two" (prototype-1.md); tests binding fixed ports 53318.. on a shared runner; flaky Windows-only tests. Effort: 3 pd (confidence low-med). Here: nothing runs locally; **verification is by the Actions log**. Free tooling: public repo = standard runners free; private repo on GitHub Free = $12/month included compute (about 2000 Linux min, my calculation; Windows $0.010/min vs Linux $0.006/min, i.e. about 1.7x), 500 MB artifact storage, so a 15-min Windows run (guess) costs about $0.15 and about 80 runs/month fit (calc). Source: https://docs.github.com/en/billing/managing-billing-for-your-products/about-billing-for-github-actions (fetched 2026-11-06).

**R3. Windows manual checklist (user's own PC, or a Windows VM).**
- In: `docs/test-reports/windows-manual.md` checklist written by us, run by the user once per release: install from zip, firewall prompt on private network, discovery to a Linux machine, send both directions byte-identical, tray icon, autostart (HKCU Run), received-file Open/Show in folder with a path containing spaces, antivirus/SmartScreen behaviour. Out: automating any of it.
- Acceptance: the checklist file exists with blank result columns and the commands to produce evidence (`certutil -hashfile`); user fills it. Effort: 0.5 pd to write (high) + about 1-2 h of the user's time. Here: writing only; execution **only on real Windows**. Free tooling: none needed.

**R4. Known-limits clean-up (inc3.md section 12 "Known limits carried forward").**
- In (one sub-item each, each with its own red test first): (a) connection cap and per-IP cap in `server/api_server.dart` (slow-loris); (b) forged `bye` datagrams spending the 5/s verify budget: cheap pre-check (known sender fingerprint/ID and rate per source) before the signature verify, location in `discovery/` to be confirmed by the tester; (c) Contacts-only greeting (`_greetContacts` in `engine/libreshare_engine.dart`): retry with back-off plus a UDP fallback, and handle a peer that restarts while still listed with the same key; (d) `_certs` LRU in `discovery/peer_registry.dart` flushed by a flood of distinct peers (cap per source); (e) the 10,000-file 413 applied before authentication where possible; (f) D4 Android file-opener hardening if module D did not finish it. Out: receiver idle timeout (goes to Wave 3 with resume), new rate-limit policy beyond these.
- Depends on: MVP accepted. All in security-critical frozen files: ESCALATE-SECURITY per sub-item; medium coder, second tester.
- Acceptance (proposed names): `test/security/connection_cap_test.dart` (open N+1 idle sockets: the (N+1)th is refused/closed, a normal transfer still completes while N-1 are held open); `test/security/bye_flood_test.dart` (1000 forged bye/s from one source leave a legitimate bye from another source processed within 1 s); `test/integration/contacts_greeting_retry_test.dart` (first greeting dropped, second delivered: contact listed within 5 s; no UDP: found by the fallback); `test/unit/peer_registry_cert_cache_test.dart`. Mutation checks: remove each guard, the named test must go red. 3x flake runs.
- Risks: a cap that is too low breaks real use (Android multi-file); defaults must be documented. Effort: 5 pd (confidence med). Here: everything (no radio needed). Free tooling: none.

**R5. P10: extra Docker end-to-end scenarios for the secure path.**
- In: steps f-l of `docs/plans/inc3.md` section 7 in `tools/docker/e2e.sh` / `compose.yaml`: TLS transfer with `tcpdump` finding no plaintext marker, SAS agreement, persistence + TOFU key change, wrong PIN x5, Contacts-only, goodbye <= 1 s, mixed old/new; remove the `--insecure-plaintext` setup-line flag where module D allows it. Out: step m (throughput) until Wave 3.
- Depends on: MVP accepted (D5 may already remove the flag). Note `tools/docker/**` was owned by the P6a coder; ownership returns to the orchestrator at that point.
- Acceptance: `docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit --exit-code-from tester` rc=0 with every step f-l printing PASS and the count of assertions larger than the current 31 (STATUS/traceability, measured 2026-11-04); the same command run 3x. Mutation: dropping the pin check in a scratch clone turns step h red.
- Risks: multicast needs a user-defined bridge network; `/tmp` quota (questions.md Q1); timing flakes. Effort: 3 pd (confidence med). Here: yes, Docker works (docs/dev/docker-install.md). Free tooling: Docker Engine (free), GitHub Actions runner has Docker.

**R6. Release packaging (all free).**
- In: (a) version policy and a single place for the version (D3); (b) Android: **own release keystore** made with `keytool` (JDK 17), stored outside the repo, signing config in `apps/libreshare_app/android/app/build.gradle.kts` replacing the debug key (today `signingConfig = signingConfigs.getByName("debug")`); keystore loss = users must uninstall, so the backup procedure is part of the item; (c) Windows: the unsigned zip (kept) plus an Inno Setup installer that adds the firewall rules from spec 15 (TCP 53318-53327, UDP 53318) and an uninstaller that removes them; (d) Linux: keep the tarball, add AppImage (and `.deb` only if cheap); (e) `release.yml` on tag `v*` building all, `SHA256SUMS`, GitHub Release; (f) an install note that SmartScreen/"unknown publisher" warnings are expected. Out: any paid certificate, Play Store, notarized macOS, Flatpak (Wave 7 optional).
- Depends on: R2 (Windows build), MVP accepted, D1/D2 (repo, version). The release workflow is orchestrator-owned.
- Acceptance: on a tag in a scratch repo run, the Release holds: Linux tarball + AppImage, Windows zip + `LibreShare-Setup-<ver>.exe`, 4 APKs, `SHA256SUMS`; `sha256sum -c` rc=0; `apksigner verify --print-certs` shows a certificate that is not the Android debug certificate (run locally with the SDK's `build-tools/36.0.0/apksigner`); the AppImage starts with `--hidden` for 10 s and exits 0 on SIGTERM in the container; installer: `iscc` compiles on the runner and, on the user's PC (R3), installs and uninstalls with firewall rules added and removed (`netsh advfirewall firewall show rule name=...`).
- Risks: Inno Setup script never run before; AppImage needs FUSE (use `--appimage-extract-and-run` in tests); keystore handling mistakes (never commit it; never print it). Effort: 5 pd (confidence low-med). Here: APK, tarball, AppImage yes; installer compile/run only on Windows. Free tooling: Inno Setup and appimagetool are free (licence terms **unverified** this session, check before adoption); `keytool`/`apksigner` ship with the JDK/SDK already in `.toolchain`.

**R7. Real user guide.**
- In: `docs/user/guide.md` (new directory; written for a non-developer): install on each platform, first transfer, the verification code explained in plain words, PIN, contacts, "why can't my phone see my PC" (AP isolation, firewall, same Wi-Fi), where files go, what is private, known limits, uninstall. Screenshots from the emulator (`adb exec-out screencap`); Linux/Windows screenshots by the user (no GUI/xvfb here). Out: translations (Wave 7), video.
- Acceptance: a link check script (same one-liner as HANDOFF A4) prints nothing; every quoted button label found with `grep -rF` in `apps/libreshare_app/lib/l10n_strings.dart`; a **cold read test**: someone who did not build the app follows it and sends one file (user-run, 30 min). Effort: 2 pd (confidence high), low-effort coder (docs only) + orchestrator review. Here: all but the cold-read test. Free tooling: Markdown only.

**R8. Publication hygiene.**
- In: first commit (needs the user's explicit word, see D2), `SECURITY.md` (how to report a problem, no promise of SLA), `CONTRIBUTING.md` short, third-party notices file from `docs/dev/licences.md` (note ML Kit terms for the Android build, see U3), CHANGELOG, issue templates; check that no key/PIN/token/secret sits in the tree (`grep` patterns agreed by the orchestrator) before anything is pushed. Out: a website.
- Acceptance: secret-scan command list (in the report) returns nothing; `git status` clean after the commit; repo builds from a fresh clone on the Actions runner (R2 is the proof). Effort: 1 pd (high). Here: yes. Free tooling: git, GitHub free.

### Wave 2: Usable every day

**U1. P9 Android background receive service (`ReceiveService`).**
- In: design 01 section 4 and inc3.md section 6: foreground service `connectedDevice` (fallback ladder F0 `connectedDevice`, F1 `dataSync` with 5 h 45 m window, F2 foreground-only = today), custom ~150-line Kotlin service holding a cached `FlutterEngine` (spike question 1 option A), `onTimeout(int,int)` handler, notification with Stop / Extend 6 h, "Receiving ended - Resume" notification, Quick Settings tile with trampoline activity, boot receiver opt-in (default off), manifest delta (remove `usesCleartextTraffic`, add FGS permissions, never `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`). Out: boot receiver default on; OEM-specific battery whitelist automation.
- Depends on: MVP accepted; U2 shares the notification channel code (do U1's Dart `ReceiveHost` seam first, U2 reuses it).
- Acceptance: Dart side with a mocked `MethodChannel` (`apps/libreshare_app/test/p9_receive_service_test.dart`: start/stop/timeout paths, state restored after process death); **emulator**: extend `tools/android_emulator_smoke.sh` with steps "send to emulator while app is in background and screen off" (`adb shell input keyevent 26`), `dumpsys deviceidle force-idle` and then the transfer must complete byte-identical; `adb shell dumpsys activity services dev.libreshare.libreshare_app` shows the service with `foregroundServiceType=0x...` for `connectedDevice`; simulated timeout -> service stops and the Resume notification is posted (`dumpsys notification`). Pass = rc=0 and those lines.
- Risks: highest uncertainty in the plan (OEM killers, Android 15/16 FGS rules, Flutter engine lifetime); emulator is not a Samsung/Xiaomi phone. Effort: 6 pd (confidence **low**). Here: emulator only; **real phones (screen-off 30 min, battery saver, OEM killers) only on hardware** - a blank checklist `docs/test-reports/inc3-android.md` as planned in inc3.md section 6 is filled by the user. Free tooling: Android SDK/emulator (free, already installed under `.toolchain`).

**U2. Notifications with actions (all platforms).**
- In: incoming-transfer notification with Accept / Reject (the in-app dialog stays the source of truth, inc3 R10), progress, "received N files - Open", "failed - why"; permission request `POST_NOTIFICATIONS` at first need (API 33+; declared but never requested today, inc2-followups #12). Package: `flutter_local_notifications` (BSD-3-Clause, 22.3.3, supports Android, Linux and Windows incl. action buttons; Linux action support depends on the desktop's notification server; Linux actions do not work after the app has terminated). Source https://pub.dev/packages/flutter_local_notifications (fetched 2026-11-06). Out: push notifications (would need FCM = Google, not planned).
- Depends on: U1 seam, MVP accepted. Acceptance: `apps/libreshare_app/test/notifications_test.dart` with a fake `NotificationService` (an incoming session posts exactly one notification; Accept action calls `engine` accept with the same session id; notification text contains no file name beyond the configured limit and **no PIN/fingerprint**); emulator: `adb shell dumpsys notification | grep -c LibreShare` shows the notification during a transfer and an action tap via `adb shell input tap`/`cmd notification` accepts it (rc=0 in the extended smoke). Linux: a `notify-send`-compatible D-Bus check only if a notification daemon exists (unverified here). Risks: Windows toast actions need packaging details (app id/AUMID) - **unverified**, may degrade to "click opens window"; Linux GNOME quirks. Effort: 4 pd (med-low). Here: Dart logic + Android emulator; Windows/Linux desktop look-and-feel only on real desktops.

**U3. QR pairing screen + Contacts-only toggle + contact management.**
- In: screen "Pair a device" showing the invite (`engine.createPairInvite()` -> `libreshare://pair?v=1&s=...`, single-use, expiry) and a scanner (existing `scan_qr_screen.dart`) calling `engine.redeemPairInvite(uri)`; visibility selector Everyone / Contacts only / Nobody in the Receive card (core `ReceiveVisibility` exists); contact list actions already partly present (view/remove); copy-paste of the invite text for desktops without a camera. Out: pairing over the internet (Inc 6), group pairing.
- Depends on: MVP accepted (secure engine wired). Acceptance: `apps/libreshare_app/test/u3_pairing_test.dart` on two real in-process engines (like core `secure_two_engine_test`): invite from A, scan on B, both list each other as contacts, a Contacts-only A is then visible to B and invisible to a third engine C (404 on `GET /info`); expired/reused invite rejected with a visible message; the secret `s=` never appears in logs or `toString` (log-capture test); 360x640 at 1.3x text scale, no `RenderFlex` overflow.
- Risks: **`mobile_scanner` pulls Google ML Kit on Android** (`docs/dev/licences.md` 2.1); F-Droid/IzzyOnDroid flag ML Kit as non-free component (secondary sources: https://zff.dev/IzzyOnDroid/repodata/issues/273 and https://gitlab.com/fdroid/fdroiddata/-/issues/2272, fetched via search 2026-11-06; current F-Droid policy itself **unverified**). Free-only consequence: the GitHub APK keeps `mobile_scanner`; an F-Droid-style build would need a different scanner (ZXing-based; package choice unverified) = optional item, see D6. Effort: 3.5 pd (med). Here: logic and widgets yes; camera scanning only on a real phone (emulator camera is synthetic; the paste path is the headless-testable one).

**U4. Windows secure key store.**
- In: a `SecretStore` implementation using Windows DPAPI (`CryptProtectData`/`CryptUnprotectData`) via `package:win32` FFI in `apps/libreshare_app/lib/platform/secret/` (interface exists in core, inc3.md D6), migration from the file store (read old file, write protected, delete old only after read-back succeeds). Out: Linux libsecret (keyring is often locked at autostart, inc3 D6: stays on the 0600 file store), TPM.
- Security-critical: medium coder, second tester. Acceptance: `apps/libreshare_app/test/platform/secret_store_windows_test.dart` runs **only on the Windows runner** (tag `windows`): put/get round-trip, wrong-user blob rejected is not testable, a corrupted blob returns an error and never regenerates the identity (core `IdentityLostException` path), migration test with a fake; on Linux the file-store contract tests still pass. Mutation: skip read-back before delete -> red.
- Risks: `win32` API surface unverified for current version (check `dart pub outdated` and the licence entry in `docs/dev/licences.md`); roaming-profile and "reset password" cases lose the key (documented: re-pair). Effort: 2.5 pd (med-low). Here: interface + migration logic yes; DPAPI behaviour only on the Windows runner/PC. Free tooling: `win32` is BSD-3 (unverified version; check).

**U5. Settings/UX leftovers found while doing U1-U4.** Short list only: battery-saver guidance text, "Receiving only while LibreShare is open" banner for F2, Windows toast opt-in. Effort 1 pd (high). Here: widgets yes.

### Wave 3: Reliable and fast (Increment 4)

Written to `docs/plans/inc4.md` first (CLAUDE.md rule). Sub-items:
- **I4.1 Profile first, then speed (NFR-02).** In: create `tools/bench/bench_lan.sh` (the file named in spec 13 **does not exist**; `tools/bench/` is empty) producing a CSV; profile sender and receiver (hash passes per byte: per-chunk hash, whole-file hash, TLS); then fix in order of measured cost: hash in an `Isolate` pool, hash whole file incrementally while chunks arrive in order, overlap I/O; optional native hashing only in the app layer (`cryptography_flutter`, Apache-2.0, **unverified for Linux/Windows support**). Acceptance: bench CSV committed; loopback 100 MiB TLS **>= 2x the measured 19.0 MiB/s baseline** as the first gate (my guess of achievable; the spec's 300 MB/s / Docker bridge 100 MB/s is very likely out of reach in pure Dart: **needs user decision D7, change NFR-02 to the measured achievable number, or accept a native hashing path in the app only**); `<= 20 %` regression gate script; byte-identical `cmp`. Risks: the claim "hashing is the bottleneck" is a hypothesis from inc2-docker.md (not profiled). Effort: 5 pd (low-med). Here: yes (loopback and Docker bridge). Real Wi-Fi throughput only on hardware.
- **I4.2 Resume.** D2 session store, `GET .../state`, receiver idle timeout (chunk idle 30 s LAN, inc2-followups #7), `.lspart` + bitmap 24 h, receiver killed and restarted resumes. Acceptance: `unit/resume_after_crash_test.dart` (name from traceability FR-15), Docker kill/restart: no acked chunk re-sent (count `PUT` requests in the server log), byte-identical. Effort: 5 pd (med). Here: yes. Security-critical (file_receiver): medium coder + second tester.
- **I4.3 Connection ladder.** `Candidate` made extensible (hook carries the pinned fingerprint), `ConnectionManager`, Wi-Fi and LAN tiers, `FaultyTcpProxy`, Docker nets `wifi_net`/`lan_net` with `tc netem` (`tools/netem/` exists but is empty). Acceptance: spec FR-12/13: cut `wifi_net` at 40 % -> LAN within 10 s, no acked chunk re-sent; NFR-03: 20 randomized fault runs each COMPLETED or clean FAILED with persisted state. Effort: 9 pd (med). Here: yes, in Docker. Real Wi-Fi roaming only on hardware.
- **I4.4 Channel badge + History screen** (D4 event log). 3 pd (med). Here: widgets yes.
Free tooling: Docker, `tc` (needs NET_ADMIN, already used).

### Wave 4: Increment 5, internet tunnel and share link/QR

Plan file `docs/plans/inc5.md`; design 04 is the source (effort there: about 22 pd; crypto 1, origin 3, link/UX 4, cloudflared 4, fake provider 2, landing 1, receiver 3, tests/live 4).
- **In:** `tunnel_crypto` v2 (random 96-bit nonces under HKDF subkeys, replacing the spec's deterministic nonce, design 04 D5; LSP-1 + schemas + conformance together), `TunnelOriginServer` with limits (<= 8 per token, <= 32 total), link codec (secrets in the URL fragment), `TunnelConnection`, `CloudflaredProvider` (download on first use with pinned SHA-256, clean HOME, never `--allowed-mail`), `FakeTunnelProvider`, `ManualUrlProvider`, `ZrokProvider` last, "Create link" and "Receive from link" in app and CLI, deep links, optional static landing page. Out: browser-only receiver (5c), Android as tunnel host.
- **Acceptance:** FR-14: with both local nets cut, transfer completes via `FakeTunnelProvider` on a third Docker net `inet_net`; NFR-04: a capture at the origin never contains the plaintext marker; NFR-06: tunnel unused while a local tier is healthy; token returns 401 after completion/expiry; hostile-provider tests (modified ciphertext rejected); SSRF: receiver rejects private/loopback hosts in links; redacting logger test (no token or fragment in logs); one **recorded live** Quick Tunnel transfer with the Dart client (`LS_TUNNEL_LIVE=1`, run by the user or the orchestrator on a normal network, result in `docs/test-reports/`).
- **Risks:** Cloudflare's "no uptime guarantee / testing and development" terms and an unclear large-file clause; campus networks may block 7844 or `trycloudflare.com`; a mandatory email gate later would break non-interactive clients. Mitigations are in design 04 5.5. **Effort:** 22 pd (confidence low-med; design estimate). **Here:** everything except the live test (needs internet from a normal network; the dev container may or may not have it, unverified) and real campus behaviour.
- **Free-tooling check:** Cloudflare Quick Tunnel (no account) and zrok free tier (5 GB/day, account token, card-less) as per design 04 section 1.1, fetched 2026-11-03; **re-check both pages when this wave starts** (limits change often). GitHub Pages landing page: published-site limit 1 GB and 100 GB/month soft bandwidth (https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits, fetched 2026-11-06); whether Pages is free for the chosen repo type: **unverified** (page does not say).

### Wave 5: Increment 6 (rendezvous), then 5b

- **Increment 6** (design 02, GO-WITH-CAVEATS): `LSP-R1.md` + schemas + ADR 0003, crypto core, `NostrBackend` (>= 3 public relays, user-editable list), pairing service, presence, offer flow (never auto-accepted), Flutter pair screen and "Last seen" badges. Acceptance: pairing via loopback relay between two CLI processes; "A sees B online <= 3 s" with `LoopbackNostrRelay`; Receive Off publishes nothing; NFR-11: all backends down -> LAN and manual-link flows unchanged; BIP-340 known-answer vectors; no `S`/`K_pair` in logs. Effort: 25 pd core (design 02 7.2; confidence low-med), +9 pd optional (STUN, port mapping, ntfy). Risks: public relays have no SLA, can add payment/PoW or vanish; relays see IPs and timing (disclosed in-app); own BIP-340 signer (security-critical). Here: everything with fake/loopback relays; real-relay behaviour needs internet (`LS_RENDEZVOUS_LIVE=1`, unverified from this container). Free tooling: Nostr relays and ntfy.sh are free best-effort services; design 02 probed them 2026-11-03; **re-probe at wave start**.
- **Increment 5b** (design 04): IPv6 candidates, SSDP/UPnP-IGD, NAT-PMP, PCP, reachability probe, ephemeral-TLS direct origin pinned in the link, "Hide my IP". Acceptance: direct transfer through an in-process fake IGD and through a Docker gateway container; no mapping left after stop or crash sweep; mapping never targets another host; wrong pin refused. Effort: 14 pd (low-med). Risk: success rate on real routers is unknown (no public figure found by design 04); UPnP surface (CallStranger class) needs the listed mitigations. Here: fake IGD and Docker only; **real routers only on the user's network**.

### Wave 6: Increment 7 (BLE + hotspot), design 03

- **7.0 spike (2 days, real radios, user hardware).** Four unknowns in design 03 7.1; result written to `docs/test-reports/`; go / no-go / Phase A only. Cannot run in the container (Bluetooth soft-blocked, no radio).
- **Phase A** (BLE discovery + LAN address exchange + QR): about 8.5 person-weeks = ~42 pd (design 03; confidence low). Windows needs C++/WinRT (Dart WinRT packages discontinued, roadmap default 7). **Phase B** (hotspot handoff): another ~8.5 pw. **Recommendation:** commit only to the spike and Phase A for Linux <-> Android; treat Windows hosting and Linux <-> Windows as experimental; decide Phase B after Phase A on real results.
- Acceptance headless: codec, rotating id, host policy, `Candidate` kinds, LSP 1.1 additions with schemas; radio tests behind `LS_RADIO=1` (flag proposed by design 03, does not exist yet). **Everything that makes it a feature (a phone sees a laptop over BLE; a hotspot is joined) is verifiable only on real devices**, recorded in a manual matrix. Free tooling: `universal_ble` (candidate, licence/maintenance **unverified**), `dbus`/`bluez` Dart packages (unverified); no paid SIG membership: use the test company id 0xFFFF (collision-prone, free, design 03 Q4).

### Wave 7: Polish

- **Accessibility:** semantics labels, 48 dp touch targets, contrast, keyboard traversal on desktop, 1.3x and 2.0x text scale; widget tests asserting `SemanticsNode` labels on the main screens and no overflow at 360x640 at 2.0x; screen-reader behaviour only on real devices (TalkBack/Narrator/Orca). 3 pd (med).
- **i18n:** the scaffold exists (`apps/libreshare_app/lib/l10n_strings.dart`, table of English strings with `tr`/`trPlural`). Add one more language (user picks, D8), a test that every key exists in every table and every placeholder matches; no machine-translated strings shipped without a human check. 3 pd (med).
- **Polish:** copy review of all error texts, empty states, dark theme check, first-run flow ("fresh install to first transfer in <= 3 clicks", NFR-01; measure with an integration test that counts taps, run on the emulator because `xvfb-run` is absent). 4 pd (med).
- **macOS best-effort:** unsigned DMG built by the GitHub macOS runner (free only for public repos; 10x Linux rate in a private repo, ~$0.062/min, docs page above), user must right-click Open; Local Network permission strings per spec 15. 2 pd (low); cannot be run here at all. Notarization costs money (Apple program): NOT planned.
- **Final docs:** manual, traceability, test report, demo script. 2 pd (high).

## 5. Ready-to-run cards for the next two waves

Format as in HANDOFF.md section 5 (Goal / Gate / You may edit / Steps / Done when / Report). Common rules from HANDOFF sections 2, 3 and 6 apply to every card (absolute paths, real exit codes, `flock -o /tmp/libreshare-heavy.lock` for heavy runs, no commit/push, never edit an existing test). "T" = tester (effort `high`), "C" = coder (`medium`, `low` where stated), "V" = verifier, a different agent (`high`, mutation checks in a scratch clone under the scratchpad, never in the real tree). Security-critical cards add a second tester review. Gate for all cards: **MVP accepted (section 1)** and the previous card of the same chain done; the orchestrator re-runs each "Done when" alone.

### Wave 1 cards

**R1. Windows code fixes** (ESCALATE-SECURITY for the three core files; orchestrator approves the diff list first)
- Goal: the Windows-risk items (a)-(g) fixed with Linux-runnable tests.
- T (high): new files `packages/libreshare_core/test/unit/atomic_replace_test.dart`, `packages/libreshare_core/test/unit/receiver_resume_offset_test.dart`, `apps/libreshare_app/test/windows_paths_test.dart`, `apps/libreshare_app/test/launcher_args_test.dart`; show red; write `docs/plans/r1-tests.md`.
- C (medium): may edit `packages/libreshare_core/lib/src/transfer/{file_receiver,resume_store,filename_sanitizer}.dart`, `packages/libreshare_core/lib/src/storage/{receive_settings_store,file_secret_store}.dart`, new `packages/libreshare_core/lib/src/storage/atomic_file.dart` (barrel export = orchestrator), `apps/libreshare_app/lib/services/{paths,file_launcher,app_settings_store}.dart`. No other file.
- V (high) + second tester: mutations (restore `FileMode.append`; helper writes the target directly; `parentDir` back to substring; launcher without quoting; `isWithin` without prefix strip); each turns a named test red.
- Done when: `dart test` for the four new files rc=0 three times; core `dart test -j 1` rc=0 with count >= 2583 (+new); CLI rc=0; app `flutter test --concurrency=2` rc=0; `dart analyze --fatal-infos` rc=0; `dart format --output=none --set-exit-if-changed .` rc=0; `grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib` rc=1; `bash tools/loopback_smoke.sh 100 <port>` rc=0 with no MiB/s regression beyond 20 % of 19.0.
- Report: mutation table, counts.

**R2. Windows CI route** (orchestrator applies the workflow; the card prepares it)
- Goal: a `windows` job that runs the suites and a TLS loopback transfer on `windows-latest`.
- T (high): writes `docs/test-reports/windows-ci-acceptance.md` = the list of expected log lines. The transfer smoke reuses `tools/loopback_smoke.sh` under Git Bash (GitHub's Windows runners ship Git Bash; whether the script runs there unchanged is unverified), with a small wrapper under `tools/` only if needed.
- C (low-medium): drafts `docs/plans/r2-workflow.yml.txt` (not under `.github/`), the orchestrator copies it to `.github/workflows/`.
- V (high): reviews the YAML by reading (no `actionlint` installed); runs the same steps locally on Linux as far as possible.
- Gate extra: user decision D1 done and the repo exists. Done when: the Actions run URL is recorded; job `windows` green; `sha256sum -c` of the downloaded zip rc=0; the scratch-branch run with the R1 fix reverted is red. Report: log excerpts with counts.

**R3. Windows manual checklist** (low coder). May edit: `docs/test-reports/windows-manual.md` (new). Done when: file exists, every command in it is copy-pasteable PowerShell 5.1 (no `&&`, no `??`) and checked against `deploy/install.ps1` style; orchestrator review. Report: one line.

**R4a-R4e. Known-limits clean-up** (one card per sub-item (a)-(e) of R4; each: T red -> C medium -> V mutation -> second tester for (a), (b), (c); security-critical)
- Files the coder may edit: (a) `packages/libreshare_core/lib/src/server/api_server.dart`; (b) the bye-handling file the tester names in `r4b-tests.md` (inside `packages/libreshare_core/lib/src/discovery/`); (c) `packages/libreshare_core/lib/src/engine/libreshare_engine.dart` method `_greetContacts` and its call site only; (d) `.../discovery/peer_registry.dart`; (e) `.../server/api_server.dart` limit check order. Tests: new files only, names as in R4.
- Done when per sub-item: new tests 3x rc=0, the related existing suites (`test/security/*`, `test/conformance/api_conformance*_test.dart`, `test/integration/secure_two_engine_test.dart`) rc=0 run alone, mutation (guard removed) turns the named test red, analyze/format rc=0. After all five: full core + CLI + app runs as in R1 "Done when".
- Escalate to the orchestrator: any default that changes behaviour visible to users (cap numbers), and any change to a model/contract.

**R5. Docker TLS e2e (P10)**
- T (high): extends `tools/docker/e2e.sh` assertions first (they fail against the unmodified compose/ services): steps f-l of inc3.md section 7. C (medium): `tools/docker/compose.yaml`, `tools/docker/carol.sh`, `tools/docker/e2e.sh` setup, `deploy/docker/**` (drop `--insecure-plaintext` only where the assertions still hold). V (high): mutation in a scratch clone (skip pin check) -> step h red.
- Done when: `docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit --exit-code-from tester` rc=0 three times with PASS for a..e and f..l; then `docker compose ... down -v --remove-orphans` rc=0. Report: assertion count, timings (multicast <= 3 s, scan <= 10 s).

**R6a/R6b. Release packaging** (R6a: Android keystore + signing config, security-relevant: medium coder; R6b: AppImage + Inno Setup + `release.yml` draft: low-medium coder)
- May edit: `apps/libreshare_app/android/app/build.gradle.kts`, `tools/package_prototype.sh` (rename later), new `tools/package_release.sh`, new `deploy/windows/libreshare.iss`, new `deploy/linux/` AppImage recipe, draft `docs/plans/r6-release.yml.txt`. The keystore and its passwords are created by the **user** or the orchestrator outside the repo; the card never prints or stores them.
- Done when: `tools/package_release.sh linux android` rc=0; `sha256sum -c SHA256SUMS` rc=0; `apksigner verify --print-certs <apk>` rc=0 and the certificate differs from the debug one; AppImage `--appimage-extract-and-run --hidden` runs 10 s and exits 0 on SIGTERM; emulator smoke rc=0 (18/18) on the release-signed APK; `iscc` compile happens on the runner (R2 chain). Heavy runs under `flock -o`, then `adb kill-server` and `gradle --stop`.

**R7. User guide** (low coder, docs only). May edit: `docs/user/guide.md` (new), `README.md` links. Done when: link-check one-liner prints nothing; every quoted UI label found by `grep -F` in `apps/libreshare_app/lib/l10n_strings.dart`; reviewer (high) lists five points where a non-developer would get stuck, the coder fixes them.

**R8. Publication hygiene** (low coder + orchestrator). May edit: `SECURITY.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `docs/dev/licences.md` (notice section). Done when: files exist; the secret-scan commands (listed in the card report) return no hits; **no commit is made by the card**.

### Wave 2 cards

Gate for all: Wave 1 cards R1, R4a-e, R6a done and the Android emulator image present (`.toolchain/`; if absent say so and stop, do not install).

**U1. Android ReceiveService (P9)**
- T (high): `apps/libreshare_app/test/p9_receive_service_test.dart` (mock `MethodChannel`: start, stop, timeout, restore after process death, F0 -> F1 -> F2 fallbacks) and the new emulator steps appended to a **copy** `tools/android_emulator_smoke_bg.sh` (new file; the existing smoke script stays untouched) with the assertions listed in section 4 U1; show the Dart tests red.
- C (medium): `apps/libreshare_app/lib/platform/android/**`, `apps/libreshare_app/lib/providers/receive_provider.dart`, `apps/libreshare_app/android/app/src/main/**` (new `ReceiveService.kt`, `ReceiveTileService.kt`, `ResumeActivity.kt`, `AndroidManifest.xml`). Not the core.
- V (high): mutations in a scratch clone: `onTimeout` not calling `stopSelf`; service type changed to `dataSync` unnoticed; restart sticky; Stop action ignored; each turns a named test or emulator step red. Reads Kotlin for exported components and logged secrets.
- Done when: new Dart tests 3x rc=0; app suite `flutter test --concurrency=2` rc=0 alone; `flock -o /tmp/libreshare-heavy.lock tools/android_emulator_smoke.sh` rc=0 (existing 18 checks) and the new background script rc=0; `flutter build apk --release` rc=0; `adb kill-server` and `gradle --stop` run. Report: `dumpsys` lines as evidence; a blank real-phone checklist `docs/test-reports/inc3-android.md` for the user.

**U2. Notifications with actions**
- T (high): `apps/libreshare_app/test/notifications_test.dart` (fake service); C (medium): new `apps/libreshare_app/lib/platform/notifications/**`, `apps/libreshare_app/lib/providers/notification_provider.dart`; `apps/libreshare_app/pubspec.yaml` is **orchestrator-owned**: the coder lists the dependency (`flutter_local_notifications`, BSD-3-Clause) in the report and the orchestrator adds it and updates `docs/dev/licences.md`. V (high): mutation: Accept action calls reject; PIN in notification text -> red.
- Done when: new tests 3x rc=0; app suite rc=0 alone; analyze/format rc=0; emulator notification evidence (`dumpsys notification` line and accepted transfer) rc=0.

**U3. QR pairing screen + Contacts-only toggle**
- T (high): `apps/libreshare_app/test/u3_pairing_test.dart`, `u3_visibility_test.dart` (two real engines in one test, same pattern as `d1_two_engine_pin_test.dart` already in the tree). C (medium): `apps/libreshare_app/lib/screens/{scan_qr_screen,my_qr_screen,settings_screen,home_screen}.dart`, new `screens/pair_screen.dart`, `widgets/receive_card.dart`, `providers/receive_provider.dart`. V (high) + second tester (pairing is security-critical): mutations: invite reusable; scanner ignores decline; Contacts-only toggle not passed to the engine; `s=` written to a log.
- Done when: tests 3x rc=0; 360x640 at 1.3x no overflow; app suite rc=0 alone; analyze rc=0; emulator smoke rc=0 still 18/18.

**U4. Windows secure key store** (security-critical; medium coder; second tester)
- T (high): `apps/libreshare_app/test/platform/secret_store_windows_test.dart` (tagged `windows`; the fake-based migration tests run everywhere). C (medium): `apps/libreshare_app/lib/platform/secret/**`, wiring in `apps/libreshare_app/lib/providers/engine_provider.dart`; pubspec change requested from the orchestrator (`win32`). V: mutation: delete the old file before read-back; identity regenerated on a corrupted blob -> red.
- Done when: Linux: new fake-based tests 3x rc=0, app suite rc=0; **Windows: the `windows` job from R2 runs the tagged tests green** (Actions URL recorded). Orchestrator does not flip the item to done until that URL exists.

**U5. UX leftovers.** Low coder, widget tests first by a high tester; same "Done when" as U3 minus pairing.

## 6. Decision points for the user (with my recommendation)

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Windows build and CI route | (a) public GitHub repo + Actions: unlimited free standard runners; (b) private repo + Actions: $12/month included compute, about 2000 Linux min, Windows about 1.7x per minute, 500 MB artifacts; (c) only your own Windows PC, no repo | (a) if you accept the source being public (MIT, no secrets, R8 scan done first); else (b). Keep (c) for the manual checklist R3 either way |
| D2 | Publish and commit | The repo has no commits; standing instruction says no commit/push | Ask me explicitly when Wave 1 is green; the first commit is a squashed "initial import" after R8. Until you say so nothing is committed |
| D3 | Versioning and naming | Today `1.0.0+1` in `apps/libreshare_app/pubspec.yaml`, artifacts `libreshare-1.0.0-*`, and "1.0.0" for an unaccepted prototype is misleading | Use SemVer `0.x` until Wave 3 (e.g. first public tag `v0.2.0` after Wave 1); Android versionCode derived from the version; project name "LibreShare" stays (check for existing projects with that name before publishing: unverified) |
| D4 | Release signing | Own self-generated Android keystore (free) vs keep debug key (no updates) | Own keystore, backed up offline; Windows/macOS stay unsigned (paid certificate NOT planned). SignPath Foundation's free signing for OSS exists as a rumour in my memory only: **unverified, not planned** |
| D5 | Wave 5 order | Roadmap: 5b then 6; mine: 6 then 5b | Mine (6 first), 5b optional after a real Quick-Tunnel experience |
| D6 | F-Droid-style repo and ML Kit | Keep `mobile_scanner` (ML Kit, GitHub APK only) vs add a build flavour with a free scanner for F-Droid | Keep ML Kit for now; decide when Wave 2 ships and someone asks for F-Droid. Google Play: NOT planned (costs a fee) |
| D7 | NFR-02 (300 MB/s) | Keep (needs native hashing in the app layer, maybe unreachable) vs re-baseline to the number Wave 3 measures | Re-baseline after the profile in I4.1, keep a "no regression > 20 %" gate |
| D8 | Second UI language | Your choice (Hindi? other) | Decide before Wave 7; one language only |
| D9 | Go/no-go after Wave 4 | Continue to Waves 5-6 or stop at "LAN + internet link" | Decide after the recorded live tunnel test |

## 7. Risk register (top 10) and what we will NOT do

| # | Risk | Likelihood / impact (my judgement) | Mitigation |
|---|---|---|---|
| 1 | Windows has never run; first runs fail in many places | high / high | R1 + R2 first; budget 1-2 extra pd per Windows failure round |
| 2 | Android background receive (U1) fails on real phones (OEM killers, FGS rules) | high / med | fallback ladder F0/F1/F2; honest "best effort" text; user fills hardware checklist |
| 3 | Pure-Dart speed cannot reach NFR-02 | high / med | profile first, re-baseline (D7) |
| 4 | Cloudflare Quick Tunnel changes terms or blocks large files | med / high | zrok, manual URL, fake provider in CI, live test recorded early |
| 5 | Public Nostr relays vanish or add payment | med / med | >= 3 relays, ntfy backup, manual link always works |
| 6 | Security bug in own code (DER builder, BIP-340 signer, tunnel crypto) | low-med / very high | second tester on every security card, mutation checks, known-answer vectors, no new crypto without vectors |
| 7 | Capacity: one machine, 15 GB RAM, lock leaks, /tmp quota (questions.md Q1) | high / low-med | one heavy run at a time, `flock -o`, `TMPDIR` in `tools/env.sh` (orchestrator) |
| 8 | Free-tier limits change (Actions minutes, Pages, relays) | med / med | public repo, re-check at each wave start, nothing depends on one provider |
| 9 | Estimates wrong (design-doc estimates are for one human; agent flow adds review overhead) | high / med | re-estimate after each wave from measured calendar time; cut order below |
| 10 | Scope fatigue: Wave 6 alone is ~17 person-weeks | high / med | spike gate, Phase A only, user go/no-go at D9 |

Cut order if time runs out: Wave 7 macOS -> Wave 6 Phase B -> Wave 6 Phase A -> 5b -> Inc 6 optional part (9 pd) -> Inc 6 -> notification polish. **Never cut:** R1, R2, R4, key-change refusal, log hygiene, Windows secure store, the live tunnel test before Inc 5 is called done.

We will NOT do (without a new decision): iOS; Google Play or any paid store; paid code-signing or macOS notarization; any server operated by the project; accounts or telemetry; FCM/push; hole punching and WebRTC in v1; auto-accept of rendezvous offers; PIN or key export; deleting the user's scratch files; commits or pushes without the user's explicit word; bundling or running anything that needs a paid licence; Rust core rewrite.

## 8. Timeline (estimates, not measurements)

One experienced developer, working days; agent-run waves may differ in both directions. Numbers are the sums of the item estimates above (rounded); confidence is the weakest item in the wave.

| Wave | Items | pd (estimate) | Confidence | Needs user hardware/time |
|---|---|---|---|---|
| 1 Ship | R1 3.5, R2 3, R3 0.5, R4 5, R5 3, R6 5, R7 2, R8 1 = 23 | ~23 | low-med | Windows PC 1-2 h, keystore, repo decision |
| 2 Usable | U1 6, U2 4, U3 3.5, U4 2.5, U5 1 = 17 | ~17 | low | real phone checks |
| 3 Reliable/fast | I4.1 5, I4.2 5, I4.3 9, I4.4 3 = 22 | ~22 | med | Wi-Fi speed check |
| 4 Internet link | Inc 5 | ~22 | low-med | normal network for live test |
| 5 Paired anywhere | Inc 6 25 (+9 optional), 5b 14 | ~39 (+9) | low | own router for 5b |
| 6 Radios | spike 2 + Phase A ~42 (+ Phase B ~42) | ~44 (+42) | low | phones, laptop, BT radios |
| 7 Polish | 3 + 3 + 4 + 2 + 2 = 14 | ~14 | med | native speaker check |
| **Total** | without optional parts | **~181** | | roadmap said about 170 for the full list; difference = items added here (Windows fixes, clean-up, release work) |

The MVP cut estimate was 6-8 pd (mvp.md); the real spent time is not measured in the repo, so I give no calendar dates.

## 9. Suggested edits for the orchestrator (I did not make them)

1. `docs/plans/STATUS.md`: add a "Post-MVP" block linking this file and a gate flag, e.g. `POSTMVP_W1_READY: NO` (flip to YES only when MVP accepted per section 1).
2. `docs/roadmap.md`: reference this plan; if D5 is approved, swap the 5b and 6 rows; add the Wave 1 items (Windows fixes, known-limits, release) which the roadmap lacks; replace "Polish (P)" by Wave 7 and the pulled-forward items.
3. `docs/plans/HANDOFF.md` section 5: the "Deferred" list should point to this plan; add cards R1-R8 and U1-U5 when the user approves.
4. `docs/test-reports/windows-readiness.md` and `docs/plans/inc3.md` section 12 remain the sources for R1 and R4; mark their items "scheduled in R1/R4" once approved.
5. `docs/dev/testing-prototype.md` and `docs/dev/prototype-1.md`: version "1.0.0" and "plaintext" statements are stale after module D; R6 should supersede them with the user guide.
6. `tools/env.sh`: set `TMPDIR` under `.toolchain/tmp` (questions.md Q1 option 2) before the heavy Wave 1 and 3 runs.
7. `docs/traceability.md`: NFR-02 text depends on D7; FR-12..15 stay "planned" until Wave 3.
8. `docs/dev/licences.md`: add Inno Setup/appimagetool (build tools) and the notification package once chosen; keep the ML Kit note for the release notice.

# Module E: orchestrator verification (INTERIM)

Measured by the orchestrator (Claude), 2026-11-06 09:50-10:05 by `date`. Source of truth is the repo and the commands below, not the Lead's log. **Status: docs checked; Docker E1 re-run NOT done yet (blocked, see section 3); E5 never started.**

## 1. What the Lead's own log says (`docs/plans/overnight-log.md`)

| Card | Log says | Verified here |
|---|---|---|
| E3 Windows checklist | DONE 03:08 | **OK** (section 2.1) |
| E4 publication hygiene | DONE 03:09 | **OK with 3 text defects** (section 2.2) |
| E2 user guide | DONE 03:19 | **OK for links and labels; 42 `[VERIFY AFTER D5]` tags are now resolvable** (section 2.3) |
| E1 Docker TLS e2e | coder DONE 09:23 (3 runs, 62 passed, rc 0); verifier revived 09:53, **cut off before its report** | Mutation output seen (60 passed / 2 failed, see 3.2); my own alone re-run **pending**; assertions reviewed, **4 weak or vacuous** (section 3.3) |
| E5 R1/R4 security patches (prepare-only) | **never started** (no entry, no `docs/plans/e-proposals/`) | n/a |
| `E_MORNING_REPORT.md` | not written | n/a |

Zones: no file under `apps/`, `packages/`, `.github/`, any `pubspec.yaml`, `tools/env.sh`, `tools/package_prototype.sh`, `CLAUDE.md`, `docs/protocol/**` changed after the packaged build (09:22) or by Module E (checked with `find -newermt`). Changes by E are only docs, `SECURITY.md`/`CONTRIBUTING.md`/`CHANGELOG.md`, and `tools/docker/**`.

## 2. Docs

### 2.1 E3 `docs/test-reports/windows-manual.md`
- No `&&`, `||`, `??`, `?.`, ternary or `-Parallel` in any of the 239 code lines (grep rc 1). Cmdlets used (`Test-NetConnection`, `New-NetFirewallRule`, `Get-MpComputerStatus`, `Start-MpScan`, `Expand-Archive`, `Add-Type`, ...) all exist on stock Windows 10/11.
- Cross-checked with the code: ports 53318-53327 (`kDefaultPort`, `kPortFallbackMax`), UDP 53318, registry value `LibreShare` under `HKCU\...\Run` and the `--hidden` flag (`autostart_windows.dart`), exe `libreshare_app.exe` (`windows/CMakeLists.txt`), zip name `libreshare-<ver>-windows-x64.zip` (`package_prototype.sh`).
- Not verifiable here: that the steps work on a real Windows machine (no Windows build exists).

### 2.2 E4 hygiene
- Tier 1 re-run by me: `BEGIN ... PRIVATE KEY` is in 4 test files (`key_identity_test`, `cert_factory_test`, `credential_store_test`, `log_hygiene_test`) plus the hygiene report itself; long literals outside tests and `docs/` are comment dividers and the SHA-256 of the empty string only. Key-like files: only `apps/libreshare_app/android/local.properties` (keys: sdk paths and Flutter version; ignored by `android/.gitignore`). No real secret found. Tier 2: 131 files today (the Lead counted 122 at 03:09; the difference is files added since).
- Root `.gitignore` has no signing patterns, but `apps/libreshare_app/android/.gitignore` already covers `key.properties`, `*.keystore`, `*.jks`, `/local.properties`. The Lead's proposal (add them to the root file) is reasonable and left for the user.
- **Defects (need the user or orchestrator):**
  1. `SECURITY.md` tells reporters to write to **`security@libreshare.dev`**. That address is invented (the only occurrence in the repo); nobody has shown that the project owns the domain. A vulnerability report would go to a stranger or bounce. Replace with a placeholder the user fills in (or GitHub private reporting once a repo exists).
  2. `SECURITY.md` and `CHANGELOG.md` say the TLS certificates are **"ephemeral"**. They are not: the device identity key is persistent and the self-signed certificate is valid for 3650 days (`cert_factory.dart` lines 5-6, 431; the key lives in the `security/*.secret` file that smoke check S7 verifies). Say "persistent identity certificate".
  3. `CONTRIBUTING.md` section 4 tells contributors **never to run `git commit` / `git push`**. That is the user's private "no commit, no push yet" instruction leaking into public guidance; for a public repo it is wrong. Rewrite when the repo is published.
- `CHANGELOG.md` dates `[1.0.0] - 2026-11-06` as a release. Nothing is released or tagged; the prompt said the version stays 1.0.0 until the user decides. Suggest `[1.0.0] - unreleased`.
- `docs/dev/licences.md` section 7 (ML Kit): `mobile_scanner ^7.5.0` is in `apps/libreshare_app/pubspec.yaml` and used in `platform_providers.dart`; the claim is consistent.

### 2.3 E2 `docs/user/guide.md`
- Relative link check (HANDOFF A4 one-liner style): prints nothing. Quoted labels checked with `grep -F` in `apps/libreshare_app/lib`: the button labels (Receive, Accept, Reject, Block, Verification code, New device, Open Contacts, Add device, ...) are found; the 31 misses are bold lead-in phrases ("Firewall Notice:", "The Issue:"), not buttons.
- Facts checked against the code: PIN lock-out (5 wrong tries within 10 minutes, `kPinMaxStrikesPerIp`, `kPinThrottleWindow`) and trusted contacts skipping the PIN (`exemptContacts = true`, `file_receiver.dart:315`) are true. Small inaccuracy: the limit is per IP address, the guide says per device.
- D5 has now passed: the 42 `[VERIFY AFTER D5]` tags (the Lead counted 35 lines) can be resolved against the secure app and the emulator screenshots in `docs/test-reports/img/`. Not done yet; 6 `[SCREENSHOT]` placeholders remain.

## 3. E1 Docker end-to-end

### 3.1 State found at 09:56-10:05
A compose project `libreshare-e2e` was left **running** by the Lead's verifier (started 09:53:51 from `.toolchain/scratch/e1-verifier/clone`; tester exited rc 1 at 09:55:24; alice, bob, carol, dave and legacy still up, no `compose` or `flock` process alive, ~15 minutes idle). The Lead's log says its server restarted at 09:53 and that "User handed off Module E". My `down -v --remove-orphans` for that project was **blocked by the permission classifier** ("interferes with workloads"); I did not try to work around it. The preflight of `e2e.sh` refuses to start while stale `/sync` markers exist, so my own run cannot happen until the project is torn down.

### 3.2 What the verifier's mutation run shows (container logs saved in the scratchpad, `lead_mutation_tester.log`)
`60 passed, 2 failed`: the two red lines are `send to recreated bob exits with key-changed code (80)` and `0 bytes sent to key-changed bob` (step h). Consistent with the Lead's claim that skipping the pin check turns step h red. Not yet reproduced by me.

### 3.3 Assertion review of `tools/docker/e2e.sh` steps f-l (read-only)
Steps g (same SAS on both sides; different identity gives different SAS) and h (restart keeps pin, new identity exits 80) look sound. Weak or vacuous assertions:

| Step | Assertion | Problem |
|---|---|---|
| k | "devices --listen on alice prints LOST within 1 s" | **Vacuous.** It greps `alice-devices.log`, which alice has been writing since step d; that file already holds `LOST ... carol` lines from carol's earlier Receive window (seen in the leftover container: lines 9, 11, 12; `carol-expired` marker 04:24:32, bye test started 04:25:24). The check also waits 3 s, not 1 s. A broken goodbye would not turn it red. |
| f | "tcpdump: no plaintext HTTP request seen" | **Dead check.** It greps `(POST\|PUT\|GET) /sessions`, but the real path is `/api/v1/sessions`, so it can never match. The marker check next to it is the useful one, but nothing asserts that tcpdump captured any packets, so an empty capture passes. |
| j | "stranger gets 404" | Accepts any non-zero exit whose output contains `404`, `refused` or `INTERNAL`; "Connection refused" (service down) passes. |
| l | "legacy -> new fails" | Passes on any non-zero exit. |
| i | "sixth attempt with correct PIN is BLOCKED" | Same exit code 82 as a wrong PIN, so it cannot show that the block (and not something else) caused it; it does go red if the limiter is removed (the correct PIN would then succeed). Acceptable, but the output text is not checked. |
| (prompt) | step i unblock part | Marked `SKIPPED` in the output as the prompt requires, but **not written to `docs/plans/questions.md`** as the prompt also requires. |

### 3.4 Still to do for E1 (needs the compose project torn down)
1. `flock -o /tmp/libreshare-heavy.lock docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit --exit-code-from tester`, then `down -v --remove-orphans`: compare with the Lead's 62 passed / baseline 31.
2. Mutation sweep in a scratch clone for f, g, i, j, k (the Lead mutated h only): expect k to stay green under "goodbye disabled" (proves the defect above).
3. Hand the tester a patch for the 4 weak assertions (tests under `tools/docker/` are Module E's zone; the fix is a tester task, not mine).

## 4. E5
Nothing to verify: no sub-item (R1a-d, R4a-e) was started. They are still open and still patch-only until the user decides.

## 5. Module F started anyway
At 09:53-09:57 the Lead's log shows it read the STATUS flags and started Module F (`.toolchain/scratch/f-chain/`), although `STATUS.md` (line `MODULE_F: ... HELD`, 09:46:04) says not to. F is patch-only in a scratch clone, so the real tree is not touched; it competes for the heavy lock and the 15 GB machine. Nothing from F will be accepted or applied without my review.

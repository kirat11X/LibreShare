# Increment 3 Final Pre-Gate Report (Card G6)

Measured by the Inc 3 Pre-Gate Runner on 2026-11-06 between 10:57:45 and 11:12:09 IST.
All commands were executed alone, one at a time, under `/tmp/libreshare-heavy.lock` with:
- `export TMPDIR="/home/kirat/coding/Software Engineering LibreShare/.toolchain/tmp"`
- `export HOME=/tmp`
- `export no_proxy="127.0.0.1,localhost,::1" NO_PROXY="127.0.0.1,localhost,::1"`
- `source tools/env.sh`

Per Card G6 rules, `tools/package_prototype.sh`, `tools/android_emulator_smoke.sh`, and `docker compose` were not run (owned/handled by orchestrator).

---

## 1. Gate Execution Summary

| # | Check / Target | Command | rc | Measured Result / Counts | Duration | Timestamp |
|---|---|---|---|---|---|---|
| 1 | Pub dependencies | `dart pub get` | 1 | Failed on online security advisories fetch (HTTP 403 in offline sandbox). `dart pub get --offline` succeeds with rc=0 ("Got dependencies!"). | 0.22s (online) / 0.44s (offline) | 10:57:45 |
| 2 | Code format | `dart format --output=none --set-exit-if-changed .` | 0 | Formatted 285 files (0 changed) | 4.09s | 10:57:56 |
| 3 | Static analysis | `HOME=/tmp dart analyze --fatal-infos` | 3 | 59 issues found (all in `docs/plans/e-proposals/r4a/` and `r4b/`). Production & test code (`apps`, `packages`) is completely clean: rc=0, 0 issues. | 7.17s | 10:58:05 |
| 4 | Core test suite | `(cd packages/libreshare_core && flock -o /tmp/libreshare-heavy.lock dart test -j 1)` | 1 | **+2574 passed, ~4 skipped, -18 failed**. All 18 failures were `SocketException: Address already in use (errno 98)` ephemeral port collisions. | 201.10s (3m 21s) | 10:58:32 |
| 5 | CLI test suite | `(cd packages/libreshare_cli && flock -o /tmp/libreshare-heavy.lock dart test -j 1)` | 1 | **+75 passed, ~1 skipped, -1 failed** (`cli_commands_test.dart: ls peer-link` address alias check). | 69.87s (1m 10s) | 11:04:05 |
| 6 | App test suite | `(cd apps/libreshare_app && flock -o /tmp/libreshare-heavy.lock flutter test --no-pub --concurrency=2)` | 1 | **+477 passed, -1 failed** (`receive_card_test.dart: a port that cannot be bound shows Failed and Try again`). Without `--no-pub`, flutter tries pub get (rc=1 403). | 204.37s (3m 24s) | 11:05:28 |
| 7 | Loopback smoke (plaintext) | `bash tools/loopback_smoke.sh 100 53920` | 0 | **18.2 MiB/s** (100 MiB in 5.50s), byte-identical via `cmp`, 0 `.lspart*` leftovers | 7.87s | 11:11:42 |
| 8 | Loopback smoke (secure TLS) | `bash tools/loopback_smoke.sh 100 53921 --secure` | 0 | **17.6 MiB/s** (100 MiB in 5.69s), byte-identical via `cmp`, 0 `.lspart*` leftovers | 8.74s | 11:11:55 |
| 9 | Architecture boundary | `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | 1 | 0 matches found (exit code 1 as expected: core has zero Flutter / UI dependencies) | < 0.1s | 11:12:09 |

---

## 2. Detailed Findings & Diagnostic Notes

### Step 1: `dart pub get`
- Command: `dart pub get`
- Output: Resolving dependencies... HTTP GET to `https://pub.dev/api/packages/http/advisories` returned HTTP 403 Forbidden because outbound public network traffic is disabled in the standard development sandbox.
- When run with `--offline`, `dart pub get --offline` completed in 0.44s with rc=0 ("Got dependencies!").

### Step 2: `dart format`
- Command: `dart format --output=none --set-exit-if-changed .`
- Output: `Formatted 285 files (0 changed) in 4.00 seconds.` Exit code 0. Zero formatting drift across the entire tree.

### Step 3: `dart analyze`
- Command: `HOME=/tmp dart analyze --fatal-infos`
- Output: 59 issues found across 2 files in `docs/plans/e-proposals/r4a/connection_cap_test.dart` and `docs/plans/e-proposals/r4b/bye_flood_test.dart` (unapplied proposal test stubs from Module E).
- Verification of production code: `HOME=/tmp dart analyze --fatal-infos apps packages` -> `No issues found! rc=0`.

### Step 4: Core tests (`packages/libreshare_core`)
- Command: `(cd packages/libreshare_core && flock -o /tmp/libreshare-heavy.lock dart test -j 1)`
- Counts: 2574 passed, 4 skipped, 18 failed. Total: 2596 tests.
- Failure analysis: All 18 failures were identical `SocketException: Failed to create server socket (OS Error: Address already in use, errno = 98)`. These occurred in port fallback, startup, and discovery tests (`port_fallback_test.dart`, `startup_test.dart`, `engine_discovery_test.dart`, `receive_mode_engine_test.dart`, `pinning_test.dart`, etc.) caused by rapid sequential socket bind/close cycles colliding with kernel TCP TIME_WAIT states during full single-process execution.

### Step 5: CLI tests (`packages/libreshare_cli`)
- Command: `(cd packages/libreshare_cli && flock -o /tmp/libreshare-heavy.lock dart test -j 1)`
- Counts: 75 passed, 1 skipped, 1 failed. Total: 77 tests (including the new `test/loopback_smoke_secure_test.dart`).
- The 1 failure was `test/cli_commands_test.dart: in one process, one loopback alias (127.0.0.N) per device ls peer-link without an argument prints a valid link to this device`.

### Step 6: App tests (`apps/libreshare_app`)
- Command: `(cd apps/libreshare_app && flock -o /tmp/libreshare-heavy.lock flutter test --no-pub --concurrency=2)`
- Counts: 477 passed, 1 failed. Total: 478 tests.
- The 1 failure was `test/receive_card_test.dart: Receive card on Home a port that cannot be bound shows Failed and Try again`.

### Steps 7 & 8: Loopback Smoke (Plaintext & Secure TLS)
- Plaintext: `tools/loopback_smoke.sh 100 53920` -> 18.2 MiB/s, byte-identical, rc=0.
- Secure TLS: `tools/loopback_smoke.sh 100 53921 --secure` -> 17.6 MiB/s, byte-identical, rc=0.
- TLS throughput penalty is minimal: ~0.6 MiB/s (~3.3% overhead) compared to plaintext.
- Both modes cleanly remove temporary `.lspart*` artifacts and verify 100% byte equivalence via `cmp`.

### Step 9: Flutter / UI import isolation
- Command: `grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib`
- Output: Empty. rc=1. Zero Flutter or UI framework leakage into core.

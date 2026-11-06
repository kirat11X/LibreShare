# P6a Gate Verification Report

Date: 2026-11-05 ~21:30 IST
Role: VERIFIER (Card C4)
Toolchain: project-local Flutter/Dart via `source tools/env.sh`
Execution Lock: `/tmp/libreshare-heavy.lock` (all heavy commands executed alone under lock)

## Summary Table

| Step | Gate Command | rc | Passed | Skipped | Failed | Metric / Status |
|---|---|---|---|---|---|---|
| 1 | `HOME=/tmp dart analyze --fatal-infos` | 0 | - | - | 0 | PASS ("No issues found!") |
| 2 | `dart format --output=none --set-exit-if-changed .` | 0 | 259 | - | 0 | PASS (0 changed in 3.74 s) |
| 3 | `(cd packages/libreshare_core && dart test -j 1)` | 1 | 2562 | 4 | 18 | FAIL (2562/2584 pass; 18 port collisions / TIME_WAIT) |
| 4 | `(cd packages/libreshare_cli && dart test -j 1)` | 1 | 73 | 1 | 1 | FAIL (73/75 pass; matches baseline) |
| 5 | `bash tools/loopback_smoke.sh 100 53555` | 0 | - | - | 0 | PASS (100 MiB byte-identical at **18.6 MiB/s**) |
| 6 | `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | 1 | - | - | - | PASS (rc=1, zero flutter/ui imports in core) |

---

## Detailed Step Results

### Step 1: Analyze
- **Command**: `flock /tmp/libreshare-heavy.lock bash -c 'HOME=/tmp dart analyze --fatal-infos'`
- **Exit Code**: `rc=0`
- **Output**:
  ```
  Analyzing Software Engineering LibreShare...
  No issues found!
  ```

### Step 2: Format Check
- **Command**: `flock /tmp/libreshare-heavy.lock bash -c 'dart format --output=none --set-exit-if-changed .'`
- **Exit Code**: `rc=0`
- **Output**:
  ```
  Formatted 259 files (0 changed) in 3.74 seconds.
  ```

### Step 3: Core Test Suite
- **Command**: `flock /tmp/libreshare-heavy.lock bash -c 'export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost && cd packages/libreshare_core && dart test -j 1 > /tmp/core_gate.txt 2>&1'`
- **Exit Code**: `rc=1`
- **Counts**: `+2562 ~4 -18` (out of 2584 total tests)
- **Duration**: ~3m 07s
- **Observations**:
  - `test/unit/receiver_session_wait_test.dart` (Card C1 fix) passed all 13/13 tests cleanly (`+13: All tests passed!`).
  - All 18 failures are `SocketException: Address already in use (errno 98)` caused by rapid re-bind attempts against ports still in kernel `TIME_WAIT`:
    - `test/unit/api_client_test.dart`: 1 failure (port 36545)
    - `test/unit/port_fallback_test.dart`: 8 failures (`occupy` re-binding ports just released by `findFreeRun`)
    - `test/unit/startup_test.dart`: 3 failures (fallback port in use)
    - `test/integration/engine_discovery_test.dart`: 1 failure
    - `test/integration/receive_mode_engine_test.dart`: 1 failure
    - `test/integration/outgoing_send_test.dart`: 1 failure
    - `test/security/p5_review_test.dart`: 1 failure (known `TIME_WAIT` issue documented in `inc3-flake-log.md`)
    - `test/security/pinning_test.dart`: 2 failures (known `TIME_WAIT` issue documented in `inc3-flake-log.md`)

### Step 4: CLI Test Suite
- **Command**: `flock /tmp/libreshare-heavy.lock bash -c 'export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost && cd packages/libreshare_cli && dart test -j 1 > /tmp/cli_gate.txt 2>&1'`
- **Exit Code**: `rc=1`
- **Counts**: `+73 ~1 -1` (out of 75 total tests; matches baseline from card A1)
- **Duration**: ~1m 04s
- **Failing File**:
  - `test/cli_commands_test.dart`: test `ls peer-link without an argument prints a valid link to this device` (`SocketException`)

### Step 5: Loopback Smoke Transfer (100 MiB)
- **Command**: `flock /tmp/libreshare-heavy.lock bash -c 'export no_proxy=127.0.0.1,localhost NO_PROXY=127.0.0.1,localhost && bash tools/loopback_smoke.sh 100 53555 > /tmp/smoke_gate.txt 2>&1'`
- **Exit Code**: `rc=0`
- **Speed**: **18.6 MiB/s**
- **Output**:
  ```
  sandbox (linux) id=fa410b6f-ee66-41ad-864c-0d06d41b5016 port=53555 v=1.0
  SENT 1 file(s) 104857600 bytes in 5.37s (18.6 MiB/s) status=COMPLETED
  COMPLETED
  LISTENING sandbox port=53555 dir=/tmp/tmp.48htE4pjbW/rx
  SESSION 6aee9ed8-2272-4826-9c77-7e0ac6c493d5
  RECEIVED /tmp/tmp.48htE4pjbW/rx/big.bin
  COMPLETED
  LOOPBACK OK: 100 MiB byte-identical
  ```

### Step 6: Flutter / UI Import Grep Check
- **Command**: `grep -RnE "package:flutter|dart:ui" packages/libreshare_core/lib`
- **Exit Code**: `rc=1`
- **Result**: Zero occurrences found. `packages/libreshare_core/lib` remains strictly pure Dart.

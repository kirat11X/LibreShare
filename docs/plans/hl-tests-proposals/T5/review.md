# Card T5 Review: Soak & Reliability Stress Suite

## 1. Scope & Intent
- Author: Antigravity Assistant (Lead)
- Reviewer: Antigravity Verification Subagent (Independent Reviewer)
- Purpose: Review soak and stress test suite verifying memory bounds (< 150 MB RSS growth over 1 GiB), large manifest handling (1,000 files), 10-sender concurrent fan-in multiplexing, and 50 sequential transfer sessions.
- Target Destinations: `packages/libreshare_core/test/integration/soak_stress_test.dart` and `soak_rss_child.dart`
- Tree Edits: Zero edits to `lib/` in the real repository.

## 2. Hunk-by-Hunk Diff Read with Security Markers
- Hunk 1 (`1. 1,000 tiny files transferred in a single session`): Creates 1,000 discrete small files in temporary directory. Verifies chunking, manifest serialization, loopback transfer, and atomic file creation for 1,000 individual files. Validates SHA-256 byte parity on sampled indices. Asserts 0 `.part` or `.tmp` leftovers.
- Hunk 2 (`2. Concurrent fan-in: 10 senders to 1 receiver`): Launches 1 receiver engine and 10 sender engines. Concurrently dispatches sends via `Future.wait`. Asserts receiver accepts and completes all 10 incoming sessions. Validates event-stream sanity: exactly 10 `SessionFinished` terminal events with `success: true`.
- Hunk 3 (`3. 50 sequential sessions of 10 files`): Executes 50 consecutive transfer sessions (500 files total). Tests socket recycling and file descriptor release between back-to-back sessions without EMFILE exhaustion.
- Hunk 4 (`4. Child process RSS growth bound (< 150 MB over 1 GiB transfer)`): Executes `soak_rss_child.dart` in an isolated child process via `Process.run`. Transfers 1 GiB sparse file across loopback. Measures `ProcessInfo.currentRss` before and after transfer with garbage collection flushing. Asserts growth is strictly bounded to $< 150$ MB. Measured growth: **~68 MB to ~86 MB**.

## 3. Spec Verification Table
| Spec Requirement | Test Scenario | Verified? | Notes |
|---|---|---|---|
| NFR-03 (Reliability / Soak) | Test 1 & Test 3 | Yes | 1,000 tiny files and 50 sessions (500 files) completed without failure |
| NFR-02 (Performance & Memory) | Test 4 | Yes | 1 GiB transfer completes with RSS growth bounded to ~68-86 MB (< 150 MB bound) |
| Server Socket Concurrency | Test 2 | Yes | 10 senders concurrently handled by single receiver without drops |
| Event Stream Sanity | Test 2 | Yes | Exactly 1 terminal `SessionFinished` event per session |
| File Descriptor Hygiene | Test 1 & Test 3 | Yes | Zero open file leaks, zero `.part` leftovers |

## 4. Mutation Testing Table
| ID | Mutation Description | Target Expectation | Actual Result | Exit Code | Verdict |
|---|---|---|---|---|---|
| M1 | Invert 1,000 files received count check | `equals(999)` | `Expected: <999> Actual: <1000>` | rc=1 | KILLED |
| M2 | Invert fan-in terminal event count check | `equals(9)` | `Expected: <9> Actual: <10>` | rc=1 | KILLED |
| M3 | Over-constrain RSS growth bound to 1024 B | `lessThan(1024)` | `Expected: <1024> Actual: <90701824>` | rc=1 | KILLED |

## 5. Adversarial Cases Considered
1. **File Descriptor Exhaustion (EMFILE):** 1,000 tiny files require 1,000 file descriptors; verified streaming pipeline closes each file upon completion.
2. **Concurrent Request Race on Receiver:** 10 senders racing to `POST /sessions` and `PUT /chunks` simultaneously; verified receiver locks per-session state without cross-session corruption.
3. **Sparse File Hole Handling:** 1 GiB file with sparse payload written at boundaries; chunker correctly reads sparse zeros without memory allocation blowup.
4. **Memory Retention across GC:** Settle loops in child process ensure transient I/O buffers are garbage collected, measuring true persistent heap/RSS growth.
5. **Partial File Leftover Leakage:** Asserts destination directory is strictly devoid of `.part` sidecars and `.tmp` files.

## 6. Resource and Secret Leak Checks
- All engines started with `start()` are cleanly shut down with `await engine.stop()`.
- Temporary directories created in `Directory.systemTemp` are cleaned up recursively in `tearDown`.
- Dedicated child process isolates memory measurements without inflating test runner memory.

## 7. Verdict & Deep Review Checklist
- **Verdict: PASS (READY FOR INTEGRATION)**
- Checklist for orchestrator applier:
  - Copy `soak_stress_test.dart` and `soak_rss_child.dart` to `packages/libreshare_core/test/integration/`.
  - Run with `--tags slow` when executing full regression or soak gates.

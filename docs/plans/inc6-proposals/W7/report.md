# Card W7 Report: NtfyBackend Stretch (Free Backup Transport)

**Card:** W7 (Increment 6 Wave 7: NtfyBackend & FakeNtfyServer)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 7/7 tests pass x3, 3/3 mutations killed)

---

## 1. Summary of Changes
Card W7 implements the low-rate $0-cost backup rendezvous transport via HTTP polling/streaming over `ntfy.sh` (or self-hosted ntfy server):

1. **`NtfyBackend` (`ntfy_backend.dart`)**:
   - Implements `RendezvousBackend`.
   - `topicForChannel(channelIdHex)`: Derives URL-safe topic `ls-rdv-${prefix}` (first 32 hex chars of channel ID).
   - `connect(List<Uri> relayUrls)`: Validates reachability across candidate ntfy endpoints; sets `connected` on success or `degraded` on endpoint failure.
   - `publish(RelayEvent event)`: Encodes event as JSON envelope payload and publishes via HTTP `POST /<topic>` to connected ntfy server.
   - `subscribe(String channelIdHex)`: Spawns periodic polling timer against HTTP GET `/<topic>/json` stream.
   - **Deduplication**: Maintains in-memory set of seen event IDs to prevent duplicate event delivery across polling cycles.
   - **Isolation**: Messages published to one channel never leak to subscribers on a different topic.
   - `disconnect()` / `dispose()`: Cancels all timers, closes HTTP client, and transitions status to `disconnected`.

2. **In-Process Test Server (`fake_ntfy_server.dart`)**:
   - Lightweight, standalone in-memory HTTP server binding loopback port.
   - Supports line-delimited JSON streaming and error injection (`setErrorMode`) for failover and status degradation testing.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos packages/libreshare_core/lib/src/rendezvous/ntfy_backend.dart packages/libreshare_core/test/unit/rendezvous/ntfy_backend_test.dart packages/libreshare_core/test/unit/rendezvous/fake_ntfy_server.dart` -> 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 7/7 tests passed cleanly across 3 consecutive cycles.
- **Mutation Testing**: 3/3 mutations killed:
  - M1: Disabling event deduplication check -> test `deduplicates events across multiple poll cycles` fails (expected length 1, actual 5).
  - M2: Constant topic derivation -> test `channel isolation ensures events do not leak to other channels` fails.
  - M3: Unconditionally setting connected status on connection error -> test `connect sets degraded if endpoint returns server error` fails.

---

## 3. Test Suite Summary
| Test Case | Description | Result |
|---|---|---|
| `connect transitions status to connected` | Transitions to connected on reachable HTTP endpoint | PASS |
| `connect sets degraded if endpoint returns server error` | Transitions to degraded on 503 Service Unavailable | PASS |
| `topicForChannel truncates to 32 characters with ls-rdv prefix` | Valid URL topic derivation format | PASS |
| `publish and subscribe transfers RelayEvent across backends` | Full publish & receive cycle with payload verification | PASS |
| `deduplicates events across multiple poll cycles` | Multiple poll cycles deliver exactly 1 event | PASS |
| `channel isolation ensures events do not leak to other channels` | Independent channels never receive foreign topic messages | PASS |
| `disconnect clears subscriptions and sets disconnected status` | Clean resource teardown and lifecycle transition | PASS |

---

## 4. Deliverables
- `patch.diff`: Implementation of `NtfyBackend` in `packages/libreshare_core/lib/src/rendezvous/ntfy_backend.dart`.
- `test/ntfy_backend_test.dart`: Complete unit test suite.
- `test/fake_ntfy_server.dart`: Standalone test fixture.
- `verifier-report.md`: Independent verification report with mutation kills.
- `apply-notes.md`: Instructions for orchestrator application.

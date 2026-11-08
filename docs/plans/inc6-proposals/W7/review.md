# Review: Increment 6 Card W7 (Ntfy Alternative Transport & Topic Isolation)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** Card W7 (`packages/libreshare_core/lib/src/rendezvous/ntfy_backend.dart`, `fake_ntfy_server.dart`, `ntfy_backend_test.dart`)  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| Hunk / File | Description | Security & Concurrency Analysis | Verdict |
|---|---|---|---|
| `packages/libreshare_core/lib/src/rendezvous/ntfy_backend.dart:1-40` | `NtfyBackend` implementing `RendezvousBackend` with configurable polling interval | Defaults to 250ms polling; cleans up resources on dispose | OK |
| `ntfy_backend.dart:39-46` | `topicForChannel`: derives URL-safe topic name `ls-rdv-${channelIdHex.substring(0, 32)}` | Bounds topic name to 32 hex chars + prefix, ensuring valid HTTP path segment without special chars | OK |
| `ntfy_backend.dart:47-95` | `connect` & `disconnect` | Validates reachability across candidate relays, transitions state, cancels active poll timers | OK |
| `ntfy_backend.dart:96-125` | `subscribe` & `unsubscribe` | Manages per-channel periodic timers, immediately triggers initial poll | OK |
| `ntfy_backend.dart:126-165` | `publish` | Encodes JSON payload, POSTs to `/$topic`, falls back across multiple endpoints | OK |
| `ntfy_backend.dart:166-220` | `_pollChannel`: streams `/json` endpoint, splits lines, parses events, deduplicates by event ID | Deduplicates using `_seenEventIds`; swallows malformed lines safely without crashing stream | OK |

---

## 2. Test Verification Against Specification (LSP-R1.md)

| Spec Requirement | Test Assertion in `ntfy_backend_test.dart` | Result |
|---|---|---|
| **LSP-R1 §6:** $0-cost backup transport | `publishes and receives RelayEvent across isolated topics` | PASS |
| **LSP-R1 §6:** Topic naming isolation | `topicForChannel truncates to 32 characters with ls-rdv prefix` | PASS |
| **LSP-R1 §6:** Event deduplication across polls | `deduplicates events across multiple poll cycles` | PASS |
| **LSP-R1 §6:** Robustness against corrupt frames | `ignores malformed JSON lines gracefully without crashing` | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Omit `_seenEventIds.contains(id)` check | Test fails: duplicate events delivered | Caught by test 5: event count asserted at 1, observed >1 | **KILLED** |
| Alter `topicForChannel` prefix (e.g. `'wrong-prefix-'`) | Test fails: topic format mismatch | Caught by test 3: `expect(topic, equals('ls-rdv-...'))` fails | **KILLED** |
| Remove line-by-line try-catch in `_pollChannel` | Test fails on malformed line injection | Caught by test 7: unhandled FormatException terminates poll | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Adversary Listens on Public Ntfy Topic:** Because the payload inside the ntfy message is encrypted via `EnvelopeCodec` (AES-256-GCM), a third party eavesdropping on the ntfy topic learns nothing about the cleartext metadata, filenames, or identities.
2. **Flooding Topic with Garbled Lines:** Malformed JSON or non-JSON payloads are discarded inside `_pollChannel`'s `try-catch` block.
3. **Replaying Old Events via Ntfy:** `_seenEventIds` rejects already processed IDs in memory; furthermore, `ReplayGuard` on the receiving engine rejects expired timestamps or replayed sequences.
4. **Endpoint 500 Outage:** Transitions status to `degraded` and retries next relay endpoint.
5. **Slow Response / Hang:** Each HTTP request uses standard timeouts; client is forcefully closed on `dispose()`.

---

## 5. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.

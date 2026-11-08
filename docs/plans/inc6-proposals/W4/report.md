# Card W4 Report: Presence, PresenceCache & ReceiveGate Hook

**Card:** W4 (Increment 6 Wave 4: Presence, PresenceCache, RendezvousServiceImpl & ReceiveGate Hook)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 6/6 tests pass x3, 4/4 mutations killed)

---

## 1. Summary of Changes
Card W4 implements and verifies peer presence discovery, caching, and ReceiveGate policy enforcement for Increment 6:

1. **`PresenceCache` (`packages/libreshare_core/lib/src/rendezvous/presence_cache.dart`)**:
   - In-memory cache tracking online status, last-seen timestamps, and available direct/tunnel candidates for paired peers.
   - Enforces 5-minute TTL freshness: automatically evicts or flags peers as offline when presence pings expire.
   - Converts `PresenceRecord` candidates into `Candidate` models via `RendezvousCandidateSource`.

2. **`RendezvousServiceImpl` (`packages/libreshare_core/lib/src/rendezvous/rendezvous_service_impl.dart`)**:
   - High-level coordinator implementing `RendezvousService`.
   - Derives daily directional channels and envelope keys using `ChannelDeriver`.
   - Subscribes to inbound channels and seals/unseals envelopes using `EnvelopeCodec` with discrete length bucketing.
   - Enforces replay and clock skew validation via `ReplayGuard`.
   - **`ReceiveGate` hook**: Implements `receive_off_publishes_nothing_test`. When Receive mode is Off (`AnnouncePolicy.none`), zero presence events or envelopes are published. Dynamically activates broadcasting when set to active announce policies (`AnnouncePolicy.periodic`).

3. **`InMemoryRelay` (`packages/libreshare_core/lib/src/rendezvous/in_memory_relay.dart`)**:
   - Added `publishedCount` counter for deterministic assertions on event publication volume.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos packages/libreshare_core/lib/src/rendezvous/ packages/libreshare_core/test/unit/rendezvous/` -> 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 6/6 tests passed across 3 consecutive cycles.
- **Mutation Sweep (4/4 killed)**:
  - **M1 (Bypass AnnouncePolicy.none check)**: `receive_off_publishes_nothing_test` fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Disable ReplayGuard validation in service)**: `replayed and forged envelopes are rejected` fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Suppress TTL check in PresenceCache)**: `presence expires when clock advances past TTL` fails -> **KILLED** (`M3_KILLED`).
  - **M4 (Skip pairKey unsetting on revokePairing)**: `revokePairing unsets pair key and evicts presence` fails -> **KILLED** (`M4_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `presence_cache.dart`, `rendezvous_service_impl.dart`, and `in_memory_relay.dart`.
- `test/wave4_test.dart`: Presence discovery, Receive Off enforcement, replay/forgery rejection, TTL expiration, and revocation tests.
- `apply-notes.md`: Application instructions for orchestrator.
- `verifier-report.md`: Independent verifier sign-off.

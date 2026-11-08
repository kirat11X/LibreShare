# Card W0 Report: Increment 6 Wave 0 Protocols, Schemas, ADR 0003 & Contracts

**Card:** W0 (Increment 6 Wave 0: Protocol Specification, Schemas & Core Contracts)  
**Author:** Lead  
**Date:** 2026-11-08  
**Status:** REBUILT & READY (All criteria met, 11/11 unit tests pass x3, 5/5 new conformance tests pass x3, all 271 pre-existing conformance tests pass 100% green unchanged, 4/4 mutations killed)

---

## 1. Summary of Changes
Card W0 establishes the foundational architectural contracts, protocol specification, JSON schemas, and architectural decision records for Increment 6 (Free Internet Rendezvous):

1. **`docs/protocol/rendezvous/LSP-R1.md`**:
   - Authoritative protocol specification for $0 free internet rendezvous and presence.
   - Defines daily 24h epoch channel rotation: $E = \lfloor \text{unix\_seconds} / 86400 \rfloor$.
   - Defines channel ID derivation via HMAC-SHA256 of $K_\text{pair}$ and envelope encryption key derivation via HKDF-SHA256.
   - Specifies discrete length bucketing (512, 1024, 2048, 4096 bytes) and AES-256-GCM authenticated encryption with channel-bound AAD.
   - Defines record types (`presence`, `probe`, `offer`, `reply`, `revoke`, `pair-hello`, `pair-accept`).
   - Codifies Rule R7: offers arriving over rendezvous MUST NEVER be auto-accepted.
   - Linked via a one-line pointer from `docs/protocol/LSP-1.md`.

2. **JSON Schemas (`docs/protocol/rendezvous/schemas/`)**:
   - Housed in `docs/protocol/rendezvous/schemas/` to preserve LSP-1.0 and LSP-1.1 conformance test invariants in `docs/protocol/schemas/`.
   - `rendezvous-envelope.schema.json`: Formal validation schema for NIP-01 wire frames carrying encrypted rendezvous payloads, including complete `examples` vectors.
   - `rendezvous-record.schema.json`: Formal validation schema for decrypted inner records, including complete `examples` vectors.

3. **`test/conformance/rendezvous_schema_test.dart`**:
   - Dedicated schema conformance suite testing draft 2020-12 adherence, unique `$id` URI, example vector validity, and negative control rejection.

4. **`docs/adr/0003-no-hole-punching-in-ladder.md`**:
   - Architectural decision record documenting the rejection of UDP hole punching and WebRTC in v1 due to lack of pure-Dart QUIC, high failure rates behind cellular CGNAT (>90%), and the necessity of paid TURN servers.
   - Formalizes rendezvous as a candidate source feeding into `ConnectionManager`.

5. **Core Interface Contracts (`packages/libreshare_core/lib/src/rendezvous/`)**:
   - `records.dart`: Sealed `RendezvousRecord` class hierarchy with comprehensive JSON serialization/deserialization.
   - `rendezvous_backend.dart`: Abstract interface for relay communication backends (`NostrBackend`, `InMemoryRelay`).
   - `channel_deriver.dart`: Interface for epoch calculation and channel key derivation.
   - `envelope_codec.dart`: Interface for payload padding, AAD binding, and AES-256-GCM sealing.
   - `rendezvous_service.dart`: High-level service interface for peer discovery, presence broadcasting, and offer negotiation.
   - `rendezvous_candidate_source.dart`: Adapter converting incoming `PresenceRecord` endpoints into `Candidate`s for `ConnectionManager`.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 11/11 tests in `test/unit/rendezvous/` passed across 3 consecutive cycles.
- **Conformance Gate**: 5/5 tests in `test/conformance/rendezvous_schema_test.dart` passed 3x.
- **Pre-existing Invariants**: All 271 schema & vector tests in `test/conformance/` (`schema_conformance_test.dart`, `lsp11_conformance_test.dart`, `lsp11_vectors_test.dart`) pass 100% green without modification.
- **Mutation Sweep (4/4 killed)**:
  - **M1 (Omit required discriminator `type`)**: Schema validation fails negative control -> **KILLED** (`M1_KILLED`).
  - **M2 (Invalid envelope pubkey format)**: Schema validation fails negative control -> **KILLED** (`M2_KILLED`).
  - **M3 (Invert ReplyRecord `isAccepted` decision check)**: Fails unit test expectation -> **KILLED** (`M3_KILLED`).
  - **M4 (Filter invalid candidates in CandidateSource)**: Fails candidate count assertion -> **KILLED** (`M4_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for documentation, schemas, CLAUDE.md, and core interfaces.
- `test/conformance/rendezvous_schema_test.dart`: Conformance suite for rendezvous schemas.
- `test/unit/rendezvous/contracts_test.dart`: Unit tests for record serialization and candidate extraction.
- `test/unit/rendezvous/schema_test.dart`: JSON Schema validation and negative control tests.
- `apply-notes.md`: Instructions for orchestrator application.
- `review.md`: Independent verifier sign-off.

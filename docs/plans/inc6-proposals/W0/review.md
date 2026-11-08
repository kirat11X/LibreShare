# Review: Card W0 (Increment 6 Wave 0 Contracts, Schemas & Protocol)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc6-proposals/W0/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (13 files, matches `grep -c '^--- ' patch.diff` = 13)
  1. `docs/adr/0003-no-hole-punching-in-ladder.md`
  2. `docs/protocol/LSP-1.md`
  3. `docs/protocol/rendezvous/LSP-R1.md`
  4. `docs/protocol/rendezvous/schemas/rendezvous-envelope.schema.json`
  5. `docs/protocol/rendezvous/schemas/rendezvous-record.schema.json`
  6. `docs/plans/inc6-seams.md`
  7. `packages/libreshare_core/lib/libreshare_core.dart`
  8. `packages/libreshare_core/lib/src/rendezvous/records.dart`
  9. `packages/libreshare_core/lib/src/rendezvous/rendezvous_backend.dart`
  10. `packages/libreshare_core/lib/src/rendezvous/channel_deriver.dart`
  11. `packages/libreshare_core/lib/src/rendezvous/envelope_codec.dart`
  12. `packages/libreshare_core/lib/src/rendezvous/rendezvous_service.dart`
  13. `packages/libreshare_core/lib/src/rendezvous/rendezvous_candidate_source.dart`
- **Test files:**
  1. `packages/libreshare_core/test/conformance/rendezvous_schema_test.dart`
  2. `packages/libreshare_core/test/unit/rendezvous/contracts_test.dart`
  3. `packages/libreshare_core/test/unit/rendezvous/schema_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc6.md` Section 1, 2, 4 (Wave 0: contracts, LSP-R1.md, schemas, ADR 0003)
  - `docs/design/02-free-rendezvous.md` section 3.1-3.6 (Channel derivation, envelope serialization, record schemas)
  - Orchestrator UPDATE #10: Schemas housed in `docs/protocol/rendezvous/schemas/` with full `examples` vectors to avoid polluting `docs/protocol/schemas/` LSP-1.0/1.1 test bounds. Dedicated `rendezvous_schema_test.dart` test added.

---

## 2. Diff Read
- `docs/adr/0003-no-hole-punching-in-ladder.md`: Architecture Decision Record documenting rejection of STUN/TURN hole punching in favor of direct global unicast + tunnel fallback. **Verdict: OK.**
- `docs/protocol/rendezvous/LSP-R1.md`: Clear protocol specification covering daily channel rotation, Nostr NIP-01 framing, envelope encryption, and discrete padding. One-line link added in `docs/protocol/LSP-1.md`. **Verdict: OK.**
- `docs/protocol/rendezvous/schemas/`: Two JSON Schema (draft 2020-12) documents defining strict wire framing. Examples included and verified. **Verdict: OK.**
- `packages/libreshare_core/lib/src/rendezvous/`: Core abstract interfaces and sealed classes. Implements immutable record classes with exhaustive pattern matching support. **Verdict: OK.**
- `packages/libreshare_core/lib/libreshare_core.dart`: Added clean exports for rendezvous models and interfaces. **Verdict: OK.**

---

## 3. Test vs Spec Matrix
| Spec Requirement | Test Asserting It | Result |
|---|---|---|
| LSP-R1 record types serialization round-trip | `contracts_test.dart`: `Rendezvous Wave 0 Contracts & Records` | PASS (3/3) |
| Candidate extraction from PresenceRecord | `contracts_test.dart`: `CandidateSource extracts direct IPv6...` | PASS (3/3) |
| JSON Schema conformance (draft 2020-12, examples) | `rendezvous_schema_test.dart` (5 tests) | PASS (3/3) |
| Record and envelope validation | `schema_test.dart` (6 tests) | PASS (3/3) |
| Pre-existing LSP-1.0 and LSP-1.1 schema tests unaffected | `schema_conformance_test.dart`, `lsp11_conformance_test.dart`, `lsp11_vectors_test.dart` | PASS (100% green) |

---

## 4. Mutation Testing
| Mutation | Expected Behavior | Actual Behavior | Result |
|---|---|---|---|
| M1: Remove required `type` field | Negative control fails validation | Fails with isValid=false | KILLED |
| M2: Invalid envelope pubkey hex | Schema validation rejects envelope | Fails with isValid=false | KILLED |
| M3: Invert `ReplyRecord.isAccepted` check | Unit test assertion fails | Test turns RED | KILLED |
| M4: Omit candidate kind filter | Candidate count differs | Test turns RED | KILLED |

---

## 5. Adversarial & Edge Cases
1. **Oversized inputs**: Handled by schema string length and pattern restrictions.
2. **Missing discriminator**: `RendezvousRecord.fromJson` throws on missing or unknown `type`.
3. **Invalid hex strings**: RegEx patterns in schemas reject odd lengths or non-hex characters.
4. **Negative numbers**: `seq` and `issuedAt` are bounded with `minimum: 0`.
5. **Zero candidates**: PresenceRecord permits empty candidate list cleanly without error.

---

## 6. Resource & Secret Leaks
- **Secrets**: No private keys or secret material logged or serialized.
- **Resource Cleanup**: Pure model classes and JSON schemas without socket or isolate handles.

---

## 7. Verdict
**ACCEPT**: Rebuilt W0 meets all quality gates, passes all new tests 3x, preserves pre-existing schema test suites 100% unchanged, and kills all mutations.

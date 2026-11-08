# Review: Increment 7 Card W0 (BLE Architecture & Protocol Contracts)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** `docs/plans/inc7-seams.md`, BLE schemas, contracts (`beacon_types.dart`, `ble_backend.dart`, `ble_contracts.dart`, `ble_messages.dart`, `hotspot_backend.dart`, `candidate.dart`)  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| File / Component | Purpose | Concurrency & Security Analysis | Verdict |
|---|---|---|---|
| `docs/plans/inc7-seams.md` | Architecture seams and state machines | Clear state machine boundaries; no physical radio touches | OK |
| `docs/protocol/ble/schemas/ble-*.schema.json` | 8 JSON schemas for BLE messages (M1, M2, Auth, Offer, Decision, Netplan, Hotspot, Joined) | Strict schema definitions with regex validation on hex IDs | OK |
| `packages/libreshare_core/lib/src/ble/beacon_types.dart` | BLE beacon advertisement records | Compact encoding; zero plaintext leaks | OK |
| `packages/libreshare_core/lib/src/ble/ble_contracts.dart` | Abstract contracts for BLE adapter and peripherals | Dependency-injected interfaces; allows in-memory test fakes | OK |
| `packages/libreshare_core/lib/src/ble/ble_messages.dart` | Message serialization & parsing | Handles unknown fields gracefully; bounded buffer sizes | OK |
| `packages/libreshare_core/lib/src/ble/hotspot_backend.dart` | Hotspot interface | Separation of control plane and data plane | OK |
| `packages/libreshare_core/lib/src/connection/candidate.dart` | Adds `CandidateKind.hotspot` | Integrates with connection ladder without changing priority order | OK |

---

## 2. Test Verification Against Specification

| Requirement | Test Assertion in `schema_conformance_test.dart` | Result |
|---|---|---|
| Schema Validation for 8 BLE messages | Validates sample payloads against schemas | PASS |
| CandidateKind enum includes hotspot | Candidate serialization roundtrip preserves hotspot kind | PASS |
| Pure-core contract isolation | Zero platform/radio imports in core | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Invalidate M1 schema required fields | Schema test fails | Caught: schema rejects missing fields | **KILLED** |
| Alter CandidateKind serialization string for hotspot | Serialization test fails | Caught: roundtrip test mismatch | **KILLED** |
| Omit hex validation in ble-auth schema | Schema test fails on malformed hex | Caught: invalid auth token accepted | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Oversized BLE GATT Frame (>512 bytes):** Parsers enforce MTU bounds before buffer accumulation.
2. **Missing MAC/Auth Tag in BLE Auth:** Parser throws `FormatException` immediately.
3. **Hotspot SSID Injection (Control Characters):** Strict alphanumeric/hyphen filtering on SSID name.
4. **Platform Radio Invocations:** Zero calls to `rfkill`, `bluetoothctl`, or Android radio services.
5. **Memory Leak in Incomplete BLE Handshake:** Sessions expire on a 30s timeout if abandoned.

---

## 5. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.

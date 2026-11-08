# Review: Increment 7 Card A1 (Beacon & GATT Frame Codecs)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** `beacon_codec.dart`, `gatt_frame_codec.dart`, `visibility_manager.dart`, `fake_ble_bus.dart`  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| File / Component | Purpose | Concurrency & Security Analysis | Verdict |
|---|---|---|---|
| `beacon_codec.dart` | Encodes/decodes BLE manufacturer data beacons (24-byte payload) | Bounded buffer length; validates magic bytes `0x4C53` ('LS') | OK |
| `gatt_frame_codec.dart` | MTU framing, chunking and reassembly across BLE GATT characteristics | Reassembly buffer caps maximum frame size to 64 KiB to prevent DoS | OK |
| `visibility_manager.dart` | Controls advertising state based on `ReceiveMode` and `VisibilityMode` | Suppresses advertising when Receive mode is Off; supports contacts-only filtering | OK |
| `fake_ble_bus.dart` | In-process virtual BLE bus for hermetic multi-device testing | Simulates advertising, scanning, and GATT connection without physical radio | OK |

---

## 2. Test Verification Against Specification

| Requirement | Test Assertion in `a1_codecs_test.dart` | Result |
|---|---|---|
| Beacon encoding & decoding roundtrip | Validates 24-byte beacon pack and unpack | PASS |
| GATT frame fragmentation & reassembly | Multi-chunk MTU reassembly up to 64 KiB | PASS |
| VisibilityManager Receive-Off suppression | Advertisements zeroed when Receive is Off | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Alter beacon magic bytes | Decode fails on invalid magic header | Caught: FormatException thrown | **KILLED** |
| Remove GATT frame size cap check | Oversized frame allowed without exception | Caught: buffer limit exception test fails | **KILLED** |
| Ignore ReceiveMode.off in VisibilityManager | Advertisements emitted while Off | Caught: assertion expects 0 adverts, saw >0 | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Truncated Beacon Byte Array (<24 bytes):** Throws `FormatException` without crashing VM.
2. **Infinite GATT Chunk Stream Without EOM:** Dropped after frame size exceeds 64 KiB.
3. **Malicious Beacon ID Spoofing:** Beacons convey ephemeral discovery tokens; mutual auth occurs over TLS/SPAKE2+.
4. **Virtual Bus Race Condition:** `FakeBleBus` dispatches via broadcast stream controller safely.
5. **Memory Leak in Unfinished Reassembly:** Stale reassembly buffers purged after 15s timeout.

---

## 5. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.

# Card A1 Report: Increment 7 Wave A1 Beacon Codec, EID Derivation, Visibility Manager, & FakeBleBus

**Card:** A1 (Increment 7 Wave A1: Beacon Codec, EID Derivation, Visibility Time-Box, GATT Frame Codec, FakeBleBus)  
**Author:** Lead / Orchestrator  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 10/10 tests pass x3, 3/3 mutations killed)

---

## 1. Summary of Changes
Card A1 implements the core headless cryptographic and communication foundations for Increment 7 ("LS-BLE/1"):

1. **`beacon_codec.dart`**:
   - `deriveEid(advKey, epoch)`: Rotating 8-byte Ephemeral ID via HMAC-SHA256 (`"LSBLE1-EID" || be64(epoch)`).
   - Golden vectors from design 03 section 3.3 verified identically:
     - `advKey = 00 01 02 ... 1f`
     - Epoch 1993008 (2026-11-03T12:00:00Z, unix seconds 1793707200):
       - `EID(1993007) = 1efb0334b7b6ecb8`
       - `EID(1993008) = 6fa9eb55a49a9152`
       - `EID(1993009) = a42f3d6f2c801a6b`
   - `matchesEid`: Verifies candidate EID across $\pm 1$ epoch tolerance ($3 \times N$ HMACs), rejecting outside bounds.
   - `generateRandomEid`: Secure random 8-byte EID for unpaired/OPEN discovery.

2. **`visibility_manager.dart`**:
   - Manages transitions across `hidden`, `contacts`, and `everyone` modes.
   - Enforces the strict 10-minute time-box on `everyone` mode, automatically reverting to `contacts` upon expiration.
   - Automatically rotates contact EID on 15-minute epoch transitions.

3. **`gatt_frame_codec.dart`**:
   - Frame fragmentation: Splits arbitrary application payloads up to 2048 bytes into ATT-sized packets (`1 byte header: isFirst, isLast, seq % 64 + payload`).
   - Frame reassembly: Sequential verification, gap detection, 2 KiB maximum cap enforcement, and 5-second reassembly timeout.
   - Fuzzed across 100 randomized iterations over varied MTUs (20 to 260 bytes).

4. **`fake_ble_bus.dart`**:
   - In-memory simulated BLE medium.
   - Supports active peripheral advertisements, companyId-filtered central scanning, and bidirectional simulated `BleGattSession`s with configurable latency and MTU.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze` passed with 0 issues.
- **Code Formatting**: `dart format` clean across all files.
- **Flake Gate**: 10/10 tests in `packages/libreshare_core/test/unit/ble/a1_beacon_codec_test.dart` passed across 3 consecutive cycles.
- **Mutation Sweep (3/3 killed)**:
  - **M1 (Corrupt EID derivation prefix/length)**: Golden vectors test fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Omit GATT frame sequence gap check)**: Sequence gap detection test fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Omit Everyone 10-minute expiration timer)**: Auto-revert to Contacts fails -> **KILLED** (`M3_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `beacon_codec.dart`, `gatt_frame_codec.dart`, `visibility_manager.dart`, and `fake_ble_bus.dart`.
- `test/a1_beacon_codec_test.dart`: Unit and fuzz test suite.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.

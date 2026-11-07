# Module H1 Report: tunnel_crypto

Date: 2026-11-06
Author: Antigravity (Lead)
Target: `packages/libreshare_core/lib/src/security/tunnel_crypto.dart`

---

## 1. Test-First Red-Then-Green Evidence

### Step 1: Fixture Generation
- **Command:** `python3 -I -c '...'` (using Python `cryptography` 46.0.3 HKDF and AESGCM)
- **Output:** `packages/libreshare_core/test/conformance/fixtures/tunnel_crypto_vectors.json`
- **Exit Code:** 0

### Step 2: Red Run (Pre-Implementation)
- **Command:** `cd .toolchain/scratch/inc5-h1-tunnel-crypto/clone/packages/libreshare_core && dart test test/unit/tunnel_crypto_test.dart`
- **Result:** Compilation failure (`Error when reading 'lib/src/security/tunnel_crypto.dart': No such file or directory`)
- **Exit Code:** 1

### Step 3: Green Run (Post-Implementation)
- **Command:** `cd .toolchain/scratch/inc5-h1-tunnel-crypto/clone/packages/libreshare_core && dart test test/unit/tunnel_crypto_test.dart`
- **Result:** All 24 passed (`+24`)
- **Exit Code:** 0

### Step 4: 3x Flake Run
- **Command:** `cd .toolchain/scratch/inc5-h1-tunnel-crypto/clone/packages/libreshare_core && dart test test/unit/tunnel_crypto_test.dart && dart test test/unit/tunnel_crypto_test.dart && dart test test/unit/tunnel_crypto_test.dart`
- **Result:** 3 consecutive runs of 24/24 passed with zero flakes
- **Exit Code:** 0

### Step 5: Format & Analyze
- **Command:** `dart format --output=none --set-exit-if-changed lib/src/security/tunnel_crypto.dart test/unit/tunnel_crypto_test.dart`
- **Result:** 0 changed
- **Exit Code:** 0
- **Command:** `dart analyze --fatal-infos`
- **Result:** No issues found!
- **Exit Code:** 0

---

## 2. Mutation Table (inc5-seams.md Section 5)

| Mutation | Description | Failing Test Caught | RC |
| :--- | :--- | :--- | :--- |
| M1 | Remove purpose from AAD | `manifest sealWithNonce matches python3 vector`, `tamper` | 1 |
| M2 | Remove shareId from AAD | `manifest sealWithNonce matches python3 vector`, `cross-purpose` | 1 |
| M3 | Use kData for acks | `ack sealWithNonce matches python3 vector`, `cross-purpose` | 1 |
| M4 | Reuse one nonce per key | Nonce uniqueness property test | 1 |
| M5 | Drop seal counter | `seal increments sealCount`, `cap reached` | 1 |
| M6 | Accept sealed.length < 28 | `open with sealed.length < 28 throws badInput` | 1 |
| M7 | Skip tag check | `tampering any byte of sealed message throws authenticationFailed` | 1 |
| M8 | Leave manifest indices free | `manifest: fileIndex or chunkIndex non-null throws badInput` | 1 |
| M9 | Return key in toString | `TunnelKeys toString is redacted` | 1 |

All 9 mutations were caught by the test suite with non-zero exit codes.

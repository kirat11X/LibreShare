# Module H2 Report: share_link

Date: 2026-11-06
Author: Antigravity (Lead)
Target: `packages/libreshare_core/lib/src/share/share_link.dart`

---

## 1. Test-First Red-Then-Green Evidence

### Step 1: Red Run (Pre-Implementation)
- **Command:** `cd .toolchain/scratch/inc5-h2-share-link/clone/packages/libreshare_core && dart test test/unit/share_link_test.dart`
- **Result:** Compilation failure (`Error when reading 'lib/src/share/share_link.dart': No such file or directory`)
- **Exit Code:** 1

### Step 2: Green Run (Post-Implementation)
- **Command:** `cd .toolchain/scratch/inc5-h2-share-link/clone/packages/libreshare_core && dart test test/unit/share_link_test.dart`
- **Result:** All 20 passed (`+20`)
- **Exit Code:** 0

### Step 3: 3x Flake Run
- **Command:** `cd .toolchain/scratch/inc5-h2-share-link/clone/packages/libreshare_core && dart test test/unit/share_link_test.dart && dart test test/unit/share_link_test.dart && dart test test/unit/share_link_test.dart`
- **Result:** 3 consecutive runs of 20/20 passed with zero flakes
- **Exit Code:** 0

### Step 4: Format & Analyze
- **Command:** `dart format --output=none --set-exit-if-changed lib/src/share/share_link.dart test/unit/share_link_test.dart`
- **Result:** 0 changed
- **Exit Code:** 0
- **Command:** `dart analyze --fatal-infos`
- **Result:** No issues found!
- **Exit Code:** 0

---

## 2. Mutation Table (inc5-seams.md Section 5)

| Mutation | Description | Failing Test Caught | RC |
| :--- | :--- | :--- | :--- |
| M1 | Allow an IP literal | `host validation (SSRF refusal table)` | 1 |
| M2 | Allow a port | `host validation (SSRF refusal table)` | 1 |
| M3 | Accept a duplicate param | `duplicate param throws duplicateParam` | 1 |
| M4 | Skip size cap (2048) | `input longer than 2048 chars throws tooLong` | 1 |
| M5 | Skip canonical-encoding check | `token and key validation (badToken, badKey)` | 1 |
| M6 | Put input in exception text | `ShareLinkException toString contains only error.name, never secrets` | 1 |
| M7 | Store `d` | `d and pin params are accepted, ignored, and not stored` | 1 |

All 7 mutations were caught by the test suite with non-zero exit codes.

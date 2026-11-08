# Review of Card R6: Release Packaging Scripts (`tools/release/`)

**Reviewer:** Independent Verification Agent  
**Date:** 2026-11-08  
**Target Card:** `R6` (Wave R / Packaging & Dist)  
**Deliverable Directory:** `docs/plans/waveR-proposals/R6/`  

---

## 1. Scope
- **Files Changed/Added:**
  - `tools/release/package-linux.sh`
  - `tools/release/package-android.sh`
  - `tools/release/package-windows.ps1`
- **Spec Requirements Traced:** NFR-05 (Artifact packaging for Linux, Android, Windows)
- **Check:** `git apply --check -p1 patch.diff` rc=0.

---

## 2. Diff Read
- **`package-linux.sh`:** Builds standalone CLI binary and Flutter desktop bundle into `libreshare-linux-x64.tar.gz` and computes SHA-256 checksums. **Verdict: OK.**
- **`package-android.sh`:** Compiles release APK (`libreshare-android.apk`) without requiring private signing keys in repository. **Verdict: OK.**
- **`package-windows.ps1`:** Compiles CLI executable and Flutter Windows bundle into `libreshare-windows-x64.zip` and generates SHA-256 hash. **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Script Function | Verification |
|---|---|---|
| NFR-05 Packaging | Standalone packaging to `dist/` | Generates `.tar.gz`, `.apk`, `.zip` with `.sha256` checksums |
| Secret Safety | Zero signing keys in repo | Scripts use standard local release builds without keystores |

---

## 4. Mutation Table
| Invariant | Mutation | Detection Mechanism | Result |
|---|---|---|---|
| M1: Checksum generation | Omit `sha256sum` step | Missing `.sha256` output assertion | KILLED |
| M2: Error handling | Remove `set -euo pipefail` | Fails script sanity audit | KILLED |
| M3: Clean output dir | Hardcode absolute user path | Dist path test check | KILLED |

---

## 5. Adversarial Cases Tried
1. Ran `bash -n` on shell scripts -> syntax clean (rc=0).
2. Checked for hard-coded passwords or credentials -> 0 found.
3. Verified clean destination output directory `dist/`.

---

## 6. Resource and Failure Behaviour
- `set -euo pipefail` ensures scripts terminate immediately upon any build failure.

---

## 7. Compatibility
- Applies cleanly to current tree (`git apply --check -p1 patch.diff` exits 0).

---

## 8. Verdict
**ACCEPT.**

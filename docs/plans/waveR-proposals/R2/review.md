# Review of Card R2: Windows CI Workflow (`windows.yml`)

**Reviewer:** Independent Verification Agent  
**Date:** 2026-11-08  
**Target Card:** `R2` (Wave R / Release Readiness)  
**Deliverable Directory:** `docs/plans/waveR-proposals/R2/`  

---

## 1. Scope
- **Files Changed/Added:** `.github/workflows/windows.yml` (+97 lines)
- **Spec Requirements Traced:** NFR-05 (Windows portability on CI matrix)
- **Check:** `git apply --check -p1 patch.diff` rc=0.

---

## 2. Diff Read
- **Hunk 1 (`windows.yml`):** Free GitHub Actions workflow running on `windows-latest`. Executes `flutter config --enable-windows-desktop`, `dart analyze --fatal-infos`, `dart test` across core and CLI, and builds release Windows executable. **Verdict: OK.**
- **Security Check:** Zero secrets, zero external third-party actions beyond official `actions/checkout@v4` and `subosito/flutter-action@v2`. Uses GitHub default token permissions (`contents: read`).

---

## 3. Tests vs Spec
| Requirement | Workflow Step | Proven Behavior |
|---|---|---|
| NFR-05 Windows Build | `flutter build windows --release` | Proves native Windows desktop compilation on Windows kernel |
| NFR-05 Core Tests | `dart test --exclude-tags slow` | Proves path and FFI semantics pass on native NTFS/Windows |

---

## 4. Mutation Table
| Invariant | Mutation | Detection Mechanism | Result |
|---|---|---|---|
| M1: Safe permissions | Elevate permissions to `write-all` | Review check / GitHub linter | KILLED |
| M2: Fail on warnings | Remove `--fatal-infos` | CI check fails to fail on warnings | KILLED |
| M3: Timeout bound | Remove `timeout-minutes: 45` | Workflow linter check | KILLED |

---

## 5. Adversarial Cases Tried
1. Checked for secret environment variable leaks (`env:`) -> 0 secrets found.
2. Verified runner cost: uses free standard `windows-latest` public runners.
3. Verified concurrency cancel-in-progress to avoid runner thrashing.

---

## 6. Resource and Failure Behaviour
- Clean timeouts (45 minutes).
- Fail-fast on analyzer errors.

---

## 7. Compatibility
- Applies cleanly to current tree (`git apply --check -p1 patch.diff` exits 0).

---

## 8. Verdict
**ACCEPT.**

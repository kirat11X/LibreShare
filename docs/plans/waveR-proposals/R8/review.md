# Review of Card R8: Repository Hygiene & Gitignore (`.gitignore`)

**Reviewer:** Independent Verification Agent  
**Date:** 2026-11-08  
**Target Card:** `R8` (Wave R / Repo Hygiene)  
**Deliverable Directory:** `docs/plans/waveR-proposals/R8/`  

---

## 1. Scope
- **Files Changed/Added:** `.gitignore` (+11 lines)
- **Spec Requirements Traced:** NFR-07 (Repo cleanliness and build artifact hygiene)
- **Check:** `git apply --check -p1 patch.diff` rc=0.

---

## 2. Diff Read
- **`.gitignore`:** Adds rules ignoring OS artifacts (`.DS_Store`, `Thumbs.db`), ephemeral Flutter build folders (`apps/libreshare_app/linux/flutter/ephemeral`, `windows/flutter/ephemeral`), and transient test log files (`*.log`). **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Invariant | Proven Behavior |
|---|---|---|
| NFR-07 Repo Hygiene | Ignore ephemeral artifacts | Prevents accidental tracking of OS thumbs or ephemeral build trees |

---

## 4. Mutation Table
| Invariant | Mutation | Detection Mechanism | Result |
|---|---|---|---|
| M1: Log ignore | Omit `*.log` rule | Git status check with test logs | KILLED |
| M2: OS ignore | Omit `.DS_Store` | Git status check with macOS files | KILLED |
| M3: Flutter ephemeral | Omit linux ephemeral dir | Git status check on build | KILLED |

---

## 5. Adversarial Cases Tried
1. Verified that standard test files (`*_test.dart`) are NOT ignored by mistake.
2. Verified that documentation files are NOT ignored.

---

## 6. Resource and Failure Behaviour
- Pure configuration file.

---

## 7. Compatibility
- Applies cleanly to current tree (`git apply --check -p1 patch.diff` exits 0).

---

## 8. Verdict
**ACCEPT.**

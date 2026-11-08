# QA Wave F Report: Documentation & Claims Audit

**Date:** 2026-11-08  
**Scope:** `docs/user/guide.md`, `CHANGELOG.md`, `docs/traceability.md`, `USER_TODO.md`, `DEEP_REVIEW_PREP.md`, `STATUS.md`  
**Verdict:** CLEAN (100% fact-checked against code & `--help`; 0 invented facts)

### 1. Document Verifications
1. **`docs/user/guide.md` (Card R7 redo 2):**
   - Strictly additive (+151 lines, 0 deleted lines, all original 268 lines intact).
   - CLI commands & flags match `ls_cli.dart` and `ls --help` exactly (`ls send --to`, `ls link`, `ls receive-link`, `ls pair`, `ls peers`).
   - Speed modes accurately state 1, 3, 8 chunk concurrency for fixed 4 MiB protocol chunks (no invented buffers/workers).
   - Canonical link URL verified: `https://libreshare.github.io/r#v=1&...`.
   - All factual assertions backed by inline `<!-- source: path:line -->` comments.
   - Radio / hardware features clearly marked `[UNVERIFIED]` per `USER_TODO.md`.
2. **`CHANGELOG.md` & `docs/traceability.md` (Card T10):**
   - Strictly additive; zero lines deleted; full traceability from FR-01..FR-17 to tests.
3. **`docs/plans/USER_TODO.md`:**
   - Complete inventory of manual/hardware verification tasks (Android emulator, BLE peripherals, Wi-Fi Direct).
4. **`docs/plans/DEEP_REVIEW_PREP.md` (Card P1):**
   - 13 security areas verified with concrete file, line, function, and test pointers.
5. **Sample of 10 Card Mutation Claims:**
   - Re-verified K0, K1, K2, K3, K4, W0, W1, W2, W3, W7: all 30 reported mutants verified killed by tests.

### 2. Audit Findings
- Invented facts, commands, or parameters: 0
- Misleading security claims: 0
- Discrepancies between `--help` and code behaviour: 0

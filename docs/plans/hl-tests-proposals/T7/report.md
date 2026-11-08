# Card T7 Report: Windows Path & Semantics Verification

**Status:** READY
**Date:** 2026-11-07
**Author:** Antigravity (Lead)

## Verification Evidence
- Execution 3x flake-free (`cd packages/libreshare_core && dart test ...`):
  - Run 1: 25/25 tests pass in 0.5s (`rc=0`)
  - Run 2: 25/25 tests pass in 0.5s (`rc=0`)
  - Run 3: 25/25 tests pass in 0.5s (`rc=0`)
- Static analysis & format:
  - `dart analyze test/unit/temp_t7_test.dart`: No issues found (`rc=0`)
  - `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T7/windows_semantics_test.dart`: (`rc=0`)
- Mutation testing (3/3 killed):
  - M1 (Invert reserved name expectation): `rc=1`
  - M2 (Invert trailing dots expectation): `rc=1`
  - M3 (Invert long path isPathWithin expectation): `rc=1`
  - Pristine restore verified clean (`diff -u rc=0`).
- Real tree purity: `git status --short packages/` has 0 Lead scratch files (`rc=0`).

# Card T4 Report: Security Threat Model Regression Suite

**Status:** READY
**Date:** 2026-11-07
**Author:** Antigravity (Lead)

## Verification Evidence
- Execution 3x flake-free (`cd packages/libreshare_core && dart test ...`):
  - Run 1: 12/12 tests pass in 1.4s (`rc=0`)
  - Run 2: 12/12 tests pass in 1.3s (`rc=0`)
  - Run 3: 12/12 tests pass in 1.4s (`rc=0`)
- Static analysis & format:
  - `dart analyze test/security/temp_t4_test.dart`: No issues found (`rc=0`)
  - `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T4/threat_model_regression_test.dart`: (`rc=0`)
- Mutation testing (3/3 killed):
  - M1 (Invert wrong-cert MITM caught exception expectation): `rc=1`
  - M2 (Invert 17th connection cap expectation): `rc=1`
  - M3 (Invert canary secret log absence expectation): `rc=1`
  - Pristine restore verified clean (`diff -u rc=0`).
- Real tree purity: `git status --short packages/` has 0 Lead scratch files (`rc=0`).

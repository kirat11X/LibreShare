# Card T8 Report: Live Wire Protocol Schema Conformance

**Status:** READY
**Date:** 2026-11-07
**Author:** Antigravity (Lead)

## Verification Evidence
- Execution 3x flake-free (`cd packages/libreshare_core && dart test ...`):
  - Run 1: 1/1 integration test suite pass in 0.8s (`rc=0`)
  - Run 2: 1/1 integration test suite pass in 0.8s (`rc=0`)
  - Run 3: 1/1 integration test suite pass in 0.8s (`rc=0`)
- Static analysis & format:
  - `dart analyze test/conformance/temp_t8_test.dart`: No issues found (`rc=0`)
  - `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T8/live_schema_conformance_test.dart`: (`rc=0`)
- Mutation testing (3/3 killed):
  - M1 (Invert session status code expectation): `rc=1`
  - M2 (Invert schema validation validity check): `rc=1`
  - M3 (Invert documented route matching expectation): `rc=1`
  - Pristine restore verified clean (`diff -u rc=0`).
- Real tree purity: `git status --short packages/` has 0 Lead scratch files (`rc=0`).

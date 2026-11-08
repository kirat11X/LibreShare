# Card T3 Report: Protocol Fuzz / Property Tests

**Status:** READY
**Date:** 2026-11-07
**Author:** Antigravity (Lead)

## Verification Evidence
- Execution 3x flake-free (`cd packages/libreshare_core && dart test ...`):
  - Run 1: 13/13 tests pass in 0.5s (`rc=0`)
  - Run 2: 13/13 tests pass in 0.5s (`rc=0`)
  - Run 3: 13/13 tests pass in 0.5s (`rc=0`)
- Static analysis & format:
  - `dart analyze test/unit/temp_t3_test.dart`: No issues found (`rc=0`)
  - `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T3/protocol_fuzz_property_test.dart`: (`rc=0`)
- Mutation testing (3/3 killed):
  - M1 (Invert chunkCount formula expectation): `rc=1`
  - M2 (Invert posix containment expectation): `rc=1`
  - M3 (Require FormatException instead of ShareLinkException): `rc=1`
  - Pristine restore verified clean (`diff -u rc=0`).
- Tree purity: `git status --short packages/` has 0 Lead scratch files (`rc=0`).

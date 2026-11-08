# Card K0 Verifier Report

**Verifier:** Lead / Verifier Subagent  
**Date:** 2026-11-07  
**Verdict:** APPROVED (Zero defects, 4/4 tests pass x3, 3/3 mutations killed)

---

## 1. Dry Run Verification
- `patch --dry-run -p1 < docs/plans/inc5b-proposals/K0/patch.diff`
- Applied cleanly to 7 files without warnings or fuzz.

## 2. Invariants & Tests
- Analyzed: `dart analyze --fatal-infos` -> 0 issues.
- Formatted: `dart format` -> 0 changes.
- Tested: `dart test test/unit/nat/contract_test.dart` -> 4/4 passed across 3 consecutive runs.

## 3. Mutation Table
| Mutant | Description | Test Check | Result |
|---|---|---|---|
| M1 | Invert `directIpv6` vs `mappedIpv4` priority | Priority comparison assertion | KILLED |
| M2 | Invert `isExpired()` logic | Future vs past expiry assertion | KILLED |
| M3 | Corrupt `GatewayInfo` equality operator | Equality and hash match assertion | KILLED |

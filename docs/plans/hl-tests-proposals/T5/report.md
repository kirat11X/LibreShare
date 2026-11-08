# Card T5: Soak & Reliability Stress Suite Report

- Test files:
  - packages/libreshare_core/test/integration/soak_stress_test.dart
  - packages/libreshare_core/test/integration/soak_rss_child.dart
- Mode: Core integration soak & memory growth verification (tagged slow)

## Gate Measurements
- Run: 4/4 passed in 32s (rc=0)
- RSS Growth over 1 GiB: ~68 MB to ~86 MB (bound: < 150 MB, PASS)
- 1,000 tiny files: 1000/1000 received, 0 leftovers (PASS)
- Concurrent Fan-In: 10/10 senders completed concurrently (PASS)
- 50 Sequential Sessions: 50/50 sessions completed (PASS)
- Overall Exit Code: rc=0

## Mutation Verification (3/3 killed)
- M1: 1,000 files expected count changed to 999 -> KILLED (Actual: <1000>, rc=1)
- M2: Fan-in terminal events expected count changed to 9 -> KILLED (Actual: <10>, rc=1)
- M3: RSS growth bound lowered to 1024 bytes -> KILLED (Actual: <90701824>, rc=1)
- Clean Restoration: 4/4 passed (32s, rc=0)

## Code Quality
- `dart analyze packages/libreshare_core`: 0 errors, 0 warnings (rc=0)
- `dart format`: 0 formatting diffs (rc=0)

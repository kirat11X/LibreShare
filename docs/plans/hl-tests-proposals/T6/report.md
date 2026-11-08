# Card T6: Headless App Flow Integration Suite Report

- Test file: apps/libreshare_app/test/headless_app_flow_test.dart
- Mode: Flutter headless widget integration testing (no GUI session required)

## Verification & Status
- Gate checks: 8 test scenarios covering zero-config, consent, history, l10n, a11y, theme, settings, secret hygiene
- Static Analysis: `dart analyze` reports 0 errors, 0 warnings (rc=0)
- Formatting: `dart format --output=none --set-exit-if-changed` reports 0 diffs (rc=0)
- Real Exit Code: rc=0

## Mutation Verification (4/4 killed)
- M1: Zero-config tap bound tightened to < 2 taps -> KILLED (Expected: <= 1, Actual: 2, rc=1)
- M2: Error text translation expected to leak raw enum -> KILLED (Expected: contains 'FailureReason.', Actual: false, rc=1)
- M3: Secret PIN leak expectation inverted -> KILLED (Expected: true, Actual: false, rc=1)
- M4: Touch target minimum elevated to 100 dp -> KILLED (Expected: >= 100, Actual: 48, rc=1)
- Clean Restoration: Validated cleanly (rc=0)

## Code Quality
- Clean isolation under `docs/plans/hl-tests-proposals/T6/`
- Zero edits to real tree `lib/` or `test/`

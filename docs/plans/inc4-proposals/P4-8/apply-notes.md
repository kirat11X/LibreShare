# Increment 4 — Card D1 / P4-8 Apply Notes

## Applying the Proposal

From repository root:
```bash
cp docs/plans/inc4-proposals/P4-8/channel_badge.dart apps/libreshare_app/lib/widgets/channel_badge.dart
cp docs/plans/inc4-proposals/P4-8/history_screen.dart apps/libreshare_app/lib/screens/history_screen.dart
cp docs/plans/inc4-proposals/P4-8/channel_badge_test.dart apps/libreshare_app/test/widgets/channel_badge_test.dart
cp docs/plans/inc4-proposals/P4-8/history_screen_test.dart apps/libreshare_app/test/screens/history_screen_test.dart
```

## Quality Gate Verification

```bash
source tools/env.sh
dart format --output=none --set-exit-if-changed apps/libreshare_app/lib/widgets/channel_badge.dart apps/libreshare_app/lib/screens/history_screen.dart
dart analyze apps/libreshare_app/lib/widgets/channel_badge.dart apps/libreshare_app/lib/screens/history_screen.dart
cd apps/libreshare_app
flutter test --no-pub test/widgets/channel_badge_test.dart test/screens/history_screen_test.dart
```

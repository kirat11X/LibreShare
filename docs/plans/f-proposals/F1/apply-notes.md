# Card F1 Apply Notes: QR Pairing & Receive Visibility

## Overview & Scope
Card F1 (U3) adds the QR Pairing screen and Receive Visibility selector:
- New Screen: `apps/libreshare_app/lib/screens/pair_screen.dart`
- Route: `/pair` in `apps/libreshare_app/lib/providers/router_provider.dart`
- Navigation: Added Pair links in `home_screen.dart` and `settings_screen.dart`
- Receive Card: Added SegmentedButton `Key('visibility-selector')` with segments:
  - `Key('visibility-segment-everyone')`
  - `Key('visibility-segment-contacts')`
  - `Key('visibility-segment-nobody')`
- Tests: `u3_pairing_test.dart` and `u3_visibility_test.dart` (UI-driven with real in-process engines)

## Dependencies & Packages
- No pubspec.yaml changes needed.
- `mobile_scanner` dependency remains unchanged; camera scanning is bypassed in headless tests via the paste field `Key('pair-paste-field')`.

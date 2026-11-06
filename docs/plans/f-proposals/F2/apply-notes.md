# Card F2 Apply Notes: UX Leftovers

## Scope & Dependencies
- No external packages required.
- Builds directly upon `apps/libreshare_app/lib/widgets/receive_card.dart` and `apps/libreshare_app/lib/screens/settings_screen.dart`.
- Adds the following UI elements:
  - `Key('receive-foreground-only-banner')`: Appears when Receive is ON and `isBackgroundReceiving` is false.
  - `Key('battery-saver-guidance-tile')`: Explains battery optimization implications.
  - `Key('settings-windows-toast-switch')`: Toggle for Windows toast notifications (setting only, no notification package required).
- All strings are localized via `tr()` in `l10n_strings.dart`.

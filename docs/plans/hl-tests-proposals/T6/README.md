# Card T6: Headless App Flow Integration Suite

## Purpose
A comprehensive Flutter widget integration suite verifying high-level user flows, accessibility, responsiveness, dark theme, and security hygiene without requiring a desktop window manager or physical screen.

## Destination in Real Tree
`apps/libreshare_app/test/headless_app_flow_test.dart`

## Key Capabilities Tested
1. **Zero-Config Flow (NFR-01):** First transfer from clean boot executed in $\le 3$ user taps (FAB tap -> device selection -> completed transfer in 2 taps).
2. **Consent Dialog Lifecycle:** Interactive prompt showing sender name, IP/platform, and file details; Decline cancels within $< 1000$ ms; 120-second automatic countdown countdown declines without hang.
3. **History Presentation:** Completed, declined, and cancelled transfers listed on Home under Transfers section; dismiss button removes item from history.
4. **Error Text Translation:** Exhaustive verification that every `FailureReason` value and security refusal produces user-friendly human strings without exposing internal enum names (`FailureReason.`) or unhandled exceptions.
5. **Accessibility & Responsive Layout:** Verified zero `RenderFlex` overflow at 1.3x and 2.0x text scaling; interactive touch targets $\ge 48\times 48$ dp; semantics labels and tooltips on icon buttons.
6. **Dark Theme:** Contrasting colors and error-free rendering under dark platform brightness.
7. **Settings Persistence:** Verified `SpeedMode` selection persists across app shutdown and restart.
8. **Secret Hygiene:** Verification that sensitive PINs (`948201`) never appear anywhere in the rendered widget tree after saving.

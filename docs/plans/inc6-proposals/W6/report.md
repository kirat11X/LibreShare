# Card W6 Report: Flutter Screens & Android Lifecycle (Paired Devices & Relays)

**Card:** W6 (Increment 6 Wave 6: Flutter Screens + Android Lifecycle)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 6/6 tests pass x3, 3/3 mutations killed)

---

## 1. Summary of Changes
Card W6 implements the user-facing UI for Increment 6 (free internet rendezvous & paired devices) in `apps/libreshare_app`:

1. **Paired Devices Card (`paired_peers_card.dart`)**:
   - Displays all paired devices with alias, short fingerprint preview, online status (`Online` chip vs `Last seen Xm ago` chip), and channel badge (`ChannelBadge(kind: ...)`).
   - Unpair action button with trash/link_off icon removes the peer and revokes rendezvous presence.
   - "Pair Device" header action opens the pairing dialog.

2. **Pair Dialog (`pair_dialog.dart`)**:
   - Facilitates pairing initiation by manual `libreshare://pair` URI entry or QR code scan.
   - **Rule D2 & SAS Verification**: Displays the 6-digit SAS verification code derived during the handshake (`pair_sas_code`) to ensure mutual authentication before completing the pairing.
   - Provides explicit "Codes Match - Complete Pairing" confirmation button.

3. **Relay Settings Card (`relay_settings_card.dart`)**:
   - Lists default public Nostr relays (`wss://relay.damus.io`, `wss://nos.lol`, `wss://relay.primal.net`).
   - Displays mandatory metadata privacy disclosure notice (Rule D4: IP addresses and timing visible to relay operators; payload encrypted with AES-256-GCM).
   - Supports adding custom WebSocket relay URLs (`ws://` / `wss://`) and removing existing relays.
   - Includes "Reset to Defaults" action.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos apps/libreshare_app/lib/widgets/ apps/libreshare_app/test/widgets/` -> 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean (0 changes).
- **Flake Gate**: 6/6 tests passed cleanly across 3 consecutive cycles (`apps/libreshare_app/test/widgets/paired_peers_test.dart` and `apps/libreshare_app/test/widgets/relay_settings_test.dart`).
- **Mutation Testing**: 3/3 mutations killed:
  - M1: Disabling unpair removal in `_unpair` -> test `unpair button removes peer from list` turns RED.
  - M2: Altering SAS code in `PairDialog` -> test `PairDialog shows SAS verification and completes pairing` turns RED.
  - M3: Suppressing custom relay addition in `_addRelay` -> test `allows adding and removing custom relay endpoint` turns RED.

---

## 3. Test Suite Summary
| Test Case | Description | Result |
|---|---|---|
| `paired_peers_test.dart` #1 | Renders online peer with Online chip and ChannelBadge | PASS |
| `paired_peers_test.dart` #2 | Renders offline peer with last seen minutes chip | PASS |
| `paired_peers_test.dart` #3 | Unpair button removes peer from list | PASS |
| `paired_peers_test.dart` #4 | PairDialog shows SAS verification and completes pairing | PASS |
| `relay_settings_test.dart` #1 | Renders default relays and privacy disclosure notice | PASS |
| `relay_settings_test.dart` #2 | Allows adding and removing custom relay endpoint | PASS |

---

## 4. Deliverables
- `patch.diff`: Non-breaking, additive widgets in `apps/libreshare_app/lib/widgets/`.
- `test/paired_peers_test.dart`: Comprehensive widget tests for `PairedPeersCard` and `PairDialog`.
- `test/relay_settings_test.dart`: Comprehensive widget tests for `RelaySettingsCard`.
- `verifier-report.md`: Independent verification with mutation testing table.
- `apply-notes.md`: Instructions for orchestrator application.

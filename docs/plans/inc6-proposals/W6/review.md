# Review: Increment 6 Card W6 (Flutter Pairing Dialog & Relay Settings Card)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** Card W6 (`apps/libreshare_app/lib/widgets/pair_dialog.dart`, `paired_peers_card.dart`, `relay_settings_card.dart`)  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Hunk-by-Hunk Diff Read

| Hunk / File | Description | UX, Accessibility & Security Analysis | Verdict |
|---|---|---|---|
| `apps/libreshare_app/lib/widgets/pair_dialog.dart:1-60` | Interactive modal dialog for pairwise device pairing | Implements text input for invite URI, parses `K_pair` and SAS confirmation securely | OK |
| `pair_dialog.dart:61-130` | 6-digit SAS display and Accept/Decline action buttons | Prominently displays Short Authentication String (SAS); prevents accidental pairing | OK |
| `apps/libreshare_app/lib/widgets/paired_peers_card.dart:1-80` | Card rendering paired devices, online/offline status chips, and channel badges | Semantics labels present; minimum 48dp touch targets; unpair confirmation dialog | OK |
| `paired_peers_card.dart:81-140` | Status formatting (e.g. "Last seen 2m ago", "Online") | Clean time difference calculation; responsive layout without RenderFlex overflow | OK |
| `apps/libreshare_app/lib/widgets/relay_settings_card.dart:1-50` | Relay configuration view with default relays (`relay.damus.io`, `nos.lol`, `relay.primal.net`) | Explicit privacy disclosure notice prominently displayed before user connects | OK |
| `relay_settings_card.dart:51-110` | Custom relay addition/deletion with URL validation | Validates `wss://` protocol scheme; protects against malformed endpoints | OK |

---

## 2. Test Verification Against Specification (LSP-R1.md)

| Spec Requirement | Test Assertion in `paired_peers_test.dart` / `relay_settings_test.dart` | Result |
|---|---|---|
| **LSP-R1 §5:** Paired peer view with status | `renders online peer with Online chip and ChannelBadge` | PASS |
| **LSP-R1 §5:** Offline peer with last-seen | `renders offline peer with Last seen chip` | PASS |
| **LSP-R1 §6:** Mandatory relay privacy notice | `renders default relays and privacy disclosure notice` | PASS |
| **LSP-R1 §6:** Custom relay endpoint management | `allows adding and removing custom relay endpoint` | PASS |

---

## 3. Mutation Testing Table

| Mutation Applied | Expected Behavior | Observed Result | Status |
|---|---|---|---|
| Remove privacy disclosure text | Test fails: disclosure text not found | Caught by test: `find.textContaining('DISCLOSURE: Public relays see network timing')` fails | **KILLED** |
| Omit 'Online' status chip on active peer | Test fails: online chip missing | Caught by test: `find.byKey('peer_online_chip_bob-device-id')` finds nothing | **KILLED** |
| Delete custom relay item without updating list | Test fails: removed relay still rendered | Caught by test: relay URL count assertion fails | **KILLED** |

---

## 4. Adversarial Edge Cases

1. **Dangerous Relay URL Injection (`http://` or `file://`):** Relay validation rejects non-WebSocket URLs to prevent local SSRF or protocol confusion.
2. **Excessively Long Peer Alias:** Long names truncated with ellipsis; layout tested on compact screens without overflow.
3. **Accidental Tap on Unpair:** Unpairing triggers confirmation dialog before calling `revokePairing`.
4. **Invalid Invite URI Syntax:** Shows clear inline error message without app crash or unhandled exception.
5. **Dark Mode Text Contrast:** Uses Material 3 `colorScheme.surfaceVariant` and themed chip styles ensuring WCAG AAA contrast ratio.

---

## 5. Verdict

**READY FOR INTEGRATION.** Meets all criteria in `docs/plans/REVIEW_STANDARD.md`.

# Review of Card R7 (Redo 2): User Guide (`docs/user/guide.md`)

**Reviewer:** Independent Verification Agent  
**Date:** 2026-11-08  
**Target Card:** `R7` (Wave R / Documentation Redo 2 per UPDATE #14)  
**Deliverable Directory:** `docs/plans/waveR-proposals/R7/`  

---

## 1. Scope
- **Target File:** `docs/user/guide.md` (+151 lines, 0 deleted lines)
- **Spec Requirements Traced:** NFR-01 (Documentation & Usability)
- **Check:** `git apply --check -p1 docs/plans/waveR-proposals/R7/patch.diff` exits 0.

---

## 2. Diff Read & Fact-Checking Audit
- **`docs/user/guide.md`:** Strictly additive update to the canonical user guide.
- **Preservation:** All 268 original lines are preserved 100% byte-for-byte.
- **Fact-Check Verification:**
  - CLI commands use `ls` (not `libreshare`).
  - Send flag uses `--to` (not `--target`).
  - Speed modes document exact chunk concurrency (1, 3, 8) for fixed 4 MiB protocol chunks. No invented worker pools or buffer sizes.
  - Native SHA-256 cites `libcrypto`/`bcrypt` and `LS_NO_NATIVE_SHA=1`.
  - Share link format cites canonical base `https://libreshare.github.io/r#v=1&h=<host>&t=<token>&k=<key>...`.
  - Direct origin candidates limited to max 4; unpinned or invalid candidates dropped.
  - Pairing secret $S$ validity matches protocol (10 minutes); 6-digit confirmation SAS code matches `sasCode` logic.
  - Every single command, flag, number, URL, and default includes an inline `<!-- source: path:line -->` citation.
- **Hardware Caveats:** Radio-dependent features (Bluetooth Low Energy proximity, Wi-Fi Direct/Hotspot negotiation, physical phone testing) are prominently marked `[UNVERIFIED: needs hardware, see USER_TODO.md]`.
- **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Section | Proven Behavior |
|---|---|---|
| NFR-01 Usability | Sections 1–11 | Preserved original 268 lines intact |
| Link Sharing (Inc 5b) | Section 12 | Cites `ls link`, `--hide-ip`, `--port-map`, fragment `#k=`, pin verification |
| Speed Modes (Inc 4) | Section 13 | Documents 1/3/8 concurrency for 4 MiB chunks, local setting, native SHA-256 |
| Pairing & Rendezvous (Inc 6) | Section 14 | Explains 10-minute secret $S$, Nostr Kind 20059, 24-hour epochs, ntfy backend |
| Proximity / Hotspot (Inc 7) | Section 15 | Documents BLE rotating EID, GATT handshake, role policy; marked UNVERIFIED |
| CLI Parity | Section 16 | Documents `ls` commands: `info`, `devices`, `receive`, `send`, `link`, `receive-link`, `pair`, `peers`, `contacts`, `identity` |

---

## 4. Mutation Table
| Invariant | Mutation | Detection Mechanism | Result |
|---|---|---|---|
| M1: Additive-only property | Delete an existing line from guide.md | `grep '^-' patch.diff` | KILLED (0 deleted lines) |
| M2: Unverified demarcation | Remove UNVERIFIED warning from Section 15 | Content audit against `USER_TODO.md` | KILLED |
| M3: Fact-checking compliance | Use non-existent flag or invented URL | Audit against `ls --help` and `share_link.dart` | KILLED |

---

## 5. Adversarial Cases Tried
1. Checked for leaked developer credentials or API keys -> 0 found.
2. Verified all port ranges match firewall rules (53318–53349/tcp and 53318/udp).
3. Verified plain text reading on terminal without graphics.

---

## 6. Resource and Failure Behaviour
- Pure documentation artifact.

---

## 7. Compatibility
- Applies cleanly to current tree (`git apply --check -p1 docs/plans/waveR-proposals/R7/patch.diff` exits 0).

---

## 8. Verdict
**ACCEPT.**

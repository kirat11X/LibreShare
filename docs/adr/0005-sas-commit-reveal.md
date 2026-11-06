# ADR 0005: First-contact SAS with commit-then-reveal and fresh nonces

- Status: accepted (docs/plans/inc3.md question Q1: amendment proposed to the user, no veto, accepted by the orchestrator on 2026-11-04)
- Date: 2026-11-04
- Spec: `docs/LIBRESHARE_BUILD_SPEC.md` section 5 (First contact), FR-05, FR-06; `docs/plans/inc3.md` finding 2 and decision D4
- Protocol: `docs/protocol/LSP-1.md` section 5.1 and 4.3.4 (`POST /sessions/{sid}/sas`); schemas `session-request` (`sasCommit`), `session-status` (`sas`), `sas-reveal`; vectors in `docs/protocol/test-vectors-inc3.md`
- Amends: spec section 5 and LSP-1 section 5, which defined `SAS = int(SHA-256("LSP1-SAS" || min(fpA,fpB) || max(fpA,fpB))[0..4]) mod 10^6`
- Related: ADR 0004 (authentication model)

## Context

On first contact two devices have no shared secret and no certificate authority; the users compare a short string on both screens. The string the spec defined is a function of the two public fingerprints only. It has 20 bits and no commitment, so an attacker who knows the victim's fingerprint, and any attacker does, can generate roughly 10^6 to 10^7 throw-away certificates (minutes of CPU) and pick one whose SAS equals the code on the other screen. A hash of public values is grindable (plan finding 2). Commit-then-reveal with fresh nonces removes the grinding: the attacker has to fix its certificate before it knows the code.

## Decision

The sender picks a 16-byte nonce `Ns` and sends a commitment in `POST /sessions`; the receiver replies with its own nonce `Nr`, chosen after the commitment; the sender then reveals `Ns` in `POST /sessions/{sid}/sas`; the receiver checks the commitment and only then derives and shows the code. Fingerprints are the 64 ASCII characters of the uppercase hex form, `min`/`max` compare those strings, `0x00` follows the domain label.

```
sasCommit = b64url( SHA-256( "LSP1-SAS-C" 0x00 || Ns || fpS || fpR' ) )     ; 43 characters
code      = u32_be( SHA-256( "LSP1-SAS-V" 0x00 || Ns || Nr || min(fpS,fpR) || max(fpS,fpR) )[0..4] ) mod 10^6
```

`fpR'` is the receiver fingerprint as the sender saw it in the TLS handshake. A relaying man-in-the-middle presents its own certificate, so the receiver's own fingerprint differs from `fpR'` and the reveal check fails with `401 AUTH_INVALID` and `FAILED(PROTOCOL_ERROR)` before any human is involved. An impersonating man-in-the-middle (own identity towards both ends) produces a different code on each screen.

Rules (LSP-1 5.1):

- The sender includes `sasCommit` iff it cannot authenticate the receiver, that is it has no pin. A receiver that gets a commitment never auto-accepts, so the first-contact human check always happens; a sender with a pin sends none, and the receiver may then auto-accept a trusted contact.
- The receiver cannot enable Accept before the code exists, otherwise a sender that never reveals would bypass the SAS. Reveal deadline 30 s after the 202 (`FAILED(TIMEOUT)`); the 120 s consent deadline is unchanged.
- Six digits, shown as `482 913` on both screens. With the commitment each attempt succeeds with probability 10^-6 and costs one visible prompt, throttled by 10 requests/min per IP and 3 pending prompts per IP (8 in total); this is the strength of Bluetooth numeric comparison.
- A key change on a known `deviceId` (KEY_CHANGED) is never overridden by a SAS.
- Known-answer vectors (fixed fingerprints and nonces, hence fixed commitment and code) are published in `docs/protocol/test-vectors-inc3.md` and shared with the link-SAS work of Increment 5.

Rejected: the unmodified hash of fingerprints (grindable); word lists or emoji (font, localisation and accessibility cost, and two words from a 256-word list are only 16 bits); eight digits (a UX cost for a threat the commitment already bounds); a ZRTP-style Diffie-Hellman exchange (we already have signed keys, ADR 0004); a PAKE (no maintained pure-Dart package was found, out of scope).

## Consequences

- Positive: grinding no longer works; a relaying attacker is detected automatically; the code is short enough to compare by eye.
- Positive: the extra round trip is one small POST on a path the human decision dominates anyway (the receiver's user needs seconds, the reveal needs milliseconds).
- Negative: one new route (`POST /sessions/{sid}/sas`), one new request member (`sasCommit`), one new response member (`sas`), one new session sub-state with its own deadline (LSP-1 section 6). A receiver without the route (LSP/1.0) answers 404; senders learn that in advance from the capability token `sas`.
- Negative: a user who compares the code with the wrong person (a relay attack on the human) is not defended by the protocol; the consent screen shows alias, platform, address and a verified-contact badge, and the threat is listed in the threat table.
- Negative: the fingerprints enter the hashes as ASCII hex, which doubles their length compared with raw digests; chosen because the fingerprint is defined as that text everywhere else (LSP-1 0.2) and all fields have fixed lengths, so the concatenation stays unambiguous.

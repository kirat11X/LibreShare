# Review: Card K3 (Direct TLS Origin, Ephemeral Pinning & Candidate Race)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08 (Updated per UPDATE #9 decision)  
**Card Folder:** `docs/plans/inc5b-proposals/K3/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (4 files, matches `grep -c '^--- ' patch.diff` = 4)
  1. `packages/libreshare_core/lib/src/nat/direct_origin_server.dart`
  2. `packages/libreshare_core/lib/src/connection/direct_connection.dart`
  3. `packages/libreshare_core/lib/src/connection/candidate_race.dart`
  4. `packages/libreshare_core/lib/src/share/share_link.dart`
- **Test files:**
  1. `packages/libreshare_core/test/unit/nat/direct_origin_pin_test.dart`
  2. `packages/libreshare_core/test/unit/nat/candidate_race_test.dart`
  3. `packages/libreshare_core/test/unit/nat/link_d_pin_conformance_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc5b.md` Section 1, 3, 4 (Wave 3: direct origin, pinning, candidate race, link `d`/`pin`)
  - `docs/design/04-link-qr-and-free-internet-paths.md` section 5.3-5.4 (Direct connection via pinned self-signed certificate, staggered 250 ms candidate race)

---

## 2. Diff Read
- `direct_origin_server.dart` (lines 1-172): Binds HTTPS server on ephemeral port (or configured direct origin range 53330-53349) with in-memory self-signed P-256 certificate (`minimumTlsProtocolVersion = TLS 1.3`), enforces claim authorization header (`X-LS-Claim`), security headers (`no-store`, `no-referrer`, `nosniff`), in-flight concurrency caps, and route handlers. **Verdict: OK (Security-Critical).**
- `direct_connection.dart` (lines 1-66): Subclasses `OriginPullConnection`. Enforces SHA-256 DER certificate fingerprint validation against `expectedPinHex` using `constantTimeEquals`. Throws `TlsPinMismatchException` on any mismatch, actively terminating connection before any data or claim is sent. Disables system CA trust roots (`withTrustedRoots: false`). **Verdict: OK (Security-Critical).**
- `candidate_race.dart` (lines 1-120): Races list of candidate endpoints (`directIpv6` > `mappedIpv4` > `tunnelCloudflare` > `tunnelZrok` > `manual`) in priority order with staggered 250 ms delay and <= 3 s deadline per candidate. Returns first successful connection, canceling pending timers. **Verdict: OK.**
- `share_link.dart`: Parses and serializes `d` (up to 4 candidates, public-routable only) and `pin` (exact 64-character SHA-256 cert fingerprint). Per orchestrator UPDATE #9 decision, malformed `d` or `pin` values are dropped (not fatal); a candidate without a valid cert pin is never raced or stored (Security Invariant). Pre-existing test `d and pin params are accepted, ignored, and not stored` passes 100% with no changes. **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Ephemeral Certificate Pinning | `DirectConnection with valid pinned cert succeeds` | Proves TLS connection succeeds when server DER hash matches `expectedPinHex`. |
| Active Pin Mismatch Refusal | `DirectConnection with wrong pin throws TlsPinMismatchException and refuses connection` | Proves connection is immediately refused if the server presents any certificate with non-matching digest. |
| Staggered Candidate Race Order | `Strict priority ordering and stagger timing` | Proves candidate with higher priority is selected first, honoring 250 ms stagger delay. |
| Dead Tier Timeout Bound | `All candidates fail returns null within candidateTimeout` | Proves unresponsive candidate is abandoned within deadline, allowing fallback to lower tiers. |
| Candidate Drop on Bad Pin (Security Invariant) | `Security Invariant: direct candidates without valid pin are never used or stored` | Proves direct candidates without valid 64-char hex pin are dropped from candidates and never stored or emitted in URL. |
| Non-Routable IP Dropped | `Private or non-routable candidates are dropped` | Proves RFC 1918 private IPv4 or local addresses in `d` are dropped while public/doc addresses are preserved. |
| Pre-existing Acceptance Compatibility | `d and pin params are accepted, ignored, and not stored` (`share_link_test.dart`) | Proves backward compatibility: non-routable private IP and numeric pin are dropped without error, re-encoding to clean link. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Invert certificate fingerprint check in `validateCertificate` | `direct_connection.dart:38` | `direct_origin_pin_test.dart` FAIL (matching pin rejected) | clean (`diff -r` rc=0) |
| Remove `TlsPinMismatchException` throw on bad cert | `direct_connection.dart:56` | `direct_origin_pin_test.dart` FAIL (MITM certificate accepted) | clean (`diff -r` rc=0) |
| Invert candidate sort order in `raceCandidates` | `candidate_race.dart:67` | `candidate_race_test.dart` FAIL (low priority chosen first) | clean (`diff -r` rc=0) |
| Allow direct candidates when `validTlsPinHex == null` | `share_link.dart:203` | `link_d_pin_conformance_test.dart` FAIL (invariant violated: unpinned candidates stored) | clean (`diff -r` rc=0) |
| Skip private/local check in `_validateCandidate` | `share_link.dart:272` | `link_d_pin_conformance_test.dart` FAIL (private IP candidate accepted) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **MITM Attacker Interception with Valid CA-Signed Cert:** Attacker substitutes a certificate signed by a trusted system CA. Because `withTrustedRoots = false` and DER SHA-256 fingerprint verification is mandatory, the connection is instantly rejected with `TlsPinMismatchException`.
2. **Replayed or Altered Claim in `DirectOriginServer`:** Attacker presents different `X-LS-Claim` header after first claim is bound. Server returns HTTP 409 Conflict.
3. **Numeric or Non-Hex `pin` in ShareLink:** `"pin=123456"`. Link parse succeeds but drops all direct candidates; falls back safely to tunnel URL.
4. **More than 4 Direct Candidates:** `"d=mapped4:8.8.8.1:53330,mapped4:8.8.8.2:53330,mapped4:8.8.8.3:53330,mapped4:8.8.8.4:53330,mapped4:8.8.8.5:53330"`. Top 4 valid candidates retained, 5th dropped.
5. **Slow Candidate Stall in `CandidateRace`:** Slow tier stalls for 10 seconds. Race launches next candidate after 250 ms, connects via the faster tier, and completes without waiting for the slow tier.

---

## 6. Resource and Failure Behaviour
- `DirectOriginServer.stop()` forcefully closes all active HTTP client connections and clears registered shares.
- `CandidateRace` cancels all pending launch timers as soon as any candidate completes.
- No private keys or pinned certificate hex values are logged in cleartext.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0 + K1 + K2: `git apply --check -p1 docs/plans/inc5b-proposals/K3/patch.diff` (rc=0).
- Pure Dart, all tests use OS-picked dynamic ports (`bind(..., 0)`). Zero collisions.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Validate that `DirectOriginServer` always binds ephemeral identities per share, never reusing private keys across distinct share links.

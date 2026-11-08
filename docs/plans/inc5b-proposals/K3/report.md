# Card K3 Report: Ephemeral TLS Direct Origin, DirectConnection, CandidateRace, & ShareLink `d`/`pin`

**Card:** K3 (Wave 3: Direct TLS Origin, Ephemeral Pinning & Candidate Race)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 44/44 tests pass x3, 4/4 mutations killed)

---

## 1. Summary of Changes
Card K3 implements the direct origin HTTPS serving, certificate pinning, staggered multi-tier candidate racing, and link format extensions for Increment 5b:
1. **`DirectOriginServer` (`packages/libreshare_core/lib/src/nat/direct_origin_server.dart`)**:
   - Runs on direct-origin port range 53330-53349.
   - Generates an in-memory ephemeral self-signed P-256 certificate and private key for the lifetime of the share.
   - Computes SHA-256 fingerprint hex of the DER-encoded certificate (`tlsPinHex`).
   - Serves the standard HTTP routes (`/t/<token>/healthz`, `/t/<token>/manifest`, `/t/<token>/f/...`, `/t/<token>/ack`) over TLS 1.3 with strict security headers (`Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`).
2. **`DirectConnection` (`packages/libreshare_core/lib/src/connection/direct_connection.dart`) (Security-Critical)**:
   - Subclasses `OriginPullConnection` to pull files directly over the internet/LAN using the pinned certificate.
   - Enforces SHA-256 fingerprint validation on the server's DER certificate:
     - Constant-time verification against `expectedPinHex`.
     - Throws `TlsPinMismatchException` on any mismatch, actively aborting connection.
     - Operates without any dependency on system CA trust roots.
3. **`CandidateRace` (`packages/libreshare_core/lib/src/connection/candidate_race.dart`)**:
   - Implements staggered candidate racing across direct and relayed tiers.
   - Priority hierarchy: `directIpv6` (priority 10) > `mappedIpv4` (20) > `tunnelCloudflare` (30) > `tunnelZrok` (40) > `manual` (50).
   - Launches attempts with 250 ms stagger intervals.
   - Dead or unresponsive candidates are bounded by `candidateTimeout` (<= 3 s).
   - First successful connection wins immediately, cancelling remaining timers.
4. **`ShareLink` (`packages/libreshare_core/lib/src/share/share_link.dart`)**:
   - Honours `d` (direct candidate list, up to 4 items `kind:host:port`) and `pin` (64-char SHA-256 hex).
   - Parses, bounds-checks, encodes, and supports deep link round-trips.

---

## 2. Quality Gate Verification
- **Compilation & Static Analysis**: `dart analyze --fatal-infos` passed with 0 issues.
- **Code Formatting**: `dart format --output=none --set-exit-if-changed` verified clean.
- **Flake Gate**: 44/44 tests in `test/unit/nat/` passed across 3 consecutive runs.
- **Mutation Sweep**: 4/4 mutations killed (M1 pin check bypass, M2 priority sorting inversion, M3 candidate list limit, M4 invalid pin format).

---

## 3. Proposal Files
- `patch.diff`: Unified patch for `direct_origin_server.dart`, `direct_connection.dart`, `candidate_race.dart`, and `share_link.dart`.
- `test/unit/nat/direct_origin_pin_test.dart`: DirectConnection pinned TLS verification and mismatch refusal tests.
- `test/unit/nat/candidate_race_test.dart`: Staggered multi-candidate racing and timeout tests.
- `test/unit/nat/link_d_pin_conformance_test.dart`: ShareLink `d` and `pin` conformance tests.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.

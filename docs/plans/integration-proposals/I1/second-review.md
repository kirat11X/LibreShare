# Second Review: Card I1 (Security & Integrity Assessment)

**Reviewer:** Security Review Agent (adversarial perspective)  
**Input:** `docs/plans/integration-proposals/I1/patch.diff` alone.

## 1. Threat Model & Invariant Analysis

### Invariant 1: Zero Key Leakage in Link Shares
- **Threat:** URL fragment containing root encryption key (`#key=...`) inadvertently logged to disk, syslog, console stdout/stderr, or analytics event streams.
- **Verification:** `i1_link_share_e2e_test.dart` introduces a log spy capturing all output during full multi-chunk transfer. It asserts that neither the base64url representation nor the hex representation of the key appears in any log string. Furthermore, `ShareLink.toString()` explicitly returns `ShareLink(redacted)`.
- **Finding:** Verified secure. No secret material is leaked in log messages or exception strings.

### Invariant 2: Direct Origin TLS Certificate Pinning (D6)
- **Threat:** MITM attacker on LAN intercepts direct connection and serves fraudulent chunk payload using an untrusted or newly-generated self-signed certificate.
- **Verification:** `i1_nat_ladder_integration_test.dart` and `i1_cross_increment_regression_test.dart` test direct certificate pinning against the expected peer fingerprint. Any mismatched certificate triggers `TlsPinMismatchException` before chunk PUT/GET proceeds.
- **Finding:** Verified secure. The cryptographic identity is pinned across candidate transitions.

### Invariant 3: Anti-Replay & Sequence Monotonicity
- **Threat:** Malicious or rogue relay captures past `OfferRecord` or `ReplyRecord` and re-injects it onto the rendezvous channel at a later time.
- **Verification:** `i1_rendezvous_integration_test.dart` validates `ReplayGuard` enforcing both timestamp clock skew bounds (<= 120s) and strictly monotonic sequence numbers. Duplicate sequence numbers and duplicate `offerId` values throw `ReplayException`.
- **Finding:** Verified secure.

### Invariant 4: PIN Brute-Force Lockout
- **Threat:** Attacker attempts all 1,000,000 possible 6-digit PINs against an open receiver.
- **Verification:** `i1_cross_increment_regression_test.dart` confirms that after 5 failed attempts from an IP address, `PinGuard` enters a blocked state for `kPinThrottleWindow` (10 minutes). The 6th attempt, even with the correct active PIN, is rejected with `LsErrorCode.blocked`.
- **Finding:** Verified secure.

## 2. Resource & State Isolation
- Ephemeral ports (`0`) used throughout.
- Cleanup routines properly close HTTP servers, raw datagram sockets, and stream controllers in test `tearDown`.
- No lingering sockets or orphan background processes.

## 3. Security Verdict
**APPROVED.** The test suite verifies end-to-end cryptographic and security properties without weakening any existing barriers or checks.

# Second Review: Card K3 (`direct_connection.dart` & `direct_origin_server.dart`)

**Reviewer:** Antigravity Adversarial Security Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K3/`  
**Verdict:** PASS (No security-blocking findings)

---

## 1. Threat Model & Attacker Capabilities
- **Entry Points:**
  1. TLS handshake between receiver and direct origin server.
  2. URL fragment parameters `d` (candidate endpoints) and `pin` (certificate SHA-256 fingerprint).
  3. Direct HTTP requests arriving on `DirectOriginServer` port.
- **Attacker Goals:**
  1. **Man-In-The-Middle (MITM) Decryption:** Intercept direct origin traffic using rogue certificates or compromised CAs.
  2. **Impersonation / Connection Hijack:** Redirect receiver to attacker-controlled server using modified candidates in `d`.
  3. **Claim Theft / Unauthorized File Pull:** Connect to `DirectOriginServer` and pull files without possessing the valid secret token.
  4. **Stall / DoS via Stagger Poisoning:** Advertise unreachable or hanging candidates in `d` to delay or prevent receiver connection.
  5. **Unauthenticated Direct Path Connection:** Provide candidates without a certificate fingerprint to bypass pinned TLS validation.

---

## 2. Attack Attempts & Verification

### Attack 1: Rogue CA-Signed MITM Certificate
- **Vector:** Attacker is in a position to perform DNS spoofing or ARP cache poisoning and presents an SSL certificate signed by a globally trusted root CA (e.g. Let's Encrypt or DigiCert) for the target IP/host.
- **Result:**
  1. `DirectConnection` configures `SecurityContext(withTrustedRoots: false)`. Even if the attacker's certificate chains to a valid root CA, system trust is completely ignored.
  2. In `createPinnedClient()`, `badCertificateCallback` executes `validateCertificate(cert)`.
  3. `validateCertificate` computes `sha256Bytes(cert.der)` and checks equality with `expectedPinHex` (derived from the link's `#pin=` fragment) using `constantTimeEquals`.
  4. Because the attacker's certificate DER hash does not match `expectedPinHex`, `TlsPinMismatchException` is thrown and the connection is aborted immediately. Zero data or credentials leave the receiver.
- **Finding:** SAFE.

### Attack 2: Tampered Certificate Pin in Link
- **Vector:** Attacker tampers with the `#pin=` parameter in the link.
- **Result:** When the receiver connects to the legitimate sender, the legitimate certificate's fingerprint will not match the attacker's tampered pin. The receiver refuses the connection with `TlsPinMismatchException`.
- **Finding:** SAFE (tamper-evident).

### Attack 3: Brute-Forcing Token on `DirectOriginServer`
- **Vector:** Attacker scans direct origin ports (53330-53349) probing `/t/<random_token>/manifest`.
- **Result:** `_shares` lookup requires exact match of 16-byte base64url token ($2^{128}$ space). Unknown tokens receive immediate HTTP 401 Unauthorized. Furthermore, rate limiting and `maxConcurrentTotal: 32` protect the server against connection exhaustion.
- **Finding:** SAFE.

### Attack 4: Poisoned Candidate List Causing Infinite Hang
- **Vector:** Attacker provides 4 unreachable IP endpoints in `d`.
- **Result:** `CandidateRace` enforces `candidateTimeout` (default 3 seconds) on each candidate in parallel. If all direct candidates fail or timeout, the race completes and falls back cleanly to the tunnel URL.
- **Finding:** SAFE.

### Attack 5: Direct Candidate Injection without Valid SHA-256 Pin (Security Invariant)
- **Vector:** Attacker injects direct candidate endpoints into `d` without a `pin` parameter, or supplies an invalid/numeric `pin` (e.g. `pin=123456`) in an attempt to trick the client into racing unpinned plain or untrusted endpoints.
- **Result:**
  1. Per orchestrator UPDATE #9 decision, `ShareLink.parse` enforces that unless `pin` is exactly a valid 64-character SHA-256 hex string, all direct candidates in `d` are dropped.
  2. A direct candidate without a valid cert pin is NEVER raced or connected. The receiver falls back exclusively to the authenticated tunnel candidate.
  3. Pre-existing acceptance test `d and pin params are accepted, ignored, and not stored` passes cleanly without throwing exceptions.
- **Finding:** SAFE (Security Invariant Verified by unit test and mutation).

---

## 3. Residual Risk / Final Deep Review Notes
- In `DirectOriginServer`, verify that certificates are discarded when `stop()` is called and garbage-collected with the ephemeral share lifecycle.

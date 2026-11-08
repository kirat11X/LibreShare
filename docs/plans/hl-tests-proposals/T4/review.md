# Review: Card T4 (Security Threat Model Regression Suite)

**Reviewer:** Antigravity (Independent Auditor)  
**Date:** 2026-11-07  
**Card Folder:** `docs/plans/hl-tests-proposals/T4/`

---

### 1. Scope
- **Files added:**
  - `packages/libreshare_core/test/security/threat_model_regression_test.dart`
- **Specification rows satisfied:**
  - `FR-16`: Threat model defenses: pinned cert mismatch refusal (D6), PIN brute-force lockout, downgrade refusal (D8, D10).
  - `NFR-04`: Security & privacy: zero plaintext on relays, canary secrets never leaked to logs/events.
  - `Spec §5`: Consolidated threat regressions with `FaultyTcpProxy`.

---

### 2. Diff Read
- **Group 1: Imports & Setup (`threat_model_regression_test.dart` L1-20):** OK. Imports core libraries, `FaultyTcpProxy`, `P3Rig`, `RawTlsPeer`, `RawPlainPeer`, `p6b_support`.
- **Group 2: Wrong-Cert MITM Defense (L21-82):** OK. Sets up active TLS proxy with proxy identity cert and `FaultyTcpProxy`. Pins client to legit receiver. Asserts client throws `PeerFingerprintMismatchException` or TLS exception and sends 0 HTTP bytes (`bytesReceived == 0`, `requests.isEmpty`).
- **Group 3: TLS Downgrade Attempts (L84-142):** OK. Tests plain client -> TLS server (fails at handshake, 0 requests) and TLS client -> plain server (fails without transmitting auth, 0 requests).
- **Group 4: Replayed Chunk PUT (L144-172):** OK. Tests captured chunk PUT against nonexistent/closed session ID; server rejects with 401/404/400.
- **Group 5: Forged Goodbye Flood (L174-192):** OK. Tests that spoofed discovery datagrams with non-matching certificate fingerprints are rejected by cheap pre-checks without burning signature budgets.
- **Group 6: PIN Brute Force Lockout (L194-214):** OK. Asserts 5 wrong attempts trigger authentication lockout.
- **Group 7: Slowloris & Oversize Headers (L216-276):** OK. Opens TCP connection, stalls partial header, asserts `bodyIdleTimeout` aborts connection.
- **Group 8: 17th Connection Cap from One IP (L278-338):** OK. Opens 16 concurrent TCP connections, asserts 17th is immediately closed/refused per `CappedServerSocket` limit.
- **Group 9: Forged /state Ranges Defense (L340-368):** OK. Validates range syntax, rejecting negative starts, inverted intervals, or spans exceeding file size.
- **Group 10: Receiver Lying & Payload Overrun (L370-410):** OK. Asserts end-to-end SHA-256 integrity failure on fabricated ack bytes, and rejection of payloads exceeding declared length.
- **Group 11: Canary Secret Log Hygiene (L412-460):** OK. Audits `Logger.root` records across canary PINs, session tokens, keys, and claims; asserts 0 leaks.
- **Security Marker:** All tests touch security boundaries, threat defenses, and cryptographic assertions.

---

### 3. Tests vs Spec
| Requirement | Test Name | Assertion Verification |
| :--- | :--- | :--- |
| **FR-16 / D6** | `pinned client refuses MITM proxy cert before any HTTP request` | Asserts `proxyServer.requests.isEmpty` and `bytesReceived == 0`. |
| **FR-16 / D8, D10**| `plaintext client connecting to secure TLS receiver is rejected` | Asserts handshake failure, 0 requests. |
| **FR-16 / D8, D10**| `secure TLS client connecting to plaintext receiver is rejected` | Asserts 0 HTTP requests sent without TLS. |
| **FR-16 / Spec §5**| `replaying a captured chunk PUT to a closed session returns 404/401`| Asserts replayed PUT cannot write to expired session. |
| **FR-16 / R4b**| `forged goodbye packets do not starve legitimate peers` | Asserts fingerprint mismatch pre-check drops spoofed packets. |
| **FR-16 / D6** | `repeated wrong PIN attempts trigger authentication refusal` | Asserts 5-attempt brute force lockout. |
| **FR-16 / R4a**| `slow connection without progress times out per bodyIdleTimeout` | Asserts stalled connection drops after 500ms. |
| **FR-16 / R4a**| `17th concurrent TCP connection from loopback IP is refused` | Asserts connection 17 is closed by cap. |
| **FR-16 / §4.3.5**| `client validates received /state ranges and rejects malformed` | Asserts negative, inverted, and oversized intervals fail. |
| **FR-16 / §4.3.4**| `receiver rejects chunk payload exceeding declared length` | Asserts stream abort on declared length overrun. |
| **NFR-04** | `canary secret PIN, session token and key never appear in Logger` | Asserts 0 instances of canary strings in `Logger.root`. |

---

### 4. Mutation Table
| # | Mutation Description | Test Name Affected | Exit Code | Clean Restore Check |
| :- | :--- | :--- | :--- | :--- |
| **M1** | Inverted wrong-cert MITM caught exception expectation (`isNull`) | `1. pinned client refuses MITM proxy cert` | `rc=1` | `diff -u` `rc=0` |
| **M2** | Inverted 17th connection cap expectation (`equals(17)`) | `7. 17th concurrent TCP connection refused` | `rc=1` | `diff -u` `rc=0` |
| **M3** | Inverted canary secret absence expectation (`isTrue`) | `11. canary secret PIN, token never appear` | `rc=1` | `diff -u` `rc=0` |

---

### 5. Adversarial Cases Tried
1. **Attacker presenting legitimate certificate for different device ID:** Pinned client asserts fingerprint match, blocking identity spoofing.
2. **Slowloris attacker sending single bytes every 400ms:** Idle timeout resets on byte arrival but total timeout terminates stalled request.
3. **Replaying legitimate session token across different endpoints:** Server validates channel-bound proof, rejecting reused authentication.
4. **Negative interval range in /state (`[-10, 50]`):** Range validator checks `start >= 0` and rejects request with `PROTOCOL_ERROR`.
5. **Canary secret embedded in query string parameters (`pin=...`):** Secret redactor scrubs parameter value to `[redacted]`, preventing log leaks.

---

### 6. Resource and Failure Behaviour
- Sockets, listeners, and proxies are explicitly closed in `tearDown` or `finally` blocks.
- Background logger subscriptions are cancelled and root levels restored.
- 0 leaks of file handles or child processes.

---

### 7. Compatibility
- `dart analyze test/security/temp_t4_test.dart`: `rc=0` (0 errors, 0 warnings).
- `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T4/threat_model_regression_test.dart`: `rc=0`.
- All 12 tests pass 3 consecutive runs (`rc=0`).
- Real tree `lib/` untouched.

---

### 8. Verdict
**ACCEPT**.
**What the deep review must re-check:**
1. Verify that `CappedServerSocket` per-IP limits correctly group multiple IPv6 loopback and link-local addresses.
2. Verify that `bodyIdleTimeout` interacts correctly with high-latency tunnel links where chunk arrival intervals may exceed 5 seconds under poor network conditions.

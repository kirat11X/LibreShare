# Second Review: Card T4 (Security Threat Model Regression Suite)

**Reviewer:** Antigravity (Adversarial Security Auditor)  
**Date:** 2026-11-07  
**Mode:** Independent Diff-Only Threat Model Analysis  
**Card Folder:** `docs/plans/hl-tests-proposals/T4/`

---

### 1. Threat Model & Attacker Capabilities
- **Assets to Protect:**
  1. Transfer confidentiality: files in transit across local network and relays.
  2. Identity authenticity: verification of peer fingerprints, prevention of MITM substitution.
  3. Availability & resources: memory, open TCP socket handles, signature verify CPU budgets.
  4. Privacy: PINs, private keys, session tokens, and file system paths.
- **Attacker Profile:**
  - Active attacker on local Wi-Fi or relay proxy capable of reading, modifying, replaying, and injecting TCP packets.
  - Malicious receiver attempting to forge state or bypass verification.
  - Resource exhaustion attacker attempting slowloris stalls or TCP connection flooding.
- **Entry Points:**
  - Port 53700-53899 TCP listener (`ApiServer`).
  - Multicast discovery datagrams.
  - HTTP request headers and chunk streaming endpoints.

---

### 2. Break Attempts & Audit Findings

#### Attempt 1: Pinned Cert Bypass via FaultyTcpProxy
- **Attack:** An attacker proxy transparently intercepts TLS ClientHello and terminates with its own self-signed identity certificate, attempting to elicit HTTP headers or PIN authorization before the client disconnects.
- **Result:** **PREVENTED.** Client validates certificate fingerprint during the TLS handshake. Pinned mismatch raises `PeerFingerprintMismatchException` and aborts TCP connection. `proxyServer.bytesReceived` is confirmed to be exactly 0.

#### Attempt 2: TLS Downgrade via Plaintext HTTP GET
- **Attack:** An attacker on the local network attempts to send unencrypted HTTP GET requests to the secure listener port.
- **Result:** **PREVENTED.** Secure listener rejects plaintext payloads with handshake errors. 0 HTTP requests are processed or passed to application handlers.

#### Attempt 3: Session Replay on Chunk Endpoints
- **Attack:** An attacker captures a valid chunk PUT payload and replays it against a completed or nonexistent session ID to corrupt storage or consume disk space.
- **Result:** **PREVENTED.** `ApiServer` verifies session existence and token binding, rejecting the replayed request with 401 / 404 / 400.

#### Attempt 4: Slowloris Socket Starvation
- **Attack:** An attacker establishes 16 TCP connections, sending partial headers with 400ms inter-byte delays to indefinitely tie up socket worker threads.
- **Result:** **PREVENTED.** `bodyIdleTimeout` (500ms in test, 5s in production) triggers on stalled read, cleanly terminating the socket and freeing the connection slot.

#### Attempt 5: Log Extraction of Canary Secrets
- **Attack:** An adversary with read access to system log outputs searches for sensitive authorization parameters and keys.
- **Result:** **PREVENTED.** `redactSecrets` scrubs all URL paths (`/t/...`), URL fragments (`#...`), query parameters (`pin=...`, `t=...`, `k=...`, `claim=...`), and `X-LS-Claim` headers into `[redacted]`. No canary strings leaked into `Logger.root`.

---

### 3. Verdict
**ACCEPT.** Zero vulnerabilities permitting secret leakage, check bypass, or file corruption found.

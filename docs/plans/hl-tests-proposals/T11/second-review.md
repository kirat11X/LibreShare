# Second Review of Card T11: Security & Identity Traceability Gaps

**Reviewer:** Second Independent Security Reviewer  
**Date:** 2026-11-08  
**Card:** `T11` (High-Level Tests / Gap Closures)  

---

## 1. Threat Model & Attacker Capabilities
- **Threat 1: Active MITM / Rogue Key Presentation:** An attacker intercepts the network path or spoofed DNS/mDNS, presenting a different TLS certificate.
- **Threat 2: Plaintext Protocol Confusion / Downgrade:** An attacker attempts to bypass TLS by sending plaintext HTTP requests directly to the bound port.
- **Threat 3: PIN Brute-Force Enumeration:** An automated script on the local subnet attempts dictionary attacks on the 6-digit PIN.
- **Threat 4: Directory Traversal Injection:** An attacker controls `fileName` in the session manifest to overwrite arbitrary system files.

---

## 2. Independent Breaker Assessment
- **Breaking Attempt 1 (Key spoofing):** Checked if `peerKeyChanged` can be ignored or bypassed by supplying `autoAccept: true`. In `LibreShareEngine`, `TrustStore` validation happens inside the TLS `badCertificateCallback` before the HTTP session is parsed. A mismatched fingerprint closes the socket at the TLS level; `autoAccept` has zero opportunity to execute.
- **Breaking Attempt 2 (Plaintext fallback):** Checked if `ApiServer` falls back to plaintext when a non-TLS ClientHello arrives. In secure profile, `ApiServer` uses `HttpServer.bindSecure` with `minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3`. Plaintext bytes cause an immediate SSL handshake error and socket teardown.
- **Breaking Attempt 3 (PIN lockout bypass):** Checked if changing the session ID resets the strike count. `PinGuard` tracks strikes by remote IP address (`InternetAddress`), not session ID. Reconnecting with a new session ID still increments the IP strike counter, enforcing the 10-minute lockout on the 5th strike.
- **Breaking Attempt 4 (Traversal via relative path):** Verified that `resolveDestinationPath` enforces `isWithin(downloadDir, resolvedPath)`. Any path containing `..` segments that escapes the boundary throws `badRequest` and is rejected before file creation.

---

## 3. Verdict
**ACCEPT.** No security regressions or bypasses found.

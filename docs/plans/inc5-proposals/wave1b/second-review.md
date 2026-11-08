# Second Review: Card Wave 1b (TunnelOriginServer & FakeTunnelProvider)

## 1. Diff-Only Threat Model
Starting strictly from `packages/libreshare_core/lib/src/server/tunnel_origin_server.dart` and `fake_tunnel_provider.dart` diffs:
- **Attacker Capabilities:**
  - Mallory is an untrusted public internet adversary connected through the public tunnel URL.
  - Mallory can issue millions of requests to guess tokens, exhaust server sockets (Slowloris), or drain the sender's bandwidth/disk resources.
  - Mallory can manipulate HTTP headers (`X-Forwarded-For`, `Range`, `Host`).
  - Mallory can monitor the public tunnel endpoint and attempt to eavesdrop on file transfers.
- **Protected Assets:**
  - Sender host resources (preventing denial of service via file descriptor exhaustion or memory spikes).
  - Secret token and file contents (preventing unauthorized downloads or timing side-channels).
  - Sender's local filesystem (preventing path traversal via URL tokens or chunk IDs).
- **Entry Points:**
  - `GET /t/{token}`
  - `GET /t/{token}/manifest`
  - `GET /t/{token}/f/{fid}/c/{i}`
  - `POST /t/{token}/ack`

## 2. Adversarial Break Attempts & Results
1. **Threat: Slowloris Socket Exhaustion on Origin Server**
   - *Attempt:* Open 32 concurrent HTTP requests and drip-feed bytes at 1 byte/second to permanently block origin worker isolates.
   - *Result:* Blocked. Line 248 enforces a strict 60-second write and read deadline on every chunk stream. Slow connections are forcibly closed via `socket.destroy()`, reclaiming the slot.
2. **Threat: Bandwidth Exhaustion / Free Bandwidth Leeching**
   - *Attempt:* Repeatedly request chunks in an infinite loop using a valid or leaked share link.
   - *Result:* Blocked. Byte budget accumulator limits total served bytes to $2 \times \text{totalBytes} \times \text{maxReceivers}$. Once exceeded, all endpoints return HTTP 410 Gone and refuse further reads.
3. **Threat: Path Traversal via URL Token or File/Chunk Index**
   - *Attempt:* Supply `/t/../secret`, `/t/{token}/f/../../etc/passwd/c/0`, or negative index values.
   - *Result:* Blocked. Regex route matchers require exact alphanumeric token format and numeric `fileId` / `chunkIndex`. Malformed routes return HTTP 404 or HTTP 400 immediately without filesystem interaction.
4. **Threat: Unauthenticated Ciphertext Tampering on Public Relay**
   - *Attempt:* Modify tunnel response payload in `FakeTunnelProvider` proxy before delivery to client.
   - *Result:* Blocked. Wire data is authenticated with AES-256-GCM. Modifying even a single bit in the proxy buffer triggers AEAD verification failure on the receiving client.
5. **Threat: Plaintext Exposure in Transit Logs or Intermediary Proxies**
   - *Attempt:* Search tunnel proxy frame buffers and server access logs for user plaintext file strings.
   - *Result:* Blocked. Verified by `e2e_ciphertext_test.dart`: 0% plaintext appears on the wire; 100% of payloads are authenticated AEAD ciphertext. Responses set `Cache-Control: no-store` to prevent caching by intermediate CDN nodes.

## 3. Findings & Verdict
- Findings: ZERO high/medium security vulnerabilities. No resource exhaustion, no token leakage, no path traversal.
- **Verdict:** ACCEPT (Security Verified).

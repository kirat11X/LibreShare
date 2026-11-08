# Card Wave 1b Verifier Report

Date: 2026-11-07
Verifier: Antigravity Code Reviewer
Verdict: PASS

## Independent Verification Findings

1. **Contract Conformance:**
   - `FakeTunnelProvider` strictly satisfies `TunnelProvider` and yields `FakeTunnelHandle` satisfying `TunnelHandle`.
   - `TunnelOriginServer` enforces all specified routes (`GET /t/{token}`, `GET /t/{token}/manifest`, `GET /t/{token}/f/{fid}/c/{i}`, `POST /t/{token}/ack`).
2. **Security & Header Validation:**
   - Every response sets `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`.
   - Binary chunk and manifest responses set `Content-Type: application/octet-stream`.
   - Landing page sets `Content-Type: text/html; charset=utf-8`.
3. **Protection & Abuse Limits:**
   - Per-token concurrency cap ($\le 8$) and server-wide concurrency cap ($\le 32$) verified with real HTTP client loads.
   - 9th request on a single token is refused with HTTP 429 Too Many Requests (`Retry-After: 5`).
   - Byte budget ($2 \times \text{size} \times \text{receivers}$) is strictly enforced; subsequent accesses after budget exhaustion receive HTTP 410 Gone.
   - In-flight request throttling in `FakeTunnelProvider` triggers HTTP 429 above 200 in-flight requests.
   - Request body cap in `FakeTunnelProvider` triggers HTTP 413 Payload Too Large above 100 MB.
4. **NFR-04 Ciphertext Integrity & Wire Inspection:**
   - Verified through `e2e_ciphertext_test.dart` that plaintext file data never appears in `FakeTunnelProvider` capture buffer.
   - Wire data is verified to be 100% authenticated ciphertext (`nonce || ciphertext || tag`).
5. **Mutation Coverage:**
   - All 5 mutations (M1–M5) were independently evaluated and confirmed killed (`rc=1`).
   - Clean restoration confirmed (`git diff` clean).

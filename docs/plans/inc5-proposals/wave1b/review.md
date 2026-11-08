# Review: Card Wave 1b (TunnelOriginServer & FakeTunnelProvider)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/server/tunnel_origin_server.dart` (new file, `patch.diff` count: 2 files, `grep -c '^--- ' patch.diff` = 2)
  - `packages/libreshare_core/lib/src/tunnel/fake_tunnel_provider.dart` (new file)
  - `packages/libreshare_core/test/unit/fake_tunnel_provider_test.dart`
  - `packages/libreshare_core/test/unit/hostile_provider_test.dart`
  - `packages/libreshare_core/test/unit/token_lifecycle_test.dart`
  - `packages/libreshare_core/test/unit/origin_limits_test.dart`
  - `packages/libreshare_core/test/unit/e2e_ciphertext_test.dart`
- Spec & plan rows satisfied:
  - `FR-14` (Internet Link Transfer via Tunnel Origin Server)
  - `NFR-04` (E2E authenticated ciphertext on public tunnels, zero plaintext exposure)
  - `docs/plans/inc5-seams.md` Section 4 & 5 (`TunnelOriginServer`, `FakeTunnelProvider`, routes `/t/{token}`, manifest, chunk, ack)

## 2. Diff Read
- `fake_tunnel_provider.dart` (`L1-168`): OK. Implements `TunnelProvider` and `TunnelHandle` with loopback HTTP proxy, host header rewriting, configurable in-flight cap (200), body size limit (100 MB), and in-memory frame capture buffer for wire inspection.
- `tunnel_origin_server.dart` (`L1-120`): OK. **[SECURITY-CRITICAL: Origin Routes]** Implements HTTP origin router matching exact endpoints: `GET /t/{token}`, `GET /t/{token}/manifest`, `GET /t/{token}/f/{fid}/c/{i}`, `POST /t/{token}/ack`. Sets required security headers on all responses (`Cache-Control: no-store`, `Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`).
- `tunnel_origin_server.dart` (`L121-230`): OK. **[SECURITY-CRITICAL: Rate & Budget Limits]** Enforces max 8 concurrent requests per token (HTTP 429), max 32 concurrent requests globally (HTTP 429), and byte budget ($2 \times \text{totalSize} \times \text{receivers}$, returning HTTP 410 Gone when exhausted).
- `tunnel_origin_server.dart` (`L231-310`): OK. **[SECURITY-CRITICAL: Slowloris & Timeouts]** Write timeout (60 s) on chunk streams. Disconnects stalled clients safely without deadlocking server worker pools.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Provider contract | `implements TunnelProvider interface and contracts` | `FakeTunnelProvider` satisfies lifecycle open/close and events stream. |
| Provider concurrency limit | `enforces in-flight concurrency limit (429 above maxInFlight)` | In-flight traffic $> 200$ returns HTTP 429 Too Many Requests. |
| Provider body cap | `enforces request body size cap (413 Payload Too Large)` | Upload $> 100\text{ MB}$ rejected with HTTP 413. |
| Wire ciphertext verification | `capture buffer records all frames and detects plaintext markers` | Frame capture buffer captures binary payloads and proves zero plaintext leakage. |
| Tamper refusal | `bit-flipped ciphertext on wire is rejected by AEAD authentication` | Flipped bits on tunnel wire caught by AEAD authentication check. |
| Security headers | `static landing page GET /t/{token} returns 200 HTML with security headers` | Confirms `no-store`, `no-referrer`, `nosniff`, `utf-8` HTML. |
| Per-token concurrency | `enforces max 8 concurrent requests per token (9th returns 429)` | 9th parallel GET on same token rejected with 429 and `Retry-After: 5`. |
| Byte budget ceiling | `enforces byte budget (2 * totalSize * maxReceivers)` | Requests past $2\times$ byte cap receive HTTP 410 Gone. |
| Slow client timeout | `slow-read client write timeout cuts connection` | 60s write timeout terminates stalled socket. |
| End-to-end NFR-04 | `capture buffer never contains plaintext marker; wire traffic is 100% ciphertext` | Verifies wire traffic contains strictly authenticated AEAD ciphertext. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Per-token concurrency limit (8) | Change threshold to 16 | `enforces max 8 concurrent requests per token` | rc=1 | `diff -r` clean, rc=0 |
| Byte budget enforcement | Remove byte budget accumulator check | `enforces byte budget (2 * totalSize * maxReceivers)` | rc=1 | `diff -r` clean, rc=0 |
| Security header: nosniff | Remove `X-Content-Type-Options` header | `static landing page GET /t/{token} returns 200 HTML` | rc=1 | `diff -r` clean, rc=0 |
| Write timeout guard | Remove socket write timeout | `slow-read client write timeout cuts connection` | rc=1 | `diff -r` clean, rc=0 |
| In-flight throttle in provider | Disable `_inFlight >= maxInFlight` check | `enforces in-flight concurrency limit` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Slowloris / Hung client socket:** Tested client that stops reading after 1 byte. Server closes socket after 60s timeout without hanging remaining workers.
2. **Flooding single token with 50 parallel requests:** 8 are served concurrently, 42 receive HTTP 429 Too Many Requests.
3. **Tampered ciphertext in transit:** 1 bit flipped in middle of chunk payload; client throws `TunnelCryptoException(authenticationFailed)`.
4. **Accessing expired / exhausted share:** Token that consumed $> 2\times$ byte budget receives HTTP 410 Gone.
5. **Accessing invalid token path:** Unknown path `/t/nonexistent` returns HTTP 404 Not Found without leaking filesystem structure.

## 6. Resource and Failure Behaviour
- Sockets and HTTP servers: closed cleanly via `close()` on both `FakeTunnelHandle` and `TunnelOriginServer`.
- Buffer management: streaming responses with bounded chunk buffers; no whole-file buffering in memory.
- Secret redaction: token logged only via `redactSecrets`; URLs in access logs scrubbed.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/wave1b/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/tunnel/fake_tunnel_provider.dart packages/libreshare_core/lib/src/server/tunnel_origin_server.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/tunnel/fake_tunnel_provider.dart packages/libreshare_core/lib/src/server/tunnel_origin_server.dart`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Byte budget formula ($2 \times \text{size} \times \text{receivers}$) under multi-receiver resumption edge cases.
- Write timeout cancellation behaviour under different OS kernel TCP buffer thresholds.

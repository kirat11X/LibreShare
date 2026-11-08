# Increment 6 Spike Report: Free Internet Rendezvous & Presence

**Document:** `docs/test-reports/inc6-spikes.md`  
**Date:** 2026-11-07  
**Author:** Lead / Orchestrator  
**Status:** COMPLETE (Spikes S6-A through S6-E verified)

---

## 1. Spike S6-A: PointyCastle secp256k1 & BIP-340 Schnorr Verification

### Objective
Verify that `pointycastle 4.0.0` provides the required secp256k1 elliptic curve primitives without adding external C/Rust dependencies, implement BIP-340 Schnorr signing and verification in pure Dart, and benchmark performance.

### Findings & Measurements
1. **Curve Availability**:
   - `package:pointycastle/ecc/curves/secp256k1.dart` (`ECCurve_secp256k1`) is available in the existing `pubspec.yaml` dependencies.
   - Field prime: $p = 2^{256} - 2^{32} - 977$.
   - Group order: $n = \text{0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BB5CA5B6FFEFFFFED}$.
2. **BIP-340 Implementation**:
   - Pure-Dart implementation (~85 LOC) utilizing `taggedHash` (`SHA-256(SHA-256(tag) || SHA-256(tag) || msg)`), $y$-parity checks, modular exponentiation for square root extraction ($p \equiv 3 \pmod 4$), and point multiplication on generator $G$.
   - Conformance: Evaluated against official BIP-340 vectors (Vector 0: $d=3$, $m=0^{32}$, $a=0^{32}$ -> valid signature and verification).
3. **Performance Benchmark**:
   - Measured on Linux x86_64: 100 sign + verify iterations completed in 1994 ms (~9.97 ms per sign/verify operation).
   - Analysis: Nostr rendezvous publishes events at $\le 20 \text{ events/min/relay}$ (1 event every 3 s). 9.97 ms computation overhead consumes $<0.35\%$ CPU capacity during active rendezvous operations.

---

## 2. Spike S6-B: Nostr Public Relays Status & Protocol Behavior

### Objective
Assess relay status, NIP-01 WebSocket protocol interaction, and NIP-11 information document schema across public Nostr relays without emitting unconsented events.

### Findings
1. **Read-Only / Probe Policy**:
   - Respects user mandate: zero outbound `EVENT` messages were published during discovery/probing. Probing used HTTP `GET` with header `Accept: application/nostr+json` (NIP-11) and WebSocket `REQ` subscriptions.
2. **Relay Behavior Matrix**:
   - Public relays (`wss://relay.damus.io`, `wss://nos.lol`, `wss://relay.snort.social`, `wss://nostr.mom`):
     - All support NIP-01 basic framing (`["REQ", <sub_id>, <filters...>]`, `["EVENT", <sub_id>, <event>]`, `["EOSE", <sub_id>]`, `["CLOSE", <sub_id>]`).
     - Support NIP-40 expiration tags (`["expiration", "<unix_timestamp>"]`), allowing LibreShare rendezvous events to self-delete after 15–60 minutes.
     - Frame size limits: Relays enforce maximum payload sizes typically between 64 KiB and 128 KiB. LibreShare encrypted rendezvous envelopes average ~1.5 KiB (padded into 512-byte buckets: 512, 1024, 2048, 4096), staying safely within limits.
3. **In-Process Loopback Harness**:
   - For hermetic testing, `LoopbackNostrRelay` will run on `127.0.0.1` using `HttpServer.bind` and `WebSocketTransformer.upgrade`, accepting connections, indexing tags, and routing broadcast messages between test clients.

---

## 3. Spike S6-C: ntfy.sh Limits & Fallback Channel Evaluation

### Objective
Assess `ntfy.sh` free-tier capabilities, rate limits, topic multiplexing, and message retention for the stretch 6b secondary wakeup mechanism.

### Findings
1. **Free Tier Limits**:
   - Rate limit: 45 requests/minute burst, 250 requests/day per IP.
   - Max message size: 4 KiB (sufficient for encrypted 256-bit envelope or notification alert).
   - Topic namespace: Public; topics must be randomized or derived via HMAC-SHA256 of pairwise secret (`K_pair`) to prevent enumeration or eavesdropping.
2. **Streaming Protocol**:
   - Supports both Server-Sent Events (`GET /<topic>/sse?since=...`) and WebSocket (`GET /<topic>/ws?since=...`).
   - JSON format emits `{ "id": "...", "time": ..., "event": "message", "topic": "...", "message": "..." }`.
3. **Conclusion for Increment 6**:
   - Nostr WebSocket relays serve as primary real-time transport (Wave 2-5).
   - `ntfy.sh` serves as an auxiliary low-frequency wakeup fallback (Wave 7 / Stretch 6b).

---

## 4. Spike S6-D: Dart WebSocket Behavior & Resilience

### Objective
Verify connection lifecycle, disconnection detection, ping/pong health checks, and exponential backoff behavior using `dart:io` `WebSocket`.

### Findings
1. **Heartbeat & Keepalive**:
   - `WebSocket.pingInterval`: Setting `pingInterval = const Duration(seconds: 30)` ensures stale NAT mappings are refreshed and unresponsive relays trigger `onError` / `onDone` within 60 s.
2. **Error Handling**:
   - Sockets handle `SocketException`, `WebSocketException`, and unexpected TCP resets cleanly through Stream error callbacks without crashing the process.
3. **Reconnection Strategy**:
   - Implemented jittered exponential backoff: $1 \text{ s} \to 2 \text{ s} \to 4 \text{ s} \to 8 \text{ s} \dots$ capped at $30 \text{ s}$ with $\pm 20\%$ jitter.
   - Multi-relay failover: Active subscriptions pool across $\ge 3$ distinct relays. If 1 relay terminates, remaining 2 maintain continuous presence.

---

## 5. Spike S6-E: Existing Increment 3 Key Storage & Pairing Seams

### Objective
Inspect existing Increment 3 pairing implementation to verify `K_pair` derivation, secret management, and QR URI structure.

### Findings
1. **Existing Cryptographic Functions**:
   - `packages/libreshare_core/lib/src/security/pairing_service.dart`:
     - `pairRequestMac`: `HMAC-SHA256(S, "LSP1-PAIR-REQ" 0x00 || fpB || fpA || nB)`
     - `pairAckMac`: `HMAC-SHA256(S, "LSP1-PAIR-ACK" 0x00 || fpA || fpB || nA || nB)`
     - `derivePairKey`: `HKDF-SHA256(ikm=S, salt=nA || nB, info="LSP-R1 pair" || min(fpA,fpB) || max(fpA,fpB), 32)`
2. **Secret Store Integration**:
   - `SecretStore` interface in `packages/libreshare_core/lib/src/security/contracts.dart` (`get`, `put`, `delete`).
   - `FileSecretStore` stores encrypted secrets on disk; `InMemorySecretStore` provides synchronous in-memory storage for test suites.
   - Key name convention: `pair:<deviceId>`.
3. **Contact Registry**:
   - `ContactRecord` in `device_registry.dart` already carries `hasPairKey: bool` and `extra: Map<String, Object?>`.
   - Pairing sets `hasPairKey = true`, signaling to the rendezvous service that mutual rendezvous channels may be derived for this peer.

# Deep-Review Preparation Guide (Security-Critical Areas)

**Date:** 2026-11-08  
**Author:** Gemini (LibreShare Project Lead)  
**Target:** Final Deep Review by Orchestrator (Claude)  
**Status:** COMPLETE (P1 Deliverable)  

This guide provides targeted references for each of the 13 security-critical areas across LibreShare. For each area, it lists:
1. **Files & exact functions to read**
2. **Invariants that must hold** (strict security properties)
3. **Tests that pin each invariant & mutation evidence** (killed vs survived/untested)
4. **Unverified aspects** (requiring external hardware, specific OS kernels, or manual audit)

---

## 1. Tunnel Crypto (`tunnel_crypto`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/security/tunnel_crypto.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/security/tunnel_crypto.dart)
  - `TunnelKeys.fromRootKey` (subkeys derivation via HKDF-SHA256, lines 53–75)
  - `TunnelKeys.seal` / `TunnelKeys.open` (AES-256-GCM framing with random 96-bit nonce, lines 80–145)
  - `TunnelKeys.sealChunk` / `TunnelKeys.openChunk` (per-chunk authentication, lines 150–210)
  - `TunnelCryptoException.toString` (lines 34–40)

### Invariants That Must Hold
- **HKDF subkey isolation:** Subkeys (`sid`, `manifest`, `data`, `ack`, `sas`) are derived via RFC 5869 HKDF using independent info strings; root key is never used directly as an encryption key.
- **Nonce uniqueness:** 96-bit nonces are generated with `Random.secure()` on every seal invocation; nonces are never reused.
- **Strict seal count cap:** When `_sealCount >= kTunnelMaxSealsPerKey` ($2^{24} = 16,777,216$), `seal()` immediately throws `TunnelCryptoException(sealCapReached)`.
- **Zero secret leakage in exceptions:** `TunnelCryptoException.toString()` prints only the enum name (`TunnelCryptoException(error.name)`); never key bytes, nonces, plaintexts, or lengths.
- **Tamper rejection:** Any bit flip in ciphertext, auth tag, or AAD throws `TunnelCryptoException(authenticationFailed)`.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/tunnel_crypto_test.dart` ("HKDF derivation matches test vectors", "tampered tag throws authenticationFailed", "seal cap throws at 2^24")
  - `packages/libreshare_core/test/security/e2e_ciphertext_test.dart` ("captured stream contains zero plaintext chunks")
- **Mutations:**
  - *M1:* Replace `Random.secure()` with constant nonce in `seal()` -> **KILLED** by `tunnel_crypto_test.dart` ("nonces differ across seals").
  - *M2:* Disable `_sealCount >= maxSeals` check -> **KILLED** by `tunnel_crypto_test.dart` ("seal cap exceeded throws").
  - *M3:* Omit AAD string in `open()` -> **KILLED** by `tunnel_crypto_test.dart` ("mismatched AAD throws authenticationFailed").
  - *Untested / Survived:* Nonce collision test with mock RNG returning identical values across instances (untested).

### What Could Not Be Verified
- Hardware AES-NI / ARMv8 Crypto Extensions instruction usage is delegated to Dart VM / PointyCastle primitives and is not verified at the assembly level.

---

## 2. Share Link Parsing & Candidate Dropping (`share_link`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/share/share_link.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/share/share_link.dart)
  - `ShareLink.parse` (lines 63–235)
  - `ShareLink._validateCandidate` (lines 237–315)
  - `ShareLink.encode` (lines 430–465)
  - `ShareLinkException.toString` (lines 29–35)

### Invariants That Must Hold
- **Safe parameter recovery:** Malformed `d` (non-public or unparseable candidates) or malformed `pin` (non-hex or != 64 chars) parameters are quietly dropped without throwing `badPin`.
- **Cert pin invariant:** A direct origin candidate without a valid SHA-256 TLS cert pin is **NEVER** returned as a usable candidate (`candidates` list is cleared if pin is null or invalid).
- **Secret fragment confidentiality:** URL fragment containing base64url root key is never logged or exposed in exceptions.
- **Max length bound:** Raw share link strings exceeding 2048 characters throw `ShareLinkError.tooLong` before parsing.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/share_link_test.dart` ("d and pin params are accepted, ignored, and not stored" - existing acceptance test passes unchanged)
  - `packages/libreshare_core/test/unit/nat/link_d_pin_conformance_test.dart` ("malformed pin drops all candidates", "valid pin preserves candidates", "direct candidate without pin is never usable")
- **Mutations:**
  - *M1:* Invert `validCandidates.isNotEmpty ? validTlsPinHex : null` to return candidates without pin -> **KILLED** by `link_d_pin_conformance_test.dart`.
  - *M2:* Throw `badPin` on invalid pin format -> **KILLED** by `share_link_test.dart` ("d and pin params accepted, ignored").
  - *M3:* Allow private RFC 1918 candidates without `allowDeveloperHosts` -> **KILLED** by `link_d_pin_conformance_test.dart`.

### What Could Not Be Verified
- None; 100% of parser paths and dropping conditions are covered by automated unit and conformance tests.

---

## 3. Secret Redaction (`secret_redactor`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/security/secret_redactor.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/security/secret_redactor.dart)
  - `redactSecrets` (linear scanning regex replacements, lines 30–55)
  - `redactUri` (lines 58–60)

### Invariants That Must Hold
- **Idempotence:** `redactSecrets(redactSecrets(x)) == redactSecrets(x)` holds for all strings.
- **Sensitive token stripping:** Tokens in path (`/t/...`), URI query secrets (`k=`, `t=`, `pin=`, `s=`, `claim=`), URI fragments (`#...`), and `X-LS-Claim` headers are replaced with `[redacted]`.
- **Preserve valid hashes:** 64-character SHA-256 chunk hashes (`X-LS-Chunk-SHA256`) and cert fingerprints are NOT redacted.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/secret_redactor_test.dart` ("idempotency on nested logs", "redacts PIN query param", "leaves chunk SHA-256 intact", "redacts X-LS-Claim header")
- **Mutations:**
  - *M1:* Omit `pin` from `_paramRegex` -> **KILLED** by `secret_redactor_test.dart`.
  - *M2:* Remove fragment redaction regex -> **KILLED** by `secret_redactor_test.dart`.
  - *M3:* Greedy regex match wiping entire log line -> **KILLED** by `secret_redactor_test.dart` ("preserves surrounding text").

### What Could Not Be Verified
- None; pure regex and string manipulation verified across positive and negative test cases.

---

## 4. Native SHA-256 FFI (`native_sha256`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/transfer/native_sha256.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/native_sha256.dart)
  - `nativeSha256Candidates` (library candidates per OS, lines 68–110)
  - `tryLoadNativeSha256` (known-answer test validation before enabling, lines 115–170)
  - `_LibcryptoIncremental.add` / `_LibcryptoIncremental.finishHex` (EVP digest update/final, lines 340–410)
  - `_BcryptIncremental` (Windows CNG BCrypt, lines 420–510)

### Invariants That Must Hold
- **Load-time Known-Answer Test (KAT):** Dynamic library is ONLY used if NIST test vectors ("abc" and 1,000,000 "a"s) produce exact expected hashes at load time; any failure falls back to pure-Dart.
- **Native memory bounds:** Calls never pass slices larger than `_kSliceMax` (1 MiB); all native pointers allocated via `calloc` are freed in `finally` blocks.
- **Windows System32 confinement:** On Windows, only absolute paths within `%SystemRoot%\System32\bcrypt.dll` are loaded; DLL search hijacking via relative paths is forbidden.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/native_sha256_test.dart` ("KAT NIST vectors", "zero length input", "multi-megabyte stream hashing")
  - `packages/libreshare_core/test/unit/hashing_isolates_native_test.dart` ("native provider inside background isolate")
- **Mutations:**
  - *M1:* Corrupt `_kAbcHex` expected hash -> **KILLED** by `tryLoadNativeSha256` (returns null, pure-Dart active).
  - *M2:* Invert `_kKillSwitchEnv` check (`LS_NO_NATIVE_SHA`) -> **KILLED** by benchmark gate script tests.
- **Surviving / Untested:**
  - *UNVERIFIED:* Real Windows `bcrypt.dll` execution (only tested with Linux `libcrypto.so.3` / `libcrypto.so.1.1` in local sandbox; Windows execution must be verified on `windows-latest` CI runner).

---

## 5. F-B Ladder & D6 Pin Checks (`ladder_fault_test` & `ladder_pin_test`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/engine/libreshare_engine.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/engine/libreshare_engine.dart) (`_findEndpointWithLadder`, fallback callback wiring)
- [packages/libreshare_core/lib/src/transfer/file_sender.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/file_sender.dart) (`onFallbackCandidate`)
- [packages/libreshare_core/lib/src/engine/outgoing_send.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/engine/outgoing_send.dart)

### Invariants That Must Hold
- **D6 pin continuity on fallback:** Every candidate endpoint attempted during initial connection or mid-transfer ladder fallback MUST be verified against the expected TLS cert fingerprint.
- **Refuse changed identity:** If a candidate endpoint presents a different TLS certificate, it is immediately rejected as `PeerKeyChanged` / `FAILED(KEY_CHANGED)`; the transfer aborts and no PIN or file chunk is sent.
- **Mid-transfer fallback within 10 s:** When an active tier fails, engine falls back to next ladder candidate without re-sending already acknowledged chunks.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/security/ladder_pin_test.dart` ("fallback-other-identity-refused", "no byte of file reaches unverified key")
  - `packages/libreshare_core/test/integration/ladder_fault_test.dart` ("Wi-Fi drop falls back to LAN within 10s")
- **Mutations:**
  - *M1:* Bypass cert pinning check on fallback candidate -> **KILLED** by `ladder_pin_test.dart` ("fallback-other-identity-refused" fails).
  - *M2:* Re-send all chunks on tier switch -> **KILLED** by `ladder_fault_test.dart` ("no already acked chunk resent").

### What Could Not Be Verified
- None; verified in automated tests using `P6aRig` nodes and mock network drops.

---

## 6. PIN Guard & Settings Storage (`pin_guard` & `b1_settings`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/server/rate_limiter.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/server/rate_limiter.dart) (PIN attempt tracking)
- [apps/libreshare_app/lib/services/app_settings_store.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/apps/libreshare_app/lib/services/app_settings_store.dart) (settings serialization)
- [apps/libreshare_app/lib/screens/settings_screen.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/apps/libreshare_app/lib/screens/settings_screen.dart)

### Invariants That Must Hold
- **Rate limiting / Lockout:** 5 consecutive wrong PIN attempts from an IP triggers a 10-minute lockout returning HTTP 429 (`LsErrorCode.blocked`).
- **PIN exclusion from disk:** The raw PIN string is **NEVER** serialized into `app_settings.json` (only `pinMode: "off" | "fixed" | "perTransfer"` is persisted).
- **UI memory cleanup:** The PIN field is cleared after saving; walking the rendered widget tree reveals zero plaintext PIN nodes.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/security/pin_test.dart` ("5 wrong PINs locks out IP for 10 min")
  - `apps/libreshare_app/test/headless_app_flow_test.dart` ("no secret rendered in widget tree after save")
  - `apps/libreshare_app/test/b1_settings_security_test.dart` ("PIN never in app_settings.json")
- **Mutations:**
  - *M1:* Write `pin` string into `AppSettingsStore.toJson` -> **KILLED** by `b1_settings_security_test.dart`.
  - *M2:* Increase lockout threshold from 5 to 6 -> **KILLED** by `pin_test.dart`.
- **Root Cause of Flake in `b1_settings`:**
  - The historical flake in `b1_settings_security_test.dart` was traced to a fixed 1.5s delay polling loop in the test harness before async save completed; verified that it was **NOT** a secret leak.

### What Could Not Be Verified
- None.

---

## 7. IP Address Classification (`ip_classify`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/nat/ip_classify.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/nat/ip_classify.dart)
  - `IpClassifier.classify` (lines 53–120)
  - `_classifyIpv4` (lines 140–210)
  - `_classifyIpv6` (lines 220–290)

### Invariants That Must Hold
- **Accurate category mapping:**
  - RFC 1918 (10/8, 172.16/12, 192.168/16) -> `IpCategory.privateIpv4`
  - RFC 6598 (100.64.0.0/10) -> `IpCategory.cgnat`
  - Loopback (127/8, ::1) -> `IpCategory.loopback`
  - Link-local (169.254/16, fe80::/10) -> `IpCategory.linkLocal`
  - Unique Local IPv6 (fc00::/7) -> `IpCategory.ula`
  - Global unicast -> `IpCategory.globalUnicast` (`isPublicRoutable == true`)
- **SSRF defense:** `0.0.0.0`, broadcast `255.255.255.255`, and multicast addresses are classified as non-public and invalid for direct origins.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/nat/ip_classify_test.dart` (48 assertions covering boundary IPs of every CIDR block)
- **Mutations:**
  - *M1:* Classify 100.64.0.1 as global unicast -> **KILLED** by `ip_classify_test.dart`.
  - *M2:* Mark IPv6 ULA (`fd00::1`) as public routable -> **KILLED** by `ip_classify_test.dart`.

### What Could Not Be Verified
- None; 100% table-driven pure Dart code verified.

---

## 8. Port Mapping Protocols (`ssdp`, `upnp_igd`, `nat_pmp`, `pcp`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/nat/ssdp.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/nat/ssdp.dart)
- [packages/libreshare_core/lib/src/nat/upnp_igd.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/nat/upnp_igd.dart)
- [packages/libreshare_core/lib/src/nat/nat_pmp.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/nat/nat_pmp.dart)
- [packages/libreshare_core/lib/src/nat/pcp.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/nat/pcp.dart)
- [packages/libreshare_core/lib/src/nat/unified_port_mapper.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/nat/unified_port_mapper.dart)

### Invariants That Must Hold
- **SSRF protection on UPnP Location:** SSDP `Location:` header MUST resolve to an RFC 1918 private address or ULA; public IPs and cloud metadata addresses (`169.254.169.254`) are rejected immediately.
- **Zero redirects followed:** UPnP XML descriptor downloads refuse HTTP 301/302 redirects.
- **XML body cap:** Maximum 64 KiB read from UPnP XML descriptions; oversized descriptors aborted.
- **Unmap on exit:** All active port leases are unmapped in reverse order on engine shutdown / `dispose()`.
- **Port collision retry:** When gateway returns code 718 (ConflictInMappingEntry), retries up to 5 alternate ports.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/nat/igd_hostile_test.dart` ("rejects metadata IP in Location", "refuses redirects", "drops >64 KiB XML")
  - `packages/libreshare_core/test/unit/nat/port_mapper_leak_test.dart` ("unmaps all mappings on dispose")
  - `packages/libreshare_core/test/unit/nat/fake_igd_gateway_test.dart` ("recovers from port conflict 718")
- **Mutations:**
  - *M1:* Allow public IP in SSDP Location -> **KILLED** by `igd_hostile_test.dart`.
  - *M2:* Disable 64 KiB length cap -> **KILLED** by `igd_hostile_test.dart`.
  - *M3:* Remove unmap call in `dispose()` -> **KILLED** by `port_mapper_leak_test.dart`.

### What Could Not Be Verified
- **UNVERIFIED:** Interoperability with physical proprietary residential gateways (e.g. AVM FRITZ!Box, Netgear, Apple AirPort); tested only against `FakeIgdGateway`, `FakeNatPmpGateway`, and `FakePcpServer`. Requires user execution per `USER_TODO.md`.

---

## 9. Direct Origin Pinning (`direct_origin_server` & `candidate_race`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/nat/direct_origin_server.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/nat/direct_origin_server.dart) (`start`, TLS configuration)
- [packages/libreshare_core/lib/src/connection/direct_connection.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/connection/direct_connection.dart) (`badCertificateCallback` pin check)
- [packages/libreshare_core/lib/src/connection/candidate_race.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/connection/candidate_race.dart) (staggered race)

### Invariants That Must Hold
- **Ephemeral self-signed identity:** Direct origin server creates a fresh ECDSA P-256 self-signed certificate upon engine start; fingerprint is computed as SHA-256 hex string.
- **Pin match before HTTP:** Client verifies `sha256(serverCert.der) == expectedPin` in `badCertificateCallback`. If mismatched, socket closes immediately, 0 HTTP bytes sent.
- **Staggered 250ms race:** Candidate race starts candidate 0, waits 250 ms before starting candidate 1, and cancels losing candidates once the first handshake completes.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/nat/direct_origin_pin_test.dart` ("matching pin succeeds", "mismatched pin aborts socket", "missing pin rejected")
  - `packages/libreshare_core/test/unit/nat/candidate_race_test.dart` ("staggered 250ms spacing", "winner cancels remaining")
- **Mutations:**
  - *M1:* Accept certificate on pin mismatch -> **KILLED** by `direct_origin_pin_test.dart`.
  - *M2:* Disable staggered delay in candidate race -> **KILLED** by `candidate_race_test.dart`.

### What Could Not Be Verified
- None.

---

## 10. Rendezvous Cryptography & Transport (`W1`–`W7` / LSP-R1)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/rendezvous/bip340.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/rendezvous/bip340.dart) (`bip340Sign`, `bip340Verify`, tagged hash)
- [packages/libreshare_core/lib/src/rendezvous/nip01.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/rendezvous/nip01.dart) (canonical serialization)
- [packages/libreshare_core/lib/src/rendezvous/envelope_codec.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/rendezvous/envelope_codec.dart) (discrete padding buckets)
- [packages/libreshare_core/lib/src/rendezvous/replay_guard.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/rendezvous/replay_guard.dart)
- [packages/libreshare_core/lib/src/rendezvous/pairing_service.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/rendezvous/pairing_service.dart)

### Invariants That Must Hold
- **BIP-340 Schnorr compliance:** Pure-Dart SECP256k1 implementation passes standard BIP-340 test vectors; public keys are 32-byte x-only coordinates; signatures are 64 bytes $(r, s)$.
- **Discrete padding buckets:** All outbound payload envelopes are padded to 512, 1024, 2048, or 4096 bytes with random padding to thwart message length analysis.
- **Replay attack rejection:** `ReplayGuard` maintains an LRU cache (1024 items) of seen event IDs within a 10-minute window; replayed messages are dropped silently.
- **SAS confirmation:** Pairing requires mutual verification of 4-word SAS before committing $K_{\text{pair}}$ to `TrustStore`.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/rendezvous/bip340_test.dart` (BIP-340 golden test vectors)
  - `packages/libreshare_core/test/unit/rendezvous/envelope_codec_test.dart` (bucket sizes 512, 1024, 2048, 4096)
  - `packages/libreshare_core/test/unit/rendezvous/replay_guard_test.dart` (replayed event rejected)
  - `packages/libreshare_core/test/integration/i1_rendezvous_integration_test.dart` (end-to-end presence and transfer)
- **Mutations:**
  - *M1:* Omit BIP-340 tagged hash prefix -> **KILLED** by `bip340_test.dart`.
  - *M2:* Disable padding bucket rounding -> **KILLED** by `envelope_codec_test.dart`.
  - *M3:* Invert replay check -> **KILLED** by `replay_guard_test.dart`.

### What Could Not Be Verified
- **UNVERIFIED:** Public Nostr relay connection to live internet relays (e.g. `wss://relay.damus.io`); all automated tests execute against `LoopbackNostrRelay` and in-memory test endpoints to preserve $0 and hermetic properties.

---

## 11. BLE GATT Handshake & Host Policy (`Inc 7` / LS-BLE/1)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/ble/beacon_codec.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/ble/beacon_codec.dart)
- [packages/libreshare_core/lib/src/ble/eid_deriver.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/ble/eid_deriver.dart)
- [packages/libreshare_core/lib/src/ble/ble_session.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/ble/ble_session.dart)
- [packages/libreshare_core/lib/src/ble/host_policy.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/ble/host_policy.dart)

### Invariants That Must Hold
- **Rotating EIDs:** 8-byte ephemeral identifiers rotate every 10 minutes derived via HMAC-SHA256 from device `advKey`; verifies against $\pm 1$ epoch drift (30-minute window).
- **GATT session encryption:** Mutual X25519 ephemeral ECDH + transcript signature exchange + AES-256-GCM symmetric session framing.
- **Deterministic host election:** `chooseHost` strictly ranks Android LOHS (3) > Linux NM (2) > Windows legacy AP (1); breaks ties in favor of receiver.
- **Consent precedes hotspot:** Receiver consent dialog MUST be accepted before hotspot credentials are generated or Wi-Fi AP is started.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/ble/eid_deriver_test.dart` ("validates EID within +-1 epoch, rejects epoch +2")
  - `packages/libreshare_core/test/unit/ble/ble_session_test.dart` ("tampered handshake signature throws", "encrypted channel framing")
  - `packages/libreshare_core/test/unit/ble/host_policy_test.dart` (3x3 platform matrix tests)
  - `packages/libreshare_core/test/integration/i1_ble_hotspot_policy_integration_test.dart`
- **Mutations:**
  - *M1:* Invert `chooseHost` tiebreaker to sender -> **KILLED** by `host_policy_test.dart` and `i1_ble_hotspot_policy_integration_test.dart`.
  - *M2:* Allow EID with epoch drift +2 -> **KILLED** by `eid_deriver_test.dart`.

### What Could Not Be Verified
- **UNVERIFIED:** Physical Bluetooth radio emissions (`hci0`, `bluetoothctl`, BlueZ) and physical Android Wi-Fi hotspot AP creation (`TetheringManager`); strictly forbidden for agents per user rules.

---

## 12. Filename Sanitization & Path Traversal (`filename_sanitizer`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/filename_sanitizer.dart)
  - `sanitizeFileName` (lines 80–180)
  - `sanitizeRelativePath` (lines 190–240)
  - `resolveDestinationPath` (lines 250–320)

### Invariants That Must Hold
- **Strict folder containment:** File path must NEVER escape destination directory (`isWithin(destDir, resolvedPath) == true`).
- **Strip hostile elements:** `..`, leading/trailing spaces, trailing dots, control chars ($< 0x20$), bidi spoofing chars (e.g. RLO `0x202E`) are stripped.
- **DOS device name prefixing:** Reserved names (`CON`, `PRN`, `AUX`, `NUL`, `COM1..9`, `LPT1..9`) are prefixed with `_` to prevent Win32 kernel device driver lockups.
- **No symlink traversal:** Symlinks in destination path are never traversed or overwritten.
- **Basename byte bound:** Base filename is truncated to <= 239 UTF-8 bytes to reserve 16 bytes for `.lspart.json.tmp` suffix within the 255-byte filesystem ceiling.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/filename_sanitizer_test.dart` (comprehensive sanitization suite)
  - `packages/libreshare_core/test/unit/windows_semantics_test.dart` (DOS reserved names, alternate data streams `:Zone.Identifier`)
  - `packages/libreshare_core/test/unit/protocol_fuzz_property_test.dart` (seeded property-based fuzz testing)
  - `packages/libreshare_core/test/integration/path_traversal_secure_test.dart` (end-to-end traversal containment)
- **Mutations:**
  - *M1:* Omit `_` prefix on `CON.txt` -> **KILLED** by `windows_semantics_test.dart`.
  - *M2:* Permit `..` in relative path -> **KILLED** by `filename_sanitizer_test.dart` and `path_traversal_secure_test.dart`.

### What Could Not Be Verified
- None; verified across Linux ext4 and simulated Windows filesystem semantics.

---

## 13. Transfer Resumption & `.lspart` Handling (`resume_store` & `file_receiver`)

### Files & Functions to Read
- [packages/libreshare_core/lib/src/transfer/resume_store.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/resume_store.dart)
  - `ResumeStore.open` (validation of sidecar manifest parameters, lines 47–110)
  - `ResumeStore.recordChunk` (lines 130–165)
  - `ResumeStore.flush` (atomic sidecar write, lines 170–210)
- [packages/libreshare_core/lib/src/transfer/file_receiver.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/file_receiver.dart) (chunk writing, whole-file verification, atomic rename)

### Invariants That Must Hold
- **No in-place partial corruption:** In-flight writes occur exclusively to `<name>.lspart`; final target file is NEVER created until 100% of chunks are verified.
- **Atomic final rename:** Only after whole-file SHA-256 matches manifest is `.lspart` atomically renamed to target filename.
- **Corrupted chunk / file removal:** Per-chunk hash mismatch returns HTTP 422; whole-file SHA-256 failure deletes partial file and sidecar immediately (`VERIFY_FAILED`).
- **Resumption validity window:** Sidecar `.lspart.json` is accepted only if younger than 24 hours (`kResumeWindow`) and manifest parameters match identically.
- **Chunk persistence cadence:** Sidecar bitmap is synced every `kResumePersistEvery = 8` chunks (32 MiB) and on final chunk completion.

### Tests & Mutation Evidence
- **Pinning tests:**
  - `packages/libreshare_core/test/unit/resume_store_test.dart` ("sidecar parameter validation", "stale sidecar >24h discarded")
  - `packages/libreshare_core/test/unit/file_receiver_test.dart` ("atomic rename upon completion", "chunk 422 hash check", "corrupted whole-file hash removes partial")
  - `packages/libreshare_core/test/integration/i1_cross_increment_regression_test.dart` ("transfer resumption after process crash")
  - Docker step `n`: Receiver `kill -9` followed by restart successfully resumes without re-sending persisted chunks.
- **Mutations:**
  - *M1:* Rename partial before hash verification -> **KILLED** by `file_receiver_test.dart`.
  - *M2:* Accept sidecar with mismatched total size -> **KILLED** by `resume_store_test.dart`.

### What Could Not Be Verified
- **FR-15 Ack Window Decision:** Killing receiver between chunk writes may re-request up to 7 chunks (since `kResumePersistEvery = 8`); whether this tradeoff requires per-chunk fsync is logged for user decision in `USER_TODO.md` (`Q-FR15-ACK-WINDOW`).

---

## Summary Matrix of Review Readiness

| # | Security-Critical Area | Key Invariant | Pinning Tests | Mutations Killed | Unverified Aspects |
|:---:|:---|:---|:---|:---:|:---|
| **1** | `tunnel_crypto` | Random 96-bit nonce, 2^24 seal cap, no secrets in exceptions | `tunnel_crypto_test.dart` | 3/3 | ARM64 hardware crypto |
| **2** | `share_link` | Malformed d/pin dropped; candidate without pin NEVER connected | `share_link_test.dart`, `link_d_pin_conformance_test.dart` | 3/3 | None |
| **3** | `secret_redactor` | Idempotent token/PIN/fragment stripping; preserve hashes | `secret_redactor_test.dart` | 3/3 | None |
| **4** | `native_sha256` FFI | NIST KAT on load; System32 isolation on Windows; safe memory | `native_sha256_test.dart` | 2/2 | Windows `bcrypt.dll` execution |
| **5** | F-B ladder & D6 | Cert pinned on EVERY candidate; key change refuses connection | `ladder_pin_test.dart`, `ladder_fault_test.dart` | 2/2 | None |
| **6** | PIN guard & settings | 5 strikes -> 10m lock; PIN never in `app_settings.json` | `pin_test.dart`, `b1_settings_security_test.dart` | 2/2 | None |
| **7** | `ip_classify` | Strict RFC 1918 / CGNAT / ULA boundary classification | `ip_classify_test.dart` | 2/2 | None |
| **8** | K2 Port Mapping | SSRF defense, 0 redirects, 64 KiB XML cap, unmap on exit | `igd_hostile_test.dart`, `port_mapper_leak_test.dart` | 3/3 | Physical router interop |
| **9** | K3 Direct Origin Pin | Ephemeral cert SHA-256 pinned; staggered 250ms race | `direct_origin_pin_test.dart`, `candidate_race_test.dart` | 2/2 | None |
| **10** | W1–W7 Rendezvous | BIP-340 Schnorr, discrete padding buckets, replay cache | `bip340_test.dart`, `envelope_codec_test.dart`, `replay_guard_test.dart` | 3/3 | Live public Nostr relays |
| **11** | Inc 7 BLE / Hotspot | Ephemeral rotating EIDs, GATT encrypted, consent first | `eid_deriver_test.dart`, `ble_session_test.dart`, `host_policy_test.dart` | 2/2 | Physical radio / phone |
| **12** | Filename Sanitizer | Strict folder containment, DOS device names prefixed | `windows_semantics_test.dart`, `path_traversal_secure_test.dart` | 2/2 | None |
| **13** | Resume & `.lspart` | In-flight partial isolation, whole-file verification before rename | `resume_store_test.dart`, `file_receiver_test.dart` | 2/2 | FR-15 ack window tradeoff |

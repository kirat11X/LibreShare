# Draft LSP-1 Section 4.5: Internet Tunnel & Link Pull Transfers

## 4.5.1 End-to-End Encryption Specification

All tunnel transfers use end-to-end AEAD encryption (AES-256-GCM) with key separation via HKDF-SHA256 (RFC 5869).

### 1. Key Derivation
- Sender generates a 256-bit random root key $k \leftarrow \text{Random.secure()}$.
- $k$ is transmitted exclusively within the link fragment (e.g. `https://host/r#...&k=...` or `libreshare://r?...&k=...`) and is never sent across HTTP request paths, query strings, or headers.
- Subkeys are expanded under the salt `"LSP1-TUN-v1"`:
  ```
  prk      = HKDF-Extract(salt = "LSP1-TUN-v1", ikm = k)
  shareId  = HKDF-Expand(prk, "sid", 16)           // derived identifier (UUID format)
  kMan     = HKDF-Expand(prk, "manifest", 32)      // sealed manifest encryption
  kData    = HKDF-Expand(prk, "data", 32)          // chunk payload encryption
  kAck     = HKDF-Expand(prk, "ack", 32)           // receiver -> sender ack encryption
  ```

### 2. Random 96-Bit Nonces & Wire Framing
Every sealed payload on the wire consists of:
$$\text{wire} = \text{nonce}_{12} \parallel \text{ciphertext} \parallel \text{tag}_{16}$$
- A fresh, uniformly random 12-byte nonce is drawn for every seal.
- Nonces are never deterministic or counter-based.
- Seal cap: Maximum $2^{24}$ seals per key $k$; exceeding this budget throws `sealCapReached`.

### 3. Canonical Associated Authenticated Data (AAD)
The AAD strictly binds message purpose, share ID, file position, and chunk length:
```
AAD = "LSP1" (4 ASCII)
      || purpose (1 byte: 1=manifest, 2=chunk, 3=ack)
      || shareId (16 bytes)
      || uint32_be(fileIndex)
      || uint64_be(chunkIndex)
      || uint64_be(plaintextLen)
```
- Manifest uses `fileIndex = 0xFFFFFFFF`, `chunkIndex = 0`.
- Final ack uses `fileIndex = 0xFFFFFFFF`, `chunkIndex = 0`.

### 4. Claim Header & Short Authentication String (SAS)
- The receiver generates a 128-bit random claim string and passes it via `X-LS-Claim`.
- Both parties can display a 6-digit SAS code:
  $$\text{SAS} = \text{uint32\_be}(\text{HKDF-Expand}(prk, \text{"sas"} \parallel \text{claim}, 4)) \pmod{10^6}$$

---

## 4.5.2 Origin Route Table & Semantics

| Route | Method | Purpose | Response / Status |
|---|---|---|---|
| `/t/{token}` | `GET` | Static HTML landing page (for browser/bot clicks, no side effects) | `200 OK`, `text/html; charset=utf-8` |
| `/t/{token}/manifest` | `GET` | Sealed manifest payload | `200 OK`, `application/octet-stream`<br>`401` (missing/invalid claim)<br>`409` (claim conflict)<br>`410` (expired/revoked) |
| `/t/{token}/f/{fid}/c/{i}` | `GET` | Sealed chunk payload (chunk $i$ of file $fid$) | `200 OK`, `application/octet-stream`<br>`429` (concurrency limit reached)<br>`410` (budget exceeded/revoked) |
| `/t/{token}/ack` | `POST` | Sealed chunk ack or verified final ack | `200 OK` / `204 No Content`<br>`400` / `401` (invalid ack) |

### Required Security Headers on All Responses:
- `Cache-Control: no-store`
- `Referrer-Policy: no-referrer`
- `X-Content-Type-Options: nosniff`

---

## 4.5.3 Concurrency & Protection Limits
- Maximum 8 concurrent in-flight requests per token.
- Maximum 32 total concurrent in-flight requests across all origin tokens.
- 60-second write timeout per chunk stream.
- Hard byte budget: $2 \times \text{totalSize} \times \text{maxReceivers}$. Exceeding budget revokes the share immediately ($410\text{ Gone}$).

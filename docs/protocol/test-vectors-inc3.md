# LSP/1.1 test vectors (Increment 3)

Status: published by the crypto package (P1), asserted by tests, consumed by `docs/protocol/LSP-1.md` (4.3.6, 5.1, 5.3) and `test/conformance/lsp11_conformance_test.dart`. Every value below is asserted byte for byte by a unit test, and each was **also reproduced independently** of the Dart code with Python `hashlib`/`hmac`, the Python `cryptography` package (X.509 parsing, self-signature, HKDF) and `openssl` 3.6 (`openssl dgst -sha256 -sign ... -sigopt nonce-type:1`, RFC 6979 deterministic ECDSA). Encodings: hex is lowercase unless a fingerprint (uppercase, LSP-1 0.2); base64url is unpadded.

## 0. Determinism

**All signatures in this file are deterministic.** The production signer (`KeyIdentity.sign`, `p256SignRaw`) is ECDSA P-256 / SHA-256 with RFC 6979 nonces, so a fixed key and a fixed signed text always give the same 64 bytes (`r || s`, 32 bytes each, big-endian). The published signature values are therefore reproducible, not merely verifiable. Verifiers must accept any valid signature (other implementations may randomise the nonce), so a conformance test checks both "reproduces the vector" (only for the Dart signer) and "verifies the vector" (for everybody). Certificates built by `identityFromScalar` are deterministic as well (fixed key, serial and clock), because the certificate signature uses the same RFC 6979 signer.

## 1. Signed bytes and domain labels

Every signature and MAC covers `label || 0x00 || message` (UTF-8 label, one NUL byte). Labels (contracts `SigDomain`): `LSP1-AUTH-v1`, `LSP1-SAS-C`, `LSP1-SAS-V`, `LSP1-BYE`, `LSP1-PAIR-REQ`, `LSP1-PAIR-ACK`, and the HKDF `info` prefix `LSP-R1 pair` (no NUL after this one, see section 5). Fingerprints enter every hash, MAC and signed text as their **64 ASCII characters in uppercase hex**, never as raw bytes. `min`/`max` compare those strings.

Decisions taken where the plan was ambiguous (also reported to the orchestrator):

1. The plan writes the signed auth text as `"LSP1-AUTH-v1\n"+METHOD+...`. The contract makes the separator after a label a NUL for every signature, so the label is **not** repeated: the signed bytes are `"LSP1-AUTH-v1" 0x00 M` with `M = METHOD LF target LF hex(SHA-256(body)) LF ts LF nonce LF serverFp LF clientFp` (this matches LSP-1 4.3.6).
2. `METHOD` is upper-cased by both sides.
3. `target` must start with `/` and consist of 1..2048 printable ASCII characters (0x21..0x7E); anything else is refused (`malformed`), so a field separator can never be smuggled into the signed text.
4. `AuthFailure.serverFingerprintMismatch` exists in the enum but is never returned: the header does not carry the server fingerprint, so a proof signed for another server is indistinguishable from a forged one and is reported as `badSignature`. Both answer 401 AUTH_INVALID.
5. The replay key is `clientFp "/" nonce`, remembered only after the signature verified.

## 2. HKDF-SHA-256 (RFC 5869 appendix A) and HMAC-SHA-256 (RFC 4231)

`hkdfSha256(ikm, salt, info, length)`; an empty salt means 32 zero bytes (RFC 5869 2.2). Output length 1..8160.

| Case | IKM | salt | info | L | OKM |
|---|---|---|---|---|---|
| A.1 | `0b` x 22 | `000102030405060708090a0b0c` | `f0f1f2f3f4f5f6f7f8f9` | 42 | `3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865` |
| A.3 | `0b` x 22 | empty | empty | 42 | `8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8` |

(A.2 is in `test/unit/crypto_primitives_test.dart`.) HMAC-SHA-256: key `0b` x 20, data `Hi There` gives `b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7`.

## 3. X-LS-Auth (LSP-1 4.3.6)

### 3.1 Inputs

| Item | Value |
|---|---|
| Client private key `d` (the RFC 6979 A.2.5 test key; public, never use for anything real) | `c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721` |
| Client public point | `04 60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6 7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299` |
| `deviceId` / certificate CN | `ls-vector-client` |
| Certificate | built by `identityFromScalar(deviceId: 'ls-vector-client', privateScalar: d, now: 2026-11-04T12:00:00Z, serial: 0x0102030405060708090a0b0c0d0e0f)` (so notBefore 2026-11-03T12:00:00Z, notAfter 2036-11-01T12:00:00Z), 363 bytes |
| Client fingerprint `clientFp` | `8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D0438` |
| Server fingerprint `serverFp` (the cert the client saw in the TLS handshake) | `F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD` |
| Method | `POST` |
| Target | `/api/v1/sessions` |
| Body (17 bytes) | `{"hello":"world"}` |
| `hex(SHA-256(body))` | `93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588` |
| `ts` (2026-11-04T12:00:05Z) | `1793793605000` |
| Nonce (16 bytes) | `202122232425262728292a2b2c2d2e2f` = `ICEiIyQlJicoKSorLC0uLw` |

Certificate DER (hex):

```
308201673082010ea003020102020f0102030405060708090a0b0c0d0e0f300a06082a8648ce3d040302301b31193017
06035504030c106c732d766563746f722d636c69656e74301e170d3236313130333132303030305a170d333631313031
3132303030305a301b3119301706035504030c106c732d766563746f722d636c69656e743059301306072a8648ce3d02
0106082a8648ce3d0301070342000460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb679
03fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299a3353033300c0603551d130101ff040230
00300e0603551d0f0101ff04040302078030130603551d25040c300a06082b06010505070301300a06082a8648ce3d04
030203470030440220608155e0edc2a136d45124064e70e2fee5d0c61406f74349f138609fc0d6277c022042e672d9ec
170d8c6f19bb482bc33298c3d4b9c4b53a1f7755eb6ef8f8415589
```

Certificate PEM:

```
-----BEGIN CERTIFICATE-----
MIIBZzCCAQ6gAwIBAgIPAQIDBAUGBwgJCgsMDQ4PMAoGCCqGSM49BAMCMBsxGTAX
BgNVBAMMEGxzLXZlY3Rvci1jbGllbnQwHhcNMjYxMTAzMTIwMDAwWhcNMzYxMTAx
MTIwMDAwWjAbMRkwFwYDVQQDDBBscy12ZWN0b3ItY2xpZW50MFkwEwYHKoZIzj0C
AQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Z5
A/4QCLi8maQa6elWKLxk8vGyDC1+n1F3o8KU1EYimaM1MDMwDAYDVR0TAQH/BAIw
ADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCgYIKoZIzj0E
AwIDRwAwRAIgYIFV4O3CoTbUUSQGTnDi/uXQxhQG90NJ8Thgn8DWJ3wCIELmctns
Fw2Mbxm7SCvDMpjD1LnEtTofd1Xrbvj4QVWJ
-----END CERTIFICATE-----
```

### 3.2 Signed text

`M` (LF shown as `\n`):

```
POST\n/api/v1/sessions\n93a23971a914e5eacbf0a8d25154cda309c3c1c72fbb9914d47c60f3cb681588\n1793793605000\nICEiIyQlJicoKSorLC0uLw\nF257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD\n8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D0438
```

Signed bytes (`"LSP1-AUTH-v1" 0x00 M`, hex):

```
4c5350312d415554482d763100504f53540a2f6170692f76312f73657373696f6e730a39336132333937316139313465
356561636266306138643235313534636461333039633363316337326662623939313464343763363066336362363831
3538380a313739333739333630353030300a494345694979516c4a69636f4b536f724c4330754c770a46323537454538
374637423731413141343935423430363939434635414144303442363638413241354336383430363243354235384435
4546423936343244440a3832373941464433344544374141313632443842303431303146353737373838424334454532
3136433738313631323931323545344543423044364430343338
```

Signature `r || s` (64 bytes, hex):

```
db1bedec5ec41b144d9482ecedd45d2b874dbf4789e29ead460b7fb859d22705a78b7a61555afc9e2415c1d556b88507d6d4941bf43016a4b886059ed4097d6f
```

### 3.3 The header (611 characters)

```
v1.MIIBZzCCAQ6gAwIBAgIPAQIDBAUGBwgJCgsMDQ4PMAoGCCqGSM49BAMCMBsxGTAXBgNVBAMMEGxzLXZlY3Rvci1jbGllbnQwHhcNMjYxMTAzMTIwMDAwWhcNMzYxMTAxMTIwMDAwWjAbMRkwFwYDVQQDDBBscy12ZWN0b3ItY2xpZW50MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Z5A_4QCLi8maQa6elWKLxk8vGyDC1-n1F3o8KU1EYimaM1MDMwDAYDVR0TAQH_BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCgYIKoZIzj0EAwIDRwAwRAIgYIFV4O3CoTbUUSQGTnDi_uXQxhQG90NJ8Thgn8DWJ3wCIELmctnsFw2Mbxm7SCvDMpjD1LnEtTofd1Xrbvj4QVWJ.1793793605000.ICEiIyQlJicoKSorLC0uLw.2xvt7F7EGxRNlILs7dRdK4dNv0eJ4p6tRgt_uFnSJwWni3phVVr8niQVwdVWuIUH1tSUG_QwFqS4hgWe1Al9bw
```

Verification with `now` = `ts` (or within +-120 s), `ownFingerprint` = `serverFp`, method `POST`, target `/api/v1/sessions`, the same body, an empty nonce cache: accepted, peer fingerprint `clientFp`, deviceId `ls-vector-client`. Changing the method, the target, any body byte, `serverFp`, or `now` by more than 120 s makes it fail (`badSignature`, `badSignature`, `badSignature`, `badSignature`, `stale`). A second verification with the same cache fails with `replayed`.

## 4. SAS commit and code (LSP-1 5.1)

Fingerprints: `fpS = SHA-256("LibreShare Inc3 test vector: sender certificate")`, `fpR = SHA-256("... receiver certificate")`, `fpM = SHA-256("... mitm certificate")`, each uppercase hex:

| | |
|---|---|
| `fpS` | `AE91A910C4E3D642640BD9CCFCBD18A6BB2ACF0091BEFFF1D7BD56C437F99EFF` |
| `fpR` | `F257EE87F7B71A1A495B40699CF5AAD04B668A2A5C684062C5B58D5EFB9642DD` |
| `fpM` | `0ABECAEB9C5DD717D0F2184B2B615F1D497EDACFE6A3FC459E298E4D2818FCDB` |
| `Ns` | `000102030405060708090a0b0c0d0e0f` (b64url `AAECAwQFBgcICQoLDA0ODw`) |
| `Nr` | `101112131415161718191a1b1c1d1e1f` (b64url `EBESExQVFhcYGRobHB0eHw`) |

`commit = b64url(SHA-256("LSP1-SAS-C" 0x00 || Ns || fpS || fpR'))` (fingerprints as 64 ASCII characters; 16 + 64 + 64 input bytes after the label):

| Case | commit (43 chars) |
|---|---|
| `fpR' = fpR` (honest) | `xVsm4yPtHTjhd4VytGITnQbYj6JcNg9e9N07JsZVscs` |
| `fpR' = fpM` (the sender saw a MITM certificate) | `l7DGyZO5eoGq8RPyF3MDvTfy1LN_4YESPyFCht7WJu4` |

`code = u32_be(SHA-256("LSP1-SAS-V" 0x00 || Ns || Nr || min(fpA,fpB) || max(fpA,fpB))[0..4]) mod 10^6`, zero-padded to six digits, symmetric in `fpA`/`fpB`:

| Ns | Nr | fpA, fpB | code | shown as |
|---|---|---|---|---|
| `00..0f` | `10..1f` | `fpS`, `fpR` (either order) | `060044` | `060 044` |
| `00..0f` | `10..1f` | `fpS`, `fpM` | `078646` | `078 646` |
| `00..0f` | `a0` x 15 then `60` | `fpS`, `fpR` | `002408` | `002 408` |
| `00..0f` | `b0` x 15 then `09` | `fpS`, `fpR` | `090751` | `090 751` |

A receiver that recomputes the commit with its own fingerprint `fpR` from the honest `Ns` accepts the first commit and rejects the second.

## 5. Pairing (LSP-1 5.3)

A is the inviter (`fpA = fpR` above), B the scanner (`fpB = fpS` above).

| Item | Value |
|---|---|
| `S` (32 bytes) | `404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f` = `QEFCQ0RFRkdISUpLTE1OT1BRUlNUVVZXWFlaW1xdXl8` (the `s=` value, 43 chars) |
| `nA` | `606162636465666768696a6b6c6d6e6f` |
| `nB` | `707172737475767778797a7b7c7d7e7f` |

| Value | Construction | Result |
|---|---|---|
| `PairRequest.mac` | `HMAC-SHA256(S, "LSP1-PAIR-REQ" 0x00 \|\| fpB \|\| fpA \|\| nB)` | hex `a4af9b3626dec060bc129302b38429c5e2a95278529ea944b9a710503fe18b67`, b64url `pK-bNibewGC8EpMCs4QpxeKpUnhSnqlEuacQUD_hi2c` |
| `PairResponse.mac` | `HMAC-SHA256(S, "LSP1-PAIR-ACK" 0x00 \|\| fpA \|\| fpB \|\| nA \|\| nB)` | hex `da859a48862641fdf686a481a241f055d1bfa7cf419db45ad1a111a16b6134af`, b64url `2oWaSIYmQf32hqSBokHwVdG_p89BnbRa0aERoWthNK8` |
| `K_pair` | `HKDF-SHA256(ikm=S, salt=nA \|\| nB, info="LSP-R1 pair" \|\| min(fpA,fpB) \|\| max(fpA,fpB), L=32)`, `info` is the 11 ASCII characters of the label followed directly by the two 64-character fingerprints (no NUL) | hex `03e8c2507e0048b521fad8c05766fb7a5d218c723f91f161d1c4ec58d52af0ff`, b64url `A-jCUH4ASLUh-tjAV2b7el0hjHI_kfFh0cTsWNUq8P8` |

The MAC messages are the fingerprints as ASCII (64 characters each) followed by the raw nonce bytes. `K_pair` is the value Increment 6 must reproduce.

## 6. Goodbye datagram signature (LSP-1 4.2 rule 9)

Signer: the client of section 3 (`ls-vector-client`). Text = `deviceId` + `fingerprint` + `ts` as UTF-8 without separators, `ts` as decimal milliseconds; signed bytes are `"LSP1-BYE" 0x00 text`.

| | |
|---|---|
| `ts` | `1793793600000` |
| text | `ls-vector-client8279AFD34ED7AA162D8B04101F577788BC4EE216C7816129125E4ECB0D6D04381793793600000` |
| signature (hex) | `a810c850c55ddb86be8ade8f00ef9f1e2ec668d93a527b3de7f7474b3d99d18b8436432ad9a087c2e94e63c2f32b7e28dd6fc62ce43831d8a50b85a61c12969d` |
| `sig` member (b64url, 86 chars) | `qBDIUMVd24a-it6PAO-fHi7GaNk6Uns95_dHSz2Z0YuENkMq2aCHwulOY8LzK34o3W_GLOQ4MdilC4WmHBKWnQ` |

The same signature does **not** verify under the domain `LSP1-AUTH-v1` (asserted).

## 7. Where each vector is asserted

| Section | Test |
|---|---|
| 2 | `test/unit/crypto_primitives_test.dart` (HKDF, HMAC) |
| 3, 6 | `test/unit/identity_proof_test.dart` group `known_answer_vector` |
| 4 | `test/unit/sas_test.dart` (`known_answer_vectors`), `test/security/sas_binding_test.dart` |
| 5 | `test/unit/crypto_primitives_test.dart` group `pairing known-answer vectors` |
| P-256 / RFC 6979 base case | `test/unit/cert_factory_test.dart` (RFC 6979 A.2.5: key `d` above, message `sample`, `r = efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716`, `s = f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8`) |

## 8. Reproducing independently

```bash
# signed bytes of section 3.2 -> /tmp/m.bin, then (key from the RFC 6979 test vector, PKCS#8 PEM):
openssl dgst -sha256 -sign key.pem -sigopt nonce-type:1 -out sig.der /tmp/m.bin   # RFC 6979 deterministic
# convert the DER (r, s) to 32+32 raw bytes and compare with section 3.2
python3 -c "import hashlib; print(hashlib.sha256(b'abc').hexdigest())"            # sanity
```

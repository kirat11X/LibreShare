# Increment 3 spikes S-A, S-B, S-C (crypto core, package P1)

Date: 2026-11-04. Host: Linux x86_64 (Fedora), Intel i7-13650HX (20 threads), Dart 3.13.7 (stable) on `linux_x64`, `pointycastle` 4.0.0, OpenSSL 3.6.0 (`/home/kirat/miniconda3/bin/openssl`), Python 3.13 with `cryptography` 46.0.3 (used only as an independent oracle). Everything here is free software run locally; no network was used.

How the spikes were run: throw-away Dart programs in the session scratch directory (not part of the repository), with certificates made by `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes ... -days 3650 -addext basicConstraints=critical,CA:FALSE -addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=serverAuth,clientAuth` (subject `CN=server` / `CN=client`, no SAN). The decisive checks were then turned into permanent tests (listed per spike) that use certificates from `generateIdentity`, so the results below are re-proven on every `dart test` run on a machine with `openssl` (those tests skip with reason `openssl missing` otherwise).

## S-A: does a server that requests client certificates reject an untrusted self-signed client certificate?

**Answer: yes, at the handshake. TLS client certificates cannot do first-contact authentication in `dart:io`. Decision D1 stands, no replan.**

Setup: server `SecurityContext(withTrustedRoots: false)` with its own certificate and TLS 1.3 minimum, no client trust anchors; client presents `client.cert.pem` (self-signed, not trusted by the server) and accepts the server with `onBadCertificate`/`badCertificateCallback` returning true.

| Case | Client sees | Server sees |
|---|---|---|
| `SecureServerSocket.bind(requestClientCertificate: true)` | `SocketException: Broken pipe` | accept error `HandshakeException: Handshake error in server (OS Error: CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate(handshake.cc:319))`; no connection delivered |
| `SecureServerSocket.bind(requestClientCertificate: true, requireClientCertificate: true)` | `SocketException` | same `HandshakeException` |
| `HttpServer.bindSecure(requestClientCertificate: true)` | `HttpException: Connection reset by peer` | handler never ran (0 requests) |
| Control: same HTTP server, client presents NO certificate | `200 "hello"` | handled, `request.certificate == null` |
| Control: `requestClientCertificate: false`, client presents the certificate | `200` | handled, `request.certificate == null` |
| Control: client certificate signed by a test CA, CA in the server trust store (the SDK test's shape) | `200` | handled, `request.certificate` present |
| Control: same CA-signed client certificate, CA not trusted | `HttpException` | 0 requests |

Two extra findings that make the plan's rejected option (a) (true mTLS with pre-trusted client certificates) worse than assumed:

* A **self-signed client certificate placed in the server's trust store as its own anchor is refused too** (`setTrustedCertificatesBytes(clientCert)`, with and without `setClientAuthorities`): same `unable to get local issuer certificate`. Reproduced both with the `openssl` client certificate and with a certificate from `generateIdentity` (client `HttpException`, server handled 0 requests). So even pairing contacts could not be made to work by adding their certificates to the trust set; only a private CA could.
* Presenting a client certificate is only attempted when the server asks; a server that does not ask (our listener) accepts the same client and sees no certificate. `openssl s_client` against our listener prints `No client certificate CA names sent` (asserted in `test/security/tls_identity_test.dart`).

Not run: Android and Windows servers (same BoringSSL code path in the Dart VM, not verified there).

Permanent tests: `test/security/tls_identity_test.dart` (`the server never asks for a client certificate`).

## S-B: certificate and TLS behaviour of `dart:io` with a no-SAN self-signed P-256 certificate

| Question | Result |
|---|---|
| Does `SecurityContext.usePrivateKeyBytes` accept a PKCS#8 EC PEM? | **Yes**, for the `openssl` key and for the key written by `encodePkcs8PrivateKeyPem` (PrivateKeyInfo with `id-ecPublicKey`/`prime256v1`, ECPrivateKey with embedded public key, PEM label `PRIVATE KEY`). No SEC1 fallback was needed. |
| Does a `HttpClient` with `withTrustedRoots: false` call `badCertificateCallback` for a no-SAN certificate when connecting by IP (`127.0.0.1`)? | **Yes.** With nothing trusted, the callback ran for every connection (observed twice per connection in the untrusted case, so the callback must be cheap and idempotent) and the control without a callback fails with `HandshakeException`. With the server certificate placed in the client trust store, the callback still ran once (host/IP verification fails for a certificate without SAN), so a pinned design cannot rely on chain validation anyway. |
| Is `X509Certificate.der` populated? | **Yes.** Length 424 for the `openssl` certificate; for a `generateIdentity` certificate the bytes equal `identity.certDer` exactly, and `certificateMatchesPin` (SHA-256 of `der`) equals `identity.fingerprint`. The host passed to the callback is `127.0.0.1`. |
| Does `minimumTlsProtocolVersion: tls1_3` refuse a TLS 1.2-only client? | **Yes.** `openssl s_client -tls1_2` against our listener: exit 1, `New, (NONE), Cipher is (NONE)`, the HTTP handler never ran. Control: the same certificate on a listener without the floor negotiates TLS 1.2 (`ECDHE-ECDSA-AES256-GCM-SHA384`, `Protocol: TLSv1.2`, exit 0). `openssl s_client -tls1_3` against our listener: `Protocol: TLSv1.3`, `TLS_AES_256_GCM_SHA384`, and the request is served. |
| Does the client floor work too? | **Yes.** A Dart client built with `buildClientContext()` against `openssl s_server -tls1_2` fails with `HandshakeException ... TLSV1_ALERT_PROTOCOL_VERSION`; against `openssl s_server -tls1_3` it connects (status 200). |
| Do `openssl x509 -text -noout` and `openssl verify` accept the generated certificate? | **Yes.** `x509 -text`: Version 3, `ecdsa-with-SHA256`, `Issuer`/`Subject: CN=<deviceId>`, `Public-Key: (256 bit)`, `prime256v1`, `CA:FALSE`, `Digital Signature`, `TLS Web Server Authentication`, no `Subject Alternative Name`, validity exactly now-24 h / now+3650 d. `openssl x509 -fingerprint -sha256` equals our fingerprint. `openssl verify -no-CAfile -no-CApath -check_ss_sig -trusted cert.pem cert.pem` prints `OK` (a self-signed leaf needs `-trusted`; plain `-no-CAfile` alone has nothing to anchor on). `openssl pkey -check` accepts the key and its `-pubout` equals the certificate's `-pubkey`. A deterministic signature from `p256SignRaw` verifies with `openssl dgst -sha256 -verify`. |
| Is the certificate parsed identically by an independent library? | Python `cryptography` 46.0.3 loads the vector certificate (CN, serial, `ecdsa-with-SHA256`, BasicConstraints and KeyUsage critical, EKU non-critical) and verifies its self-signature. |

Not run / unverified: TLS 1.3 enforcement on **Android and Windows** (the check above is the Linux VM only; the plan's test `downgrade_test.tls12_only_client_refused` should be repeated in CI on those platforms); behaviour of macOS/iOS (not a target).

Permanent tests: `test/security/tls_identity_test.dart` (pin accepted/refused, expired certificate accepted when pinned, TLS 1.2 refused with differential control, client floor against `openssl s_server`), `test/unit/cert_factory_test.dart` group `openssl oracle`.

Note on the first full-suite run of `tls_identity_test.dart` by another agent: two `TLS version floor` tests were red at that moment because the first version of the test expected a body from `openssl s_client`/`s_server -www`, which never terminates (an artefact of the oracle program, not of our TLS). The tests now check the handshake and the served request instead and are green (15/15, three consecutive runs).

## S-C: pointycastle 4.0.0 timings

Budgets from D2: key generation <= 500 ms, sign <= 50 ms, verify <= 100 ms. **All met by a wide margin on this machine.**

Primitives (`ECKeyGenerator` + Fortuna, `SHA-256/DET-ECDSA` signer, `SHA-256/DET-ECDSA` verifier, 300-byte message; `dart run` = JIT, `dart compile exe` = AOT; milliseconds):

| | JIT | AOT |
|---|---|---|
| key generation (n=10) | min 6, median 9, max 42 (first call includes warm-up) | min 5, median 6, max 7 |
| sign (n=20) | min 6.1, median 6.4, max 14.8 | min 6.1, median 6.2, max 6.6 |
| verify (n=20) | min 9.1, median 9.3, max 11.1 | min 9.2, median 9.3, max 10.2 |

Production code path (`dart compile exe` of a benchmark that calls the shipped functions; milliseconds, medians):

| Operation | JIT | AOT |
|---|---|---|
| `generateIdentity` (key + certificate + PKCS#8) | 20.4 | 19.4 |
| `KeyIdentity(...)` (strict parse, self-signature check, key/cert match) | 22.1 | 22.0 |
| `buildAuthHeader` (one signature) | 6.4 | 6.5 |
| `verifyAuthHeader` (certificate parse + one verification) | 9.6 | 9.6 |
| SHA-256 of a 4 MiB body (D11 body hashing for `POST /sessions`) | 54.7 | 37.6 |

Mitigation from D2 (sign once per session, cache verified proofs): **not needed** on this evidence. Per-request cost of the proof is about 6.5 ms to sign and 9.6 ms to verify. The body hash dominates for the largest allowed manifest (4 MiB, about 40-55 ms).

Not run: a **mid-range Android phone** (no Android SDK or device here). The measured numbers leave a factor of about 8 for signing (50 ms budget / 6.5 ms) and about 10 for verification before a budget is exceeded; a phone slower than that would exceed them, and then the D2 mitigation applies. This must be measured on the first Android build (the same benchmark compiles as a plain Dart AOT or a Flutter profile run).

Known limitation, not a budget issue: pointycastle does scalar multiplication on `BigInt`, which is not constant time. Signing and key generation therefore leak timing to an attacker who can run code on the same machine or measure repeated signing on it; the threat model (LAN peers that only see responses over TLS) does not include that, and RFC 6979 signing needs no RNG. If this is later judged unacceptable, the replacement is an FFI/native P-256 (rejected for Inc 3 in D2).

## Other results worth keeping

* **RFC 6979 is available and exact.** `ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))` reproduces the RFC 6979 A.2.5 known answer (P-256, SHA-256, message `sample`: `r = efd48b2a...3716`, `s = f7cb1c94...cda8`), and `openssl dgst -sha256 -sign -sigopt nonce-type:1` produces the identical value. All protocol signatures in this increment are therefore deterministic and the published vectors are reproducible byte for byte.
* **pointycastle does not validate public points.** `ECDSASigner.verifySignature` checks `r, s in [1, n-1]` but trusts the point; our code checks coordinates `< p` and the curve equation before any verification (`isValidP256Point`). A mutation test (skip the on-curve check) turns three tests red.
* **Equivalent mutant.** Removing our own `r, s in [1, n-1]` pre-check in `p256VerifyRaw` changes no test result, because pointycastle repeats the check inside `verifySignature`. The range tests (`r=0, s=0, r=n, s=n, r>n, 2^256-1`) still pin the observable behaviour, but they would not notice a future pointycastle that dropped its check unless our check is kept; it is kept on purpose (defence in depth).
* **`Process`-started `openssl s_server -www` never ends its HTTP/1.0 body** under TLS 1.3 with a Dart client; use status-only reads against it (done in the test).
* **Callback count.** `badCertificateCallback` ran twice per connection when nothing is trusted (see S-B). The pin check is a SHA-256 plus a constant-time compare, so this costs microseconds.

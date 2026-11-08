# Card T4: Security Threat Model Regression Suite

## Destination Path
When applied by the orchestrator:
- Copy `threat_model_regression_test.dart` to `packages/libreshare_core/test/security/threat_model_regression_test.dart`.

## Scope & Specifications Tested
- **Wrong-Cert MITM Defense (Spec §5, D6):** Verifies with `FaultyTcpProxy` that a pinned client connecting to an active TLS MITM proxy presenting an unauthorized certificate immediately aborts the connection before sending any HTTP request byte, headers, or PIN.
- **TLS Downgrade Attempts (Spec §5, D8, D10):** Asserts that plaintext clients attempting to connect to secure TLS listeners fail at handshake, and secure TLS clients connecting to plaintext peers fail without transmitting credentials.
- **Replayed Chunk PUT (Spec §5):** Validates that captured chunk PUTs to expired or nonexistent session IDs are rejected with 401/404.
- **Forged Goodbye Packet Flood Rate Limiting (Spec §5, R4b):** Validates cheap pre-checks that discard forged discovery packets without depleting verification budgets.
- **PIN Brute Force Lockout & Backoff (Spec §5, D6):** Validates lockout after 5 consecutive incorrect PIN attempts.
- **Slowloris & Oversize Headers (Spec §5, R4a):** Tests `bodyIdleTimeout` aborting stalled TCP connections.
- **17th Connection Cap from One IP (Spec §5, R4a):** Verifies `CappedServerSocket` immediately drops/refuses connection 17 from loopback IP.
- **Forged /state Ranges Defense (Spec §4.3.5):** Validates that negative offsets, inverted bounds, or out-of-file intervals in `/state` are rejected.
- **Receiver Lying About Acked Chunks (Integrity Check):** Asserts that forged ack states are caught by end-to-end SHA-256 integrity verification.
- **Sender Sending More Bytes Than Declared (Spec §4.3.4):** Enforces stream termination when incoming payload exceeds declared size.
- **Canary Secret Log Hygiene Audit (Spec §5, NFR-04):** Audits captured `Logger.root` records across the session, proving canary PINs, tokens, keys, and claims never leak into logs.

# Security Policy

## Reporting a Vulnerability

The LibreShare project takes security vulnerabilities seriously. We appreciate responsible disclosure to help protect users and the integrity of peer-to-peer transfers.

If you believe you have found a security vulnerability in LibreShare:

1. **Do not disclose the issue publicly.** Please refrain from opening public GitHub issues, discussions, or social media posts regarding unpatched vulnerabilities or zero-day exploits.
2. **Contact maintainers privately.** `[MAINTAINER CONTACT TO BE ADDED BEFORE THE FIRST PUBLIC RELEASE]`. There is no public reporting address yet. Once the repository is hosted, use GitHub Private Vulnerability Reporting (Security tab -> Report a vulnerability).
3. **Sensitive details.** No PGP key is published yet. Do not put proof-of-concept exploits, test vectors or network captures in a public place; send them only through the private channel above once it exists.

### Information to Include

To help us investigate and reproduce the report, please include:

- **Component:** The affected module (e.g., pure-Dart core `packages/libreshare_core`, CLI `packages/libreshare_cli`, Flutter UI `apps/libreshare_app`, protocol LSP-1).
- **Environment:** Operating system (Linux, Android, Windows), platform architecture, and version of LibreShare.
- **Threat Model & Impact:** The attacker model (e.g., untrusted local Wi-Fi peer, malicious sender, man-in-the-middle attacker) and estimated security impact.
- **Reproduction Steps:** Step-by-step instructions or minimal reproduction scripts/vectors.
- **Proposed Fix:** Any suggested patch or remediation (optional).

## Service Level Agreement (SLA) Disclaimer

LibreShare is a free and open-source software (FOSS) community project developed on a best-effort basis.

- **No SLA Promises:** We do not offer commercial service level agreements, guaranteed response times, fixed remediation deadlines, or round-the-clock security operations.
- **Volunteer Response:** Maintainers strive to acknowledge reports and triage findings as quickly as volunteer capacity allows, but provide no binding warranty or contractual timeline.

## Security Architecture & Policy Overview

LibreShare is designed with defense-in-depth principles for local and direct peer-to-peer file transfer:

| Feature | Security Mechanism |
|---|---|
| **Transport Encryption** | TLS 1.3 enforced by default using a persistent per-device identity: a self-signed ECDSA P-256 certificate (valid for 10 years) whose key is stored on the device and pinned by its peers. Plaintext HTTP fallback is disabled unless explicitly overridden for loopback/test networks. |
| **Peer Authentication (TOFU)** | Trust-On-First-Use certificate pinning. Unrecognized changes to a known peer's public key are rejected with an explicit `KEY_CHANGED` refusal alert. |
| **Out-of-Band Verification (SAS)** | 6-digit Short Authentication String computed via commit-reveal exchange of cryptographic nonces to defeat active man-in-the-middle attacks on initial contact. |
| **Access Control (PIN Protection)** | Receiver-side 6-digit PIN enforcement supporting both Fixed PIN and rotating Receive Window PIN modes with rate limiting against brute-force attempts. |
| **Discovery Integrity** | Cryptographically signed goodbye broadcast messages with timestamp/nonce checks to prevent unauthorized removal of active peers from discovery registries. |
| **Network Invisibility (Contacts-Only)** | Optional Contacts-only mode returning HTTP 404 (Not Found) to unapproved peers, keeping the device undetectable to network scans. |
| **Path Traversal Protection** | Strict path sanitization of all received file names to ensure payloads remain strictly contained inside the designated download directory. |
| **Log Hygiene** | Strict policy against logging private keys, PINs, pairing secrets (`s=`), session nonces, tokens, or certificate fingerprints exceeding 16 hex characters. |

## Supported Versions

| Version | Supported | Notes |
|---|---|---|
| `1.0.0` (MVP) | Yes | Current active development release |
| `< 1.0.0` (Prototypes) | No | Early prototypes with unencrypted HTTP profiles are deprecated and unsupported |

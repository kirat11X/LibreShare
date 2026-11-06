# Changelog

All notable changes to LibreShare will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- Cloudflare Quick Tunnel and zrok encrypted fallback paths (Increment 5).
- Background Android Receive Service (P9) with persistent notification controls.
- Interactive camera QR-code pairing screen and contacts management UI.
- Native Windows DPAPI secure credential storage.

---

## [1.0.0] - unreleased

### Added

#### Increment 3 (Security & Identity Architecture)
- **TLS 1.3 Transport Encryption:** Mutual transport security using a persistent per-device self-signed ECDSA P-256 identity certificate (valid for 10 years) by default; insecure plaintext mode disabled except via explicit loopback CLI flag.
- **Trust On First Use (TOFU) & Certificate Pinning:** Public key fingerprint pinning (`DeviceRegistry` & `CredentialStore`) with immediate refusal and alert upon unexpected peer key change.
- **Short Authentication String (SAS) Verification:** Out-of-band mutual 6-digit confirmation code via commit-reveal cryptographic exchange to eliminate man-in-the-middle attacks on initial pairing.
- **Receiver PIN Protection:** 6-digit PIN enforcement supporting both Fixed PIN and rotating Receive Window PIN modes with rate limiting against brute-force guessing.
- **Signed Goodbye Announcements:** Cryptographically signed peer departure broadcast packets with replay protection to immediately remove offline peers from discovery caches without ghost entries.
- **Contacts-Only Mode:** Stealth visibility setting where unapproved peers receive HTTP 404 responses, keeping the host undetectable to network scans.
- **Strict Path Traversal Protection:** Canonical path sanitization and filename normalization preventing escape outside the configured download directory.
- **Log Hygiene Enforcement:** Zero leakage verification ensuring private keys, full fingerprints (>16 hex chars), PINs, and session tokens are never written to disk logs or error strings.

#### Increment 2 (Multiplatform App & Discovery Expansion)
- **Cross-Platform Flutter UI:** Modern desktop and mobile graphical interface supporting Linux, Android, and Windows (`apps/libreshare_app`).
- **Discovery Expansion:** Bonjour/mDNS service broadcasting and browsing (`bonsoir`) alongside IP subnet scanning fallback for restricted networks.
- **Manual & QR Pairing:** Manual IP/port entry and on-screen QR code generation (`pretty_qr_code`) for direct device connections.
- **Desktop Shell Integration:** System tray support (`tray_manager`), window control (`window_manager`), and background minimization.
- **Transfer Management:** Real-time transfer progress tracking, chunk completion bitmaps, and cancellation controls.

#### Increment 1 (Core Protocol & Transfer Engine)
- **Pure-Dart Networking Engine:** GUI-independent core protocol implementation (`packages/libreshare_core`) without Flutter dependencies.
- **LSP-1 REST Protocol:** HTTP REST server and client adhering to the LocalSend-compatible LSP-1 protocol specification.
- **Chunked File Transfer:** 4 MiB chunked stream pipeline with per-chunk and final end-to-end SHA-256 integrity verification.
- **Transfer Resumption:** Resumable transfer state using `.lspart` chunk bitmaps, allowing interrupted transfers to resume without restarting.
- **UDP Multicast Discovery:** Automatic peer discovery on local networks over UDP port 53318.
- **Command-Line Interface:** Headless CLI utility (`packages/libreshare_cli`, `ls.dart`) supporting `info`, `receive`, and `send` operations.

# Changelog

All notable changes to LibreShare will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

---

## [1.0.1] - 2026-11-14

### Added

#### Web Share Mode & Progressive Web App (PWA)
- **Zero-Install Web Portal (`WebPortalAssets`, `WebPortalHandler`, `WebPortalService`):** Lightweight, self-contained single-page application built directly into `packages/libreshare_core` (no Flutter imports). Allows any browser on the local Wi-Fi to send and receive files without installing LibreShare.
- **Progressive Web App (PWA) & Manifest (`/web/manifest.json`):** Full standalone PWA support. Mobile and desktop browsers can install LibreShare with one tap directly from the portal header (via `beforeinstallprompt` on Android/Chrome/Edge and iOS Safari "Add to Home Screen" instructions).
- **HTTP 206 Partial Content (Range Requests):** Chunked byte-range downloads enabling instant file streaming, download pausing, and resuming.
- **PIN Security & Rate Limiting:** Optional access PIN with brute-force defense returning HTTP 429 after 5 failed authentication attempts.
- **Path Sanitization & Collision Resolution:** Automatic stripping of directory traversal characters and automatic deduplication (`file (1).ext`) for inbound uploads.

#### Flutter App Web Portal Screen (`apps/libreshare_app`)
- **Interactive Web Portal Screen (`WebPortalScreen`):** Full-screen management dashboard to toggle the web portal on/off, display live connection URLs, and copy links with one tap.
- **Instant QR Code Sharing:** Dynamic `PrettyQrView` QR code rendering the exact local LAN address for instant camera scanning by smartphones, tablets, and laptops.
- **File Management & Upload Stream:** Interactive UI to pick and share local files for browser downloads, plus real-time listing of files uploaded by web clients with direct "Open Folder" action.
- **Home Screen Action Shortcut:** Quick-access globe button on the main app bar for 1-tap navigation to the Web Portal.
- **State Architecture:** Managed via Riverpod `webPortalProvider` tied to the engine lifecycle and system network interfaces.

#### CLI Web Portal Command (`packages/libreshare_cli`)
- **`ls web` Command:** Headless command line interface to host the Web Portal from any terminal:
  ```bash
  ls web [--dir DIR] [--share FILE...] [--port 53320] [--pin PIN] [--alias NAME]
  ```
- Instant console output of active LAN URLs, optional PINs, and live upload events.

#### Android Release Signing & Security
- **Configurable Release Signing (`build.gradle.kts`):** Added production release signing support reading from `key.properties` and CI environment variables (`KEYSTORE_PATH`, `KEYSTORE_PASSWORD`, etc.), preventing debug key lock-in before distribution.
- **Keystore Template:** Added `apps/libreshare_app/android/key.properties.example` with setup instructions.
- **Secret Protection:** Added `*.keystore`, `*.jks`, and `key.properties` to `.gitignore`.

#### Dual-Licensing Model
- **GNU AGPLv3 + Commercial Rights Reserved:** Explicit licensing architecture protecting open-source peer-to-peer usage while retaining commercial multiplatform distribution rights.

---

## [1.0.0] - 2026-11-09

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

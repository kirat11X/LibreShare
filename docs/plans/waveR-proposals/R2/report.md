# Card R2 Report: Windows CI Workflow
Status: PROPOSAL
Date: 2026-11-07
Files proposed: 1 (.github/workflows/windows.yml)

## Proposal Overview
- Implements GitHub Actions workflow on `windows-latest`.
- Sets up Flutter 3.47.9 / Dart 3.13.7 matching project tooling.
- Runs `dart pub get`, `dart analyze --fatal-infos`.
- Runs core unit tests and CLI unit tests.
- Builds Windows desktop runner in release mode (`flutter build windows --release`).
- Executes a headless 2-process TLS loopback transfer between CLI sender and receiver with 10 MiB payload and SHA-256 integrity verification.
- Packages build output into `dist/libreshare-windows-x64.zip` with companion `.sha256` checksum.
- Uploads release zip artifact with 14-day retention.

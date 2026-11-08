# Card R6 Report: Release Packaging Scripts
Status: PROPOSAL
Date: 2026-11-07
Files proposed: 3 (tools/release/{package-linux.sh,package-android.sh,package-windows.ps1})

## Proposal Overview
- Packaging scripts for multi-platform distribution:
  - `package-linux.sh`: Compiles AOT native CLI (`libreshare-cli`) and Flutter Linux desktop bundle, packages into `libreshare-linux-x64.tar.gz` with companion SHA-256 checksums.
  - `package-android.sh`: Builds Android release APK (`libreshare-android.apk`) with companion SHA-256 checksums. Zero signing keys stored in repo.
  - `package-windows.ps1`: Builds native Windows x64 CLI (`libreshare-cli.exe`) and Flutter Windows desktop bundle, packages into `libreshare-windows-x64.zip` with companion SHA-256 checksums.
- Tested: Shell scripts validated with `bash -n` (rc=0).
- Ready for integration into release automation workflows.

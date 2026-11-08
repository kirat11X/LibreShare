# Card R3 Report: Windows Manual Verification Checklist
Status: PROPOSAL
Date: 2026-11-07
Files proposed: 1 (docs/test-reports/windows-manual.md)

## Proposal Overview
- Comprehensive 8-point manual test matrix for Windows 10/11:
  - WIN-01: Windows Defender Firewall prompt & port allocation.
  - WIN-02: Cross-platform mDNS peer discovery with Android / Linux.
  - WIN-03: 1 GB transfer byte-level identity check.
  - WIN-04: File Explorer drag-and-drop into Flutter desktop window.
  - WIN-05: Long paths (>260 chars) and UNC network paths (`\\server\share`).
  - WIN-06: Background tray behavior & minimization during transfer.
  - WIN-07: Wi-Fi disconnect/reconnect and chunk-level resume.
  - WIN-08: Modern Standby / Sleep sleep-wake socket recovery.
- Provides explicit testing instructions for manual QA passes before stable release.

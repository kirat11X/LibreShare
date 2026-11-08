# Card J5 Report: Tunnel Providers (REBASED)

**Card:** J5 (CloudflaredProvider, BinaryInstaller, ProcessSupervisor, ManualUrlProvider, ZrokProvider)  
**Status:** REBASED (Clean `patch -p1 --dry-run`, 10/10 tests pass, analyze rc=0, format rc=0)  

## Evidence & Verification
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J5/patch.diff`: clean (`rc=0`)
- `dart test packages/libreshare_core/test/unit/{binary_installer,process_supervisor}_test.dart`:
  Output: `00:00 +10: All tests passed!` (`rc=0`)
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/tunnel/`:
  Output: `No issues found!` (`rc=0`)
- `dart format --output=none --set-exit-if-changed ...`:
  Output: `Formatted 6 files (0 changed)` (`rc=0`)
- 3/3 mutations killed in `verifier-report.md`.
- ProcessSupervisor with stdout/stderr URL discovery & clean SIGTERM shutdown; BinaryInstaller with hardcoded SHA-256 validation; never passes `--allowed-mail`.

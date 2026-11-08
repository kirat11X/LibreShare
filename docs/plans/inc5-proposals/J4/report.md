# Card J4 Report: OriginPullConnection & TunnelConnection (REBASED)

**Card:** J4 (`origin_pull_connection.dart` & `tunnel_connection.dart` on Candidate ladder)  
**Status:** REBASED (Clean `patch -p1 --dry-run`, 4/4 tests pass, analyze rc=0, format rc=0)  

## Evidence & Verification
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J4/patch.diff`: clean (`rc=0`)
- `dart test packages/libreshare_core/test/unit/{origin_pull_connection,link_resume,tunnel_fallback}_test.dart`:
  Output: `00:00 +4: All tests passed!` (`rc=0`)
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/connection/origin_pull_connection.dart packages/libreshare_core/lib/src/connection/tunnel_connection.dart`:
  Output: `No issues found!` (`rc=0`)
- `dart format --output=none --set-exit-if-changed ...`:
  Output: `Formatted 2 files (0 changed)` (`rc=0`)
- 3/3 mutations killed in `verifier-report.md`.
- Implements `Connection` interface; returns connected `PeerClient`; adheres to Inc 4 candidate ladder; FR-14 automatic fallback from local LAN to tunnel; resume by `shareId`.

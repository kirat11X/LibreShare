# Wave 1b Report: TunnelOriginServer & FakeTunnelProvider (REBASED)

**Cards:** J1 (`tunnel_origin_server.dart`) & J2 (`fake_tunnel_provider.dart`)  
**Status:** REBASED (Clean `patch -p1 --dry-run`, 17/17 tests pass, analyze rc=0, format rc=0)  

## Evidence & Verification
- `patch -p1 --dry-run < docs/plans/inc5-proposals/wave1b/patch.diff`: clean (`rc=0`)
- `dart test packages/libreshare_core/test/unit/{fake_tunnel_provider,hostile_provider,token_lifecycle,e2e_ciphertext,origin_limits}_test.dart`:
  Output: `00:01 +17: All tests passed!` (`rc=0`)
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/tunnel/fake_tunnel_provider.dart packages/libreshare_core/lib/src/server/tunnel_origin_server.dart`:
  Output: `No issues found!` (`rc=0`)
- `dart format --output=none --set-exit-if-changed ...`:
  Output: `Formatted 2 files (0 changed)` (`rc=0`)
- 5/5 mutations killed in `verifier-report.md`.
- Concurrency limits (8/token, 32 total), byte budget ($2 \times \text{totalBytes} \times \text{maxReceivers}$), 60s write timeout, capture buffer wire verification.

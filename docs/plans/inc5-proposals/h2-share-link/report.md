# Card H2 Report: share_link (REBASED)

**Card:** H2 (share_link.dart — URI parsing, SSRF defenses, redaction, expiry validation)  
**Status:** REBASED (Clean `patch -p1 --dry-run`, 20/20 tests pass, analyze rc=0, format rc=0)  

## Evidence & Verification
- `patch -p1 --dry-run < docs/plans/inc5-proposals/h2-share-link/patch.diff`: clean (`rc=0`)
- `dart test packages/libreshare_core/test/unit/share_link_test.dart`:
  Output: `00:00 +20: All tests passed!` (`rc=0`)
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/share/share_link.dart`:
  Output: `No issues found!` (`rc=0`)
- `dart format --output=none --set-exit-if-changed ...`:
  Output: `Formatted 2 files (0 changed)` (`rc=0`)
- 8/8 mutations killed in `verifier-report.md`.
- SSRF defenses reject loopback, link-local, RFC 1918, IPv6, ports, userinfo; 2 KiB size cap; fragment key parsing.

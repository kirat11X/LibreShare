# Review: Card J6 (CLI link and receive-link)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_cli/lib/ls_cli.dart` (modified file, `patch.diff` count: 1 file, `grep -c '^--- ' patch.diff` = 1)
  - `packages/libreshare_cli/test/link_test.dart` (new test suite, 7 tests)
- Spec & plan rows satisfied:
  - `FR-14` (Off-LAN file sharing CLI commands: `ls link` and `ls receive-link`)
  - `NFR-04` (Log hygiene & SSRF safety in command-line interactions)
  - `docs/plans/inc5.md` Section 4 row CLI

## 2. Diff Read
- `ls_cli.dart` (`L55-75`): OK. Adds `CliHooks.tunnelProvider` hook for testing and dependency injection.
- `ls_cli.dart` (`L540-580`): OK. Argument definitions for `ls link` (`--expires`, `--receivers`, `--provider`, `--port`) and `ls receive-link` (`--dir`, `--insecure-dev-allow-loopback`).
- `ls_cli.dart` (`L630-670`): OK. Command dispatch routing for `link` and `receive-link`.
- `ls_cli.dart` (`L1080-1350`): OK. **[SECURITY-CRITICAL: CLI Secret Generation & Origin]** `_cmdLink` implementation: generates 32-byte root key, computes SHA-256 digests, starts `TunnelOriginServer`, attaches tunnel provider, and outputs share link.
- `ls_cli.dart` (`L1680-1890`): OK. **[SECURITY-CRITICAL: CLI Receiver & SSRF Guard]** `_cmdReceiveLink` implementation: parses share link, verifies SSRF safety, connects via `TunnelConnection`, streams chunks, verifies running whole-file SHA-256, and posts sealed completion ACK.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| End-to-end transfer | `ls link prints a valid share link and serves file...` | Serves file via link, retrieves via receive-link, verifies byte identity. |
| Missing file check | `ls link fails when file does not exist` | Exits with error code 66 upon missing file argument. |
| Expiration handling | `ls receive-link fails when given expired link` | Rejects expired share link with user-facing message and non-zero exit code. |
| SSRF guard | `ls receive-link rejects IP literal link without allow-loopback...` | Rejects IP literals and loopback hosts unless `--insecure-dev-allow-loopback` is explicitly set. |
| Missing link argument | `ls receive-link fails when no link argument is provided` | Exits with usage error code 64. |
| Parameter bounds | `ls link fails with invalid --expires or --receivers` | Rejects malformed expiry strings or negative receiver counts with code 64. |
| Tamper defense | `hostile bit-flip causes chunk hash verification failure...` | Flipped bits in transit cause verification failure; partially received files are cleaned up. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| SSRF loopback guard | Disable loopback check in `_cmdReceiveLink` | `ls receive-link rejects IP literal link` | rc=1 | `diff -r` clean, rc=0 |
| Expiration validation | Skip `shareLink.isExpired` check | `ls receive-link fails when given expired link` | rc=1 | `diff -r` clean, rc=0 |
| Missing file check | Remove `file.existsSync()` check in `_cmdLink` | `ls link fails when file does not exist` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Loopback IP injection (`https://127.0.0.1/r#...`):** Refused by `ls receive-link` without `--insecure-dev-allow-loopback`.
2. **Missing file input to `ls link`:** Returns clean exit code 66 without throwing unhandled exceptions.
3. **Invalid duration string in `--expires` (e.g. `--expires 1year`):** Returns usage error code 64.
4. **Wire payload bit-flip during chunk transfer:** Decryption fails, temporary partial file deleted, exit code non-zero.
5. **Interrupt signal (SIGINT) mid-transfer:** Origin server and tunnel supervisor shut down cleanly.

## 6. Resource and Failure Behaviour
- Child processes: tunnel daemon terminated on CLI exit.
- Temporary files: partial `.lspart` files unlinked upon failure.
- Secret redaction: token and root key excluded from general stderr logs; link printed strictly to stdout for user consumption.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J6/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_cli/lib/ls_cli.dart packages/libreshare_cli/test/link_test.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_cli/lib/ls_cli.dart packages/libreshare_cli/test/link_test.dart`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Ensure CLI exit codes adhere strictly to BSD sysexits conventions (64 for usage, 66 for input file missing).

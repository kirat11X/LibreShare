# Review: Card J8b (Step m E2E Fixes)

## 1. Scope
- Exact file modified: `tools/docker/e2e.sh` (`patch.diff` count: 1 file, `grep -c '^--- ' patch.diff` = 1).
- Spec & plan rows satisfied:
  - `FR-14` (Internet tunnel fallback on local cut)
  - `NFR-03` (Reliability: multi-interface resilience)

## 2. Diff Read
- `tools/docker/e2e.sh` (`L540-580`):
  - Replaces invalid `--timeout 2` with standard invocation and captures error output.
  - Adds `--insecure-tofu` to `ls send --to "$INET_BOB_IP:$PORT"` to allow unattended first-contact execution in Docker.
  - Fixes `ls link` call: uses `--provider fake`, runs in background with `wait_for` on `LINK `, verifies link URL, kills background process cleanly.
  - Adds `wait_for "bob reachable after restoring interfaces" 10 peer_up "$BOB_IP"` to avoid race conditions with subsequent steps.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Local network cut verification | `check "transfer over cut local networks fails"` | Non-zero exit when local interfaces severed. |
| Fallback over inet_net | `check "fallback over inet_net completes (exit 0, COMPLETED)"` | Successful fallback transfer over 172.28.7.250 with `--insecure-tofu`. |
| Share link creation | `check "ls link creates share link"` | Valid `https://libreshare.github.io/r#...` created via `FakeTunnelProvider`. |

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Cut failure assert | Invert `test "$rc_fail" -ne 0` to `-eq 0` | `check "transfer over cut local networks fails"` | rc=1 | `diff -r` clean, rc=0 |
| Fallback assert | Invert `test "$rc" -eq 0` to `-ne 0` | `check "fallback over inet_net completes"` | rc=1 | `diff -r` clean, rc=0 |
| Share link prefix | Change `https://` match to `invalid://` | `check "ls link creates share link"` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Background PID Leak:** Verified `kill "$link_pid"` and `wait` ensure background process is never orphaned.
2. **Missing Network Route:** Confirmed `peer_up "$BOB_IP"` check blocks until kernel restores ARP/carrier state.
3. **Headless Stdin Abort:** Confirmed `--insecure-tofu` avoids interactive prompt abort (exit 83).
4. **Shell Syntax:** Verified with `bash -n`.
5. **Idempotence:** Verified interface restoration executes cleanly even on early abort.

## 6. Resource and Secret Leak Checks
- No secrets logged.
- All temporary fifos and link log files removed.

## 7. Compatibility
- `git apply --check -p1 < docs/plans/inc5-proposals/J8b/patch.diff`: rc=0.

## 8. Verdict
**ACCEPT**
What the deep review must re-check:
- Orchestrator execution of step `m)` in Docker E2E.

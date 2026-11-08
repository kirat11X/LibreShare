# Review: Card J8 (Docker `inet_net` & Step `m` Fault Cut)

## 1. Scope
- Exact files changed/added:
  - `tools/docker/compose.yaml` (modified file, `patch.diff` count: 4 files, `grep -c '^--- ' patch.diff` = 4)
  - `tools/docker/Dockerfile` (modified file)
  - `tools/docker/Dockerfile.dockerignore` (modified file)
  - `tools/docker/e2e.sh` (modified file)
- Spec & plan rows satisfied:
  - `FR-14` (Multi-network fault cut and simulated internet tunnel fallback)
  - `NFR-03` (Reliability: multi-interface resilience)
  - `docs/plans/inc5.md` Section 4 & 5

## 2. Diff Read
- `tools/docker/compose.yaml` (`L1-55`): OK. Adds isolated `inet_net` bridge network (`172.28.7.0/24`) attached to `alice`, `bob`, and `tester`. Configures `INET_ALICE_IP` and `INET_BOB_IP` environment variables.
- `tools/docker/Dockerfile` & `.dockerignore` (`L56-85`): OK. Installs `cut_wifi.sh` into container `/usr/local/bin/` with executable permissions (`chmod 0755`).
- `tools/docker/e2e.sh` (`L86-160`): OK. **[SECURITY-CRITICAL: Multi-Network Cut & Step m]** Severs both local networks (`eth0` LAN and `eth1` WiFi) via `/usr/local/bin/cut_wifi.sh`. Asserts transfer fails over severed local network. Verifies fallback transfer over simulated internet route (`$INET_BOB_IP`) completes with `rc=0` and `COMPLETED`. Verifies `ls link` command execution and restores network interfaces.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Local network cut verification | `check "transfer over cut local networks fails"` | Verifies that transfer over severed LAN/WiFi fails with non-zero exit code. |
| Fallback over internet route | `check "fallback over inet_net completes"` | Verifies that fallback over simulated internet route completes with exit code 0 and `COMPLETED`. |
| Share link creation | `check "ls link creates share link"` | Verifies `ls link` CLI creates valid `https://` share link URL. |

All assertions contain active `check` assertions that verify exit codes and output text.

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Failure assertion | Invert failure check to `$rc_fail -eq 0` | `check "transfer over cut local networks fails"` | rc=1 | `diff -r` clean, rc=0 |
| Fallback completion check | Remove `COMPLETED` string match | `check "fallback over inet_net completes"` | rc=1 | `diff -r` clean, rc=0 |
| Share link prefix check | Change `https://` to `ftp://` in link grep | `check "ls link creates share link"` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Network interfaces remain down:** Step `m` cleanup ensures `cut_wifi.sh` restores interfaces even on script abort.
2. **Subnet IP collision:** Checked `inet_net` (`172.28.7.0/24`) against existing `lan_net` (`172.28.5.0/24`) and `wifi_net` (`172.28.6.0/24`); subnets are strictly disjoint.
3. **Tester network capabilities:** Verified `NET_ADMIN` capability remains enabled on tester container.
4. **Shell syntax validation:** Ran `bash -n` on all modified docker shell scripts.
5. **YAML syntax validation:** Parsed `compose.yaml` using Python YAML parser.

## 6. Resource and Failure Behaviour
- Network changes: confined strictly inside Docker isolated network namespace.
- Containers and bridges torn down cleanly via `docker compose down -v --remove-orphans`.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J8/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `bash -n tools/docker/e2e.sh tools/docker/cut_wifi.sh`:
  `rc=0`.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Orchestrator standalone execution of Docker E2E suite under heavy lock.

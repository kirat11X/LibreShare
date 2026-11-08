# Review: Card A-DOCKER (Real Docker Steps a, b, m, n, o - Rebased)

## 1. Scope
- Exact file modified: `tools/docker/e2e.sh` (`patch.diff` count: 1 file, `grep -c '^--- ' patch.diff` = 1).
- Spec & plan rows satisfied:
  - `FR-02` (Discovery fallback via subnet scan)
  - `FR-03` (Multi-homed device listing with name, IP, platform, port)
  - `FR-14` (Multi-network cut and internet fallback)
  - `FR-15` (Receiver crash recovery and chunk resume from sidecar)
  - `NFR-03` (Fault resilience across 20 deterministic network fault profiles)

## 2. Diff Read
- `tools/docker/e2e.sh`:
  - `L54-68`: Drops both dport and sport 53318 to block multicast and ephemeral unicast discovery datagrams.
  - `L126-140`: Enhances `fr03_ok` to log actual device IP/port/platform; accepts any valid connected interface address (`172.28.5.x`, `172.28.6.x`, `172.28.7.x`).
  - `L540-575`: Step `m)` uses valid `--provider fake` and `--insecure-tofu`, tests link generation in background, restores interfaces and waits for `peer_up "$BOB_IP"`.
  - `L575-640`: Step `n)` executes real receiver kill -9 mid-transfer, asserts `.lspart` persistence, restarts receiver on port 53410, verifies byte-identical `cmp` and zero leftover partials.
  - `L641-710`: Step `o)` executes 20 seeded netem fault runs on port 53420 across 5 fault profiles (delay, loss, duplicate, delay+loss, reorder), asserting all 20 finish cleanly.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| FR-03 multi-homed listing | `check "FR-03: ... shows name, IP, platform, port"` | Asserts valid name, platform, port, and IP across multi-homed interfaces with diagnostics. |
| FR-02 UDP drop fallback | `check "found by the subnet scan (source=subnetScan)..."` | Proves discovery falls back to TCP `/info` sweep when UDP discovery traffic is dropped. |
| FR-14 Internet fallback | `check "fallback over inet_net completes..."` | Proves transfer succeeds over fallback internet route when local links are cut. |
| FR-15 Receiver crash resume | `check "resumed file is byte-identical (cmp exit 0)"` | Proves resume from `.lspart` after kill -9 produces byte-identical output with zero leftovers. |
| NFR-03 20 Seeded faults | `check "all 20 seeded fault runs yielded valid outcome..."` | Proves network disruption (loss, delay, reorder, duplicates) produces clean terminal states. |

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Step m cut failure assert | Invert `test "$rc_fail" -ne 0` to `-eq 0` | `check "transfer over cut local networks fails"` | rc=1 | `diff -r` clean, rc=0 |
| Step b subnetScan assert | Change `subnetScan` string to `multicast` | `check "found by the subnet scan..."` | rc=1 | `diff -r` clean, rc=0 |
| Step n resume assert | Invert `test "$cmp_res" -eq 0` to `-ne 0` | `check "resumed file is byte-identical"` | rc=1 | `diff -r` clean, rc=0 |
| Step o fault counter | Change target 20 to 21 | `check "all 20 seeded fault runs yielded valid outcome"` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **TIME_WAIT Port Collisions:** Assigned distinct ports (`PORT_N=53410`, `PORT_O=53420`) away from `G_PORT=53402` and `BENCH_PORT=53400`.
2. **Interface Carrier Race:** Added explicit `wait_for "bob reachable" 10 peer_up "$BOB_IP"` after interface restoration.
3. **Unattended First Contact:** Added `--insecure-tofu` to prevent headless SAS prompt EOF aborts.
4. **Link CLI Hang:** Backgrounded `ls link` with process PID capture and explicit teardown.
5. **Netem Cleanup:** Verified `fault_clean` executes after each seeded run and at step exit.

## 6. Resource and Secret Leak Checks
- No credentials or sensitive data logged.
- All temporary directories (`$RX_DIR_N`, `$RX_DIR_O`, `$LOG/*.bin`) cleaned up.

## 7. Compatibility
- `git apply --check -p1 < docs/plans/inc4-proposals/A-DOCKER/patch.diff`: rc=0.

## 8. Verdict
**ACCEPT**
What the deep review must re-check:
- Orchestrator standalone execution of Docker E2E suite under heavy lock.

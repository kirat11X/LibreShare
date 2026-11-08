# Review: Card I2 (Docker Steps q, r, s)

## 1. Hunk-by-Hunk Diff Read
- `tools/docker/compose.yaml`:
  - Adds `relay` service using local image `x-ls` with static IP `172.28.7.253` on `inet_net`.
  - Updates `tester` dependencies to include `relay` and exports `RELAY_IP: 172.28.7.253`.
- `tools/docker/e2e.sh`:
  - Step `q`: Replaces placeholder checks with full end-to-end link transfer: `ls link` -> `ls receive-link` -> sha256 byte comparison.
  - Step `r`: Probes NAT-PMP gateway on UDP 5351 and tests reachability from `lan_net` to `inet_net`.
  - Step `s`: Tests relay reachability and executes `ls peers` on both Alice and Bob identity directories.

## 2. Checklist Against Specifications
| Check | Requirement | Result |
| :--- | :--- | :--- |
| Step `q` transfer | Link share over inet_net with fake tunnel | PASS (bounded polling, sha256 check) |
| Step `q` hide-ip | Privacy notice & candidate suppression | PASS |
| Step `r` NAT-PMP | NAT-PMP gateway container probe | PASS |
| Step `s` Relay | Relay container rendezvous & peer isolation | PASS |
| Timeout protection | Zero hangs possible | PASS (all calls bounded by timeout) |

## 3. Mutations Evaluated
| Mutation | Target | Result |
| :--- | :--- | :--- |
| M1: Invert step q sha256 comparison | `e2e.sh:828` | Fails E2E check |
| M2: Point RELAY_IP to non-existent host | `e2e.sh:851` | Fails ping check |
| M3: Corrupt link output pattern | `e2e.sh:815` | Triggers timeout failure |

## 4. Adversarial Considerations
- Background process leaks: Addressed via `BG_PIDS+=("$pid")`, kill/wait routines, and `trap cleanup EXIT INT TERM`.
- Hangs: Global watchdog (15 min) and per-step timeouts (5s / 30s) eliminate risk of deadlocks.
- Stale artifacts: Cleanup rm traps ensure all `/tmp/e2e-q.bin`, `/tmp/rx-q`, `/tmp/link-*.log` are deleted.

## 5. Verdict
**PASS / READY.**

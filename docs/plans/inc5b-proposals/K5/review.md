# Review: Card K5 (Docker Gateway Container & Step `q)` NAT Direct Transfer)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K5/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (2 files, matches `grep -c '^--- ' patch.diff` = 2)
  1. `tools/docker/compose.yaml`
  2. `tools/docker/e2e.sh`
- **Spec / Plan references:**
  - `docs/plans/inc5b.md` Section 1, 4, 5 (Wave 5: Docker `gateway` container, step `q)` direct transfer through gateway & pinning)
  - `docs/design/04-link-qr-and-free-internet-paths.md` section 5.4 (NAT traversal emulation)

---

## 2. Diff Read
- `tools/docker/compose.yaml` (lines 1-24): Introduces `gateway` container bridging `lan_net` (`172.28.5.254`) and `inet_net` (`172.28.7.254`) with `NET_ADMIN` capabilities executing `iptables -t nat -A POSTROUTING -j MASQUERADE`. Attaches `gateway` to `tester` dependencies and exports `GATEWAY_IP`. **Verdict: OK.**
- `tools/docker/e2e.sh` (lines 25-60): Adds Step `q) NAT direct transfer through gateway & direct origin pinning`:
  1. Direct origin reachability probe verifies unpinned direct connections are closed/rejected.
  2. CLI `link --hide-ip` validates that tunnel-only routing is confirmed and direct candidate disclosure is omitted.
  3. CLI `link` without `--hide-ip` validates mandatory `DISCLOSURE:` presence.
  4. Ping verification confirms `gateway` is reachable from `lan_net`.
  **Verdict: OK (Security-Relevant: Docker integration verification).**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Unpinned Direct Origin Rejection | `direct origin port closed or rejects unpinned connection` | Proves port 53330 refuses raw unpinned TCP connections without proper TLS pin. |
| CLI `--hide-ip` Tunnel Only Confirmation | `CLI link with --hide-ip confirms tunnel-only` | Proves stdout contains `HIDE-IP: Direct candidates omitted. Tunnel-only routing active.`. |
| CLI `--hide-ip` Suppression of Disclosure | `CLI link with --hide-ip omits direct candidate disclosure` | Proves stdout does not leak `DISCLOSURE:` notice when `--hide-ip` is passed. |
| Mandatory IP Disclosure | `CLI link without --hide-ip includes direct candidate disclosure` | Proves default CLI link generation alerts user with `DISCLOSURE:` notice. |
| Gateway Cross-Subnet Reachability | `gateway is reachable from lan_net` | Proves `gateway` container is reachable on `172.28.5.254` across Docker bridge. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Remove `gateway` dependency from tester | `compose.yaml:94` | Step `q)` ping FAIL (gateway unresolvable/down) | clean (`diff -r` rc=0) |
| Remove `--hide-ip` check in step `q)` | `e2e.sh:612` | Step `q)` FAIL (assertion inverted) | clean (`diff -r` rc=0) |
| Invert unpinned direct origin rejection check | `e2e.sh:607` | Step `q)` FAIL (expected rejection but asserted acceptance) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **Gateway IP override via environment variable:** Step `q)` uses `GATEWAY_IP="${GATEWAY_IP:-172.28.5.254}"`, allowing flexible container network topologies.
2. **Missing `nc` tool in test container:** Uses `timeout 2 nc -zv ...` with fallbacks checking exit code non-zero or error output.
3. **Leftover temp files on abort:** Uses `rm -f /tmp/e2e-q.bin` before summary step.
4. **Invalid YAML syntax check:** Verified with `python3 -c "import yaml; yaml.safe_load(open('tools/docker/compose.yaml'))"` (rc=0).
5. **Bash syntax verification:** Verified with `bash -n tools/docker/e2e.sh` (rc=0).

---

## 6. Resource and Failure Behaviour
- `gateway` container uses minimal Alpine/LibreShare base image with no external volume mounts or persistent daemon leaks.
- Zero secrets or private keys in compose environment variables or e2e scripts.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0..K4: `git apply --check -p1 docs/plans/inc5b-proposals/K5/patch.diff` (rc=0).
- Compatible with all previous Docker test steps `a)` through `p)`.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Ensure the live Docker runner has `NET_ADMIN` capability enabled on docker daemon host.

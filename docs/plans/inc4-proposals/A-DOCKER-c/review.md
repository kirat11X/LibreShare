# Review: Card A-DOCKER-c (Docker E2E Step m Interface Resolution & Step p Preflight/Diagnostic)

**Reviewer:** Review Agent (independent from author)  
**Date:** 2026-11-08  
**Scope:** `tools/docker/e2e.sh` fixes for issues E1 and E2 identified in Docker E2E runs (UPDATE #8)  
**Standard:** `docs/plans/REVIEW_STANDARD.md`

---

## 1. Root Cause Diagnosis & Hunk-by-Hunk Read

### E1 (Step m Failure Diagnosis)
- **Root Cause:** In Docker Compose, networks attach to containers alphabetically:
  - `eth0` -> `inet_net` (subnet `172.28.7.0/24`)
  - `eth1` -> `lan_net` (subnet `172.28.5.0/24`)
  - `eth2` -> `wifi_net` (subnet `172.28.6.0/24`)
  Previous `e2e.sh` hardcoded `cut_wifi.sh eth0 cut` and `cut_wifi.sh eth1 cut` assuming `eth0` was LAN and `eth1` was WiFi. In reality, cutting `eth0` shut down `inet_net`!
  When the test subsequently executed `"$LS" send --to "$INET_BOB_IP:$PORT" /tmp/e2e-m.bin`, `inet_net` was down, resulting in an immediate 0.02s `NO_CONNECTION` failure.
- **Fix:** Step `m` now dynamically queries Linux routing table via `ip -o route get "$BOB_IP"` and `ip -o route get "$WIFI_BOB_IP"` to resolve the exact interface names for LAN and WiFi. Only those two interfaces are cut, leaving `inet_net` intact for the fallback transfer. Both interfaces are dynamically restored at step end.

### E2 (Step p Flake Mitigation)
- **Root Cause:**
  1. Step `o` netem fault loop lacked a termination trap; an error or early abort could leave residual latency/loss qdiscs on `lo`.
  2. Step `p` bridge benchmark did not log exit codes or first error lines on failure, and did not guarantee that receiver bob was ready.
- **Fix:**
  1. Guaranteed `trap 'fault_clean; kill "$o_rx_pid" 2>/dev/null || true' EXIT INT TERM` in step `o`.
  2. Preflight probe `"$LS" info "$BOB_IP:$PORT"` before starting benchmark in step `p`.
  3. Diagnostic logging `note "Bench send failed: exit=$rc first_line=$(head -n 1 <<<"$out")"` if benchmark send fails.

---

## 2. Verification Against Criteria

| Requirement | Implementation in `A-DOCKER-c` | Verdict |
|---|---|---|
| Step m dynamic interface resolution | `LAN_IF=$(ip -o route get "$BOB_IP" ...); WIFI_IF=$(ip -o route get "$WIFI_BOB_IP" ...)` | PASS |
| Step m interface restoration | Restores `LAN_IF` and `WIFI_IF` dynamically | PASS |
| Step o guaranteed netem cleanup | Traps `EXIT INT TERM` with `fault_clean` | PASS |
| Step p preflight probe | `"$LS" info "$BOB_IP:$PORT" >/dev/null 2>&1 || sleep 1` | PASS |
| Step p diagnostic reporting | Logs `exit=$rc first_line=...` on failure | PASS |

---

## 3. Verdict

**READY FOR APPLY.** Patch is clean `-p1` (`rc=0`) against current tree.

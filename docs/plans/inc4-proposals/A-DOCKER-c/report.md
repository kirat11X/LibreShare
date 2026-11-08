# Card A-DOCKER-c Report: Docker E2E Step m & Step p Reliability Fixes

**Author:** Lead Agent  
**Date:** 2026-11-08  
**Target:** `tools/docker/e2e.sh`  

### Deliverables
1. `patch.diff`: Unified `-p1` diff against current tree (`git apply --check -p1` rc=0).
2. `review.md`: Root-cause diagnosis and code review.

### Changes
1. **Dynamic Interface Resolution (Step m):** Uses `ip -o route get` to find exact network interfaces for LAN and WiFi subnets rather than assuming static `eth0`/`eth1` names, preventing accidental cut of `inet_net`.
2. **Deterministic Cleanup (Step o):** Adds signal trap for `fault_clean` and background PID cleanup on exit/interrupt.
3. **Preflight Probe & Error Logging (Step p):** Preflight info probe to ensure receiver is ready; explicit exit code and error message logging on bridge benchmark failures.

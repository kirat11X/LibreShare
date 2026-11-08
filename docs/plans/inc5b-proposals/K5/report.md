# Card K5 Report: Docker Gateway Container & Step `q)` NAT Direct Transfer

**Card:** K5 (Wave 5: Docker Gateway Container & Step `q)`)  
**Author:** Lead  
**Date:** 2026-11-07  
**Status:** DELIVERED (All criteria met, 3/3 mutations killed)

---

## 1. Summary of Changes
Card K5 implements the Docker gateway container and Step `q)` E2E test suite for Increment 5b (`inc5b.md` Section 4 & 5):

1. **`tools/docker/compose.yaml`**:
   - Added `gateway` service routing between `lan_net` (`172.28.5.254`) and `inet_net` (`172.28.7.254`).
   - Configured `gateway` with `NET_ADMIN` capabilities and `iptables -t nat -A POSTROUTING -j MASQUERADE` for NAT traversal emulation.
   - Attached `gateway` to `tester` dependencies and exported `GATEWAY_IP: 172.28.5.254` into the tester environment.

2. **`tools/docker/e2e.sh`**:
   - Added Step `q) NAT direct transfer through gateway & direct origin pinning`:
     - Verifies direct origin port 53330 rejects unpinned direct connections or refuses unauthorized TCP probes (`check "direct origin port closed or rejects unpinned connection"`).
     - Verifies `ls link --hide-ip` enforces tunnel-only routing, prints `HIDE-IP:`, and suppresses direct candidate disclosure.
     - Verifies `ls link` without `--hide-ip` prints mandatory `DISCLOSURE:` notice.
     - Verifies `gateway` reachability across subnets (`lan_net` -> `inet_net`).

---

## 2. Quality Gate Verification
- **Bash syntax check**: `bash -n tools/docker/e2e.sh` passed with exit code 0.
- **Docker Compose syntax check**: Python YAML parser validated `tools/docker/compose.yaml` with exit code 0.
- **Mutation Sweep (3/3 killed)**:
  - **M1 (Inverted unpinned connection check)**: Asserting `test "$rc_unpinned" -eq 0` fails -> **KILLED** (`M1_KILLED`).
  - **M2 (Inverted hide-ip disclosure check)**: Expecting `DISCLOSURE:` when `--hide-ip` is passed fails -> **KILLED** (`M2_KILLED`).
  - **M3 (Inverted normal disclosure check)**: Suppressing `DISCLOSURE:` when `--hide-ip` is omitted fails -> **KILLED** (`M3_KILLED`).

---

## 3. Proposal Files
- `patch.diff`: Unified patch against `tools/docker/compose.yaml` and `tools/docker/e2e.sh`.
- `apply-notes.md`: Instructions for orchestrator application.
- `verifier-report.md`: Independent verifier sign-off.

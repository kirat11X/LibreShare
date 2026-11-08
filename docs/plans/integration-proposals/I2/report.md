# Integration Card I2 Report: Docker Steps q, r, s

## Summary
Card I2 proposes the final multi-network Docker E2E test steps:
1. **Step `q` (Link share over `inet_net` with fake tunnel):**
   - Backgrounds `ls link` with bounded 30s polling for `^LINK `.
   - Executes real file transfer via `ls receive-link` into `/tmp/rx-q`.
   - Computes whole-file SHA-256 and asserts byte-identical match with source file.
   - Asserts exit code 0 on both sender and receiver.
   - Enforces `--hide-ip` direct candidate omission and unpinned origin rejection.
2. **Step `r` (NAT-PMP mock gateway container):**
   - Verifies gateway IP reachability (`172.28.5.254`) on `lan_net`.
   - Executes NAT-PMP probe on UDP port 5351.
   - Verifies gateway masquerading and NAT traversal connectivity.
3. **Step `s` (Fake relay container rendezvous):**
   - Adds lightweight `relay` container (`172.28.7.253`) on `inet_net` in `compose.yaml`.
   - Verifies relay reachability across containers.
   - Runs `ls peers` on Alice (`/alice-id`) and Bob (`/bob-id`) confirming zero unpaired strangers.

## Verification
- `bash -n tools/docker/e2e.sh`: exit code 0.
- `python3 -c "import yaml; ..."`: exit code 0.
- Patch applies cleanly with `git apply --check -p1` (rc=0).
- All commands in steps `q`, `r`, `s` bounded by `timeout` (5s or 30s) to guarantee zero hangs.

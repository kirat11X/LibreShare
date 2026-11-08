# Card A-DOCKER Verifier Report: Mutation Analysis

## Mutation Testing Summary

| Mutation ID | Target File & Line | Mutation Description | Expected Result | Actual Result | Status |
|-------------|-------------------|----------------------|-----------------|---------------|--------|
| **M1** | `tools/docker/e2e.sh:577` | Alter expected byte count in step m (`grep -q "99999999 bytes"`) | Step m check fails (RED) | Check failed as expected | **KILLED** |
| **M2** | `tools/docker/e2e.sh:612` | Remove `.lspart` file before restarting receiver in step n | Step n check fails (RED) | Check failed as expected | **KILLED** |
| **M3** | `tools/docker/e2e.sh:625` | Corrupt the received file (`echo "corrupt" >> "$RX_DIR_N/e2e-n.bin"`) | `cmp -s` check fails (RED) | Check failed as expected | **KILLED** |
| **M4** | `tools/docker/e2e.sh:678` | Require 21 valid fault outcomes instead of 20 (`test "$valid_fault_outcomes" -eq 21`) | Step o check fails (RED) | Check failed as expected | **KILLED** |

All 4 mutations are killed by the test assertions.
Bash syntax check: `bash -n tools/docker/e2e.sh` -> `rc=0`.
Diff check: `grep -c '^--- ' docs/plans/inc4-proposals/A-DOCKER/patch.diff` -> `3`.

# QA Wave E Report: Loopback CLI End-to-End Scenarios

**Execution Date:** 2026-11-08  
**Scope:** Real `ls` CLI processes on loopback under `/tmp/libreshare-heavy.lock`.  
**Script:** `.toolchain/scratch/qa/run_wave_e_scenarios.sh`  
**Verdict:** ALL 9 CLI SCENARIOS PASSED (exit code 0, 64, 66 matches spec).

### Scenario Results

| Scenario | Command Executed | Expected Exit / Output | Actual Result | Status |
| :--- | :--- | :--- | :--- | :--- |
| **S1** | `ls info` | Exit 0, JSON/text device info (`port=0 v=1.1`) | Matched output, rc=0 | **PASS** |
| **S2** | `ls devices --timeout 1` | Exit 0, device discovery list (`DEVICES 0`) | Output `DEVICES 0`, rc=0 | **PASS** |
| **S3** | `ls send ... missing_file` | Exit 66 (file not found per BSD/CLI standard) | rc=66 | **PASS** |
| **S4** | `ls send --speed invalid` | Exit 64 (usage/syntax error) | rc=64 | **PASS** |
| **S5** | `ls link --help` | Exit 0, usage documentation for link sharing | Help text displayed, rc=0 | **PASS** |
| **S6** | `ls receive-link --help`| Exit 0, usage documentation for receiving links | Help text displayed, rc=0 | **PASS** |
| **S7** | `ls pair --help` | Exit 0, usage documentation for pairing | Help text displayed, rc=0 | **PASS** |
| **S8** | `ls peers` | Exit 0, list paired rendezvous peers | Empty table/list, rc=0 | **PASS** |
| **S9** | `ls contacts list` | Exit 0, list trusted/blocked contacts | Table header, rc=0 | **PASS** |

### Summary
- Scenarios executed: 9 / 9 PASS
- Contract compliance: Exit codes 0, 64, 66 conform strictly to `docs/user/guide.md`
- S0/S1 defects found: 0

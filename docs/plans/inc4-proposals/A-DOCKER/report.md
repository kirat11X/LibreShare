# Card A-DOCKER Report: Real Docker Steps a, b, m, n, o (rebased)

Status: READY (rebased against current tree, patch -p1 clean rc=0)
Apply check: git apply --check -p1 docs/plans/inc4-proposals/A-DOCKER/patch.diff -> rc=0

## Scope & Deliverables
- Step a): Diagnostic logging of actual IP/port/platform; handles multi-homed bridge arrivals.
- Step b): Fixes UDP drop rule with `--sport "$PORT"` alongside `--dport "$PORT"`.
- Step m): Fixes CLI options (`--insecure-tofu`, `--provider fake`), tests share link, restores nets.
- Step n): Real receiver kill -9 mid-transfer, sidecar `.lspart` persistence, byte-identical resume.
- Step o): 20 seeded netem fault runs on loopback asserting clean terminal states.

## Verification & Mutation Sweep (4/4 killed)
- Syntax: `bash -n tools/docker/e2e.sh` -> rc=0.
- Patch verification: `git apply --check -p1` -> rc=0.
- M1 (invert step m cut failure assert): fails rc=1. KILLED.
- M2 (invert step b subnetScan assert): fails rc=1. KILLED.
- M3 (invert step n resume assert): fails rc=1. KILLED.
- M4 (invert step o fault outcome counter): fails rc=1. KILLED.
- Review: `review.md` complete per REVIEW_STANDARD.md.

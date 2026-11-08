# Card J8b Report: Step m) E2E Fixes (rebased)

Status: READY (patch -p1 against current tree rc=0)
Apply check: git apply --check -p1 docs/plans/inc5-proposals/J8b/patch.diff -> rc=0

## Scope & Diagnoses
- Diagnosis: Step `m)` failed because:
  1. `ls send` received invalid option `--timeout 2` (exit 64).
  2. Fallback transfer over `$INET_BOB_IP` lacked `--insecure-tofu`, causing SAS prompt EOF abort (exit 83).
  3. `ls link` received non-existent `--allow-dev` and hung synchronously.
- Fix: Use valid options (`--insecure-tofu`, `--provider fake`), background `link`, wait for `peer_up "$BOB_IP"` after restore.

## Verification & Mutation Sweep (3/3 killed)
- Syntax: `bash -n tools/docker/e2e.sh` -> rc=0.
- Patch verification: `git apply --check -p1` -> rc=0.
- M1 (invert failure check): fails rc=1. KILLED.
- M2 (invert fallback completion check): fails rc=1. KILLED.
- M3 (corrupt share link check): fails rc=1. KILLED.
- Review: `review.md` complete per REVIEW_STANDARD.md.

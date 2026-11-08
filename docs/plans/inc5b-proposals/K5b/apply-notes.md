# Card K5b Apply Notes

## Summary
Resolves the hang in Docker E2E step q:
1. Runs `ls link` in background with output redirected to temporary log files, polling (max 30 s) for link readiness.
2. Bounds every blocking command in step q with `timeout`.
3. Adds global watchdog to `tools/docker/e2e.sh` (exits non-zero after 15 min if hanging process occurs).
4. Restores `trap cleanup EXIT INT TERM` after step o.
5. On failure or timeout, prints last 10 lines of background log.

## Modified Files
- `tools/docker/e2e.sh`

## Verification
- `git apply --check -p1 patch.diff` exits 0.
- `bash -n tools/docker/e2e.sh` exits 0.

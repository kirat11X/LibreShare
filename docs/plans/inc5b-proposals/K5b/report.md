# Card K5b Report: Fix Docker E2E Step q Hang & Global Watchdog

**Increment:** 5b  
**Card:** K5b  
**Status:** READY  
**Date:** 2026-11-08  

## Root Cause Analysis
In Docker E2E step q, `ls link /tmp/e2e-q.bin --provider fake ...` was invoked synchronously in the foreground. In LibreShare CLI, `ls link` starts an HTTP server serving the share until explicitly terminated or expired. As a result, the command never exited on its own, causing the test runner to hang until killed externally (run 1 killed after 143/SIGTERM; run 2 hung for 11+ minutes).

## Fix Implemented
1. Backgrounded `ls link` calls with output redirected to `/tmp/link-hide.log` and `/tmp/link-disc.log`.
2. Added polling loops (bounded by 30 s) looking for `^LINK ` before performing assertions.
3. Added diagnostic logging (`tail -n 10 <log>`) on timeout or failure.
4. Added process cleanup (`kill` and `wait`) immediately following each test block.
5. Wrapped `nc -zv` and `ping` commands with explicit `timeout 5`.
6. Installed a global 15-minute background watchdog in `e2e.sh` that aborts the script with an error banner if any step ever hangs.
7. Fixed trap handling so `cleanup()` is restored after step o.

## Verification
- `git apply --check -p1 docs/plans/inc5b-proposals/K5b/patch.diff` exits 0.
- `bash -n tools/docker/e2e.sh` exits 0.

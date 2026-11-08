# Card J8b Apply Notes

## Summary
Fixes step `m)` in `tools/docker/e2e.sh`:
- Removes invalid `--timeout 2` argument on `ls send`.
- Adds `--insecure-tofu` to `ls send --to $INET_BOB_IP:$PORT` to avoid headless SAS abort (exit 83).
- Uses `--provider fake` in background with timeout/grep to capture share link without hanging.
- Waits for `peer_up "$BOB_IP"` after restoring interfaces.

## Target Files
- `tools/docker/e2e.sh`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5-proposals/J8b/patch.diff
```

## Verification Steps
```bash
bash -n tools/docker/e2e.sh
git apply --check -p1 docs/plans/inc5-proposals/J8b/patch.diff
```

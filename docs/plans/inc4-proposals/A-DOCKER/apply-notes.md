# Card A-DOCKER Apply Notes (Rebased)

## Summary
Rebased Docker E2E suite against current tree (with Increment 5 applied):
- Step `a)`: Diagnoses and accommodates multi-homed addresses across connected Docker bridge networks, printing actual IP/port/platform.
- Step `b)`: Drops incoming UDP from source port 53318 as well as destination port 53318 to ensure full UDP drop simulation for ephemeral probe replies.
- Step `m)`: Replaces invalid CLI flags with `--insecure-tofu` and `--provider fake`, cleanly testing share link generation and internet route fallback without hanging.
- Step `n)`: Real receiver kill -9 mid-transfer, verifying `.lspart` persistence and byte-identical resume (`cmp`).
- Step `o)`: 20 seeded deterministic fault runs (delay, loss, duplicate, reorder) verifying valid terminal states.

## Target Files
- `tools/docker/e2e.sh`

## Application Instructions
```bash
patch -p1 < docs/plans/inc4-proposals/A-DOCKER/patch.diff
```

## Verification Steps
```bash
bash -n tools/docker/e2e.sh
git apply --check -p1 docs/plans/inc4-proposals/A-DOCKER/patch.diff
```

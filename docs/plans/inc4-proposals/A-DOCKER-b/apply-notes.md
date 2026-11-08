# Card A-DOCKER-b Apply Notes

## Summary
Fixes the Step `b)` premise in `tools/docker/e2e.sh`:
- Adds `RULE_SPORT=(INPUT -p udp --sport "$PORT" -j DROP)` alongside `RULE_DPORT=(INPUT -p udp --dport "$PORT" -j DROP)`.
- Drops incoming unicast responses sent from peer discovery port 53318 to tester's ephemeral probe port.
- Ensures UDP discovery is completely blocked so that `devices` control finds 0 devices and `--scan` discovers peers via TCP subnet sweep (`source=subnetScan`).

## Target Files
- `tools/docker/e2e.sh`

## Application Instructions
```bash
patch -p1 < docs/plans/inc4-proposals/A-DOCKER-b/patch.diff
```

## Verification Steps
```bash
bash -n tools/docker/e2e.sh
git apply --check -p1 docs/plans/inc4-proposals/A-DOCKER-b/patch.diff
```

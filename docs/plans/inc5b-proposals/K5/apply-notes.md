# Card K5 Apply Notes

## Summary
Adds `gateway` container with NAT masquerading between `lan_net` and `inet_net` in `tools/docker/compose.yaml`, and adds Step `q)` in `tools/docker/e2e.sh` verifying direct origin TLS pinning, CLI hide-ip disclosure behavior, and gateway reachability.

## Target Files
- `tools/docker/compose.yaml`
- `tools/docker/e2e.sh`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5b-proposals/K5/patch.diff
```

## Verification Steps
```bash
bash -n tools/docker/e2e.sh
python3 -c "import yaml; yaml.safe_load(open('tools/docker/compose.yaml'))"
```

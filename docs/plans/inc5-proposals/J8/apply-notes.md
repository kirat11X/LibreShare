# Card J8 Apply Notes

## Summary
Updates Docker Compose networks, Dockerfile context, and end-to-end integration test step `m)` to exercise multi-network topology and internet fallback when all local network interfaces are severed.

## Target Files
- `tools/docker/compose.yaml`
- `tools/docker/Dockerfile`
- `tools/docker/Dockerfile.dockerignore`
- `tools/docker/e2e.sh`

## Application Instructions
```bash
patch -p1 < docs/plans/inc5-proposals/J8/patch.diff
```

## Verification Steps
```bash
python3 -c "import yaml; yaml.safe_load(open('tools/docker/compose.yaml'))"
bash -n tools/docker/e2e.sh tools/docker/cut_wifi.sh
```

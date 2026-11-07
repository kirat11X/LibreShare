# Increment 4 — Card D2 / P4-9 Apply Notes

## Applying the Proposal

From repository root:
```bash
cp docs/plans/inc4-proposals/P4-9/cut_wifi.sh tools/docker/cut_wifi.sh
cp docs/plans/inc4-proposals/P4-9/compose.yaml tools/docker/compose.yaml
chmod +x tools/docker/cut_wifi.sh
```

## Quality Gate Verification

```bash
docker compose -f tools/docker/compose.yaml config
bash -n tools/docker/cut_wifi.sh
```

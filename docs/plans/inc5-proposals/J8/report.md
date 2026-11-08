# Card J8 Report: Docker inet_net & Step m) Multi-Network Cut (rebased)

Status: READY (rebased against current tree, patch -p1 clean rc=0)
Apply check: git apply --check -p1 docs/plans/inc5-proposals/J8/patch.diff -> rc=0

## Scope & Deliverables
- `tools/docker/compose.yaml`: adds `inet_net` bridge network (`172.28.7.0/24`).
- `tools/docker/Dockerfile*`: installs `cut_wifi.sh` (0755) in image context.
- `tools/docker/e2e.sh`: step `m)` multi-network fault cut (fails on severed LAN/Wi-Fi, succeeds via tunnel route, restores interfaces).

## Verification & Mutation Sweep (3/3 killed)
- Syntax: `bash -n tools/docker/{e2e,cut_wifi}.sh` -> rc=0.
- Compose: `python3 -c "import yaml; yaml.safe_load(open('tools/docker/compose.yaml'))"` -> rc=0.
- M1 (invert severed transfer assertion): red -> KILLED.
- M2 (corrupt transfer completion check): red -> KILLED.
- M3 (corrupt link generation check): red -> KILLED.
- Review: `review.md` complete per REVIEW_STANDARD.md.

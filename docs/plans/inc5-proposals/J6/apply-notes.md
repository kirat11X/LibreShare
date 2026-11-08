# Apply Notes for Card J6: CLI link and receive-link commands

## 1. Apply Patch
Apply `patch.diff` with `patch -p0 < docs/plans/inc5-proposals/J6/patch.diff` from the repo root to update:
- `packages/libreshare_cli/lib/ls_cli.dart`

## 2. Copy Test Files
```bash
cp docs/plans/inc5-proposals/J6/test/link_test.dart packages/libreshare_cli/test/
```

## 3. Dependencies & Prerequisites
Card J6 uses `TunnelKeys`, `TunnelOriginServer`, `TunnelOriginShare`, `TunnelConnection`, `FakeTunnelProvider`, `CloudflaredProvider`, `ManualUrlProvider`, `ZrokProvider`, and `ShareLink` from `libreshare_core`. Requires Increment 5 groundwork and Phase J cards (H1-H3, J0, wave1b, J3, J4, J5) applied.

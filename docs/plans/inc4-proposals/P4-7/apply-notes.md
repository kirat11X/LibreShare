# Increment 4 — Card C2 / P4-7 Apply Notes

## Applying the Proposal

The engine and CLI wiring are already incorporated into `packages/libreshare_core/lib/src/engine/libreshare_engine.dart` and `packages/libreshare_cli/lib/ls_cli.dart`.

## Quality Gate Verification

```bash
source tools/env.sh
dart format --output=none --set-exit-if-changed packages/libreshare_cli/
dart analyze packages/libreshare_core/lib/ packages/libreshare_cli/lib/
cd packages/libreshare_cli
dart test -j 1
```

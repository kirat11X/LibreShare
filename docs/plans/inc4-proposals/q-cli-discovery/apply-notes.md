# Apply Notes: Card Q-CLI-DISCOVERY

## Modified Files
1. `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart`
   - Added `import '../protocol.dart';` for `kDefaultPort`.
   - In `_reply()`: also send probe replies via `transport.sendMulticast(bytes)` when `packet.source.isLoopback || packet.port == kDefaultPort`.
2. `packages/libreshare_cli/lib/ls_cli.dart`
   - In `_findDevice`: trigger `unawaited(engine.refresh().then((_) {}, onError: (_) {}));` on discovery start.
   - In `_awaitMatches`: check `_matchDevices(engine.currentDevices, selector).isNotEmpty` immediately on entry and arm `settle`.

## New Test File
1. `packages/libreshare_cli/test/q_cli_discovery_test.dart`
   - Tests `_awaitMatches` pre-populated cache settle timing.
   - Tests multicast probe reply delivery on loopback / default port.

## Application Instructions
Apply `patch.diff` with `-p0` from repository root:
```bash
patch -p0 < docs/plans/inc4-proposals/q-cli-discovery/patch.diff
cp docs/plans/inc4-proposals/q-cli-discovery/test/q_cli_discovery_test.dart packages/libreshare_cli/test/
```

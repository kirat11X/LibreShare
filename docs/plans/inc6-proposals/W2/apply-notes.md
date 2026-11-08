# Card W2 Apply Notes

## Summary
Implements pure-Dart BIP-340 Schnorr signature engine (`bip340.dart`), canonical NIP-01 event encoder/validator (`nip01.dart`), in-process WebSocket Nostr relay server (`loopback_nostr_relay.dart`), and multi-relay failover backend (`nostr_backend.dart`).

## Target Files
- `packages/libreshare_core/lib/src/rendezvous/bip340.dart`
- `packages/libreshare_core/lib/src/rendezvous/nip01.dart`
- `packages/libreshare_core/lib/src/rendezvous/loopback_nostr_relay.dart`
- `packages/libreshare_core/lib/src/rendezvous/nostr_backend.dart`
- `packages/libreshare_core/lib/libreshare_core.dart`
- `packages/libreshare_core/test/unit/rendezvous/wave2_test.dart`

## Application Instructions
```bash
patch -p1 < docs/plans/inc6-proposals/W2/patch.diff
cp docs/plans/inc6-proposals/W2/test/unit/rendezvous/wave2_test.dart packages/libreshare_core/test/unit/rendezvous/
```

## Verification Steps
```bash
dart analyze --fatal-infos packages/libreshare_core/lib/src/rendezvous/ packages/libreshare_core/test/unit/rendezvous/
dart test packages/libreshare_core/test/unit/rendezvous/
```

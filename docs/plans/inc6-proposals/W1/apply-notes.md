# Card W1 Apply Notes

## Summary
Implements `ChannelDeriverImpl` for 24h epoch channel rotation, `EnvelopeCodecImpl` with discrete length bucketing and AES-256-GCM authentication, `ReplayGuard` enforcing monotonic sequences and clock skew bounds, and `InMemoryRelay` for in-process test execution.

## Target Files
- `packages/libreshare_core/lib/src/rendezvous/channel_deriver.dart`
- `packages/libreshare_core/lib/src/rendezvous/envelope_codec.dart`
- `packages/libreshare_core/lib/src/rendezvous/replay_guard.dart`
- `packages/libreshare_core/lib/src/rendezvous/in_memory_relay.dart`
- `packages/libreshare_core/lib/libreshare_core.dart`
- `packages/libreshare_core/test/unit/rendezvous/wave1_test.dart`

## Application Instructions
```bash
patch -p1 < docs/plans/inc6-proposals/W1/patch.diff
cp docs/plans/inc6-proposals/W1/test/unit/rendezvous/wave1_test.dart packages/libreshare_core/test/unit/rendezvous/
```

## Verification Steps
```bash
dart analyze --fatal-infos packages/libreshare_core/lib/src/rendezvous/ packages/libreshare_core/test/unit/rendezvous/
dart test packages/libreshare_core/test/unit/rendezvous/
```

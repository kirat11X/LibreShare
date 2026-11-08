# Card W4 Apply Notes

**Files modified by patch.diff:**
1. `packages/libreshare_core/lib/src/rendezvous/presence_cache.dart` (new)
2. `packages/libreshare_core/lib/src/rendezvous/rendezvous_service_impl.dart` (new)
3. `packages/libreshare_core/lib/src/rendezvous/in_memory_relay.dart` (update)

**New test files to place:**
1. `docs/plans/inc6-proposals/W4/test/wave4_test.dart` -> `packages/libreshare_core/test/unit/rendezvous/wave4_test.dart`

**Verification command:**
```bash
patch -p0 < docs/plans/inc6-proposals/W4/patch.diff
cp docs/plans/inc6-proposals/W4/test/wave4_test.dart packages/libreshare_core/test/unit/rendezvous/wave4_test.dart
dart test packages/libreshare_core/test/unit/rendezvous/wave4_test.dart
```

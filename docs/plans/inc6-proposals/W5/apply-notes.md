# Card W5 Apply Notes

**Files modified by patch.diff:**
1. `packages/libreshare_core/lib/src/rendezvous/nostr_backend.dart` (BIP-340 Schnorr signature fallback)
2. `packages/libreshare_core/lib/src/rendezvous/loopback_nostr_relay.dart` (`_safeSend` guards)
3. `packages/libreshare_core/lib/src/rendezvous/rendezvous_service_impl.dart` (`sealedAck` computation & validation, `relayUrls` option)

**New test files to place:**
1. `docs/plans/inc6-proposals/W5/test/wave5_test.dart` -> `packages/libreshare_core/test/unit/rendezvous/wave5_test.dart`

**Verification command:**
```bash
patch -p0 < docs/plans/inc6-proposals/W5/patch.diff
cp docs/plans/inc6-proposals/W5/test/wave5_test.dart packages/libreshare_core/test/unit/rendezvous/wave5_test.dart
dart test packages/libreshare_core/test/unit/rendezvous/wave5_test.dart
```

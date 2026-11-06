# Apply notes R4d
1. `cd <repo root> && patch -p1 < docs/plans/e-proposals/r4d/patch.diff` (touches only packages/libreshare_core/lib/src/discovery/peer_registry.dart; paths a/ b/).
2. Copy `peer_registry_cert_cache_test.dart` to packages/libreshare_core/test/unit/ (about 2 min, @Timeout 5 min).
3. Verify: that file, `dart test -j 1` of the package (expect 2614 passed, 1 skipped), `dart analyze --fatal-infos`, `dart format --set-exit-if-changed`.
No protocol/schema/contract/engine change; `learnCertificate` signature unchanged. Note `test/discovery` does not exist, do not use it in gate commands.

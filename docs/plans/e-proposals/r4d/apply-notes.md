# Apply notes R4d
1. `cd <repo root> && patch -p1 < docs/plans/e-proposals/r4d/patch.diff` (touches only packages/libreshare_core/lib/src/discovery/peer_registry.dart; paths a/ b/).
2. Copy the three test files: `peer_registry_cert_cache_test.dart`, `verifier-tests/peer_registry_cert_cache_verifier_probes_test.dart` (about 20 min alone) and `verifier-tests/peer_registry_cert_cache_verifier_p6_test.dart` to packages/libreshare_core/test/unit/ (about 2 min, @Timeout 5 min).
3. Verify: that file, `dart test -j 1` of the package (expect 2625 passed, 1 skipped with the verifier files; 2614 without), `dart analyze --fatal-infos`, `dart format --set-exit-if-changed`.
No protocol/schema/contract/engine change; `learnCertificate` signature unchanged. Note `test/discovery` does not exist, do not use it in gate commands.

## Round 3 apply list (F7 fix)
Apply patch.diff (1 section, peer_registry.dart only), then copy into packages/libreshare_core/test/unit/:
1. peer_registry_cert_cache_test.dart (7 tests)
2. verifier-tests/peer_registry_cert_cache_verifier_p6_test.dart (1)
3. verifier-tests/peer_registry_cert_cache_verifier_r2_test.dart (10) -- NOTE: 3 of its tests (R2-A2, R2-B4, R2-C3) assert the old attribution label '' and are RED with the F7 fix (actual label is the victim's own address, which is the intended result). They need the verifier/tester to flip those assertions; the coder may not edit tests.
4. verifier-tests/peer_registry_cert_cache_verifier_probes_test.dart (optional, ~18 min)

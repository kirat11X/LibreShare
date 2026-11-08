# Card H1 Report: tunnel_crypto (REBASED)

**Card:** H1 (tunnel_crypto.dart — E2E AEAD encryption, HKDF derivation, replay protection)  
**Status:** REBASED (Clean `patch -p1 --dry-run`, 24/24 tests pass, analyze rc=0, format rc=0)  

## Evidence & Verification
- `patch -p1 --dry-run < docs/plans/inc5-proposals/h1-tunnel-crypto/patch.diff`: clean (`rc=0`)
- `dart test packages/libreshare_core/test/unit/tunnel_crypto_test.dart`:
  Output: `00:00 +24: All tests passed!` (`rc=0`)
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/security/tunnel_crypto.dart`:
  Output: `No issues found!` (`rc=0`)
- `dart format --output=none --set-exit-if-changed ...`:
  Output: `Formatted 2 files (0 changed)` (`rc=0`)
- 9/9 mutations killed in `verifier-report.md`.
- Known-answer vectors self-contained in `tunnel_crypto_test.dart` (zero writes to `test/conformance/fixtures/`, zero regression in `schema_conformance_test.dart`).
- RFC 5869 HKDF subkeys, AES-256-GCM authenticated encryption, 96-bit nonces, AAD binding, $2^{24}$ seal cap.

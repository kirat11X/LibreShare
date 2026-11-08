# Review: Card J0 (Wave 0 Contracts)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/tunnel/tunnel_provider.dart` (new file, `patch.diff` count: 3 files, `grep -c '^--- ' patch.diff` = 3)
  - `packages/libreshare_core/lib/src/model/origin_candidate.dart` (new file)
  - `packages/libreshare_core/lib/src/model/share_models.dart` (new file)
  - `docs/protocol/LSP-1.md` Section 4.5 (`lsp1-section-4.5.md`)
  - `docs/protocol/schemas/tunnel-offer.schema.json`
- Spec & plan rows satisfied:
  - `FR-14` (Internet Link Transfer Wave 0 Contracts: TunnelProvider interface, OriginCandidate, ShareRecord)
  - `docs/plans/inc5.md` Section 13 (Wave 0 contracts)

## 2. Diff Read
- `L1-71` (`tunnel_provider.dart`): OK. Abstract interfaces for `TunnelProvider`, `TunnelHandle`, and sealed `TunnelEvent` hierarchy (`TunnelUpEvent`, `TunnelLostEvent`, `TunnelRateLimitedEvent`, `TunnelLogEvent`).
- `L72-103` (`origin_candidate.dart`): OK. **[SECURITY-CRITICAL: Origin & Pinning]** `OriginKind` enum, `OriginCandidate` model with value equality and `[pinned]` redaction in `toString()`.
- `L104-162` (`share_models.dart`): OK. **[SECURITY-CRITICAL: Secret Redaction]** `ShareMode` enum, `ShareRecord` with JSON serialization. `toString()` strictly redacts `token: [redacted]`.

## 3. Tests vs Spec
| Requirement | Test / Verification Point | What Assertion Proves |
|---|---|---|
| Contract interfaces | Static analysis on `tunnel_provider.dart` | Zero errors or circular dependencies; clean abstract signatures. |
| Model equality | Downstream suite `origin_pull_connection_test.dart` | Confirms `OriginCandidate` value equality across kind, base URI, and TLS pin. |
| JSON serialization | Downstream suite `share_store_test.dart` | Verifies `ShareRecord.toJson()` and `fromJson()` round trip without data loss. |
| Token redaction | `ShareRecord.toString()` assertion in `share_store_test.dart` | Verifies raw secret token never appears in string representations. |
| Schema conformance | `tunnel-offer.schema.json` schema validation | Matches draft LSP-1 Section 4.5 JSON payload requirements. |

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Token redaction | Output raw `token` in `ShareRecord.toString` | `share_store_test.dart` (toString redaction test) | rc=1 | `diff -r` clean, rc=0 |
| TLS pin check equality | Remove `tlsPinHex` from `OriginCandidate.operator ==` | `origin_candidate_test.dart` | rc=1 | `diff -r` clean, rc=0 |
| Default `maxReceivers` | Change default fallback from 1 to 0 | `share_store_test.dart` (default receiver count) | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **OriginCandidate with null TLS pin:** Correctly treats pin as optional without NullPointer exceptions.
2. **ShareRecord with null expiration:** Serializes and deserializes cleanly without `'expiresAt'` key.
3. **Unexpected JSON types in ShareRecord:** Types cast with safe numeric conversion (`as num`).
4. **OriginCandidate toString:** Prints `'tlsPinHex: [pinned]'` instead of exposing raw hex certificate fingerprint.
5. **ShareRecord toString:** Emits `'token: [redacted]'` preventing accidental log leaks.

## 6. Resource and Failure Behaviour
- Pure contracts, models, and interfaces: zero background timers, sockets, or open file descriptors.
- Serialization and deserialization execute in memory without unbounded collections.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J0/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/tunnel/ packages/libreshare_core/lib/src/model/`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/tunnel/ packages/libreshare_core/lib/src/model/`:
  `rc=0` (0 files changed).

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Validate LSP-1 Section 4.5 text and `tunnel-offer.schema.json` against RFC schema standards.

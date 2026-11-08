# Card J0 Report: Wave 0 Contracts (REBASED)

**Card:** J0 (TunnelProvider, OriginCandidate, ShareRecord, LSP-1 4.5, tunnel-offer schema)  
**Status:** REBASED (Clean `patch -p1 --dry-run`, analyze rc=0, format rc=0)  

## Evidence & Verification
- `patch -p1 --dry-run < docs/plans/inc5-proposals/J0/patch.diff`: clean (`rc=0`)
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/tunnel/ packages/libreshare_core/lib/src/model/`:
  Output: `No issues found!` (`rc=0`)
- `dart format --output=none --set-exit-if-changed ...`:
  Output: `Formatted 3 files (0 changed)` (`rc=0`)
- Defines interfaces for `TunnelProvider`, `TunnelHandle`, `TunnelEvent`, `OriginCandidate`, and share models.
- Proposal includes `lsp1-section-4.5.md` and `tunnel-offer.schema.json`.

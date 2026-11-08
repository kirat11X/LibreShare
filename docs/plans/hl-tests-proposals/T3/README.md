# Card T3: Protocol Fuzz / Property Tests

## Destination Path
When applied by the orchestrator:
- Copy `protocol_fuzz_property_test.dart` to `packages/libreshare_core/test/unit/protocol_fuzz_property_test.dart`.

## Scope & Specifications Tested
- **FR-08 (Chunker math & 64-bit offsets):** Boundary file sizes (0, 1, cs-1, cs, cs+1, 2cs-1, 2cs, 2cs+1, 3cs-1, 3cs, 3cs+1), huge file arithmetic (2^32-1, 2^32, 2^32+1, 2^53-1/9 PB), 500 seeded random size property tests asserting `(size + cs - 1) ~/ cs`, chunk boundary adjacency, and 0-size safety.
- **FR-09 & T7 (Filename Sanitizer & Path Traversal):** 24 corpus traversal/DOS/bidi/Unicode filenames + 1000 seeded random mutated path strings evaluated against both POSIX (`p.posix.isWithin`) and Windows (`p.windows.isWithin`) path semantics; verifies that sanitized paths NEVER escape target directory.
- **LSP-1 §4.2 (Discovery Announce Codec):** 1000 seeded fuzz iterations of random bytes, truncated payloads, and mutated envelopes; asserts non-throwing decode, schema compliance, length bounds (<= 512 bytes), and round-trip fidelity.
- **Spec §4.3 (Manifest & Wire DTOs):** Unknown-field tolerance, malformed JSON dictionary parsing, and missing required field rejection across `FileItem` and `SessionRequest`.
- **Request Headers:** Boundaries and malformed formats for `X-Chunk-Sha256` (64-char hex), `Content-Length` (negative, overflow, non-numeric), and `Range: bytes=start-end` syntax.
- **FileState Response Shape:** JSON parsing and interval monotonicity properties.
- **FR-14 & H2 (ShareLink / URI Parser):** 1000 seeded random URL/URI strings; asserts parser throws exclusively `ShareLinkException` or produces a valid structure.

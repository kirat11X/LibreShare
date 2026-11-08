# Review: Card T3 (Protocol Fuzz / Property Tests)

**Reviewer:** Antigravity (Independent Auditor)  
**Date:** 2026-11-07  
**Card Folder:** `docs/plans/hl-tests-proposals/T3/`

---

### 1. Scope
- **Files added:**
  - `packages/libreshare_core/test/unit/protocol_fuzz_property_test.dart`
- **Specification rows satisfied:**
  - `FR-08`: Chunker 64-bit chunk range and boundary mathematics.
  - `FR-09` & `T7`: Filename sanitization, path traversal containment on both POSIX and Windows path contexts.
  - `LSP-1 §4.2`: Discovery announce packet decoding safety, fuzz tolerance, round-trip re-encoding.
  - `Spec §4.3`: Wire DTO unknown-field tolerance, schema bounds.
  - `FR-14` & `H2`: ShareLink parsing fuzzing, SSRF defensive containment, exception type safety.

---

### 2. Diff Read
- **Group 1: Imports & Test Setup (`test/unit/protocol_fuzz_property_test.dart` L1-40):** OK. Clean imports of core classes (`Chunker`, `FileItem`, `SessionRequest`, `FileState`, `ShareLink`, `ShareLinkException`, `encodeAnnounce`, `decodeAnnounce`, `kMaxAnnounceBytes`). Seeded random initialization (`Random(42)`, `Random(1337)`, `Random(777)`).
- **Group 2: Chunker boundary & 64-bit properties (L41-155):** OK. Tests sizes 0, 1, `cs-1`, `cs`, `cs+1`, `2cs-1`, `2cs`, `2cs+1`, `3cs-1`, `3cs`, `3cs+1`, and 64-bit boundaries (`2^32-1`, `2^32`, `2^32+1`, `2^53-1` / 9 PB). Validates chunk adjacency `ranges[i].end == ranges[i+1].start` and total span equality.
- **Group 3: Filename sanitizer & cross-platform traversal (L156-322):** OK. Tests 24 corpus traversal attack vectors (`../`, `..\`, `CON`, `NUL`, `AUX`, `C:\`, `\\server\share`, URL-encoded `%2e%2e`, RTL overrides, trailing dots/spaces) + 1000 random mutations. Asserts `p.posix.isWithin(base, joined)` AND `p.windows.isWithin(base, joined)`.
- **Group 4: Discovery announce codec fuzzing (L323-376):** OK. Tests 1000 iterations of random byte arrays, truncated headers, flipped bits. Asserts `decodeAnnounce` never throws unexpected exceptions, respects `<= 512` byte cap, and preserves valid announce payloads through decode-encode roundtrip.
- **Group 5: Wire DTO and HTTP headers fuzzing (L377-540):** OK. Tests unknown field tolerance in `FileItem` and `SessionRequest`. Tests `X-Chunk-Sha256` 64-hex requirement, `Content-Length` integer overflow/negative parsing, and `Range` header interval monotonicity.
- **Group 6: /state shape & ShareLink fuzzing (L541-610):** OK. Validates `FileState` JSON contract and 1000 seeded iterations of random URLs into `ShareLink.parse`. Confirms parser throws exclusively `ShareLinkException` or produces valid link model.
- **Security Marker:** All tests touch untrusted parser boundaries (network bytes, URL strings, untrusted filenames). Code is purely defensive assertions.

---

### 3. Tests vs Spec
| Requirement | Test Name | Assertion Verification |
| :--- | :--- | :--- |
| **FR-08** | `boundary sizes [0, 1, cs-1, cs...]` | Asserts chunkCount, total span, exact range boundaries. |
| **FR-08** | `64-bit offsets and huge file arithmetic` | Asserts offsets up to 9 PB compute without integer wrap-around. |
| **FR-08** | `random size property test (500 seeded iterations)` | Asserts `count == (size + cs - 1) ~/ cs` and range adjacency. |
| **FR-09 / T7** | `corpus traversal names always resolve strictly inside download dir` | Asserts `p.posix.isWithin` and `p.windows.isWithin` on 24 attack strings. |
| **FR-09 / T7** | `random filename mutation fuzzer (1000 iterations)` | Asserts sanitized names never escape base dir under either path engine. |
| **LSP-1 §4.2** | `decodeAnnounce never throws and validates round trips (1000 iterations)` | Asserts parser catches malformed packets gracefully and roundtrips valid packets. |
| **Spec §4.3** | `FileItem and SessionRequest tolerance of unknown fields` | Asserts DTOs parse JSON with arbitrary extra properties without throwing. |
| **Spec §4.3** | `X-Chunk-Sha256 header validation properties` | Asserts exact 64-char lowercase hex regex acceptance and malformed rejection. |
| **Spec §4.3** | `Range header syntax and interval properties` | Asserts bytes=start-end syntax, rejects inverted and malformed ranges. |
| **FR-14 / H2**| `ShareLink.parse fuzzer (1000 iterations)` | Asserts parser strictly throws `ShareLinkException` and never unhandled crash. |

---

### 4. Mutation Table
| # | Mutation Description | Test Name Affected | Exit Code | Clean Restore Check |
| :- | :--- | :--- | :--- | :--- |
| **M1** | Inverted expected chunk count in random size test (`~/ cs + 1`) | `1. Chunker math random size property test` | `rc=1` | `diff -u` `rc=0` |
| **M2** | Inverted posix path containment check (`isFalse`) | `2. Filename Sanitizer corpus traversal` | `rc=1` | `diff -u` `rc=0` |
| **M3** | Changed caught exception from `ShareLinkException` to `FormatException` | `7. ShareLink / URI Parser Fuzzing` | `rc=1` | `diff -u` `rc=0` |

---

### 5. Adversarial Cases Tried
1. **9 Petabyte file size (2^53 - 1):** Computed chunkCount and range for index `count - 1`. `Chunker` calculated `(9007199254740991 - 4194304, 9007199254740991)` without 64-bit integer overflow.
2. **Windows Alternate Data Streams (`test.txt:secret:$DATA`):** Sanitizer stripped the stream separator `:` resulting in `test.txt_secret_$DATA`, safely within directory.
3. **Null-byte injection in filename (`file\x00.exe`):** Sanitizer replaced null byte with underscore `file_.exe`, preventing C-string truncation vulnerability.
4. **Fuzzed Announce packet with truncated payload (1 byte):** `decodeAnnounce` safely returned `null` instead of throwing `RangeError` or `StateError`.
5. **ShareLink with IPv6 loopback literal (`http://[::1]/#...`):** `ShareLink.parse` threw `ShareLinkException(host_rejected)` as required by SSRF defense.

---

### 6. Resource and Failure Behaviour
- Pure in-memory unit tests; 0 sockets opened, 0 background isolates spawned, 0 temp files written.
- All 13 tests execute in under 0.5 seconds total.
- No secrets, tokens, or private keys logged or rendered.

---

### 7. Compatibility
- `dart analyze test/unit/temp_t3_test.dart`: `rc=0` (0 errors, 0 warnings).
- `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T3/protocol_fuzz_property_test.dart`: `rc=0`.
- All 13 tests pass 3 consecutive runs (`rc=0`).
- Real tree `lib/` files untouched.

---

### 8. Verdict
**ACCEPT**.
**What the deep review must re-check:**
1. Verify that `p.windows.isWithin` behaves identically on native Windows host as under the simulated `p.windows` context on Linux.
2. Verify that 64-bit offsets in `Chunker` map correctly onto OS filesystem write offsets when writing sparse files.

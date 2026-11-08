# Review: Card T8 (Live Wire Protocol Schema Conformance Integration Test)

**Reviewer:** Antigravity (Independent Auditor)  
**Date:** 2026-11-07  
**Card Folder:** `docs/plans/hl-tests-proposals/T8/`

---

### 1. Scope
- **Files added:**
  - `packages/libreshare_core/test/conformance/live_schema_conformance_test.dart`
- **Specification rows satisfied:**
  - `T8`: Live wire traffic checked against protocol schemas (`docs/protocol/schemas/`).
  - `LSP-1 §4.1`: Header casing, constraints, and error envelopes.
  - `LSP-1 §4.3`: REST route inventory, parameter constraints.

---

### 2. Diff Read
- **Group 1: Schema Loading & Validation Harness (`live_schema_conformance_test.dart` L1-100):** OK. Dynamically loads all `.schema.json` files, resolves local cross-file `$ref` with `RefProvider.sync`, compiles `JsonSchema.create` with `draft2020_12`.
- **Group 2: Intercepting Reverse Proxy (L101-200):** OK. Runs in-memory loopback HTTP server that captures full request and response payloads, headers, paths, query params, and forwards transparently to target `ApiServer`.
- **Group 3: Full Transfer Lifecycle (L201-340):** OK. Spawns `LibreShareEngine`, exercises `/api/v1/info`, `/api/v1/register`, `/api/v1/sessions`, `/sessions/:id`, `/state`, chunk `PUT` with `x-ls-chunk-sha256`, `/complete`, and negative control generating `error-envelope`.
- **Group 4: Conformance Verification Loop (L341-410):** OK. Loops over every captured wire exchange:
  - Validates request and response bodies against corresponding JSON schemas.
  - Enforces route whitelist, failing on any undocumented route.
  - Enforces query parameter whitelist, failing on unexpected query parameters.
  - Enforces header casing and lowercase 64-hex format for chunk hashes.
- **Security Marker:** Validates parser strictness, preventing undocumented API exposure or schema drift.

---

### 3. Tests vs Spec
| Requirement | Test Name | Assertion Verification |
| :--- | :--- | :--- |
| **T8 / Schemas** | `full loopback transfer captures live traffic matching schemas` | Validates `device-info`, `session-request`, `session-status`, `file-state`, `error-envelope`. |
| **T8 / Routing** | `no undocumented route called` | Asserts all captured paths match canonical regex set. |
| **T8 / Query** | `no undocumented query parameter sent` | Asserts only `wait` or `token` appear in query parameters. |
| **LSP-1 §4.1** | `header casing and chunk hash format` | Asserts `x-ls-chunk-sha256` is exactly 64 lowercase hex chars. |

---

### 4. Mutation Table
| # | Mutation Description | Test Name Affected | Exit Code | Clean Restore Check |
| :- | :--- | :--- | :--- | :--- |
| **M1** | Inverted expected session status (`equals(201)`) | `full loopback transfer captures live traffic` | `rc=1` | `diff -u` `rc=0` |
| **M2** | Inverted schema validation validity check (`!r.isValid`) | `full loopback transfer captures live traffic` | `rc=1` | `diff -u` `rc=0` |
| **M3** | Inverted documented route matching (`!matchesKnown`) | `full loopback transfer captures live traffic` | `rc=1` | `diff -u` `rc=0` |

---

### 5. Adversarial Cases Tried
1. **Undocumented route query (`/api/v1/unknown_probe`):** Intercepting proxy catches request; regex whitelist rejects with clear error reason.
2. **Undocumented query parameter (`?admin=true`):** Query parameter whitelist rejects request.
3. **Upper-case hex in chunk hash (`A-F`):** Header validator regex `^[0-9a-f]{64}$` rejects uppercase hex, enforcing LSP-1 §4.1 lowercase requirement.
4. **Malformed session request body (`{'sender': 'string_not_object'}`):** Triggers 400 error response from `ApiServer`, validated against `error-envelope.schema.json`.
5. **Missing required fields in wire payloads:** `JsonSchema` validator identifies missing properties and outputs descriptive validation errors.

---

### 6. Resource and Failure Behaviour
- Temporary download directory cleanly removed in `tearDown`.
- Proxy HTTP server and engine cleanly closed in `tearDown`.
- 0 leaked sockets or file handles.

---

### 7. Compatibility
- `dart analyze test/conformance/temp_t8_test.dart`: `rc=0` (0 errors, 0 warnings).
- `dart format --output=none --set-exit-if-changed docs/plans/hl-tests-proposals/T8/live_schema_conformance_test.dart`: `rc=0`.
- All tests pass 3 consecutive runs (`rc=0`).
- Real tree `lib/` untouched.

---

### 8. Verdict
**ACCEPT**.
**What the deep review must re-check:**
1. Confirm that future extensions to `LSP/1.1` (such as BLE beacons or Nostr relay events) update the schema directory and corresponding router whitelist simultaneously.

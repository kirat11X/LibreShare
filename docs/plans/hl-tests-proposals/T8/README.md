# Card T8: Live Wire Protocol Schema Conformance Integration Test

## Destination Path
When applied by the orchestrator:
- Copy `live_schema_conformance_test.dart` to `packages/libreshare_core/test/conformance/live_schema_conformance_test.dart`.

## Scope & Specifications Tested
- **Live Intercepting Reverse Proxy:** Runs a live loopback file transfer between real `ApiClient` / HTTP client and `LibreShareEngine` / `ApiServer` instances through an in-memory intercepting proxy.
- **Protocol JSON Schema Validation:** Captures every HTTP request and response payload on the wire and validates each against canonical JSON schemas under `docs/protocol/schemas/` (`device-info.schema.json`, `session-request.schema.json`, `session-status.schema.json`, `file-state.schema.json`, `error-envelope.schema.json`).
- **Header Constraints & Casing:** Verifies `Content-Type: application/json` casing and enforces that `x-ls-chunk-sha256` is exactly 64-character lowercase hex.
- **Undocumented Route Detection:** Whitelists all observed request paths (`/api/v1/info`, `/api/v1/register`, `/api/v1/sessions`, `/api/v1/sessions/<id>`, `/api/v1/sessions/<id>/files/<id>/state`, `/api/v1/sessions/<id>/files/<id>/chunks/<index>`, `/api/v1/sessions/<id>/files/<id>/complete`) and fails if any undocumented route is invoked.
- **Undocumented Query Parameter Detection:** Enforces that only documented query parameters (`wait`, `token`) appear in request URIs.

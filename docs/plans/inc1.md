# Increment 1 plan - Basic transfer

Spec: `docs/LIBRESHARE_BUILD_SPEC.md` section 12 "Increment 1 (Sprint 1)". Protocol: `docs/protocol/LSP-1.md` (Increment 1 profile in section 0.1). Traceability: `docs/traceability.md`.

## 1. Goal

Prove the transfer core end to end on one machine: two LibreShare instances in separate processes (or one process) move one or more files between each other over the LSP/1 REST API, chunked in 4 MiB pieces, hashed per chunk and per file, reassembled byte-identically, driven entirely from a CLI. HTTP first (TLS is Increment 3); the peer address is given on the command line (discovery is Increment 2).

Done when all acceptance checks in section 5 pass in CI and `docs/traceability.md` shows FR-07, FR-08, FR-09, FR-10 (hashing part), FR-11 and FR-17 as `done`.

### In scope

- Workspace and CI skeleton (`pubspec.yaml` workspace, `analysis_options.yaml`, `.github/workflows/ci.yml`).
- Shared contracts (orchestrator-owned): wire models, `protocol.dart`, `IncomingTransferHandler`, `PeerClient`, `Chunker`, `Clock`, events.
- Sender: manifest, chunk streaming, background-isolate hashing, retry, `FileSender`.
- Receiver: `.lspart` files, idempotent chunk writes, per-chunk and whole-file SHA-256, atomic rename, filename sanitizer, in-memory resume bitmap.
- `ApiServer` (HTTP, behind an interface) and `ApiClient` implementing the Increment 1 profile of LSP/1, including the 426 check and per-IP request-rate limit.
- CLI `packages/libreshare_cli/bin/ls.dart`: `info`, `receive`, `send`.
- Loopback integration tests, a 100 MiB CLI smoke run in CI, and a first throughput measurement (not gated).

### Out of scope (later increments)

Discovery, `/register` callers, engine port announcement, Flutter UI (Inc 2); TLS/mTLS, SAS, TOFU, PIN, consent prompt UI, `BLOCKED`, `INSUFFICIENT_STORAGE` check (Inc 3); connection ladder, D2 session store, resume across channels and the receiver-restart acceptance, `FaultyTcpProxy`, Docker two-network tests, bench gate (Inc 4); tunnel (Inc 5).

## 2. Files per module

Paths are under `packages/libreshare_core/lib/src/` unless stated. "Orch" = orchestrator-owned shared contract (do not edit; report needed changes). Letters refer to the subagent split in section 7.

| Module | File | Owner | Purpose |
|---|---|---|---|
| protocol | `protocol.dart` | Orch | LSP/1 constants (chunk size, ports, limits, header name) |
| model | `model/{device,file_item,session_models,transfer_status,ls_exception,events}.dart` | Orch | Wire DTOs, `LsErrorCode` table, `TransferStatus`/`FailureReason`, `LsEvent` |
| model | `clock.dart` | Orch | Injectable time source |
| transfer 5.0 | `transfer/chunker.dart` | Orch | Chunk math + `openChunk` streaming (0-byte file = 0 chunks) |
| transfer 5.0 | `transfer/manifest.dart` | A | Build `FileItem`/`SessionRequest` from local files: sizes, chunkCount, mime, `modified`, smallest-first order, null sha256 over 2 GiB |
| transfer 5.0 | `transfer/hashing.dart` | A | Streaming SHA-256 of bytes/streams/files/chunk ranges; background `Isolate` for large inputs |
| transfer 6.0 | `transfer/file_sender.dart` | A | `FileSender`: create session, long-poll for acceptance, per-chunk send with retries 0.5/1/2 s, `/state` resync, `complete`, `finish`, events |
| transfer 7.0 | `transfer/file_receiver.dart` | B | `FileReceiver implements IncomingTransferHandler`: sessions, tokens, auto-accept, `.lspart` writes via `RandomAccessFile.setPosition`, chunk-hash check (422), idempotent re-PUT, `complete` (MISSING_CHUNKS / VERIFY_FAILED), atomic rename + mtime, `FileSaved` |
| transfer 7.0 | `transfer/resume_store.dart` | B | Per-file received-chunk bitmap, `receivedRanges` via `compactRanges`; persisted to a `<name>.lspart.json` sidecar every 8 chunks with a 24 h window; D2 integration and resume-across-channels are Inc 4 |
| transfer 7.0 | `transfer/filename_sanitizer.dart`, `transfer/unicode_nfc.dart` | B | NFC, separators, `..` rejection, reserved names, 255-byte truncation, inside-download-dir assertion, collision suffix |
| server | `server/api_server.dart` | C | `ApiServer` (shelf/`dart:io` HTTP, behind an interface): all 9 routes, port fallback 53318..53327, status/envelope mapping, body limits, `Content-Length` rule, streaming chunk body, long-poll `wait` clamp 0..25, 426 pre-check, `Cache-Control: no-store` |
| server | `server/rate_limiter.dart` | C | Token-bucket limiter, 10 `POST /sessions`/min/IP, injectable clock |
| server | `server/incoming_transfer_handler.dart` | Orch | Interface `ApiServer` calls |
| client | `client/api_client.dart` | C | `ApiClient implements PeerClient` over `dart:io` `HttpClient`: streaming PUT with exact `Content-Length`, envelope -> `LsException`, long-poll |
| client | `client/peer_client.dart` | Orch | Interface `FileSender` depends on |
| barrel | `../libreshare_core.dart` | Orch | Exports (add new public files here only through the orchestrator) |
| CLI | `packages/libreshare_cli/bin/ls.dart` | E | `info [--to host:port]`, `receive --port N --dir D [--auto-accept]`, `send --to host:port <files...>` |
| CI | `.github/workflows/ci.yml` | D | `core` job + guarded `e2e-docker`/`app` jobs + loopback smoke step |
| docs | `docs/protocol/LSP-1.md`, `docs/protocol/schemas/*.schema.json`, `docs/traceability.md`, `docs/plans/inc1.md`, `docs/adr/0001..0002`, `README.md` | D | Documentation |

CLI behaviour (Increment 1):

- `ls info --to host:port` prints the peer's `GET /info` (alias, platform, port, version). `ls info` with no argument prints the local device info.
- `ls receive --port 53400 --dir /tmp/rx --auto-accept` starts `ApiServer` on HTTP, writes into `--dir`, accepts every session automatically, and prints one line per received file plus a final success line when the session reaches `COMPLETED`. Without `--auto-accept` it asks on the terminal and rejects when stdin is not interactive. Exit code 0 only after a clean shutdown (Ctrl-C).
- `ls send --to 127.0.0.1:53400 file1 file2 ...` builds the manifest (smallest first), runs `FileSender`, prints progress, and prints a final success line on `COMPLETED`. Exit code 0 on success, non-zero with the `FailureReason` on failure. `--insecure-tofu` from the spec template is not needed until TLS exists (Inc 3).
- Logging uses `package:logging`; file contents, tokens and keys are never logged.

## 3. Test list (tests first; never edit acceptance tests to make them pass)

Under `packages/libreshare_core/test/`. FR mapping follows `docs/traceability.md`.

| Test file | Covers | FR | Owner |
|---|---|---|---|
| `unit/chunker_test.dart` | chunk counts for sizes 0, 1, chunkSize-1, chunkSize, chunkSize+1, 5 GiB sparse (1280 chunks, last chunk readable at 64-bit offset); `range`; `openChunk` streams exact bytes | FR-08 | orchestrator/A |
| `unit/manifest_test.dart` | multiple files, smallest first, fileIds, chunkCount = ceil(size/chunkSize), 0-byte file, null sha256 over 2 GiB, `modified` UTC | FR-07, FR-08 | A |
| `unit/hashing_test.dart` | known vectors, lowercase 64-hex, stream with uneven pieces, file and chunk range, isolate path equals `package:crypto` | FR-09, FR-10 | A |
| `unit/file_sender_test.dart` | against a fake `PeerClient`: happy path with multiple files incl. empty, events, long-poll `wait=25`, trusted auto-accept, unaccepted files skipped, retry/back-off, `/state` resync sends only missing chunks | FR-07, FR-08, FR-11 | A |
| `unit/file_receiver_test.dart` / `unit/reconstruct_test.dart` | `.lspart` creation, out-of-order and duplicate chunks, reassembly byte-identical, atomic rename + mtime, 0-byte file, `FileSaved`, tokens bound to file, WRONG_STATE before accept, OUT_OF_RANGE, MISSING_CHUNKS | FR-09 | B |
| `unit/corruption_test.dart` | chunk with wrong `X-LS-Chunk-SHA256` -> CHUNK_HASH_MISMATCH and chunk not recorded; whole-file mismatch -> VERIFY_FAILED and partial removed (Inc 3 adds the end-to-end resend acceptance) | FR-10 | B |
| `unit/resume_store_test.dart` | bitmap <-> inclusive `receivedRanges`, `compactRanges`/`expandRanges` round-trip, adjacency merge | FR-08, FR-15 groundwork | B |
| `unit/filename_sanitizer_test.dart`, `unit/sanitizer_fuzz_test.dart` | traversal, reserved names, NFC, 255 bytes, symlinks, collision suffix, 10k fuzz names stay inside the dir | FR-16 groundwork | B |
| `unit/rate_limiter_test.dart` | token bucket, refill, key pruning | FR-16 groundwork | C |
| `conformance/api_conformance_test.dart` | every route and status via a raw `dart:io` client against `test/helpers/api_fake_handler.dart`: envelope for each `LsErrorCode` on each route, 400/401/404/413/416/422, ack JSON, `wait` clamp, body limits, unknown fields, 426 + `supported`, rate limit | FR-07..FR-11 (protocol) | C |
| `unit/api_client_test.dart` | `ApiClient` against `ApiServer` + fake handler: round-trips of every call, `LsException` mapping, streaming PUT, `Content-Length` | FR-08, FR-09 | C |
| `conformance/schema_conformance_test.dart` | every DTO `toJson()` and every schema `examples` entry validates against `docs/protocol/schemas`; golden fixtures; unknown fields ignored; `LsErrorCode` table equals LSP-1 section 4.3.5 | protocol | E |
| `integration/loopback_transfer_test.dart` | real `FileReceiver` + `ApiServer` + `ApiClient` + `FileSender` in one process on ephemeral ports: multi-file session incl. 0-byte and a multi-chunk file, byte-identical + SHA-256 equal | FR-07, FR-09, FR-10 | E |
| `integration/completion_events_test.dart` | `SessionCreated`, `FileProgress`, `FileSaved`, `SessionFinished(success)` on both sides | FR-11 | E |
| `integration/bidirectional_test.dart` | engine A sends to B, then B sends to A, both directions byte-identical | FR-17 | E |
| CI step "Loopback transfer smoke" | CLI processes, 100 MiB random file, `cmp` | FR-08..FR-11 | D (workflow), E (CLI) |

## 4. Order of work

1. Orchestrator: workspace, shared contracts, barrel (done before the split).
2. D: docs, schemas, CI skeleton (parallel; no Dart).
3. A, B, C in parallel: each writes its failing tests first, then implements against the contracts only (A talks to `PeerClient`, B implements `IncomingTransferHandler`, C bridges HTTP to both interfaces).
4. E (after A, B, C land): CLI and the integration/conformance tests that need all pieces; wire the CI smoke step.
5. Orchestrator: `dart analyze --fatal-infos`, `dart format`, `dart test`, smoke run, update `docs/traceability.md` statuses to `done`.

## 5. Acceptance checks (spec section 12, Increment 1)

| # | Check | Requirement | Verified by |
|---|---|---|---|
| 1 | Multiple files are transferred in one session | FR-07 | `manifest_test`, `loopback_transfer_test` |
| 2 | Correct chunk counts for sizes 0, 1, chunkSize-1, chunkSize, chunkSize+1, and a 5 GiB sparse file | FR-08 | `chunker_test` |
| 3 | Received files are byte-identical and SHA-256 matches | FR-09, FR-10 | `reconstruct_test`, `loopback_transfer_test`, CI `cmp` |
| 4 | Success is printed/emitted on both the sending and the receiving side | FR-11 | `completion_events_test`, CLI output in CI smoke |
| 5 | A sends to B, then B sends to A | FR-17 | `bidirectional_test` |
| 6 | Command: loopback transfer of a 100 MiB random file via the CLI, then `cmp` | FR-08..FR-11 | CI `core` job step |
| 7 | `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .` and `dart test` are green; core imports no Flutter | NFR-07 | CI `core` job |

Smoke command (also in CI):

```bash
source tools/env.sh
head -c 104857600 /dev/urandom > /tmp/big.bin
dart run packages/libreshare_cli/bin/ls.dart receive --port 53400 --dir /tmp/rx --auto-accept &
dart run packages/libreshare_cli/bin/ls.dart send --to 127.0.0.1:53400 /tmp/big.bin
cmp /tmp/big.bin /tmp/rx/big.bin
```

## 6. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Pure-Dart hashing and HTTP are slow for 100 MiB+ (and the 5 GiB sparse case) | CI timeouts; later NFR-02 gate missed | Hash in a background isolate pipelined with sending; stream chunks with `openRead` (memory <= inFlight x chunkSize); the 5 GiB test exercises chunk math and a sparse tail read only, never a full transfer; record an ungated baseline MB/s from the smoke step |
| Shared-contract drift between concurrent agents | Compile errors at integration | Contracts are orchestrator-owned; agents report required changes instead of editing; every agent codes against the interfaces and the fake handler/client |
| Spec/contract ambiguities (ack body, 426 `supported` location, header optionality, method-mismatch status) | Divergent client/server behaviour | LSP-1.md fixes them (ack = HTTP 200, `supported` top-level, hash header optional at the HTTP layer in Inc 1 and mandatory in Inc 3, wrong method = 404); conformance suite is written against LSP-1.md |
| `dart:io` HTTP server buffering/backpressure on 4 MiB bodies | Memory spikes, hung uploads | Stream the request body to the handler; require `Content-Length`; abort early on handler error; test mid-body abort and disconnect |
| `.lspart` and rename edge cases (name collisions, Windows reserved names, long names, symlinks) | Data loss or escape from the download dir | Sanitizer + `assertInsideDir` + collision suffix, fuzz-tested; `.lspart` suffix length reserved within 255 bytes |
| Plain HTTP shipped by accident | Plaintext transfers on a LAN | Inc 1 profile is documented as loopback/test-only; TLS arrives in Inc 3 behind the same interface; CLI prints a warning when bound to a non-loopback address |
| CI cold-start (`dart run` compile) racing the receiver | Flaky smoke step | Poll `GET /api/v1/info` until ready (timeout 60 s), then send; log files uploaded on failure |
| No GUI or radio in the container | Cannot test Wi-Fi paths | Inc 1 touches no radio; loopback and Docker networks only |
| Toolchain pin drift | Local vs CI differences | `.fvmrc`, `tools/env.sh`, `FLUTTER_VERSION: "3.47.9"` in CI |

## 7. Subagent split

| Agent | Scope | Deliverables | Constraint |
|---|---|---|---|
| **A** | Sender / hashing / manifest | `transfer/manifest.dart`, `transfer/hashing.dart`, `transfer/file_sender.dart` + `manifest_test`, `hashing_test`, `file_sender_test` | Depends only on `PeerClient`, `Chunker`, models |
| **B** | Receiver / sanitizer / resume | `transfer/file_receiver.dart`, `transfer/resume_store.dart`, `transfer/filename_sanitizer.dart` (+ `unicode_nfc.dart`) + `file_receiver`/`reconstruct`, `corruption`, `resume_store`, `filename_sanitizer`, `sanitizer_fuzz` tests | Implements `IncomingTransferHandler` |
| **C** | ApiServer / ApiClient | `server/api_server.dart`, `server/rate_limiter.dart`, `client/api_client.dart` + `api_conformance_test`, `api_client_test`, `rate_limiter_test`, `test/helpers/api_fake_handler.dart` | HTTP behaviour exactly as LSP-1.md section 4.3 |
| **D** | Docs / CI | `docs/protocol/LSP-1.md`, `docs/protocol/schemas/*`, `docs/traceability.md`, `docs/plans/inc1.md`, `docs/adr/*`, `README.md`, `.github/workflows/ci.yml` | No `.dart` or pubspec edits |
| **E** (later) | CLI + loopback integration / bench | `packages/libreshare_cli/bin/ls.dart`, `integration/{loopback_transfer,completion_events,bidirectional}_test.dart`, `conformance/schema_conformance_test.dart`, 100 MiB smoke verification, first MB/s measurement | Starts after A, B, C land; schema validation needs a JSON-schema validator dev dependency (e.g. `json_schema`) or hand-written checks - pubspec changes go through the orchestrator |
| Orchestrator | Contracts, reconciliation | `protocol.dart`, `model/*`, interfaces, `chunker.dart`, barrel, final analyze/format/test run, traceability status updates | Owns all shared contracts |

## 8. Outcome / deviations

Status at the close of Increment 1: all acceptance checks of section 5 pass locally (evidence and commands in `docs/traceability.md`, "Inc 1 evidence"); the CI run is pending the first push. FR-07, FR-08, FR-09, FR-10 (hashing and receiver checks), FR-11 and FR-17 are `inc1-done`.

### Bugs found and fixed while closing the increment

- **Engine shutdown race.** `SessionFinished` fires inside the `POST /finish` handler, before its response is flushed. A receiver that stopped its engine in the event listener (the CLI's `--once` does exactly this) cut the connection, and the sender reported `FAILED(NO_CONNECTION)` although every file had been verified. `LibreShareEngine.stop()` is now graceful (waits up to 5 s for in-flight requests, then forces). Regression tests: `integration/two_engine_test.dart`, group "receiver shuts down inside its SessionFinished listener" (`dispose()`, `stop()`, `stop(force: false)`); verified to fail with the old forced close.
- **CLI `send` never printed its final line.** The `COMPLETED` / `FAILED` line came from an event listener that was cancelled before the broadcast stream delivered the last event (engine events are delivered asynchronously, a microtask after `sendFiles` returns). It is now printed from the `SendResult`, and a failure also prints `send failed: <REASON>` (with `cannot reach host:port` for `NO_CONNECTION`) on stderr.
- **CLI `receive --once` lost a failed outcome.** With stdin not a terminal the session is rejected at once and the receiver exited before the sender's first long-poll arrived, so the sender saw `NO_CONNECTION` after about 4 s instead of `REJECTED`. After a failed `--once` session the receiver now lingers 1 s before shutting down.
- **Schema/doc corrections found by the conformance suite.** `DeviceInfo.port` allows `0` (a send-only client such as `ls send` has no listener and reports 0; `discovery-announce` still requires `>= 1`); the receiver's `chunkSize` rule (power of two, 64 KiB to 16 MiB, else 400) is now written in `session-request.schema.json` and LSP-1 4.3.4.
- `LibreShareEngine` gained an optional `permissionTimeout` (default `kPermissionTimeout`, passed to `FileReceiver`) so the `FAILED(TIMEOUT)` path can be tested without waiting 120 s.

### Deviations from this plan

- **Test file names.** `unit/reconstruct_test.dart` and `unit/corruption_test.dart` became groups of `unit/file_receiver_test.dart`; `integration/loopback_transfer_test.dart`, `completion_events_test.dart` and `bidirectional_test.dart` were consolidated into `integration/two_engine_test.dart` (plus `large_transfer_test.dart`, tagged `slow`; the 5 GiB case is tagged `very-slow` and runs only with `LS_SLOW=1`, optionally `LS_SLOW_DIR=<dir>` because `/tmp` may be a small tmpfs). CLI tests live in `packages/libreshare_cli/test/cli_loopback_test.dart`. `packages/libreshare_core/dart_test.yaml` declares the two tags.
- **`ls info` without `--to`** exits 64 ("--to host:port is required"); section 2 promised that it prints the local device info. Not implemented in Inc 1.
- **`GET /info` reports the requested port, not the bound one.** After a port fallback (`preferredPort` busy) the receiver's `DeviceInfo.port` still carries the requested value, because `FileReceiver.self` is fixed before `ApiServer` binds. Harmless in Inc 1 (nothing announces it); FR-01 ("the actual port is announced") needs the engine to build the `DeviceInfo` after binding, in Inc 2.
- **Timestamps** are emitted by Dart as `2026-10-30T10:00:00.000Z` (milliseconds); the LSP-1 examples omit the fraction. Both are valid RFC 3339 `date-time`; the golden fixtures use the Dart form.
- **Engine events are asynchronous.** Consumers (UI, tests) must not assume that an event has reached a listener when `sendFiles` returns; tests yield once before inspecting an event log.

### Findings that matter for later increments

- **NFR-02 (loopback >= 300 MB/s).** Pure-Dart SHA-256 on the JIT runs at about 70 MB/s and is computed at both ends, so the measured end-to-end rate is 19.1 MiB/s (100 MiB, CLI) and 32.3 MiB/s (5 GiB, in-process, hashing mostly pipelined). The gate will need AOT-compiled binaries and/or a faster hash path; decide before Inc 4.
- **`FileMode.append` + `setPosition`.** The receiver writes chunks out of order with `RandomAccessFile.setPosition` on a file opened in append mode. This works on Linux (the out-of-order, resume and 5 GiB tests pass). It is unverified on Windows: re-verify in the Windows CI job when it exists (Inc 2 builds).
- **JSON cap vs file count.** The 256 KiB request limit (`kMaxJsonBytes`) fits only about 1,000 `FileItem` entries (roughly 250 bytes each), while `kMaxFilesPerSession` is 10,000. A 10,000-file manifest would be refused with 413 before the file-count rule applies. Spec inconsistency; resolve in Inc 2 (raise the cap for `POST /sessions`, or lower the file limit, or paginate the manifest) and update LSP-1 4.1, the schema and the conformance tests together.

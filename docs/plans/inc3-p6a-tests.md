# Inc 3 / P6a tests: engine facade and CLI (written first, red)

Spec: LSP-1 4.2/4.3/5.1-5.4, docs/plans/inc3.md D3/D6/D7/D12 and sections 5, 9b, 10, 11.
No `lib/` or existing test was touched. Counts are static `test(` calls; loops (profile twins,
traversal modes) expand to more executed tests.

## Files
Core (`packages/libreshare_core/test/`):
- `helpers/p6a_support.dart`: `P6aRig`/`P6aNode`/`P6aEvents`, `sendTo`, `rawGet`, `TcpTap`, `contactsOf`
  (engine on 127.0.0.N aliases, `InMemoryMulticastBus`, auto-accept of the receiver SAS when `acceptSas`).
- `unit/security_wiring_test.dart` (16): `SecurityWiring.open`.
- `unit/send_result_refusal_test.dart` (15): `SendResult.refusal` (orchestrator decision 2026-11-05).
- `security/engine_tls_handshake_test.dart` (13), `engine_tofu_test.dart` (17),
  `engine_contacts_only_test.dart` (10), `log_hygiene_test.dart` (2, big flow + detector self-test).
- `integration/secure_two_engine_test.dart` (10), `contacts_only_engine_test.dart` (10),
  `path_traversal_secure_test.dart` (4 x modes), `goodbye_engine_test.dart` (5).
CLI: `packages/libreshare_cli/test/cli_security_test.dart` (34, real processes, kernel-compiled once).

## Groups (one line each)
- security_wiring: identity created once and reloaded; IdentityLost (key/meta missing or corrupt, never
  regenerated); key file 0600; trust store persists; PIN policy and consent pass-through.
- tls_handshake: served cert == identity fingerprint; /info v1.1; plaintext client gets no HTTP bytes;
  openssl TLS1.2 refused / TLS1.3 ok; plaintext engine keeps the 1.0 wire; restart keeps the identity;
  `advertiseIp` is what info/discovery/peer-link tell.
- tofu: first contact needs SAS on both sides (autoAccept does not skip it), then both pin `known`;
  second send has no SAS; reject/abort pins nobody; key change either direction refused (KEY_CHANGED);
  wrong pinned key; block/unblock; contact management; persistence.
- contacts_only (engine): `setVisibility(contacts)` no longer throws; per-request gate; stranger 404 equals
  unknown route; contact/removed/blocked/key-changed; plaintext still `UnsupportedError`.
- contacts_only (integration): stranger invisible on the bus; pairing invite/redeem/decide flow, single use,
  decline, removal hides again.
- secure_two_engine: both profiles full transfer; eavesdropper tap sees no plaintext/secrets (twin: sees
  them in plaintext profile); PIN rotate/block policy.
- path_traversal_secure: hostile fileNames neutralised and `..` relativePaths refused over secure (pinned and
  unpinned) and plaintext; an absolute relativePath (`/etc/cron.d/evil`, UNC) is re-rooted and saved inside the
  download dir (sanitizer behaviour); zero files outside the sandbox (twin: honest name lands).
- goodbye: Receive Off removes device from the other list <= 1 s, bye sent twice; engine stop too;
  forged bye ignored; plaintext profile sends none.
- log_hygiene: sentinels, 64-hex, base64url >= 40 and PINs never reach logs through pairing, SAS, 10k
  files, key change, wrong PINs, bye (leak detector proven by planted leaks).
- CLI: identity show/rotate/IdentityLost; contacts add/list/remove/block/unblock; two-process SAS first
  contact; n by either side; EOF; `--insecure-tofu`; key change; plaintext peer; PIN/BLOCKED; `--pin auto`;
  pair --show/--scan and Contacts-only; `--insecure-plaintext` byte-for-byte Inc 1/2; TLS default;
  `--advertise-ip`; `-v` hygiene; `--help`; Broken pipe (`| true`, twin `| cat`); closed port.

## Expected new symbols (the coder implements to these)
- `lib/src/engine/security_wiring.dart`: `class SecurityWiring { static Future<SecurityWiring> open({required
  Directory directory, String? deviceId, PinPolicy pinPolicy, String? pin, ConsentPolicy? consent, bool
  allowInsecurePeers = false}); }` (identity, trust store, PinGuard, file secret store 0600).
- `LibreShareEngine(..., SecurityWiring? security, String? advertiseIp)`; members: `identity` (null when
  plaintext), `ownFingerprint`, `pinGuard` (`PinGuard?`), `pairing` (`pendingPrompt`, `decide({accept})`,
  `hasActiveInvite`), `String createPairInvite()`, `Future<bool> redeemPairInvite(String uri)`,
  `Future<void> addContact({deviceId, fingerprint, alias, trust})`, `removeContact(id)`, `block(fp)`,
  `unblock(fp)`, `setTrust(...)`, `currentContacts`, `contacts` stream, `incomingInfo(...)`.
- `ReceiveController.setVisibility(contacts)` works when secure.
- `SendResult.refusal` (`LsErrorCode?`, default null, in `file_sender.dart`): the code of the LsException that
  failed the send (createSession or any later call, after retries); null on success, own cancel, SocketException,
  TimeoutException and on receiver-user rejection (a status, not a wire error). `FailureReason` mapping unchanged.

## CLI contract and exit codes
Existing: 0 ok, 1 transfer failed, 64 usage, 66 no input. New: 80 key changed, 81 insecure peer (no
`--allow-insecure`), 82 PIN/auth/blocked/bad pair secret, 83 SAS aborted/not confirmed, 84 identity lost.
New flags: `--insecure-plaintext|--secure` (mutually exclusive, default secure), `--identity-dir`,
`--insecure-tofu`, `--allow-insecure`, `--pin PIN|auto`, `--visibility everyone|contacts`,
`--advertise-ip`. New commands: `identity show|rotate`, `contacts add|list|remove|block|unblock`,
`pair --show|--scan URI`. Output lines are listed at the top of `cli_security_test.dart`
(SAS/ID/FINGERPRINT/CONTACT/CONTACTS/PAIR/PAIR-REQUEST/PAIRED/PIN).

## Red state (measured)
| file | tests | failing | reason |
|---|---|---|---|
| 9 core files above | 86 static | all (load error) | compile errors only for missing `SecurityWiring`, `security:`, `advertiseIp`, engine members listed above |
| cli_security_test.dart | 34 | 34 | exit 64 "Could not find an option named ..." / unknown command |
| unit/send_result_refusal_test.dart | 15 | all (compile: `refusal` missing) | with the `refusal` lines removed 15/15 pass against today's FileSender (mapping untouched) |
| rest of core | 2349 (+1 skipped) | 0 | pre-existing, green |
| rest of cli | 41 | 0 | pre-existing, green |
`dart analyze` on the new files: only the missing-symbol errors (core); CLI file: no issues.
Not run green: the tests were never executed against an implementation, expect small harness fixes
(report them, do not weaken). 3x flake runs are still owed once green.

## SPEC-GAPs (safer reading chosen)
1. Contacts-only: an unpinned sender sends an unsigned `/info`, so it is a stranger even if listed; first
   contact with a Contacts-only device goes through pairing.
2. Plaintext profile keeps `UnsupportedError` for Contacts-only (no trust store).
3. Engine stop also sends the goodbye (bound 1.5 s).
4. `--insecure-tofu`: SAS line still printed, sender continues without asking; a receiver also needs
   `--auto-accept` to skip the accept prompt. EOF without the flag = "no".
5. `receive --pin auto` prints `PIN nnnnnn` once; a fixed `--pin` is never printed or logged.
6. `contacts remove` of an unknown id exits 1; `contacts add` with another key for a known id exits 80.
7. `send --allow-insecure` is the only way to talk plaintext to a fingerprint-less peer.
8. `SendResult.refusal` decided: exit 80/82 derive from it (engine tests assert it for KEY_CHANGED, BLOCKED,
   PIN_REQUIRED, PIN_INVALID; null for a receiver-user rejection). A CANCELLED sent by the receiver itself is
   untested (open).

## Accepted limitations (orchestrator, not tested)
- No sender-side SAS confirm gate: both screens show the code, the receiver's Accept is the human comparison and
  data flows only after it; the sender's user can Cancel at any time.
- FileSender session-id logging: the P5 coder fixes it (log_hygiene_test is the spec).

## Mutation checks for the verifier (each must turn named tests red)
1. Engine pins the receiver without waiting for SAS -> tofu "first contact", secure_two, CLI first contact.
2. Engine regenerates the identity when the key is missing -> security_wiring IdentityLost, CLI exit 84.
3. `ReceiveController` ignores `contactsOnly` (flag not passed to ApiServer) -> engine_contacts_only stranger
   tests, contacts_only_engine invisibility.
4. CLI `--auto-accept` skips the SAS prompt -> CLI first-contact (receiver `RECEIVED` before `y`).
5. CLI default plaintext -> CLI "defaults to TLS" and every secure CLI test.
6. Engine overwrites the pin on key change -> tofu key-changed (both directions), CLI exit 80.
7. Engine ignores `advertiseIp` -> tls_handshake advertise group, CLI `--advertise-ip`.
8. Goodbye accepted without a valid signature / sent in plaintext -> goodbye forged and plaintext control.
9. Engine logs PIN, fingerprint, nonce or full session id -> log_hygiene.
10. Listener accepts plaintext while secure -> tls_handshake "no downgrade", CLI plaintext-sender test.
11. PinGuard exempts known (not only trusted) contacts or never blocks -> secure_two PIN group, CLI 5 PINs.
12. Pair inviter accepts without `decide` / secret not single use -> contacts_only_engine pairing, CLI pair.
13. CLI does not catch `SocketException`/Broken pipe on stdout -> "stdout closed early".
14. `--insecure-plaintext` writes an identity or prints SAS -> CLI plaintext byte-for-byte test.
15. FileSender sets `refusal` from the FailureReason (e.g. rejected -> pinInvalid) or never sets it ->
    send_result_refusal and the engine PIN/KEY_CHANGED assertions.

## Round 2 (2026-11-05 ~19:15, tester T2 in a scratch clone; applied and re-measured by the orchestrator on the real tree)

- `test/security/engine_tls_handshake_test.dart`: TEST bug. `sClient` hardcoded `127.0.0.1` but rig engines bind `127.0.0.N`; it now takes the bound address (`a.ip`). Every assertion unchanged. Redundant `security_wiring.dart` import dropped (the barrel exports it now).
- `test/helpers/p6a_support.dart`: TEST-SUPPORT bug behind `engine_tofu_test`: default directory names used `nodes.length`, which shrinks on `stop()`, so a restarted device reused the old `rx-*` folder (still holding `11-ok.bin`). Monotonic counter `_started` added; `engine_tofu_test.dart` itself is unchanged. Not a production bug.
- NEW `test/unit/receiver_session_wait_test.dart` (13 tests, `FileReceiver` driven directly, real time): LSP-1 4.3 `GET /sessions/{sid}?wait=N`. Red today on exactly two cases: (a) an auto-accepted IN_PROGRESS session with `wait` holds 3.0 s, (f) a second poll right after `accept()` holds 3.0 s. Green twins: PENDING held and woken by accept/reject, PENDING times out after `wait`, terminal states and `wait = 0` immediate. Passes when the clone's condition is `s.status == TransferStatus.pending` (mutation proof). Fix = Wave C card C1 in `HANDOFF.md`.
- Orchestrator re-measurement on the real tree after applying: the 9 P6a core files, 98 tests, `+98: All tests passed!` on 3 of 3 runs (`dart test -j 1`); the new wait file `+11 -2` (the two intended reds).
- Contacts-only greeting limits (read-only finding, outside the MVP): `_greetContacts` fixes "B heard first, becomes a contact later" only if B is still reachable over HTTPS; the one-shot `/register` POST is not retried and has no UDP fallback, and a peer that restarts while the other side still lists it with the same key is never greeted. No test covers the greeting.


# Inc 3 P7 drift check: LSP-1 / schemas / vectors vs code (tester report)

Method: LSP-1.md and the vector file read in full, code read at the places below. Classes: DOC-BEHIND (doc should say it), CODE-BEHIND (code should change), TEST-GAP, OK. `A:` = api_server.dart, `R:` = transfer/file_receiver.dart, `P:` = security/pairing_service.dart, `G:` = security/pin_guard.dart (all under packages/libreshare_core/lib/src/).

Vectors: all of test-vectors-inc3.md (HKDF, HMAC, RFC 6979, cert, X-LS-Auth text/bytes/signature/header, verification outcomes, SAS commits and 5 codes, pairing MACs and K_pair, bye) match the code. 40 tests in `test/conformance/lsp11_vectors_test.dart`, 3 of 3 runs green. No mismatch.

## Needs a decision (spec and code disagree)

1. **Non-6-digit `pin`.** LSP-1 5.2 (L555) and session-request schema `pin` pattern say 400 BAD_REQUEST. Code: no format check in `A:_validateSessionRequest` (L529) or `R:_validate` (L1083); a bad PIN reaches `G:check` (L103-128) and gives 401 PIN_INVALID plus a strike. Existing tests only check the schema and fixed-PIN construction. CODE-BEHIND + TEST-GAP.
2. **PIN-failure block position.** LSP-1 4.3.4 secure order step 1 (L260) says a blocked IP gets 403 BLOCKED before rate limit and body read. Code: blocked state is only consulted in `G:check` (L103-110) called from `R:createAuthenticatedSession` step 10 (L308-321), after body, proof, sender match and trust; trusted contacts are exempt from it. DOC-BEHIND (or CODE-BEHIND if the early gate is wanted). TEST-GAP: no test pins either order.
3. **10,000-file cap vs proof.** L262 puts the 413 file-count in step 3 (before auth). Code: `A:L722` runs after `_readAuthenticated` and JSON decode, so an unauthenticated 10,001-file body gets 401, an invalid-JSON one 401. DOC-BEHIND.
4. **Unsafe `relativePath` 400** is step 7 in L266; code rejects it in `R:_plan` (called from `_open`, L392), i.e. after PIN, storage, pending and busy. A `..` path with a missing PIN gets 401, with a busy receiver 409. DOC-BEHIND / TEST-GAP.

## Doc silent or imprecise (DOC-BEHIND)

5. **Sender binding also includes `deviceId`**: `R:L283-287` and `P:L248-254` require cert CN == `sender.deviceId`, else 401. LSP-1 L267, L305, 4.3.6 check 6 (L383) mention only the fingerprint.
6. **`POST /pair`**: after the MAC check, blocked/key-changed gives 403 BLOCKED/KEY_CHANGED (`P:L266-279`), then BUSY if a request is held (`P:L280`). Table row L175 lists neither 403 nor 426; L305 order omits them. Also 404 "no invite" is only reached after rate limit, size and valid proof (`A:L888`, `R:L594`): an unauthenticated caller sees 401, not 404 ("indistinguishable from an unknown route", L305, holds only for callers with a valid proof). A failed contact store returns `accepted:false` (`P:L326`), undocumented. Nonce/mac decode (400) precedes version (426) (`P:L233-245`).
7. **`bodyIdleTimeout` 5 s**: `A:L88, L609, L620, L961-1010`. A gap of 5 s between body bytes on the secure JSON routes (`/info`, `/register`, `/sessions`, `/pair`, `/sas`) gives 400 "Request body timed out". Not in LSP-1 (grep: no mention). Not applied to `/complete` or the plaintext profile.
8. **`Retry-After`** (L150 "whole seconds"): BLOCKED uses ceil, minimum 1 (`A:L466`); rate limit uses `inSeconds+1` (`A:L659`, differs from ceil by 1 at exact integers: nit, CODE-BEHIND low); oversize-body 429 is fixed 5 s (`A:L615`); pending-prompt 429 fixed 30 s (`R:L339`). State these values.
9. **One-time PIN** (L554): consumed atomically (`R:L363-371` serialises PIN requests; `consume` runs only when the session is registered, `R:L359`, `G:L93`). A request refused at storage/pending/busy does not burn the PIN. Doc says "consumed" only.
10. **Sender does not gate on its own SAS** (`file_sender.dart` `_runSas` L364-415 emits `SasReady` then long-polls). L536 diagram and 5.1 are silent; add that the receiver's Accept is the human comparison.
11. **Pinning after SAS** (L549 says "Trust this device"). Code pins `known` automatically when the receiver's user accepts a SAS session (`R:_pinAfterSas` L465-486) and the sender pins the receiver at IN_PROGRESS (`file_sender.dart` L269); `trusted` (auto-accept) is a separate opt-in. `/pair` stores `trusted` (`P:L367`, matches L305).
12. **`/sas` details**: a foreign proof gives 401 but does not fail the session (`R:L544-556`); proof-binding 401 precedes 410/409; nonce format 400 is decided in `A:L875` before the session lookup. L303 lists the statuses without order.
13. **Accept-time recheck**: `R:accept` L440-451 fails the session `REJECTED` and throws BLOCKED/KEY_CHANGED if the sender was blocked or re-keyed while the prompt was open. Not in doc.
14. **TLS error mapping**: reset/terminated handshake without OS error is a `SocketException` (NO_CONNECTION), but a TLS error with an OS cause (bad version, HTTP reply to ClientHello) maps to `InsecurePeerException` (`api_client.dart` L396-405). L470 (4.7) only describes the closed-connection case.
15. **Plaintext order**: `R:createSession` checks busy (L246) before validation (L250); LSP-1 L254 puts busy last (step 7). Legacy Inc 1/2 behaviour. Low.
16. **426 vs sasCommit 400**: `A:L731-733` checks the major before the `sasCommit` format; L264-265 order shape before version. Low, TEST-GAP.
17. **Registry edge** (rule 7, L124): `peer_registry.dart` L126-136 protects an existing entry exactly as documented. If the pinned device has no listed entry yet, an announcement with an empty fingerprint is listed WITH the pinned fingerprint (L138-146, `baseline`), not as a legacy peer; a different fingerprint creates an entry flagged changed. TEST-GAP / DOC-BEHIND.
18. **Minor**: `bye` also requires the peer to be listed with the same fingerprint (`multicast_discovery.dart` L468-470); an `announce:true` from a peer already listed with the same fingerprint gets no reply (L433-436). Rule 2 / rule 9 silent.
19. **AUTH_INVALID message generic** (L376): true for proof failures (`A:L64, L640`). Binding/MAC failures carry distinct messages ('sender does not match proof' `R:L287`, 'proof does not match session' `R:L554`, 'SAS commitment mismatch' `R:L577`, 'pairing proof invalid' `P:L263`), after a valid signature so not an oracle for outsiders. CODE-BEHIND low, or narrow L376 to checks 1-5.

## Confirmed OK

- 507 for an unusable download folder, both profiles: L270, L338; `R:L253, L323, L1141`. OK.
- Contacts-only: no announce/probe/bye/mDNS (`multicast_discovery.dart` L278-307), reply only for contact fingerprints (L431-448), malformed header = stranger on `/info`, `/register`, `/sessions` (`A:L361-402`), `/pair` exempt. L133, L260, L398. OK.
- `Date` on every secure response including 400 malformed URL (`A:L329, L344`); scanner and client never follow redirects (`subnet_scanner.dart` L113, `api_client.dart` L335); 10,000-file cap is 413 (apart from item 3); chunk hash mandatory only in secure (`A:L811-817`); clock-skew single retry (`api_client.dart` L366-376); TLS 1.3 minimum (`tls_context.dart`). OK.
- Error enums: schema `error-envelope` code enum == `LsErrorCode`; doc table == `LsErrorCode` (existing lsp11 test); every schema example (13 files incl. `lsp11/`) validates; vector header satisfies `auth-proof` `$defs/header`; vector bye and MACs satisfy the schemas. OK (asserted in the new file).

## Before Inc 3 is done

- Decide items 1-4 (spec or code). Everything else is doc text.
- At review time the engine had no security wiring (`engine/security_wiring.dart` absent, `libreshare_engine.dart` has no `SecurityConfig`, CLI has no secure flags, so `v:"1.1"` and caps `sas`/`pair` are never set by production code). I understand a coder is editing it now; `test/security/engine_*` stay red until it lands. Re-check 4.2 rule 11 and 4.7 (`--allow-insecure`) after.

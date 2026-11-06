# Inc 3 / P5 tests (secure ApiClient + FileSender), tester hand-off

Author: P5 tester, 2026-11-05. Tests only: nothing under `lib/` was touched. Spec: LSP-1 0.3, 4.3.1, 4.3.6, 4.7, 5.1; `inc3.md` D1, D4, D8, D9, D10; `inc3-seams.md` data-flow 3, 5, 6.

## Files (all new)
| File | What |
|---|---|
| `test/security/pinning_test.dart` | pin check before any HTTP byte (raw TLS peer counts bytes), expired/not-yet-valid pinned cert accepted, first contact + `serverFingerprint`, `/info` fingerprint == cert hash, cert swapped mid-session |
| `test/security/downgrade_test.dart` | plaintext/legacy peer => `InsecurePeerException` with 0 HTTP bytes, no HTTP retry after TLS failure (port that sniffs TLS vs HTTP), redirects not followed, TLS 1.2-only server refused (`openssl`, skipped without it) |
| `test/unit/api_client_tls_test.dart` | HTTPS only, `X-LS-Auth` on register/sessions/sas/pair verified by P1 `verifyAuthHeader` (channel binding, body, target, fresh nonce, ts), no proof on the other routes, request/response shapes, wire errors stay `LsException` |
| `test/unit/api_client_clock_skew_test.dart` | D9: 401 AUTH_INVALID + `Date` => exactly one retry with corrected ts and fresh nonce, second refusal final, only AUTH_INVALID retries |
| `test/unit/file_sender_sas_test.dart` | commit iff unpinned, reveal right after the 202 and before polling, `SasReady(outgoing:true)` code, aborts, non-PENDING answer to a commit, pinned = no SAS, legacy, error classification, plaintext unchanged |
| `test/helpers/p5_raw_peer.dart` | `RawTlsPeer`, `RawPlainPeer`, `RawSniffPeer` (hand-written HTTP/1.1, byte counters), `ProofChecker`, `infoFor` |
| `test/helpers/p5_fake_secure_peer.dart` | `FakeSecurePeer`: receiver side of the SAS flow for FileSender (verifies the commit with ITS fingerprint, cannot accept before the reveal) |
| `test/helpers/p5_support.dart` | identities, `secureConfig`, `secureClient`, `sampleRequest` |

## New symbols the tests expect
- `lib/src/client/peer_security_exceptions.dart` (tests import it by path; not in the barrel):
  `class InsecurePeerException implements Exception { const InsecurePeerException(); }`
  `class PeerFingerprintMismatchException implements Exception { const PeerFingerprintMismatchException(String expectedShort, String presentedShort); final String expectedShort, presentedShort; }` (positional, as written in inc3-seams)
  `class SasAbortedException implements Exception { const SasAbortedException(); }`
  All: fixed text, no 64-hex run, no nonce, no address; must NOT extend `HandshakeException`/`SocketException`.
- `FileSender({..., SecurityConfig security = const SecurityConfig.plaintext(), String? pinnedReceiverFingerprint})` (null pin in the secure profile = first contact = SAS). Orchestrator-owned decision, see SPEC-GAP 1.
- `SendResult.receiverFingerprint` (`String?`): the fingerprint the receiver showed, set iff the session was accepted in the secure profile (null if rejected/aborted/plaintext), so P6a can pin.
- `ApiClient` existing ctor only (`security:`, `expectedFingerprint:`); no `https:` flag needed in secure mode.

## Red state (stubs as of today + the three exception classes and the two FileSender members stubbed in a scratch copy)
Real repo: 4 files fail to LOAD (compile error on the new symbols above, nothing else); `api_client_clock_skew_test` loads and fails 13/13 at runtime. Scratch copy (symbols stubbed, rest of `lib/` as is):
| File | tests | failing | reason |
|---|---|---|---|
| pinning_test | 28 | 27 | secure client uses plain HTTP: no PeerFingerprintMismatch, no serverFingerprint |
| downgrade_test | 20 | 15 | no InsecurePeerException, stub `revealSas` UnimplementedError, sniff peer sees plain connections |
| api_client_tls_test | 30 | 29 | no TLS, `revealSas`/`pair` UnimplementedError, no proof header |
| api_client_clock_skew_test | 13 | 13 | no TLS/proof/retry |
| file_sender_sas_test | 34 | 24 | no commit/reveal/SasReady, no security exceptions |
The 17 that pass already are the controls (plaintext profile unchanged, harness-sees-traffic twins). With a throw-away reference implementation (scratch only, not delivered) all 125 pass, 3 runs, no flakes.

## SPEC-GAPs (safer reading chosen; orchestrator to ratify or overrule)
1. FileSender secure surface (`security`, `pinnedReceiverFingerprint`, `SendResult.receiverFingerprint`) is not in any doc.
2. In the secure profile FileSender must learn fpR' before `createSession`: tests assume it calls `client.info()` first (then reads `serverFingerprint`); the fake's `serverFingerprint` is null until the first request. Plaintext profile must NOT call `info()`.
3. Security refusals leave `send()` as exceptions (the three types), everything else stays a `SendResult`. `SasAbortedException` = reveal failed (any reason, incl. transport), or `cancel()` while a SAS comparison is outstanding. A non-PENDING / nonce-less answer to a commit stays `FAILED(PROTOCOL_ERROR)` as 5.1 says; a malformed `sas.nonce` may be either.
4. `/info` over TLS: empty fingerprint => `InsecurePeerException`; non-empty but != cert hash => `PeerFingerprintMismatchException`.
5. An unpinned (first-contact) client locks onto the first certificate it saw and refuses a different one later (swap after SAS).
6. A pinned `GET /info` always carries `X-LS-Auth` (client cannot know the peer is Contacts-only); unpinned never. Routes "not used" in 4.3.6 carry none.
7. A pin that is not 64 hex (empty, short) must never mean first contact: `ArgumentError` or mismatch, 0 bytes.
8. TLS 1.2-only refusal: only "not an LsException/Timeout/mismatch" is asserted (the type is unspecified).
9. Not tested: whether the skew correction persists for later requests; `ApiClient` behaviour with `allowInsecurePeers` (FileSender-level only); `announce_with_other_fingerprint...` and `legacy_listed_but_send_requires_allow_insecure` (P6b/P6a); full client+server MITM/SAS binding (other tester).

## Mutation checks for the verifier (all run once in the scratch copy: red as listed)
| Mutation | Caught by |
|---|---|
| skip the pin comparison in `badCertificateCallback` | pinning 16, downgrade 1 |
| signed `serverFp` = something else than the handshake fingerprint | api_client_tls 13, skew 8 |
| retry over `http://` after a TLS failure | pinning 15, downgrade 12 |
| remove the `/info` fingerprint == cert check | pinning 2 |
| attach the proof to an unpinned `GET /info` / to every route | api_client_tls 1 / 2 |
| no skew retry / unlimited retry | skew 8 / skew 4 + tls 1 |
| unpinned client does not lock the first cert | pinning 1 |
| scheme `http` in the secure profile | nearly all |
| send `sasCommit` although pinned | file_sender_sas 2 |
| commit over the sender's own fp instead of the fp seen | file_sender_sas 11 |
| emit `SasReady` before the reveal returns | file_sender_sas 5 |
| swallow a reveal error | file_sender_sas 5 |
| `cancel()` during SAS not a `SasAbortedException` / fixed `Ns` / legacy allowed without flag / security exceptions swallowed | file_sender_sas 1 / 1 / 1 / 4 |

## Full suite (real repo, 04:30 IST, other testers' Inc 3 files included)
`dart test` in `packages/libreshare_core`: +1688 ~1 -261 plus 13 files that fail to load. Every failing/unloadable file is a new Inc 3 test file (P3/P4/P5/P6b testers); no pre-existing test file fails. P5 results do not involve ApiServer or PinGuard (own raw peers), so the 04:25-04:29 leak window does not affect them.

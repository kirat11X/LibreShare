# R4c tests-plan (tester, 2026-11-06 12:05)

Clone: `.toolchain/scratch/e5-r4c/clone`. New file only: `packages/libreshare_core/test/integration/contacts_greeting_retry_test.dart` (copy here). Uses `P6aRig` (real secure engines on loopback aliases, in-memory multicast bus).

## Decision: NO protocol or contract change needed -> not STOPPED
The greeting is the existing `POST /register` via `ApiPeerRegistrar.call` (returns false on any failure, e.g. the stranger-gate 404), and the engine already receives a `DeviceUpdated` registry event whenever a listed peer announces again. Both retry-with-back-off and "re-greet a contact that announces again (rate limited)" live in `LibreShareEngine` (`_greetContacts`, `_greeted`, the `_trustWatch`/registry-event call sites). No change to `protocol.dart`, `security/contracts.dart`, `model/*`, LSP-1. The UDP fallback named in post-mvp-plan R4(c) is NOT tested and NOT needed for this item (it would need MulticastDiscovery changes; ask the orchestrator if it is wanted).
Coder scope hint: `libreshare_engine.dart` (`_greetContacts` + registry-event hook). Note card (c) says "`_greetContacts` and its call site only"; subscribing to registry events for the re-greeting is one more call site.
Finding on restart: a restarted peer normally gets a UDP unicast reply to its start-up probe (rule 8) and lists the contact again; the bug shows when that reply is lost or no probe is sent. The restart test therefore drops unicast (`bus.dropUnicast`) for the first 1.5 s after the restart, HTTP untouched.

## Tests
| test | guard | now |
|---|---|---|
| greeting-retry | first greeting refused (404: Sam is Contacts-only and does not know Bob), Sam pins Bob 0.5 s later; Sam lists Bob within 5 s of the first greeting | RED |
| greeting-retry-keeps-going | Sam is ready only 3.5 s after the first greeting; a late retry still reaches him (retrying covers >= 3.5 s) | RED |
| regreet-after-restart | Sam restarts (bye lost, same key, still listed at Bob), UDP reply lost; Bob re-greets, Sam lists Bob within 5 s | RED |
| retry-stops-when-contact-removed | Bob removes Sam while retrying; after Sam pins Bob nothing is delivered within 6 s | green (pin: a naive retry that ignores removal turns it red) |
| greet-only-contacts | an announcing stranger is never greeted (5 s) | green (pin against a re-greet-everyone fix) |
| regreet-rate-limited | with Sam announcing ~20 times in 6 s, Sam's registry changes <= 8 times (Bob must not POST per announce) | green (pin against an unthrottled re-greet) |

## Command and result
`cd clone/packages/libreshare_core && flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/integration/contacts_greeting_retry_test.dart` -> rc=1 at 2026-11-06 12:02:18, `+3 -3`: the three RED tests above ("Sam lists Bob within 5 s of the first greeting not met in 0:00:04.39", "a late retry reaches Sam not met in 0:00:06.000000", "the restarted Sam learns Bob ... not met in 0:00:05.000000"). An earlier first run (11:4x) was killed by the OS (rc 137, memory) and is not counted.
Run time about 70 s (real time waits).

## Open protocol question (questions.md Q4)
LSP-1 4.2 rule 2 says an `announce:true` from a peer already listed with the same fingerprint gets no reply at all (neither /register nor datagram). The RETRY tests (greeting-retry, greeting-retry-keeps-going, retry-stops-when-contact-removed, greet-only-contacts) are unaffected. The RESTART tests (regreet-after-restart, regreet-rate-limited) require a repeated /register greeting to an already listed contact and need the orchestrator's decision (Q4): keep them if rule 2/10 is amended, delete them if the restart half is dropped. Coder: do the retry half first; the throttle must allow a re-greeting about 5 s after the previous one.

## Documented skip (tester, 2026-11-06 14:25, per apply-notes.md)
`regreet-after-restart` now has `skip: 'DEFERRED (questions.md Q4): LSP-1 4.2 rule 2 forbids a reply to an already-listed same-fingerprint announce; known limit'` (replaces `skip: skip` on that one test; body untouched; `dart format` re-wrapped that test's indentation only). Same file in the clone and in this folder. Results in the clone with the coder's patch: `dart test -j 1 test/integration/contacts_greeting_retry_test.dart` -> `+5 ~1: All tests passed!` rc=0 (14:25:40); `dart analyze` of the file no issues; `dart format --set-exit-if-changed` rc=0.

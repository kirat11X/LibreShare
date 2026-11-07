# R4c verifier report (Contacts-only greeting retry, retry half only), verifier agent, 2026-11-06

Patch: `docs/plans/e-proposals/r4c/patch.diff` (only `engine/libreshare_engine.dart`), applied together with the R4b patch to a fresh clone of the current real tree (`.toolchain/scratch/e5-r4bc-verify/clone`, `patch -p1` rc 0).

## Verdict: SAFE AFTER FIXES
The lib patch is safe to apply: the greeting still travels only over the pinned HTTPS `ApiPeerRegistrar` path, timers are cancelled on stop, retries are bounded (17 POSTs, about 40 s), nothing can throw out of the retry chain. Conditions: (1) the red-by-design `regreet-after-restart` must be carried as the documented `skip` agreed with the orchestrator (otherwise the core suite stays at exactly 1 failure); note each test already has `skip: skip` (host cannot bind 127.0.0.2), so use `skip: skip ?? 'DEFERRED (questions.md Q4) ...'` for that one test; (2) the tester's six tests miss four mutations (see table); my verifier tests close them, but they use `dart:mirrors` (see below) so they need a lib getter before they can live in the analyzed tree.

## The `retry-bounded` question (orchestrator, 20:45)
`retry-bounded` is NOT an R4c test and NOT a tester test: it is one of MY verifier tests (`contacts_greeting_retry_verifier_test.dart`). Its first version failed once on the unmutated patched clone (14:08, rc 0 in my log line but the test line was `-1`) because the test itself was wrong: it waited for `_greetRetry` to be empty, which it is momentarily while a POST is in flight, and then sampled again. That was a defect of my test, not of the coder's patch. I rewrote it (wait 46 s past the end of the ~40 s schedule, then sample the map every 50 ms for 12 s, require empty at every sample) and ran the final file on the unmutated patched clone: 3 runs `+5 All passed` (rc 0, 20:50:42, 20:51:55, 20:53:09), plus the formatted copy once more `+5` rc 0 (20:56:48). No R4c test of the tester fails on the unmutated clone except the by-design `regreet-after-restart`.

## Gate table (clone, each alone under `flock -o /tmp/libreshare-heavy.lock`)
| gate | result | rc | time |
|---|---|---|---|
| `dart test -j 1 test/integration/contacts_greeting_retry_test.dart` x3 | each `+5 -1`; the one red = `restart GUARD regreet-after-restart ...` in all 3 runs | 1,1,1 | 12:59:42, 13:00:19, 13:00:56 |
| `dart test -j 1 test/unit/goodbye_test.dart` | +26 passed | 0 | 13:01:02 |
| `dart test -j 1` core | +2618, ~1, -1 (exactly `regreet-after-restart`); 2618 = 2607 + 6 (R4b) + 5 (R4c) | 1 | 13:04:51 |
| `dart test -j 1` cli | +76 -1: `loopback_smoke_secure_test` (`Expected: contains 'SAS '`); the same test also fails alone in the REAL unpatched tree (13:56-13:59), independent of this patch; the first clone run additionally lacked a `.toolchain/` dir (snapshot path) | 1 | 13:06:02 |
| `dart analyze --fatal-infos` clone root | 1 issue, tester R4b file unused import (R4c files clean) | 2 | 13:06:10 |
| `dart format --output=none --set-exit-if-changed .` | 0 changed | 0 | 13:06:14 |
| `grep -RnE "package:flutter\|dart:ui" packages/libreshare_core/lib` | none | 1 (expected) | 12:39 |

## Code review
- Channel: `_greet` calls the same `_registrar.call` as before. `ApiPeerRegistrar._callSecure` is HTTPS only, pinned to the announced fingerprint at the handshake, `X-LS-Auth`, answer fingerprint checked, "Never falls back to HTTP"; a peer without a fingerprint is never contacted. `_greetContacts` runs only from `_trustWatch`, which is subscribed only when `_secure`, so `security!` is safe and a plaintext engine never greets. No new path was introduced.
- Only contacts: `_greetContacts` marks `_greeted` only for known/trusted fingerprints, and `_greet` re-checks trust on every attempt (defence in depth; mutation c needs both removed).
- Timers: stored in `_greetRetry`, cancelled and cleared in `stop()` (killed by my timers-cancelled test; the tester tests do not see it, because a late timer finds `_started == false` and returns).
- Per-contact state: removal cancels the timer and drops `_greeted` (only if the device is still in `_registry.current`; otherwise the next timer firing, at most 10 s later, does it); re-listing starts a fresh cycle (verified: removal -> `_greetRetry` and `_greeted` empty, re-add delivers within 3 s). Contacts-only switched off: the chain stops at its next firing (at most one back-off step, 10 s, later), verified by my test.
- Bounded: 1 first try + 16 retries (8x0.5 s, 2x1 s, 2x2 s, 2x5 s, 2x10 s, about 40 s) then the chain ends; verified (map empty and not re-armed 46-58 s after the start).
- Throwing POST: `ApiPeerRegistrar.call` catches everything and returns false, `_greet` additionally wraps it in `try/on Object` and logs only `runtimeType`; the Timer callback does `unawaited(_greet(...))` and nothing before the try can throw. No unawaited error can escape; the tests ran with no uncaught async error.

## Mutation table (copy `.toolchain/scratch/e5-r4bc-verify/mut`; lib restored and `diff -r` vs clone rc 0 after each). Tests: tester file + my verifier file. `regreet-after-restart` is red in every row and is omitted.
| # | mutation | tester tests red | verifier tests red | result |
|---|---|---|---|---|
| a | no retry (`return;` after the first attempt) | `greeting-retry`, `greeting-retry-keeps-going` | retry-bounded, state-cleaned, timers-cancelled (premise) | killed |
| b1 | removal branch of `_greetContacts` no longer cancels the timer (other guards stay) | none (SURVIVED: the other guards in `_greet` mask it) | `state-cleaned-on-removal-and-relisting` | killed by verifier (state leak, behaviourally redundant) |
| b2 | retry ignores removal completely (no cancel, no `_greeted`/trust re-check) | `retry-stops-when-contact-removed` | state-cleaned | killed |
| c | greet non-contacts too (`contact = true` and no trust re-check) | `retry-stops-when-contact-removed` only; `greet-only-contacts` SURVIVED (it never triggers `_greetContacts`, which runs only on trust changes) | new `greet-only-contacts-after-trust-change` (separate run c2, red), state-cleaned | killed after new test |
| d | timers not cancelled in `stop()` | none (SURVIVED) | `timers-cancelled-on-stop` | killed by verifier |
| e | unbounded attempts (back-off clamps at 10 s forever) | none (SURVIVED) | `retry-bounded` | killed by verifier |
| f | zero back-off | `greeting-retry`, `greeting-retry-keeps-going` | retry-bounded, state-cleaned | killed |
| g | retry continues after Contacts-only is switched off | none (SURVIVED) | `retry-stops-when-contacts-only-switched-off` | killed by verifier |

## Verifier tests (`docs/plans/e-proposals/r4c/verifier-tests/contacts_greeting_retry_verifier_test.dart`, 5 tests, about 70 s)
They use `dart:mirrors` to read the private `_greetRetry` and `_greeted`. They pass with `dart test`, but `dart analyze` in this repo does not resolve `dart:mirrors` (analyzer: `uri_does_not_exist`), so the file cannot go into the analyzed tree as is. Recommended: add `@visibleForTesting int get greetRetryPending` (and a `bool isGreeted(String fp)`) to the engine (orchestrator decision, lib change) and port the tests; or keep the file under `verifier-tests/` as evidence. Raw logs: `verifier-tests/gates.log`, `verifier-tests/mutation.log`.

## Findings
- MEDIUM (test gap, closed by verifier tests): the tester's six tests do not detect mutations b1, c (the `greet-only-contacts` test is vacuous: no trust change ever triggers `_greetContacts` in it), d, e, g. Fix: adopt the five verifier tests (after adding the getters) or at least `greet-only-contacts-after-trust-change` (needs no mirror for its first assertion) and `retry-stops-when-contacts-only-switched-off`.
- LOW: overlapping chains. If a contact is removed and re-added (or the engine stopped and started) while a POST is in flight, `_greet` B starts while chain A's POST completes, and both do `_greetRetry[fp] = Timer(...)`; the second assignment overwrites the first timer without cancelling it, so two chains continue and the orphan timer is not in the map for `stop()` to cancel (it fires later and `_greet` returns because `!_started`). By reading only: my probe (second `_greet` started after chain 1's first attempt) did NOT reproduce it (the pending timer was cancelled and merged: 6 timers in both cases), so the window is the in-flight POST only (up to 2 s for an unresponsive contact). Consequence bounded (17 POSTs per chain). Fix: `_greetRetry.remove(fp)?.cancel();` immediately before the assignment, and in the callback only act `if (identical(_greetRetry[fp], timer))`.
- LOW: when `_greet` stops because Contacts-only was switched off, `_greeted` keeps the fingerprint and nothing triggers `_greetContacts` on switching it back on, so that contact is not greeted again until the next trust change (the same one-shot behaviour as before the patch, but the patch can end a chain early). Fix: remove the fingerprint from `_greeted` in that branch and call `_greetContacts()` after a visibility change.
- LOW: a spoofed announce that replaces a listed contact's address makes the engine attempt up to 17 pinned TLS handshakes at the attacker's address after a trust change (was 1); nothing is leaked (pinned, fails closed).
- INFO: `regreet-after-restart` red by design (Q4), skipped per the orchestrator decision; `regreet-rate-limited` stays green because it is a pin.

## Round 2 (2026-11-06 21:08-21:30): verifier tests converted, no `dart:mirrors`
Setup: fresh clone `.toolchain/scratch/e5-r4bc-verify2/clone` of the current real tree; the regenerated `r4c/patch.diff` (mtime 21:07:59, adds `@visibleForTesting` getters `greetingRetryPendingCount`, `greetingRetryActiveTimerCount`, `greetedFingerprints`) applied with `patch -p1` rc 0. The tester file and the converted verifier file were copied into `test/integration/`.
Converted file: `docs/plans/e-proposals/r4c/verifier-tests/contacts_greeting_retry_verifier_test.dart` (same 5 test names and expectations). `retryMap(n).isNotEmpty` -> `engine.greetingRetryPendingCount > 0`, `greeted(n)` -> `engine.greetedFingerprints`. One design point: with only the getters, mutation d (cancel loop removed, `clear()` kept) would be invisible, because `stop()` clears the map and both counters read 0 afterwards. So `timers-cancelled-on-stop` additionally captures every Timer created by `LibreShareEngine._greet` through a `ZoneSpecification(createTimer: ...)` hook (stack contains `_greet`) and asserts none is active after the stop, besides `greetingRetryActiveTimerCount == 0 && greetingRetryPendingCount == 0`. No mirrors, no lib dependency beyond the three getters.
| command (clone, under the heavy lock) | result | rc | time |
|---|---|---|---|
| `dart analyze --fatal-infos` on the converted test + `libreshare_engine.dart` | No issues found | 0 | 21:09 |
| `dart format --output=none --set-exit-if-changed` on the same two files | 0 changed | 0 | 21:09 |
| `dart test -j 1 test/integration/contacts_greeting_retry_verifier_test.dart` run 1 / 2 / 3 | +5 / +5 / +5 all passed | 0 / 0 / 0 | 21:19:37 / 21:20:50 / 21:22:03 |
Mutations against the converted file only (copy `.toolchain/scratch/e5-r4bc-verify2/mut`; after each the engine file was restored and `diff -r` lib clone vs mut returned rc 0):
| mutation | red test | result |
|---|---|---|
| b1 removal branch no longer cancels the timer | `state-cleaned-on-removal-and-relisting` | killed |
| c greet non-contacts too | `greet-only-contacts-after-trust-change` (privacy pin) and `state-cleaned-on-removal-and-relisting` | killed |
| d cancel loop removed in `stop()` (clear kept) | `timers-cancelled-on-stop` (thanks to the Zone hook) | killed |
| d2 cancel loop and `clear()` both removed | `timers-cancelled-on-stop` | killed |
| e unbounded attempts | `retry-bounded` | killed |
| g retry continues after Contacts-only is switched off | `retry-stops-when-contacts-only-switched-off` | killed |
Logs: `.toolchain/scratch/e5-r4bc-verify2/log.txt`.

**Files to apply together with the R4c patch:** `docs/plans/e-proposals/r4c/contacts_greeting_retry_test.dart` (tester, with the agreed `skip` on `regreet-after-restart`) and `docs/plans/e-proposals/r4c/verifier-tests/contacts_greeting_retry_verifier_test.dart` (to `packages/libreshare_core/test/integration/`). The older mirror-based version is superseded. The probe file (`contacts_greeting_retry_probe_verifier_test.dart`) is NOT to be applied (it was inconclusive).

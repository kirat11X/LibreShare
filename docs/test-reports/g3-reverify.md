# G3 / G2 / mitm_test independent re-verification

Verifier run, 2026-11-06 (11:56 to 13:13 by `date`). Scratch: `.toolchain/scratch/g3-verify/{clone,pristine}`. Every test run was alone under `flock -o /tmp/libreshare-heavy.lock dart test -j 1`, from `clone/packages/libreshare_core`. Each mutation was applied by exact-string replace in the clone, then analyzed and tested in one lock acquisition, restored from `pristine`, and checked with `diff -r -x .dart_tool -x build clone pristine`. No test file was edited. The real tree was not touched except for this file. Raw logs are in the verifier scratchpad (`mut_<ID>.log`, `ana_<ID>.log`).

## Part 1: baseline (unmutated, clone)

| File | Result | rc |
|---|---|---|
| security/pinning_test | +28 all passed | 0 |
| unit/identity_proof_test | +59 all passed | 0 |
| unit/sas_test | +23 all passed | 0 |
| security/pin_test | +40 all passed | 0 |
| security/sas_binding_receiver_test | +32 all passed | 0 |
| security/contacts_only_server_test | +19 all passed | 0 |
| unit/goodbye_test | +26 all passed | 0 |
| unit/credential_store_test | +47 all passed | 0 |
| security/mitm_test | +4 all passed | 0 |

No mutation was skipped. In the tables, "compiles?" means `dart analyze` of the mutated file gave 0 errors AND the test run loaded (a load failure would show "Failed to load"; none occurred).

## Part 2: G3 re-run (M1..M10), my own mutations

| ID | My mutation (file:line, one line) | compiles? | first failing test | counts | rc | restored diff rc | agrees with Lead? |
|---|---|---|---|---|---|---|---|
| M1 | api_client.dart:119 `certificateMatchesPin(cert, required) \|\| required.isNotEmpty` (pin never refuses) | yes (analyze rc 0) | pinned peer with another certificate ... pinned_peer_with_other_certificate_refused_before_any_http_byte | pinning_test +13 -15 | 1 | 0 | yes on the test; counts differ (Lead said 25 failed). See finding 1 |
| M2 | identity_proof.dart ~177 drop `_normalizeFp(serverFingerprint)` from `buildAuthMessage` | yes | valid proof the signature covers exactly the documented text | identity_proof_test +51 -8 | 1 | 0 | yes (8 failed, same first test) |
| M3 | sas.dart ~102 drop `...ns, ...nr` from the `sasCode` hash input | yes | sasCode known_answer_vectors | sas_test +18 -5 | 1 | 0 | yes (5 failed) |
| M4 | pin_guard.dart ~116 call `_recordStrike` on the success path | yes | per-IP throttle ... a success is never a strike (4 failures, 20 successes, then 1 failure) | pin_test +37 -3 | 1 | 0 | yes (3 failed) |
| M5 | pin_guard.dart ~117 `Logger('PinGuard').fine('rejected pin $pin')` on the strike path (plus `package:logging` import) | yes | the PIN never appears in logs ... through every code path | pin_test +39 -1 | 1 | 0 | yes (1 failed) |
| M6 | file_receiver.dart:438 delete the `sasCommit != null && sasCode == null` guard in `accept()` | yes | Accept needs the code (receiver_cannot_accept_before_reveal) accept before the reveal is refused (409) | sas_binding_receiver_test +29 -3 | 1 | 0 | yes (3 failed) |
| M7 | api_server.dart:365 answer `_errorResponse(blocked)` (403) instead of `_notFound` to Contacts-only strangers | yes | stranger (5.4 ...) GET /info, /register and /sessions: 404 identical to an unknown route | contacts_only_server_test +10 -9 | 1 | 0 | yes (9 failed) |
| M8 | multicast_discovery.dart:478 delete the `verifySignature(... SigDomain.bye ...)` block in `_handleBye` | yes (analyze rc 2 = 1 warning, `unused_import`; 0 errors) | receiving a bye forged_signature_ignored | goodbye_test +24 -2 | 1 | 0 | yes (2 failed) |
| M9 | file_receiver.dart:352 drop the `commit == null &&` term, so `autoAccept` / trusted auto-accept also fire for a request with a commit | yes | sas_binding_receiver_test: commit_present_means_no_auto_accept ... trusted contact + autoAcceptTrusted + commit -> 202 with SAS pending | sas_binding_receiver_test + permission_test together: +72 -3 | 1 | 0 | partly: killed, but the Lead's named first failure and its count (26) are for a different mutation. See finding 2 |
| M10 | credential_store.dart ~236 `if (key == null) return null;` instead of throwing `IdentityLost(keyMissing)`, so `loadOrCreate` regenerates | yes | IdentityLost: never a silent regeneration key deleted -> keyMissing | credential_store_test +45 -2 | 1 | 0 | yes (2 failed) |

Variants run to compare with the Lead's literal mutations:

| ID | Mutation | first failing test | counts | rc | restored diff rc |
|---|---|---|---|---|---|
| M1L | Lead's form: `return true` at the top of `_checkCertificate` | pinned_peer_with_other_certificate_refused_before_any_http_byte | pinning_test +3 -25 | 1 | 0 |
| M9L | Lead's form: `commit != null \|\|` prefixed to `auto` | sas_binding_receiver_test: 202 with the receiver nonce PENDING with sas.nonce of 16 bytes and no tokens | sas_binding_receiver + permission_test +36 -39 | 1 | 0 |

Broader runs (the directory the file belongs to, same mutation):

| ID | Run | Result | rc | restored diff rc |
|---|---|---|---|---|
| M1 | test/security | +474 -22 (first: downgrade_test client_never_retries_over_http_after_tls_failure) | 1 | 0 |
| M2 | test/security | +493 -3 (first: mitm_test proxy_cannot_replay_captured_proof_to_real_receiver) | 1 | 0 |
| M3 | sas_binding_test + sas_binding_receiver_test | +37 -1 (code depends on both nonces and both fingerprints) | 1 | 0 |
| M4 | test/security | +492 -4 (first: log_hygiene_test) | 1 | 0 |
| M5 | test/security | +494 -2 (first: log_hygiene_test) | 1 | 0 |
| M6 | test/security | +493 -3 | 1 | 0 |
| M7 | test/security | +476 -20 | 1 | 0 |
| M8 | integration/goodbye_engine_test | +5, all passed (SURVIVES at integration level) | 0 | 0 |
| M9 | test/security | +477 -19 (first: engine_contacts_only_test) | 1 | 0 |

Score for the Lead's named test files: 10 killed, 0 survived, 0 killed only by a compile error. Final `diff -r` after the whole sweep: rc 0.

## Part 3: mitm_test.dart (4 tests), one targeted mutation per test

| Test | Mutation | first failing test | counts | rc | restored diff rc | verdict |
|---|---|---|---|---|---|---|
| 1 pinned_sender_refuses_proxy | T1: same as M1 (pin never refuses) | pinned_sender_refuses_proxy | +3 -1 | 1 | 0 | killed, only that test |
| 2 first_contact_relay_fails_at_reveal | T2: sas.dart `_commitBytes` drops the receiver fingerprint (commit no longer bound to it) | first_contact_relay_fails_at_reveal | +3 -1 | 1 | 0 | killed, only that test |
| 3 proxy_cannot_replay_captured_proof_to_real_receiver | T3: same as M2 (drop `serverFp` from signed text) | proxy_cannot_replay_captured_proof_to_real_receiver | +3 -1 | 1 | 0 | killed, only that test |
| 4 proxy_with_own_identity_never_gets_files_without_user_accept | T4a: `fileState` skips `_requireInProgress` | none | +4 | 0 | 0 | SURVIVES |
| | T4b: `_tokenEquals` always true | proxy_with_own_identity_never_gets_files_without_user_accept | +3 -1 | 1 | 0 | killed (analyze rc 2: 1 warning, unused local) |
| | T4ab: T4a and T4b together ("serves data to an unaccepted session") | same test | +3 -1 | 1 | 0 | killed |
| | T4c: `autoStart: auto` becomes `autoStart: true` (session accepted without the user) | first_contact_relay_fails_at_reveal, proxy_with_own_identity_never_gets_files_without_user_accept | +2 -2 | 1 | 0 | killed (2 tests; analyze rc 2: 1 warning, unused local `auto`) |

Part 5, flake check (unmutated, `dart test -j 1 test/security/mitm_test.dart`, run alone, three times): +4 all passed, rc 0 / 0 / 0 (13:01:04, 13:01:06, 13:01:08).

## Part 4: G2 audit

Row count of inc3.md section 4.1: 16 table rows (15 test-file rows plus the App row); the Lead's "17 categories" is correct only if the carried/roadmap block is counted (15 + App + carried). Cases, counted as the ` · ` / `;` separated items of section 4.1: 105 (pin 9, rate_limit 10, identity_proof 9, pinning 5, key_change 5, sas 8, sas_binding 6, mitm 4, downgrade 6, contacts_only 6, permission 8, log_hygiene 1, credential/registry/secret 7, goodbye 7, pairing 7, App 7), plus 2 carried items = 107. The Lead's own audit table has 107 data rows, so its headline "96 test cases" (89 core + 7 app) does not match its own table or the plan.

Spot check (15 rows plus the four new tests):

| Row | Cited | Real? | Note |
|---|---|---|---|
| pin: replayed_one_time_pin | pin_test.dart:625 | yes | test "with oneTime, the PIN works until consume(), then it is PIN_INVALID" |
| pin: non_six_digit_pin_is_400 | pin_shape_test.dart:113 | yes | group "secure ApiServer: malformed pin is 400" |
| rate_limit: retry_after_header_present, eleventh_session_post | rate_limit_test.dart:20 | test yes, line wrong | :20 is setUp; real test at :59 "the 11th request ... 429 with Retry-After" |
| rate_limit: rate_limit_runs_before_body_read | rate_limit_test.dart:61 | test yes, line wrong | real at :137/:158 |
| rate_limit: fourth_pending_prompt | receiver_secure_session_test.dart:576 | yes | |
| identity_proof: proof_for_server_A_rejected_by_server_B | identity_proof_test.dart:286 | yes | exact name |
| pinning: announce_with_other_fingerprint | announce_fingerprint_test.dart:143 | yes | exact name |
| sas_test: 10k_samples_roughly_uniform | sas_test.dart:365 | yes | 20,000 samples, seeded chi-square |
| sas_binding: plain_hash_sas_is_grindable | sas_binding_test.dart:207 | yes | exact name |
| downgrade: tls12_only_client_refused | downgrade_test.dart:329 | yes | |
| contacts_only: no_mdns_no_periodic_announce | contacts_only_discovery_test.dart:245 | PARTIAL | the cited test is `no_periodic_announce`; the file header itself says the mDNS half is "engine wiring (P6a)" and I found no mDNS assertion in contacts_only_engine_test.dart or engine_contacts_only_test.dart (it checks bus announces only) |
| permission: accept_races_timeout_exactly_one_wins | permission_test.dart:337 | yes | |
| goodbye: verification_budget_5_per_second | goodbye_test.dart:271 | test yes, line wrong | real at :516 |
| goodbye: forged_signature_ignored | goodbye_test.dart:178 | test yes, line wrong | real at :329 (:178 is a format-case table) |
| pairing: S_erased_after_success | pairing_test.dart:106 | test yes, line wrong | real at :452 |
| credential: missing key => IdentityLost | credential_store_test.dart:345 | yes | "key deleted -> keyMissing" |
| App: device_card_trust_badge_test | b1_incoming_security_test.dart:186/200/214 | yes | three badge tests |
| App: trust_settings_test (list, remove, block, auto-accept toggle, own fp) | b1_settings_security_test.dart | PARTIAL, marked Y | no auto-accept test or UI exists (`grep -i auto` finds nothing in the app test file; no autoAccept in apps/libreshare_app/lib), the Lead's own note says it is deferred |
| mitm: all four | mitm_test.dart | exist, 3 solid, 1 weak | see Part 3 |

The three rows the audit marks N (pair_screen_test, visibility_contacts_test, notification_service_test) are honestly marked N.

## Findings

1. M1: the Lead's mutation (`return true` before the pin logic) fails 25 pinning tests partly as a side effect (it also skips recording `_seenFp`, hence its "InsecurePeerException"). The natural mutation (pin never refuses) still kills the named test, with 15 failures. Same verdict, different reason; the Lead's error text does not describe a pin bypass.
2. M9: the Lead's "26 failed, first failure `202 with the receiver nonce`" belongs to a different, cruder mutation (`commit != null ||`, reproduced here as M9L: 39 failed). The natural "auto-accept even with a commit" mutation (drop `commit == null &&`) is killed by `commit_present_means_no_auto_accept` and the `permission_test` auto-accept matrix (3 failures), not by the test the Lead named. Both killed; the Lead's detail is not reproducible for the stated mutation.
3. mitm_test #4 is weak: dropping the in-progress check in `fileState` (T4a) leaves it green (+4). It calls only `fileState` with a made-up token, never `putChunk`/`getChunk`, and accepts `tokenInvalid`/`authInvalid`/`notFound`. It is killed only by mutations that open the token check (T4b/T4ab) or auto-start the session (T4c). The Lead's comment says "or write chunks" but nothing writes chunks.
4. mitm_test #3 is not a proxy test: it calls `buildAuthHeader`/`verifyAuthHeader` for two identities and has no TLS proxy; it duplicates `identity_proof_test` "proof_for_server_A_rejected_by_server_B". The file header ("in-process TLS-terminating proxy") overstates tests 2 to 4; only test 1 uses a real TLS proxy (RawTlsPeer).
5. M8 is killed only at unit level: `integration/goodbye_engine_test.dart` stays green with the signature check removed (+5). Unit `goodbye_test` carries the whole guard.
6. G2 audit: headline "96 cases" is inconsistent with its own 107-row table; many line numbers cite the wrong line (about 6 of 19 checked), though the named tests exist; `no_mdns_no_periodic_announce` is only half covered; `trust_settings_test` is marked Y though its auto-accept part does not exist.
7. The Lead's G3 claim (10/10 killed, 0 survivors, all restored with diff rc 0) holds for its named test files.

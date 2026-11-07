# R4e verifier report (2026-11-06; gates 14:27-15:47 and re-run 20:46-20:58 on a fresh clone)

**Verdict: SAFE TO APPLY** (add the tester's file as is; no lib change). One optional addition: the verifier's file (6 tests, below) closes the one mutation survivor.

Scratch: `.toolchain/scratch/e5-r4e-verify/` (clone, clone2 = fresh copy of the current tree at 20:46, r4a, r4a2, mut). No stale process of mine is alive. The tester's file is byte-identical to `r4e/manifest_limit_order_test.dart` in every copy. `lib/` was never edited except in the `mut/` copy (restored, `diff -r` rc 0 after each mutation). `api_server.dart` and `protocol.dart` of the first clone were identical to the real tree at 20:46 (cmp).

## 1. Does the test pin the documented order (LSP-1 4.3 steps 3-5)?
Yes. No proof -> 401 AUTH_INVALID; proof signed for another body -> 401; malformed `v1.not.a.proof` -> 401; correct proof, 10,001 files -> 413 TOO_LARGE with `retryable:false`; exactly 10,000 signed -> 202; after an unsigned 401 a signed request still works. A `premise` test checks the 10,001-file body is above 256 KiB and below 4 MiB (so it really goes through the secure 4 MiB path) and that the constant is 10000.
- "Nothing created": asserted with `handler.count('createAuthenticatedSession') == 0` in no-proof, bad-proof and enforced (413); NOT asserted in garbage-proof (LOW, the 401 comes before the handler anyway) and the fake handler has no separate pending-prompt counter (the only handler entry for a session is `createAuthenticatedSession`, so the count covers it).
- Time/port dependence: none. The rig binds an ephemeral port, the rate limiter is off (`enableRateLimit:false`), the clock is the rig's fixed `P3Clock`. Each test starts its own rig. No flake in 7 runs (below).

## 2. Gate table
| gate | result | rc |
|---|---|---|
| tester file, fresh clone #1 (14:27 tree), 3 runs | `+7: All tests passed!` x3 (the first run 14:27-15:03 waited for the lock; runs 2, 3 at 15:16) | 0,0,0 |
| tester file, fresh clone #2 (20:46 tree), 2 runs | `+7` x2 (20:54:31, 20:54:38) | 0,0 |
| tester file + R4a applied, 3 runs (first copy at 15:17, patch from 12:32 mtime) | `+7` x3 | patch 0; 0,0,0 |
| tester file + R4a applied, 3 runs, **second copy 20:55 with patch.diff mtime 2026-11-06 20:46:10 +0530, md5 761a4781c0c65acdb264fe60fd2b3175** (the revised version) | `+7` x3 | patch 0; 0,0,0 |
| R4a `connection_cap_test.dart` on that patched tree (sanity that the wrapper is really in) | `+12: All tests passed!` | 0 |
| verifier file, clone #1 x2, clone #2 x2, R4a x2 | `+6` each (13 tests with the tester file together, last run 20:58) | 0 |
| `dart analyze --fatal-infos` on the tester file (clean and with R4a: `lib` + file) | No issues found | 0 |
| `dart format --output=none --set-exit-if-changed` on the tester file | 0 changed | 0 |
| analyze + format on the verifier file | clean | 0 |

## 3. Mutation table (tree #1, `api_server.dart` / `protocol.dart` in `mut/`, tester file + verifier file run together; restore + `diff -r` rc 0 after each)
| # | mutation | killed by (tester's file) | verdict |
|---|---|---|---|
| a | file count (and its 413) moved BEFORE the proof check | `file-limit-after-auth-no-proof`, `-bad-proof`, `-garbage-proof`, `-replay-not-spent` (4 red) | KILLED |
| b | file-count limit removed (`&& false`) | `file-limit-enforced` | KILLED |
| c | check `> kMax + 1` (limit 10,001) | `file-limit-enforced` | KILLED |
| d | check `> kMax - 1` (limit 9,999) | `file-limit-boundary`, `-replay-not-spent` | KILLED |
| c2 | constant 10000 -> 10001 | `premise` | KILLED (by the explicit `expect(kMaxFilesPerSession, 10000)`) |
| d2 | constant 10000 -> 9999 | `premise` | KILLED |
| e | no proof verification at all on POST /sessions | no-proof, bad-proof, garbage-proof, replay-not-spent (4 red) | KILLED |
| f | bad proof answered 400 instead of 401 (`_readAuthenticated`) | no-proof, bad-proof, garbage-proof, replay-not-spent (4 red) | KILLED |
| g | JSON decoded BEFORE the proof check | **none of the 7 tester tests** | **SURVIVED** the tester's file; killed by verifier `invalid-json-unauth` |

Note on c2/d2: because the tests build their bodies from `kMaxFilesPerSession`, only `premise` catches a constant change; this is intended and sufficient.

## 4. Probe: unauthenticated body above 4 MiB
Verifier test `bytes-before-auth` (`p3SessionBody(length: kMaxSessionJsonBytes + 1)`, no `X-LS-Auth`) -> **413 TOO_LARGE**, no session created. This matches LSP-1 step 3 ("body size ... the only size check before authentication") and `_readSecureBody` (a declared length above the cap is refused without reading). The tester's file does not contradict it: it only uses a body below the cap (premise test). Between 256 KiB and 4 MiB the body is read (<= 2 concurrent) and the proof is verified before the count, as pinned.

## 5. Findings
- **MEDIUM (closed by the verifier file):** mutation g (decode JSON before the proof) survives the tester's seven tests. LSP-1 step 4 says an unauthenticated invalid-JSON body also gets 401; the tester's file only pins the oversize-manifest case. Verifier test `invalid-json-unauth` (401, not 400) kills it; `invalid-json-signed` (400) is its twin.
- **LOW:** the verifier file adds `proof-for-other-server` (oversize with a proof naming another server -> 401), `replay` (the proof of a 413 manifest is spent, replay -> 401) and `oversize-bad-shape-signed` (signed 10,001 files -> 413). All green on the unchanged tree and with R4a.
- **LOW:** garbage-proof test has no "no session created" assertion (see section 1).
- **LOW (information):** production has a second 10,000-file check in `file_receiver.dart` (`r.files.length > kMaxFilesPerSession`, after the handler is reached), so removing the `api_server.dart` check (mutation b) would still answer 413 in the real engine, later than step 5 and after the trust/pin steps; only the fake-handler rig sees the difference. The test therefore pins the HTTP layer, as intended.
- No HIGH findings. R4a (both patch versions) does not change the result.

## Files
- Verifier test (apply together with the tester's file if wanted): `docs/plans/e-proposals/r4e/verifier-tests/manifest_limit_order_verifier_test.dart` -> `packages/libreshare_core/test/security/`.
- Logs, scripts, mutation logs `mut-*.log`, `mut.log`, `gates.log`, `gates2.log`: `.toolchain/scratch/e5-r4e-verify/`.

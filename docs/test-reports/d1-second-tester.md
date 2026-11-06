# D1 second-tester report (independent verifier)

Date: 2026-11-06 ~02:00-02:55 IST. Author: second tester. Scope: card D1 "Wire the app to the secure engine and make the PIN real".
Read-only on `apps/` and `packages/`. All mutations and extra tests were done in the scratch clone
`.toolchain/scratch/d1-second-tester/clone/`; logs are in `.toolchain/scratch/d1-second-tester/logs/`.

## VERDICT: **FAIL** (gate not passed)

Reasons, in order of weight:

1. The three delivered d1 test files are NOT green on the real tree: 3 of 3 runs red (`rc=1`). One delivered test deadlocks for 10 minutes.
2. Real defects in the coder's code that no delivered test detects (found with my probe tests, red on the pristine tree): the "Change PIN" flow keeps enforcing the OLD PIN, and "PIN configured" is shown even when the save fails.
3. Of the 11 mutations, the DELIVERED tests cleanly kill only 3 (a, b, f) and (d) only by accident; 7 survive (c, e, g, h, i, j, k). With my probe tests added all 11 are killed (see table).
4. Design bullet 8 / test 8 ("plaintext peer produces the older-version message") is not met through the app's send path (`FailureReason.noConnection` instead).
5. Sender-side PIN dialog (design bullet 7) has no way to submit a PIN in the app code at all.

Recommended verdict after fixes: PASS WITH TEST ADDITIONS (add `d1x_probe_test.dart` tests X1-X5, X9, X10 to the repo and fix the test-side defects listed in section 1).

## 1. Test-file static review (step 1)

Coverage map of D1 "Tester writes NEW tests" items 1-8:

| # | Behaviour | Delivered test(s) | Judgement |
|---|---|---|---|
| 1 | engine has identity + fingerprint | `d1_secure_engine_test` "positive twin: engine built by engineProvider ..." + negative twin (plain engine) | Real engine via `AppHarness`/`engineProvider`; real asserts (`identity`, fingerprint equal, caps sas/pair). Good. Negative twin tests a hand-built plaintext engine, not the provider; acceptable. |
| 2 | identity persisted, same fingerprint after restart | "second build with same support dir has the SAME fingerprint" + "fresh support dir ... different" | Good. Uses `reuseSandbox`; asserts `identity.json` exists and `fp2 == fp1`. |
| 3 | damaged key -> `IdentityLostException`, not regenerated | "missing/damaged key causes provider to fail with IdentityLostException" | Good: corrupts `*.secret`, expects `throwsA(isA<IdentityLostException>())` and `identity.json` unchanged. Only `.secret` corruption is tested; a deleted `identity.json` or deleted key is not. |
| 4 | PIN Off -> not enforced; Fixed saved -> enforced, survives restart, not in settings JSON/logs/toString | Off: "default PIN mode is Off" (passes). Fixed: "Fixed mode saves 6 digits ..." | The Fixed test is **red on the pristine tree** (see below), so it protects nothing. "logs" is never checked (no `Logger`/`debugPrint` capture anywhere in the 3 files). The settings-JSON check is under `if (settingsFile.existsSync())` and is read right after a `pump()` before the async write finished: it can pass vacuously. |
| 5 | window PIN non-null while Receive on, rotates, shown only while on | "window PIN is active ... rotates ... displayed" and "NOT displayed ... when Receive is Off" | Positive twin **deadlocks** (10 min) on the pristine tree. The negative twin only asserts `findsNothing` for two keys (`receive-pin`, `receive-card-pin`) on the Home screen with the default Off mode: it would also pass if the feature did not exist and does not use window mode, so mutation (k) (PIN shown when Receive is off) is invisible to it. |
| 6 | invalid input rejected with visible message, nothing saved | three validation tests (valid / 5 digits / letters) | Pass in isolation. The negative tests check `textContaining('6 digits')` / `'digits'` (note: 'digits' also matches the label "6-digit"? No: "6-digit PIN" has no "digits"; ok) and the secret store is empty, but the store check is under `if (secDir.existsSync())` and there is no check that `app_settings.json` stayed `off`. |
| 7 | sender PIN dialog works against a real secure receiver | "sender encounters pinRequired ... succeeds with correct PIN", "wrong PIN ...", "sender-side PIN dialog renders and accepts 6 digits", "trusted contact exempt" | Weak. The success path calls `h.engine.sendFiles(pin:)` directly, bypassing the app's transfer provider and dialog (the dialog in `screens/transfer_screen.dart:160` is a bare `TextField` with no controller and no submit button; no code in `lib/` ever passes `pin:` to the engine except the receiver side). The dialog test ends with `expect(find.text(correctPin), findsOneWidget)`, which only finds the text the test itself typed (tautology). Two of the four are red (the sender never confirms the SAS, so `sendFiles` hangs: my diagnostic X7 printed `TIMEOUT events=[bob:SessionCreated, SessionCreated, bob:SasReady, SasReady]`). Only "wrong PIN" (refused before the SAS) is green. |
| 8 | `allowInsecurePeers` false by default, plaintext peer gives "older version" message | "allowInsecurePeers is false by default; ... plaintext peer fails with older version message" + "secure peer does not report insecurePeer" | Positive twin is **red on the pristine tree**; negative twin is satisfied by any value of `allowInsecurePeers`, so mutation (h) survives. My diagnostic X8 shows the app path (`beginSendTo` -> `_findEndpoint`) ends in `phase=failed ... failure=FailureReason.noConnection`, never an `InsecurePeerException`. |

Test-side defects (the tests cannot pass whatever the coder does):
* `d1_pin_persistence_test` "Fixed mode saves ...": reads `h1.engine.pinGuard` immediately after `pump()`, before the settings change has rebuilt the engine (real file I/O needs `settleUntil`). Failure: `Fixed PIN must set enforced == true  Expected: true Actual: <false>`.
* `d1_pin_persistence_test` window positive twin: calls `tester.runAsync(() => actions.setEnabled(true))` right after the tap that triggers an engine rebuild; the rebuild's continuation runs in the fake-async zone, so `engineProvider.future` never completes. The test then times out after the 10-minute `testWidgets` default and **poisons the binding**: the next testWidgets in the file fail with `Reentrant call to runAsync() denied` and each also waits 10 minutes (observed: run 1 took 24:44 minutes).
* `d1_two_engine_pin_test` pos-twin and trusted-contact tests: no SAS confirmation on either engine.
* None of the new UI text (`Off`, `Fixed`, `New each time`, `Enter 6 digits`, `PIN configured`, `PIN: ######`) has a 360x640 / 1.3x text-scale check (required by the project's widget standard); all of it is also hard-coded English instead of `tr(...)`.
* No test for: a failing save (read-only secret dir), changing the PIN while already Fixed, stored `app-pin` missing/corrupt while the policy is Fixed, shutdown order, log capture, `EngineTuning` default.
* Test ordering: window test + validation tests depend on a clean binding (see poison above); temp sandboxes are created under system tmp and deleted in teardown, so no leftover-dir dependence found.

## 2. Runs of the three d1 files on the real tree (step 2)

Command (from `apps/libreshare_app`, `source tools/env.sh`, `TMPDIR=.toolchain/tmp`):
`flock -o /tmp/libreshare-heavy.lock flutter test --no-pub --concurrency=1 test/d1_secure_engine_test.dart test/d1_pin_persistence_test.dart test/d1_two_engine_pin_test.dart -r expanded`

Source files sha256 (97 files under `apps/libreshare_app/lib` + `test`) before and after: `diff sha-before.txt sha-after.txt` -> **IDENTICAL** (also unchanged right before run 3). No coder activity during my measurements.

| Run | Variation | rc | Final line | Red tests |
|---|---|---|---|---|
| 1 (`logs/run1.log`) | exact command; I terminated my own hung `flutter_tester` once (PID 793544) after the 2nd 10-minute wait to let the run reach the remaining files | rc=1 | `24:44 +10 -7: Some tests failed.` | insecure-peer positive twin; Fixed-PIN positive twin; window positive twin (`TimeoutException after 0:10:00`); window negative twin (`Reentrant call to runAsync() denied`); validation "valid 6 digits" (10-min timeout); validation 5 digits + letters ("did not complete", killed); two-engine "pinRequired ... succeeds" (`sendFiles with correct PIN must succeed Expected: true Actual: <false>`); trusted-contact exempt (`TimeoutException after 0:00:30`) |
| 2 (`logs/run2.log`) | added `--timeout 60s` (applies only to plain `test()`, not to `testWidgets`); I terminated the hung tester after ~6 min | rc=1 | `08:09 +10 -4: Some tests failed.` | same set; the 4 widget tests after the window hang are reported "did not complete" because of my kill |
| 3 (`logs/run3.log`, `run3.watchdog`) | exact flags of run 1, watchdog script terminated the hung tester after 90 s of silence | rc=1 | `02:43 +10 -4: Some tests failed.` | same set |

First assertion messages (identical in all 3 runs):
* insecure peer positive twin: `Expected: true Actual: <false> transfer to plaintext peer must be flagged as insecurePeer when allowInsecurePeers is false` (`d1_secure_engine_test.dart:212`).
* Fixed PIN positive twin: `Expected: true Actual: <false> Fixed PIN must set enforced == true` (`d1_pin_persistence_test.dart:90`).
* two-engine pinRequired positive twin: `sendFiles with correct PIN must succeed` (`d1_two_engine_pin_test.dart:98`).

The "+10" counts are tests that ran and passed in all three runs: 6 of 7 in the secure-engine file, "default PIN mode is Off", the sender dialog render test, the wrong-PIN test. Not measured in isolation by me: the window negative twin (red only because of the poisoned binding). In isolation the 3 validation tests PASS (`logs/mut-base.log`, `+16 -3`, the 3 reds being insecure-peer, X3, X4).

## 3. Mutations (step 3)

Method: scratch clone, one mutation at a time from the pristine `lib/` (`mutate.py`, `runall.sh`), restore by `rsync` and `diff -r` rc=0 verified after each (`logs/mut-<x>.restore` all read `restored rc=0`), no compile errors (`grep -c 'Error:'` = 0 in every log).

Run set (because the delivered window/Fixed tests are red or hang on the pristine tree, 3 full runs per mutation would be 25 min each): `d1_secure_engine_test` (all), `d1_pin_persistence_test` and `d1_two_engine_pin_test` filtered with `--name "engineProvider|default PIN mode|Fixed PIN input validation|wrong PIN causes|sender-side PIN dialog|X[1-5] "`, plus my probe file `test/d1x_probe_test.dart` (X1-X5). Baseline on the pristine clone (`logs/mut-base.log`): `00:18 +16 -3` with the 3 reds = delivered insecure-peer test, probe X3, probe X4. Mutation 'catches' below mean a test that is green on the baseline turned red. X9/X10 (added later) were run with `--name "X9|X10"`: baseline `All tests passed!`.

| # | Mutation (clone only) | File:line | Caught by DELIVERED tests? | Caught by probe? | Result |
|---|---|---|---|---|---|
| a | `security: security,` removed | `providers/engine_provider.dart:137` | yes: "engine built by engineProvider has engine.identity != null", "second build ... SAME fingerprint", "intact security directory loads identity", "fresh support dir ... different", "default PIN mode is Off" (`guard` null), "wrong PIN causes refusal" (`mut-a.log`: `+7 -12`) | X1, X2, X5 | CAUGHT |
| b | new identity every start (`directory: Directory.systemTemp.createTempSync(...)` for `SecurityWiring.open`) | `engine_provider.dart:96` | yes: "second build with same support dir has the SAME fingerprint", "missing/damaged key causes provider to fail with IdentityLostException" (`+14 -5`) | - | CAUGHT |
| c | fixed PIN also appended to `app_settings.json` after `setPinMode(fixed)` | `settings_screen.dart:623` | **no** (the only test that could, "Fixed mode saves ...", is red on the baseline and reads the file before the async write) | X1 (`app_settings.json` contains PIN) | **SURVIVED the delivered set** |
| d | `secretStore.put('app-pin', ...)` removed (PIN accepted, not saved) | `settings_screen.dart:616-619` | only incidentally: "Fixed PIN input validation positive twin" turned red because `ref.read` ran after the widget was disposed (`ConsumerStatefulElement._assertNotDisposed ... settings_screen.dart:618`), not because of any assertion about persistence | X1 (stored value missing) | CAUGHT only by accident in the delivered set; semantically SURVIVES |
| e | window PIN not rotated between Receive windows (both `rotate()` calls removed) | `providers/receive_provider.dart:98,124` | **no** (window positive twin is red/deadlocked on the baseline) | X2 | **SURVIVED the delivered set** |
| f | `IdentityLostException` swallowed, identity files deleted and regenerated | `engine_provider.dart:95-110` | yes: "missing/damaged key causes provider to fail with IdentityLostException" | - | CAUGHT |
| g | PIN text logged (`Logger('libreshare.app.engine').info('fixed pin loaded $fixedPin')`) | `engine_provider.dart:14,93` | **no** (no log capture in any delivered test) | X1 (captures `Logger.root` + `debugPrint`) | **SURVIVED the delivered set** |
| h | `allowInsecurePeers = true` default in `EngineTuning` | `engine_provider.dart:31` | **no** (positive twin red on the baseline; negative twin satisfied either way) | X9 (red on mutation, green on baseline) | **SURVIVED the delivered set** |
| i | Fixed policy but stored `app-pin` missing -> `PinPolicy.off()` (engine enforces nothing) | `engine_provider.dart:98` | **no** | X5 | **SURVIVED the delivered set** |
| j | `SecurityWiring.close()` before `engine.dispose()` in `_closeCurrent` | `engine_provider.dart:184-190` | **no** | X10 (red on mutation, green on baseline) | **SURVIVED the delivered set** |
| k | `receive_card.dart` shows the PIN also when Receive is off | `widgets/receive_card.dart:44` | **no** | X2 | **SURVIVED the delivered set** |

Delivered set: caught 3 cleanly (a, b, f) + 1 incidentally (d) of 11; survived 7 (c, e, g, h, i, j, k) and d semantically. With the probe file added: 11 of 11 killed.

Note on (i), the real behaviour on the pristine tree: `PinGuard` receives `pin: null` for a Fixed policy and **generates a random PIN that no one is shown** (fail-closed but silent: every sender is locked out and the user sees "PIN configured"). A corrupt stored value (non-UTF-8 or not 6 digits) makes `utf8.decode`/`PinGuard` throw inside `build()` -> the whole engine fails to start. Neither case has a test or a visible message.

## 4. Defects found on the pristine tree by my probe tests (all red at baseline in the clone)

* **A. Changing the PIN while already in Fixed mode does not take effect.** X3: first PIN `111111`, tap "Change", save `222222`: the secret store holds `222222` (poll shows `X3 stored=222222 configured=1 input=0`), but `engine.pinGuard.currentPin` stays `111111`: `Expected: '222222' Actual: '111111' the engine must enforce the new PIN, not the old one`. Cause: `setPinMode(PinMode.fixed)` is a no-op when the mode is already fixed (`providers/settings_provider.dart`, `if (mode == state.pinMode) return;`), so the engine is not rebuilt; contradicts the design ("saving a PIN rebuilds the engine").
* **B. "PIN configured" is shown when the save failed** (design: "only after the save really succeeded"). X4: security dir made read-only (`chmod 500`), Save -> `Found 1 widget with text "PIN configured"`. Cause: `screens/settings_screen.dart` sets `_pinSaved = true` synchronously, then runs the save in an un-awaited closure with no `try/catch`; the same closure also calls `ref.read` after awaits with no `mounted` check (it throws "used after dispose" if the user leaves the screen during the save, which is how mutation d got caught).
* **C. Plaintext peer from the device list gives `noConnection`, not the "older version" message** (X8: `phase=failed insecure=false failure=FailureReason.noConnection`). Through host:port (`sendFiles`) the refusal works (X9 green). The device-list path (`beginSendTo` -> `_findEndpoint`) is in the core (orchestrator-owned): report only.
* **D. The sender PIN dialog cannot submit** (`transfer_screen.dart:160`): there is no controller, button or call to `sendFiles(pin:)`, so a user cannot send to a PIN-protected receiver from the app. Not in the coder's file list but it makes design item 7 "still works" unprovable.
* **E. Fixed PIN is shown on the Receive card** (`receive_card.dart:44`: `activePin = receiving ? pinGuard.currentPin : null` applies to Fixed as well as Window), while Settings promises "PIN is protected and will not be displayed." Decide which is intended; no test pins either.

## 5. Proposed extra tests (all exist, green on pristine except where marked, in `.toolchain/scratch/d1-second-tester/clone/apps/libreshare_app/test/d1x_probe_test.dart`; proposed repo name `apps/libreshare_app/test/d1_probe_secure_pin_test.dart`)

Every widget test must `await tester.settleUntil(...)` after any action that rebuilds the engine, tap `receive-switch` (not `runAsync(setEnabled)`), and carry an explicit `timeout: Timeout(Duration(seconds: 60))` so a hang cannot cost 10 minutes.

* **X1** (kills c, d, g): Fixed -> enter `654321` -> Save -> `settleUntil(engine pinGuard.policy.mode == fixed)`; assert "PIN configured", `pinGuard.enforced`, `currentPin == '654321'`, `FileSecretStore.get('app-pin')` decodes to it, then after `settle(ms:100)` `app_settings.json` has `"pinMode": "fixed"` and does not contain the PIN; restart on `reuseSandbox` keeps it; with `Logger.root.level = ALL` and `debugPrint` captured, no record contains the PIN. Green on pristine.
* **X2** (kills e, k): Window mode; Receive off -> `pinGuard.currentPin != null` and `find.byKey('receive-pin')` is `findsNothing`; tap `receive-switch` -> `receive-pin` appears with text `PIN: <currentPin>`; off -> disappears; on again -> `currentPin` differs. Green on pristine.
* **X3** (defect A): see section 4. **Red on pristine** until the coder rebuilds the engine after saving a new PIN.
* **X4** (defect B / mutation d semantic): `chmod 500 <supportDir>/security` after boot, Fixed + Save, `settle`; expect `find.text('PIN configured')` is `findsNothing` and an error text is visible. **Red on pristine.**
* **X5** (kills i): write `app_settings.json` with `pinMode: fixed` and no `app-pin`; boot; assert `pinGuard.enforced == true` (or that the provider fails with a clear message). Green on pristine (random PIN), red on mutation i.
* **X9** (kills h): `startPeer('LegacyBob', discover: false)`; `expectLater(h.engine.sendFiles([f], host: peer.ip, port: peer.engine.port), throwsA(isA<InsecurePeerException>()))` and the peer's rx directory is empty. Green on pristine, red on mutation h.
* **X10** (kills j): `final sec = engine.security!`; record the order of `engine.events` `onDone` and `sec.trust.changes` `onDone`; `container.dispose(); await notifier.closed;` expect `['engine','security']`. Green on pristine, red on mutation j (also catches "SecurityWiring never closed").
* Fix the delivered tests (test-side only, by the tester): wait for the rebuild in "Fixed mode saves ...", use the switch in the window test, confirm the SAS on both engines in the two-engine success tests, drop `if (exists)` guards, add 360x640 + `textScaler 1.3` pumps for the PIN card and Receive-card PIN row, and make the dialog test assert on a real submit once D (above) exists.

## 6. Spec-gap read of the diff (step 4)

Implemented as designed: `security:` passed to the engine; `SecurityWiring.open` under `<supportDir>/security` with the settings device id; fixed PIN only in `FileSecretStore` under `app-pin`; `pinMode` in `AppSettings` (default off, parsed with fallback to off); security closed in `_closeCurrent` after the engine; PinMode window rotates on `setEnabled(true)`/`resume()`; "New each time" shows no input; no `libreshare_core/src` import in the 7 changed files (only the pre-existing test harness imports `src/discovery/testing`); no hard-coded device id in `lib/`; no logging or `print` in the changed providers/screens; `allowInsecurePeers` default false.

Not implemented / deviating:
1. Saving a new PIN while already Fixed does not rebuild the engine (defect A).
2. "PIN configured" is not tied to a successful save; no error handling in the save closure (defect B).
3. Device-id follow-up is `unawaited(setDeviceId(...))` with no error handling; a first-run mismatch causes a start-then-supersede of the engine (`StateError('engine start superseded')` is possible); the design asked for a clear failure, not a silent rebuild.
4. Missing/corrupt `app-pin` with Fixed mode: no message, no fallback (see note under (i)).
5. The sender PIN dialog cannot submit (defect D); plaintext-device message (defect C).
6. New UI text is hard-coded English (not `tr`) and the PIN row lacks narrow-width/large-text tests.
7. `Fixed` can be selected without a saved PIN: the stored mode stays at the previous value, the chip shows Fixed, and returning to the screen shows the old mode; harmless for security (nothing is enforced that was not saved) but confusing.
8. No `security.close()` call is placed in `ref.onDispose` literally as designed; it is inside `_closeCurrent`, called from `onDispose`, which is equivalent (X10 green).

## 7. Evidence index

* sha256 before/after: `.toolchain/scratch/d1-second-tester/sha-before.txt`, `sha-after.txt` (97 lines each, `diff` rc=0).
* Runs: `logs/run1.log`, `run2.log` (+`run2.rc`), `run3.log` (+`run3.rc`, `run3.watchdog`).
* Mutations: `logs/mut-base.log`, `mut-<a..k>.log|rc|diff|restore|apply`, `logs/x-*.log` (X9/X10), `probe-base1..3.log`, `probe-x8.log`.
* Scripts: `mutate.py`, `runset.sh`, `runall.sh`, `runx.sh`, `run3.sh`, `summ.sh` in `.toolchain/scratch/d1-second-tester/`.
* Not measured: full-suite run of the whole app (not requested); `dart analyze`/`flutter build apk` (not requested; builds forbidden); Windows/Android runtime behaviour of the file secret store.

# LibreShare Questions & Escalation Log

Logged when stuck twice, encountering ambiguities, or needing orchestrator escalation per HANDOFF.md section 8b.

### Q1 2026-11-05 from C4
Question (one sentence): How should disk quota exhaustion (`errno = 122` on `/tmp`) during full core `dart test -j 1` be handled when `/tmp` (tmpfs 6GB user quota) is filled by concurrent agent clones (`/tmp/claude-1000` 3.5GB, `/tmp/lead-scratch` 948MB, abandoned `dart_test.kernel.*` dirs)?
What I tried / what I read: Executed Step 3 (`cd packages/libreshare_core && dart test -j 1`) twice under `/tmp/libreshare-heavy.lock`; both runs failed at ~test 42-45 with `Cannot copy file to '/tmp/dart_test.kernel.*/test.dart_*.dill' (OS Error: Disk quota exceeded, errno = 122)`. `/tmp` has a 6GB user quota with 5.9GB used, whereas `/dev/nvme1n1p4` has 55GB free. Per rule ("anything red: list failing files and stop", "fails twice: stop and write question to questions.md"), stopped at Step 3.
Options I see (max 3):
1. Clean abandoned `/tmp/dart_test.kernel.*` and dead `/tmp/ls_app_test_*` temp directories in `/tmp` to reclaim ~1.2GB.
2. Configure `tools/env.sh` to export `TMPDIR="$ROOT/.toolchain/tmp"` so Dart test runner places kernel files on the 55GB btrfs filesystem.
3. Orchestrator cleans/moves inactive agent clones (`/tmp/lead-scratch`, `/tmp/claude-1000`) before running the gate.

### Q2 2026-11-05 from B2 (ESCALATE-SECURITY)
Question (one sentence): Should `FileOpenerChannel` enforce receive-folder containment and `file_paths.xml` be scoped to `Download` rather than root external storage?
What I tried / what I read: B2 Verifier noted during static review of Android Kotlin channels that `file_paths.xml` specifies `<external-path name="external_files" path="." />`, which allows `FileProvider` to serve any file on external storage given an arbitrary path, rather than restricting it to `Download/LibreShare`.
Options I see (max 3):
1. Keep as-is for MVP (app only requests viewing received files managed by app paths).
2. Scope `file_paths.xml` to `<external-path name="external_files" path="Download" />` and validate in `FileOpenerChannel.kt` that the path starts within the download directory.
What I will do meanwhile: Logged for orchestrator review per HANDOFF.md section 8b; proceeding with other cards.

---
## ORCHESTRATOR ANSWERS (2026-11-05 ~23:05)

**Q1 (/tmp disk quota):** do not delete other agents' or the user's files. `/tmp` is a 7.7 GB tmpfs, 4.0 GB used at 22:57 (3.5 GB is the orchestrator session's old scratch, deliberately left alone by the user). Re-run C4's core step alone now. If it recurs, the orchestrator will set `TMPDIR` in `tools/env.sh`; no action for the Lead.

**Q2 (FileOpenerChannel containment) ESCALATE-SECURITY:** accepted for the MVP. The saved path always comes from the receiver's sanitiser (`filename_sanitizer.dart` rejects `..` and re-roots absolute paths), so it lies inside the receive folder; the provider is not exported and only URIs for those paths are created. Scoping `file_paths.xml` to `Download` would break "Choose a folder" anywhere else. One cheap hardening is queued as card D4; no test changes.

**Gate requests of 22:50 (P6A_GATE -> DONE, MVP_APP_DONE -> YES): NOT GRANTED.** Reasons: (1) the app does not enable the secure engine and the PIN control is a no-op (HANDOFF Wave D, D1); (2) C5 adversarial review not done; (3) the repo is not format/analyze clean (B1 test files, D2); (4) the C4 entry hid its own red runs (D2). What was verified and IS accepted: C1, C2, C3 (the orchestrator read the diffs; each is exactly the scoped change) and the clean full-suite results in STATUS.md.


### Q3 2026-11-06 12:15 from E5/R4e tester
Question (one sentence): May LSP-1 4.3 "Secure-profile order" (step 3 "the 10,000-file limit is decided after the proof verified", step 4 "an unauthenticated body that lists more than 10,000 files therefore also gets 401") be changed so that a manifest with more than `kMaxFilesPerSession` files is answered 413 before the proof is verified?
What I tried / what I read: `api_server.dart` `_postSessions` -> `_readAuthenticated` reads the body (cap `kMaxSessionJsonBytes` 4 MiB, the only pre-auth size check, exactly as LSP-1 says), verifies the `X-LS-Auth` proof, and only then decodes the JSON and counts `files` (413 `Too many files`). The file count is not known cheaply before authentication: `Content-Length` says nothing about the number of entries (a valid 10,001-file manifest and a valid 10,000-file one differ by about 260 bytes), so the only possible early check would be to JSON-decode up to 4 MiB of unauthenticated data before the proof, which is more CPU for a stranger than the single ECDSA verify it would save, and it contradicts the normative order and the 401 sentence in LSP-1 4.3. Nothing in the repo tests the >10,000-file HTTP answer today.
Options I see (max 3):
1. Keep as is (documented limit; the cost before the 413 is one body read <= 4 MiB plus one proof verify, already behind the rate limit of 10/min per IP and the 2-slot oversize cap). R4e is closed as "won't fix, documented".
2. Change the spec: add a cheap count (for example a bounded scan counting `"fileId"` keys, or a streaming decode that stops at file 10,001) before step 4 and answer 413; needs LSP-1 4.3/4.3.6 + conformance test changes by the orchestrator.
3. Keep the order but add a regression test pinning the current behaviour (unauthenticated oversize manifest -> 401, authenticated -> 413).
What I will do meanwhile: R4e is STOPPED (no test written, no clone); continuing with R4d.

### Q4 2026-11-06 12:20 from E5/R4c tester
Question (one sentence): LSP-1 4.2 rule 2 says an `announce:true` from a peer already listed with the same fingerprint "gets no reply at all (neither /register nor datagram)": is a Contacts-only device allowed to re-send its `POST /register` greeting to a contact that announces again (needed to find a contact that restarted while still listed), or must that half of R4c be dropped?
What I tried / what I read: the retry half (re-send the greeting when `POST /register` failed) needs no protocol change and is tested (`contacts_greeting_retry_test.dart`, tests greeting-retry, greeting-retry-keeps-going). The restart half (test regreet-after-restart, plus the throttle test regreet-rate-limited) makes the engine greet a listed contact again after it announces; that is a `/register` sent in response to an announce from an already-listed fingerprint, which the quoted sentence forbids for the general case (the greeting itself is the Contacts-only addition of rule 10, whose text I did not find to cover repeats).
Options I see (max 3):
1. Allow it for contacts only, throttled (for example at most once per 5 s per contact; the tests need the re-greeting within about 5 s of the restart, so a longer throttle would fail them), and amend rule 2/10 in LSP-1 by one sentence (orchestrator edits the protocol, then the coder implements; tests stay as written).
2. Drop the restart half: keep only the retry; the restart case is then covered by the peer's own start-up probe (rule 8, a UDP unicast reply from the contact) and stays a documented limit when that UDP reply is lost.
What I will do meanwhile: both halves have tests in the same file; the restart tests are marked in tests-plan.md so the orchestrator can delete or keep them; the coder should do the retry half first.

## ORCHESTRATOR ANSWERS to Q3 and Q4 (2026-11-06 12:12:15 by `date`)

**Q3 (R4e, 10,000-file limit before auth):** option 3. LSP-1 4.3 order stays normative (the proof is verified before the body is decoded; an unauthenticated oversize manifest gets 401, an authenticated one gets 413). The cost before the 401 is one body read (<= 4 MiB) plus one proof verify, already behind the per-IP rate limit and the oversize slot cap, so R4e is closed as "documented limit". A tester adds a regression test that pins the current behaviour (unauthenticated 401, authenticated 413); no `lib/` change and no spec change. A spec change (option 2) would be a protocol change and is not worth it for this cost.

**Q4 (R4c, re-greet after restart):** option 2 for now. The retry half proceeds (no protocol change). The restart half (tests `regreet-after-restart`, and the pin `regreet-rate-limited`) is DEFERRED: LSP-1 4.2 rule 2 ("no reply at all" to an already-listed same-fingerprint announce) exists to stop amplification and I will not amend it inside E5. The deferred test stays in the test file, expected RED, and must not be edited, skipped or weakened by anyone; it is recorded as a known limit (covered by the start-up probe of rule 8; lost UDP reply = documented limit). If the user later wants it, the amendment is: contacts only, at most one re-greeting per contact per 5 s, one sentence in rule 2 and rule 10, plus a conformance test.

# Module D: paste-in prompt for the Lead (Antigravity / Gemini)

Paste everything between BEGIN and END into the Lead. The orchestrator (Claude) finishes module B first; the Lead starts module D only when `docs/plans/STATUS.md` says `B_MODULE_DONE: YES`.

--- BEGIN ---

You are the Lead for LibreShare **module D** (Wave D in `docs/plans/HANDOFF.md`). Repo: `/home/kirat/coding/Software Engineering LibreShare`. You spawn subagents (at most 6 at once, but see the memory rule); you write no feature code yourself.

**Step 0 - read, in this order:** `docs/plans/STATUS.md`, `docs/plans/HANDOFF.md` (sections 2, 3, 5 "Wave D", 6, 7, 8, 8b), `docs/plans/MASTER_PROMPT.md`, `docs/plans/questions.md`, `CLAUDE.md`.

**Step 1 - start gate:** `STATUS.md` must contain `B_MODULE_DONE: YES`. If it says NO, start nothing that runs tests, builds or an emulator (the orchestrator is taking a clean, serialized measurement and any run of yours would corrupt it). Re-read STATUS.md every 10 minutes. You may spend the wait writing test plans (read-only).

**Step 2 - do Wave D in this order:**
1. **D1** (MVP blocker, security-critical): wire the app to the secure engine and make the PIN real. Flow: tester (effort high) writes `apps/libreshare_app/test/d1_*_test.dart` first and shows them red -> coder (effort medium) edits only `apps/libreshare_app/lib/**` until green, following the fixed design in HANDOFF D1 -> a different verifier subagent runs mutations (a)-(h) in a scratch clone and each must turn a named test red. Done = new tests 3x green, whole app suite green (alone), `dart analyze --fatal-infos` rc 0, `flutter build apk --debug` rc 0, verifier PASS. Then ask me (questions.md or the gate request) to re-run and flip `APP_SECURE_WIRED`; do not flip it yourself.
2. **D2 rest:** correct the C4 entry in `docs/plans/handoff-log.md` (it says DONE although core was rc=1 and CLI rc=1). From now on every gate request lists the rc of EVERY command, red ones included.
3. **D3 = C5:** P6a adversarial review (10 seeded mutations, scratch clone only, each must turn a named test red).
4. **D4:** harden `FileOpenerChannel.kt` as written in HANDOFF D4 (no contract change).
5. **D5 is NOT yours (user decision 2026-11-06 03:24: the orchestrator does D1 round 2 and D5 itself).** Do not repackage, do not run `tools/package_prototype.sh`, do not run `tools/android_emulator_smoke.sh`, do not edit either script. You may still finish `docs/plans/d5-smoke-secure.md` as a read-only proposal; the orchestrator applies and runs it.

**Rules that keep biting:**
- Do NOT `git commit` or `git push`. No remote. Everything free ($0).
- NEVER edit, delete, skip or weaken an existing test. A needed test change goes to `docs/plans/questions.md` and waits for my answer.
- NEVER delete scratch, temp or dead files unless the user asks.
- Orchestrator-only files (do not edit): CLAUDE.md, docs/protocol/**, schemas/**, docs/plans/inc3*.md, docs/plans/mvp.md, STATUS.md, security contracts, `model/*`, `protocol.dart`, the core barrel, any pubspec.yaml. Put requests in `questions.md`.
- Memory: the machine has 15 GB and an OOM kill already happened (exit 137 = killed for memory, not a test result). ONE heavy run at a time: `flock /tmp/libreshare-heavy.lock <cmd>` with `dart test -j 1` / `flutter test --concurrency=2`. Tests bind fixed ports (53318...): two test processes at once give false "Address already in use" reds.
- NEVER wrap `tools/package_prototype.sh` in `flock /tmp/libreshare-flutter-build.lock` (it takes that lock itself -> self-deadlock). Use only the heavy lock around it.
- Use `flock -o /tmp/libreshare-heavy.lock ...` (the `-o`!) for the emulator smoke and Android builds: a background `adb` server inherits a plain flock and blocks every later run forever. After the emulator step run `.toolchain/android-sdk/platform-tools/adb kill-server`. Diagnose with `lslocks | grep libreshare` (holder `WRITE`, waiter `WRITE*`).
- After every Android/Gradle build run `.toolchain/gradle/wrapper/dists/gradle-9.3.1-all/*/gradle-9.3.1/bin/gradle --stop` (a left-over Gradle daemon holds ~4 GB and blocks the emulator step).
- A step is DONE only with a real exit code from a run that was alone. "Passed" without the command and its rc does not count. Report red results honestly; do not retry until green without saying so.
- Security items (crypto, TLS, pairing, PIN storage, key storage) get a medium coder at least and a second reviewer. Anything touching a contract goes to the orchestrator.
- Never log or print file contents, keys, PINs or tunnel URL fragments.

**Reporting:** append one entry per card to `docs/plans/handoff-log.md` (format in HANDOFF section 7): what changed, every command with its rc, files touched, open questions. When D1 and D5 are done, write "MODULE_D_READY_FOR_GATE" at the top of `questions.md` and stop; I will re-run every gate and flip the flags.

--- END ---

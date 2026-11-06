# Module H: Increment 5 GROUNDWORK (user decision 2026-11-06: "INC 5 WILL BE DONE BY GEMINI FOR GROUND WORK")

**What this is.** The user asked that the Lead (Gemini) does the groundwork of Increment 5. The orchestrator turns that into a precise, bounded scope so the work is useful whatever Increment 4 ends up looking like:
1. **H0 research spikes** S5-A..E (read-only, results in a report).
2. **H1-H3 three pure-function modules** (`tunnel_crypto`, `share_link`, `secret_redactor`) built test-first in scratch clones and delivered as PATCHES. The signatures are fixed in `docs/plans/inc5-seams.md`.

**What it is NOT.** Not the whole increment. The origin server, `FakeTunnelProvider`, the tunnel providers (cloudflared, zrok), `link_share`, the connections on the Increment 4 ladder, CLI/app screens, deep links, Docker `inet_net` and the live test all wait for: Wave 0 (orchestrator contracts), Increment 4 accepted, and the user's answers Q1-Q5 in `inc5.md`. Do NOT start them even if you are idle.
**Recorded exception.** CLAUDE.md says "do not start N+1 until N's acceptance tests pass". The user overrode that for groundwork only. Everything below is patch-only, so nothing in the real tree changes until the orchestrator applies it, alone, with the full gate.

**SEQUENCE (user decision 2026-11-06 ~14:30, recorded 2026-11-06 14:38:13): Increment 4 first (`MODULE_I_PROMPT.md`), then this module.** Paste it only after STATUS.md says `INC4_DONE: YES`, unless the user says otherwise.

**When to paste:** after the Lead has finished task L1 of `docs/plans/STATUS.md` ("LEAD INSTRUCTION (current)", the user guide). Paste everything between BEGIN and END.

--- BEGIN ---

You are the Lead for LibreShare **module H** (Increment 5 groundwork). Repo: `/home/kirat/coding/Software Engineering LibreShare` (REPO; the path contains spaces, always quote it). The orchestrator (Claude) gates every result by re-running it alone; your reports are claims, not evidence.

**Read first, in this order:** `docs/plans/STATUS.md` (all of it, especially "LEAD INSTRUCTION" and "PROGRESS SNAPSHOT"), `CLAUDE.md`, `docs/plans/inc5.md` (sections 0-5), `docs/plans/inc5-seams.md` (THE contract for H1-H3), `docs/design/04-link-qr-and-free-internet-paths.md` sections 2.1, 3.1, 3.2, `docs/test-reports/gemini-claims-verification.md` (what went wrong last time: read it, it is the list of things not to repeat).

## Hard rules (a breach means the orchestrator rejects the whole output)
1. **Roles.** You (Lead) write NO code and NO tests. Testers (subagent, effort high) write tests FIRST and show them red. Coders (effort medium) make them green and may not edit, delete, skip or weaken any test; if a test looks wrong they report it. A DIFFERENT agent (verifier, effort high) reviews every diff and runs the mutation table. h1 and h2 get a THIRD agent as second tester. No agent plays two roles on the same module.
2. **Never edit a test to get green.** If you or an agent edited a test after its first red run, say so in the report with the diff; the orchestrator decides.
3. **Capacity.** At most **2 subagents at the same time** until the orchestrator writes `E5_WAVE_DRAINED: YES` in STATUS.md (about 7 of the orchestrator's own agents are queued on the same machine, which has about 4 GB RAM free). No Antigravity features that spawn extra processes beyond that.
4. **Where you may write.** `docs/test-reports/inc5-spikes.md`, `docs/plans/inc5-proposals/**`, scratch clones `.toolchain/scratch/inc5-<id>/**`, one line per milestone in `docs/plans/overnight-log.md`, questions in `docs/plans/questions.md` (append). **Never** the real `packages/`, `apps/`, `tools/`, `.github/`, `pubspec.yaml`, `docs/protocol/**`, schemas, `CLAUDE.md`, `STATUS.md`, `inc*.md`, `docs/plans/inc5-seams.md`. Do not delete anything of anyone. No `git add/commit/push`, no `pub add`/`pub upgrade`, no new dependency.
5. **Heavy runs.** Only single test files, each under `flock -o /tmp/libreshare-heavy.lock <cmd>` with `export TMPDIR="$REPO/.toolchain/tmp"` and `source "$REPO/tools/env.sh"`. No whole-suite runs (the orchestrator does the gates). Waiting for the lock is normal. Use `date '+%F %T'` for every timestamp. Clones: `rsync -a --exclude=.toolchain --exclude=dist --exclude=build --exclude=.dart_tool --exclude=.git "$REPO/" "$REPO/.toolchain/scratch/inc5-<id>/clone/"` then `source "$REPO/tools/env.sh" && cd <clone> && dart pub get --offline`.
6. **Evidence.** Every claim in a report has the command and its REAL exit code and counts (`+N -M`). "Passed" without counts is rejected. Red runs are listed. A mutation table row = guard removed | test that went red | rc. A mutation that survives gets a new test, not an explanation.
7. **Security.** Never log, print or paste keys, tokens, PINs, link fragments or `k=` values into any report or log; the vectors file is the only place test keys live and they are throw-away values. No network except where H0 says so.
8. **Stop rules.** A card that fails twice: write what you tried in `docs/plans/questions.md`, park it, take the next. When H0-H3 are delivered, write `H DONE` in `overnight-log.md` and **stop**; do not continue with anything from the "NOT" list above.

## H0: research spikes (one subagent, light; start immediately, no heavy lock needed except S5-A)
Result file `docs/test-reports/inc5-spikes.md`; each spike: question, method (commands), result, date, verdict, UNVERIFIED items.
- **S5-A AES-GCM speed.** Scratch Dart program under `.toolchain/scratch/inc5-s5a/` using `pointycastle` `GCMBlockCipher(AESEngine())`: seal+open 64 chunks of 4 MiB, JIT and `dart compile exe` (AOT), main isolate and one worker isolate; report MiB/s for each, and the ratio to the 17.9 MiB/s loopback figure in `docs/test-reports/mvp-acceptance-secure.md`. The package `cryptography` is NOT in the offline pub cache and installing it is forbidden: write "cryptography not measured: not available offline" and do not guess its speed.
- **S5-B reachability.** DNS lookup and a plain TCP connect to port 443 (no request body, no download) for `trycloudflare.com`, `api.trycloudflare.com` and `github.com`; also TCP 7844 to `region1.v2.argotunnel.com`. Report ok/blocked per host. Nothing else.
- **S5-C provider terms.** Fetch (read-only, public pages) the current Cloudflare Quick Tunnel page and the zrok pricing/limits page; record URL, fetch date, limits, "testing and development" wording, the large-file wording, and the `--allowed-mail` status. Quote at most one short sentence per fact. Anything you cannot read: UNVERIFIED.
- **S5-D release layout.** From the GitHub release metadata pages of `cloudflare/cloudflared` and `openziti/zrok` (read only; do NOT download any asset), record the asset names per OS/arch and where the SHA-256 is published. No binary is downloaded or run.
- **S5-E redaction paths.** Read-only code reading of `package:logging` and `shelf` access logging as used in `packages/libreshare_core/lib` (file:line): which paths could print a request path containing `/t/<token>`.

## H1-H3: build chain (strictly in this order of priority: H1, then H2, then H3; H2 and H3 may overlap H1's coder stage within the 2-agent cap)
For each module `<id>` in `h1-tunnel-crypto`, `h2-share-link`, `h3-secret-redactor`:
1. **Tester (high)** in `.toolchain/scratch/inc5-<id>/clone`: write the NEW test files listed in `inc5-seams.md` section 4 (plus any more you can justify), against the signatures of that file, touching nothing under `lib/`. Because the module does not exist yet, a first red run is a compile error; to prove the tests are satisfiable and not vacuous, ALSO write a throwaway reference stub in a SECOND scratch copy (never the deliverable) and show the tests pass there, and a naive stub (for example no AAD, or no host checks) and show named tests fail. Record the commands and rcs. For h1 generate the known-answer vectors with an independent implementation (`python3 -I` with the installed `cryptography` package) and record the generator command and rc.
2. **Coder (medium)** in the same clone: create ONLY the lib file named in the seams doc; make the tests green; then run (alone, under the lock): the new test files 3x, `dart analyze --fatal-infos` and `dart format --output=none --set-exit-if-changed` on the changed files. No pubspec edit, no barrel edit, no other lib file.
3. **Verifier (high, different agent)**: read the diff line by line against `inc5-seams.md`, re-run the gates, run the mutation list of seams section 5 in a SECOND scratch copy (restore, `diff -r` rc 0), add tests for survivors (as new files, labelled), write `verifier-report.md`.
4. **Second tester (high, third agent) for h1 and h2**: adversarial spec-gap review of the diff (nonce handling, AAD canonical form, off-by-one in caps, SSRF notations, canonical base64), fuzz or property loops of at least 100,000 iterations where applicable, 3x flake runs, `second-tester-report.md`.
5. **Delivery** in `docs/plans/inc5-proposals/<id>/`: test copies and fixtures, `patch.diff` (new lib file only; `diff -ruN` against the real tree, paths relative to the repo root), `report.md`, `verifier-report.md`, `second-tester-report.md` (h1, h2), `apply-notes.md` (barrel exports the orchestrator must add, nothing else).

## What to tell the user (in chat, at the end)
A table: H0 spikes done / UNVERIFIED items; H1-H3: tests written, red evidence, green evidence, mutation table result, verifier verdict; plus every rule you bent or could not follow. Then `H DONE` and stop.

--- END ---

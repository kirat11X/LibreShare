# Review standard for every Lead card (user order 2026-11-07: "make gemini do those tasks as well, well reviewed")

A card is READY only when its folder holds a review that meets this standard. The review is written by a DIFFERENT agent than the coder and the tester (cheapest capable model is fine, but it must follow the checklist; security-critical cards get a second, independent review file `second-review.md`). The orchestrator's gate re-runs the suites; the deep review at the end of the project re-reads the security-critical diffs, so write for that reader.

## `review.md` must contain (copy the headings)
1. **Scope:** exact files changed/added (matches `apply-notes.md` and `grep -c '^--- ' patch.diff`), and the spec/plan rows the card claims to satisfy (FR/NFR ids, inc plan section).
2. **Diff read:** the reviewer read every hunk. List each hunk group in one line with a verdict (OK / question / defect). Say explicitly which hunks touch security-relevant code (keys, PINs, TLS, pinning, parsing of untrusted input, file paths, network exposure, native/FFI memory).
3. **Tests vs spec:** table requirement -> test name -> what the assertion really proves. Flag assertions that cannot fail (no `expect`, always-true matchers, catch-all `catch`, `skip`, early `return`, time-only checks).
4. **Mutation table:** for each guard/branch that matters: the mutation (what was removed/inverted), the test that went red (name + rc), restore + `diff -r` rc 0. At least 3 mutations per card, at least 1 per security guard. A mutant that survives is either fixed (new test) or listed as an equivalent mutant with the reason.
5. **Adversarial cases tried:** at least 5 inputs/situations the author did not test (empty, huge, malformed, hostile peer, concurrent, replayed, truncated, wrong order, cancel mid-way), what happened, and the new test if one was added.
6. **Resource and failure behaviour:** timers/sockets/isolates/temp files/native memory released on every exit path (success, failure, cancel); no unbounded buffers; no secret (PIN, key, token, URL fragment, file content) in logs, events, exceptions or toString.
7. **Compatibility:** `dart analyze --fatal-infos`, `dart format` rc 0 on touched files; patch applies to the CURRENT tree (`patch -p1 --dry-run` rc 0); existing tests touching the same files run (names + rc); no existing test edited.
8. **Verdict:** ACCEPT / ACCEPT-WITH-NOTES / REJECT, plus a list "what the final deep review must re-check" (this list is copied into `docs/plans/DEEP_REVIEW_QUEUE.md`).
Numbers need command + real exit code (`rc=$?` on the next line) + counts. Unknown = write UNVERIFIED.

## `second-review.md` (security-critical cards only: crypto, TLS/pinning, pairing, PIN/consent, parsing of network input, tunnels/relays/UPnP, BLE, FFI)
A second reviewer starts from the diff only (not from the first review), writes their own threat list (attacker capabilities, assets, entry points), tries to break the code with new tests in a scratch clone, and reports each attempt with its result. Any finding of severity "can leak a secret, bypass a check or corrupt a file" blocks the card until a fix + test exists.

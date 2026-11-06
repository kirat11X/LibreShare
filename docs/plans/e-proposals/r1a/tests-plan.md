# R1a tests-plan (tester, 2026-11-06)

Clone: `.toolchain/scratch/e5-r1a/clone` (verified identical to the real tree for packages/ and apps/ with `diff -rq`, rc 0 at 10:28).
New file: `packages/libreshare_core/test/unit/receiver_resume_offset_test.dart` (9 tests; no existing test or lib file touched).

Command (cwd `clone/packages/libreshare_core`, `TMPDIR` set, `source tools/env.sh`):
`flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/unit/receiver_resume_offset_test.dart`

## Result: HONESTLY GREEN on Linux (rc 0, "+9: All tests passed", 2026-11-06 10:30:20)

Reason: the Dart VM opens `FileMode.append` as read/write positioned at the end, not with `O_APPEND`, so `setPosition` followed by a write lands at the requested offset on Linux (out-of-order chunks, overwrite of a middle chunk, sparse write beyond EOF all work). The Windows claim in windows-readiness.md (setPosition unusable with `FileMode.append`) CANNOT be reproduced or refuted on Linux; I could not verify the Dart Windows runtime behaviour here. No Windows-safe lib change is justified by a failing test, so none is proposed. What these tests still protect (mutation targets for the verifier): removing the `setPosition(range.start + received)` call, replacing it with an append-order write, or switching the partial to a truncating mode (`FileMode.write`) must turn the named tests red; they are also the safety net if the coder/orchestrator DOES change the open mode for Windows (e.g. `FileMode.writeOnly`/`readWrite`), because the change must keep every one of them green. Not run by me: the mutation itself (verifier's job).

## Tests (name prefix = guard)
| Test | Guard / scenario |
|---|---|
| write-at-chunk-offset: chunks 3,1,2,0,4 | `setPosition(range.start+received)` in `putChunk`; byte-identical, same length |
| write-at-chunk-offset: chunk 3 first | after only chunk 3 arrives its bytes sit at 3*cs of the `.lspart`, not at 0 |
| write-at-chunk-offset: descending with short tail | order 4,3,2,1,0, tail chunk of 123 B, 7001 B pieces |
| write-at-chunk-offset: parallel scrambled | 8 in-flight puts, order 6,2,7,0,5,1,4,3, 3000 B pieces |
| already-received-skip | `already` branch: re-sent stored chunk neither appends nor grows the partial |
| resume-writes-at-offset | crash with chunk 8 on disk but unpersisted ([0,7] in sidecar): the resumed chunk 8 is written at 8*cs, strictly inside the 9*cs partial |
| resume-overwrites-stale-bytes | chunk 8 region holds 0xAB garbage; resumed chunk replaces it in place (hash verified at completion) |
| partial-longer-than-declared | partial has a 3*cs+17 junk tail after the crash; final file has exactly the declared size/bytes (works whether the receiver keeps or discards the bitmap) |
| resume-out-of-order | after the crash remaining chunks arrive 10,9,8 |

Helpers are local to the file (copied style of `file_receiver_test.dart`; nothing shared edited).

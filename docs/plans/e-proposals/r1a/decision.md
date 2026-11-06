# R1a decision (orchestrator, 2026-11-06 12:14:55 by `date`)

- **Closed as "no lib change".** The tester's 9 tests (`receiver_resume_offset_test.dart`) are green on Linux (4 runs, rc 0): the Dart VM opens `FileMode.append` without `O_APPEND`, so `setPosition` + write lands at the requested offset. The readiness-report claim could not be reproduced here, and no lib change is justified without a failing test.
- The test file stays as a **regression test** (safety net if the open mode is ever changed for Windows). It will be applied to the real tree together with the R1b patch, because R1b also touches `file_receiver.dart`.
- **Still open, cannot be closed in this container:** whether `FileMode.append` + `setPosition` behaves the same on Windows. It needs a Windows run (user's Windows-route answer pending).
- Before applying: the R1 verifier runs one mutation (write the chunk at the end instead of at its offset) and the test must go red.

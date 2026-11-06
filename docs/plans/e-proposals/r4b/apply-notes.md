# Apply notes R4b
1. From repo root: `patch -p1 < docs/plans/e-proposals/r4b/patch.diff` (one lib file; no protocol/schema/contract change; LSP-1 rule 9 text already states the 5/s budget, optionally add a sentence about 2 failures/source/s).
2. Tester must drop the unused import (line 26) of bye_flood_test.dart, then copy the test into the real tree.
3. Verify: `dart test -j 1 test/security/bye_flood_test.dart test/unit/goodbye_test.dart`, then full suite, analyze, format.

# Card J6 Report: CLI link & receive-link (rebased)

Status: READY (rebased against current real tree with send rc=66 preserved)
Apply check: git apply --check -p1 docs/plans/inc5-proposals/J6/patch.diff -> rc=0

## Scope & Verification
- Adds `ls link` & `ls receive-link` to `packages/libreshare_cli/lib/ls_cli.dart`.
- Preserves existing `send` missing-file behavior (return 66).
- Tests: `packages/libreshare_cli/test/link_test.dart` (7/7 pass x3 rc=0).
- Existing suites: `cli_loopback_test.dart` (pass rc=0), `cli_commands_test.dart` (pass rc=0).
- Formatting: `dart format --output=none --set-exit-if-changed` -> rc=0.
- Analysis: `dart analyze --fatal-infos` -> rc=0.

## Mutation Verification (3/3 killed)
- M1 (missing file exit code 66 -> 0 in `link`): `link_test` fails rc=1. KILLED.
- M2 (invert expiry validation in `receive-link`): `link_test` fails rc=1. KILLED.
- M3 (force allowDeveloperHosts: false): `link_test` fails rc=1. KILLED.
- Review: `review.md` complete per REVIEW_STANDARD.md.

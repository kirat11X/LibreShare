# S3b: nullable chunkConcurrency fix and CLI --concurrency validation
Patch: S3b/patch.diff (2 files, `patch -p1 --dry-run` clean on the current real tree). Clone: .toolchain/scratch/speed-s3/coder-clone-s3b (left untouched by the tester).
- core libreshare_engine.dart: `const int kChunkConcurrencyFromProfile = 0;`; the 5 public send methods take non-null `int chunkConcurrency = kChunkConcurrencyFromProfile`; `_beginSend` resolves the sentinel via speedProfileFor(speedMode). Negative values still reach FileSender (throws). Explicit 0 now means the profile.
- cli ls_cli.dart: `--concurrency` not a number or < 1 -> exit 64, "send: --concurrency must be a whole number, 1 or more". Chosen direction: exit 64, not a silent fallback. No existing test contradicts it.
- Results on final code: d1v_retry_throw_test +1 rc0; S3 app +11 rc0; S3 core unit +15 rc0; S3 core engine +10 rc0 (after the tester's helper fix, now in the real tree); S3 CLI +14 rc0.
- analyze --fatal-infos (apps, core, cli): only the known receive_mode_engine_test info.
- Regression on final code, all rc0: core 13, cli 4, app 8 (the S3 send-path, security and settings files listed in S3 coder-report).
- Status: the S3b changes are ALREADY in the real tree (engine sentinel present; ls_cli.dart identical to the clone). The patch.diff dry-run now fails only because the ladder agent has since edited libreshare_engine.dart (ladder/enableFallback hunks), not because of these hunks.

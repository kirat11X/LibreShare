# S3 speed modes: coder report (green phase)
Clone: .toolchain/scratch/speed-s3/coder-clone. Patch: S3/patch.diff (7 files, `patch -p1 --dry-run` clean on the real tree).
## Files edited
- core: lib/src/engine/libreshare_engine.dart (speedMode option + public field, `int? chunkConcurrency` on 5 send methods, resolved in _beginSend, speed_mode import)
- cli: lib/ls_cli.dart (`send --speed`, no default; exit 64 naming eco, balanced, turbo; `--concurrency` no default, wins; own `send --help` flag)
- app: lib/services/app_settings_store.dart (speedMode field, copyWith, JSON `speedMode`, unknown/missing -> balanced)
- app: lib/providers/settings_provider.dart (setSpeedMode: store first, then state)
- app: lib/providers/engine_provider.dart (engine built with mode; ref.listen updates running engine)
- app: lib/screens/settings_screen.dart ("Transfer speed" section, ListTiles speed_mode_eco|balanced|turbo)
- app: lib/l10n_strings.dart (7 keys, kStringsEn is the only table)
## Test table (S3 tests, unmodified; cmp-verified)
| File | +pass | -fail | rc |
|---|---|---|---|
| core/unit/speed_mode_test.dart | 15 | 0 | 0 |
| core/integration/speed_mode_engine_test.dart | 10 | 0 | 0 |
| cli/speed_mode_cli_test.dart | 12 | 0 | 0 |
| app/speed_mode_settings_test.dart | 11 | 0 | 0 |
## Regression (existing files, all rc 0)
core 13 (outgoing_send, two_engine, secure_two_engine, large_transfer, chunk_retry_integrity, contacts_only_engine, receive_mode_engine, file_sender, startup, engine_tofu, engine_tls_handshake, engine_contacts_only, log_hygiene); cli 4 (cli_commands, q_cli_discovery, cli_loopback, cli_security); app 8 (settings_screen, f3_alias_store, d1v_settings_save, b1_settings_security, d1b_pin_settings, d1b_engine_lifecycle, d1_secure_engine, transfer_screen).
## Analyze / format
core `dart analyze --fatal-infos`: 1 info, pre-existing and untouched (test/integration/receive_mode_engine_test.dart:332 unawaited_futures). cli rc 0; app `flutter analyze --fatal-infos lib` rc 0. `dart format --set-exit-if-changed` rc 0 on all touched files.
## Not done / notes
- Full suites and 3x flake runs not run (orchestrator gate). No dedicated transfers_provider or app_settings_store test file exists.
- Behaviour change: an invalid `--concurrency` value now falls back to the speed profile (was 3). Untested by S3.
- setSpeedMode saves before updating state (needed by the S3 persistence test); a failed save leaves the mode unchanged.

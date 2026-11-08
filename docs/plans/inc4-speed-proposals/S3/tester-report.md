# S3 speed modes: tester report (red phase)
Tester run 2026-11-07, production code untouched.
Test files: `S3/test/` (destinations in its README).
## Files and behaviour
- core/unit/speed_mode_test.dart: CHARACTERIZATION (green today): names, aliases, case, trim, null/empty/unknown, profiles 1/3/8, default balanced.
- core/integration/speed_mode_engine_test.dart: engine option, getter/setter, mode-driven chunk concurrency (eco 1, balanced 2..3, turbo 4..8), explicit chunkConcurrency wins, next-send-only, bytes identical. Observed by an in-process HTTP proxy that counts chunk PUTs in flight and holds each 40 ms (validated against the current engine: peaks 1/3/8 for chunkConcurrency 1/3/8).
- cli/speed_mode_cli_test.dart: `send --speed eco|slow|balanced|turbo|fast|TURBO`, default balanced (2..3, green today), `--concurrency` beats `--speed`, `--speed warp` exit 64 naming eco/balanced/turbo, `send --help` lists `--speed`.
- app/speed_mode_settings_test.dart: store roundtrip and unknown-value fallback, l10n keys, Settings selector, persistence across a fresh screen, engine follows the mode.
## API the coder must implement
- Core: `LibreShareEngine({..., SpeedMode speedMode = kDefaultSpeedMode})`, `SpeedMode get speedMode`, `set speedMode(SpeedMode)`.
- Core: `sendFiles / beginSendFiles / sendTo / beginSendTo / beginSendToCandidates` take `int? chunkConcurrency` (null = `speedProfileFor(speedMode).chunkConcurrency`).
- CLI: `--speed <name>` on `send`, no default in parser (absent = balanced), `--concurrency` no longer defaults to 3 (absent = speed profile); invalid value -> exit 64, stderr names `eco, balanced, turbo`.
- App: `AppSettings.speedMode` (default balanced, JSON key `speedMode`, unknown -> balanced), `copyWith(speedMode:)`, `SettingsNotifier.setSpeedMode(SpeedMode)`.
- App: Settings "Transfer speed" section; `ListTile` options with keys `speed_mode_eco|balanced|turbo` whose `selected` shows the current mode.
- App: l10n keys `settings.speed`, `settings.speedEco`, `settings.speedBalanced`, `settings.speedTurbo`, `settings.speedEcoHelp`, `settings.speedBalancedHelp`, `settings.speedTurboHelp` in `kStringsEn` (the only table).
- App: engine_provider passes `speedMode: settings.speedMode` and updates `engine.speedMode` on change.
## Red / green table (rc from real runs)
| File | rc | State |
|---|---|---|
| core/unit/speed_mode_test.dart | 0 (x3) | green, characterization |
| core/integration/speed_mode_engine_test.dart | 1 | red: compile, no `speedMode` param/getter/setter, `int?` |
| cli/speed_mode_cli_test.dart | 1 | red: 11 of 12 fail (`--speed` exit 64); default-balanced test green |
| app/speed_mode_settings_test.dart | 1 | red: compile, no `AppSettings.speedMode`, no engine `speedMode` |

## Mutation table (verifier)
| Mutation | Expected red |
|---|---|
| eco profile = 3 | engine eco, CLI eco/slow |
| turbo profile = 3 (= balanced) | engine turbo, CLI turbo/fast, next-send test |
| setter ignored / mode read once at construction | engine next-send, app switch test |
| explicit chunkConcurrency overridden by mode | engine explicit-2 test, CLI `--concurrency 2` |
| CLI always passes `--concurrency` 3 | CLI eco, turbo |
| `fast` / `slow` alias removed | unit alias tests, CLI fast |
| unknown `--speed` falls back to balanced | CLI warp test |
| store drops speedMode / engine_provider ignores it | app store roundtrip, app engine checks |
## Notes
Peaks come from a 40 ms-holding proxy; files are 40 MiB = 10 chunks. CLI tests use 127.0.0.1 only.

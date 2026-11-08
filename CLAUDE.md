# LibreShare — Claude Code guide
P2P file sharing: Flutter UI + pure-Dart core. Spec: docs/LIBRESHARE_BUILD_SPEC.md. Protocol: docs/protocol/LSP-1.md.

## Rules
- ONE increment at a time (spec §12). Write docs/plans/inc<N>.md first. Do not start N+1 until N's acceptance tests pass.
- Tests first, then code. NEVER edit acceptance tests to make them pass — ask.
- packages/libreshare_core must not import Flutter; platform code lives in apps/libreshare_app/lib/platform/.
- Protocol change => update LSP-1.md + schemas + conformance tests together.
- TransferStatus = {PENDING, IN_PROGRESS, COMPLETED, FAILED}; causes in FailureReason.
- Never log file contents, keys, PINs or tunnel URL fragments.
- Shared contracts (lib/src/model/*, protocol.dart, interfaces in server/incoming_transfer_handler.dart and client/peer_client.dart, transfer/chunker.dart) are owned by the orchestrator: subagents must not edit them — report needed changes instead.

## Agent roles (user decision 2026-11-05; applies to all remaining work)
- **Orchestrator** (the main session; the user sets its effort to extra-high): plans, owns contracts/docs/seams, spawns agents, verifies every gate by real exit codes. Writes no feature code.
- **Testers** (Agent `effort: "high"`): write the tests FIRST from the spec/plan/seams doc and show them red; later review the coder's work adversarially (mutation checks, 3x flake runs, spec-gap review of the diff). They never edit production code under `lib/`.
- **Coders** (Agent `effort: "medium"`; `"low"` only for mechanical work: docs, scripts, string tables, boilerplate): implement until the testers' tests pass. They must not edit, delete, skip or weaken tests: they report instead.
- **Flow per package:** tester red -> coder green -> tester verify -> orchestrator gate. Security-critical packages (crypto, TLS/auth, trust, pairing, key storage) get at least a medium coder and a second tester review.
- Resumed agents keep the effort they were spawned with: to change a role, spawn a fresh agent.

## TOKEN-SAVING MODE (user decision 2026-11-07; applies until the user ends it)
- Finish the whole project first, deep review by the orchestrator afterwards. Orchestrator reads only compact summaries and does not re-derive agent/Gemini claims; every cheaper acceptance is logged in docs/plans/DEEP_REVIEW_QUEUE.md.
- Testers, gate runners, appliers and doc writers: `model: "haiku"`. Coders: haiku, or sonnet with `effort: "low"` when haiku fails twice. Gemini (the Lead) continues Inc 5..7 cards in order; its READY cards are applied after a full-suite gate (script `.toolchain/scratch/gates/full_gate.sh <name>` under `flock -o /tmp/libreshare-heavy.lock`) without a separate orchestrator re-derivation.
- Hard rules unchanged: never weaken/edit acceptance tests, no secrets in logs, nothing deleted, no commit/push, TLS and integrity checks never weakened.

## Toolchain (project-local, gitignored)
`source tools/env.sh` puts Flutter 3.47.9 / Dart 3.13.7 on PATH and sets PUB_CACHE=.toolchain/pub-cache.
It also sets JAVA_HOME (JDK 17), ANDROID_HOME and GRADLE_USER_HOME when `.toolchain/{jdk-17,android-sdk,gradle}` exist (see docs/dev/android-toolchain.md). Wrap every `flutter build|test` in `flock /tmp/libreshare-flutter-build.lock` when several agents work at once. Prototype builds: `tools/package_prototype.sh [linux|android|windows]` -> `dist/prototype/` (Windows only on a Windows host or via `.github/workflows/prototype.yml`).

## Commands
- `dart pub get` (root) · `cd packages/libreshare_core && dart test` · `dart test test/unit/chunker_test.dart -N "last chunk"`
- `dart analyze --fatal-infos && dart format --set-exit-if-changed .`
- Loopback: `dart run packages/libreshare_cli/bin/ls.dart receive --port 53400 --dir /tmp/rx --auto-accept &` then `... send --to 127.0.0.1:53400 file.bin`
- E2E: `docker compose -f tools/docker/compose.yaml up --build --abort-on-container-exit`
- App: `cd apps/libreshare_app && flutter test` · `xvfb-run -a flutter test integration_test -d linux`

## Map
discovery 1.0 · session 2.0 · security 3.0 · connection 4.0 · transfer 5.0–7.0 · monitor 8.0
storage: D1 device_registry, D2 session_store, D3 credential_store, D4 event_log. UI/CLI use only engine/libreshare_engine.dart.

## Gotchas
- No GUI/Wi-Fi radio here: test via CLI + Docker networks; never test Wi-Fi Direct/hotspot in the container.
- Docker multicast needs a user-defined bridge network.
- Tunnel tests use FakeTunnelProvider unless LS_TUNNEL_LIVE=1.
- Android: hold MulticastLock while discovering; dataSync FGS must handle onTimeout.
- Heavy runs (whole suites, builds, emulator): one at a time via `flock -o /tmp/libreshare-heavy.lock <cmd>` (the `-o`: a background `adb`/daemon otherwise inherits the lock and blocks everything after it); afterwards `adb kill-server` and `gradle --stop`. Never wrap `tools/package_prototype.sh` in `/tmp/libreshare-flutter-build.lock` (it takes it itself). See docs/plans/HANDOFF.md section 3.

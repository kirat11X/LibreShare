# Q-CLI-DISCOVERY fix2 (orchestrator, applied 2026-11-07 19:44:38 by `date`)

Why: the Lead's first delivery was REJECTED (multicast reply hunk broke 3 existing core tests and LSP-1 4.2 rule 10; see overnight-log). Root cause of the failing `cli_commands_test`: on one host the unicast reply to the shared discovery port 53318 lands on the replier's own SO_REUSEPORT socket, so a send-only probe (port 0) never hears it.

## What is applied on the real tree (no wire change, no protocol text change)
- `packages/libreshare_core/lib/src/discovery/multicast_transport.dart`: new `ProbeFromEphemeralPort` interface; `RawMulticastTransport` opens an ephemeral-port socket that also listens (`_probeSocket`), sends probes from it, drains it, closes it in `stop()`.
- `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart`: `_announce` also sends the probe through `sendProbeFromEphemeralPort` when the self info is a probe (port 0).
- New tests: `packages/libreshare_core/test/integration/probe_ephemeral_reply_test.dart` (2 tests), `packages/libreshare_cli/test/q_cli_discovery_test.dart` (1 test, kept as a promptness guard).
- NOT applied: the coder's `ls_cli.dart` `_awaitMatches` immediate-check hunk. Mutant M2 (hunk removed) survived because the hunk is equivalent code: `LibreShareEngine.devices` already emits the current list on listen (documented at `libreshare_engine.dart:631`), so the settle timer already starts for a known device. Removed (snapshot `.toolchain/snap/qcli-m2-port-20261107-193425`); `ls_cli.dart` is byte-identical to HEAD. `patch.diff` in this folder still contains that hunk: do not re-apply it.
- Lint fix: the formatter-wrapped `if (fd < 0) throw ...` in the two `test/helpers/port_blocker.dart` copies got braces (behaviour unchanged).

## Evidence (orchestrator, run alone under `flock -o /tmp/libreshare-heavy.lock`)
- new core probe test 3x +2 green; new CLI test 3x +1 green; target `cli_commands_test` 3x +29 green (summary: .toolchain/scratch/qcli-apply/summary.txt).
- Mutants: M1 (no ephemeral probe) killed (rc 1, +1 -1); M3 (drain ignores the probe socket) DETECTED ONLY AS A HANG: the handler spins at 100 % CPU, the test never finishes, the orchestrator killed it after 4 min (rc 137). Weak kill; recorded as such. M2: equivalent mutant, hunk removed (above).
- Gate 1 (with the M2 hunk): analyze rc 1 (3 infos), format rc 0, core +2917 ~2 rc 0, CLI +78 rc 0, app +548 rc 0.
- Gate 2 (after removing the hunk and bracing port_blocker): analyze rc 1 with 1 info (`receive_mode_engine_test.dart:332` missing await = one of the six weakened tests, the user's call), format rc 0, CLI target +30 rc 0, CLI +78 rc 0, core targets +7 rc 0, app +548 rc 0, core FIRST run rc 1 (+2913 ~2 -4: receive_mode_engine bind-error, secure_two_engine plaintext, connection_cap per-ip-slot-release, connection_cap round3 R5/R7; not reproducible), then those 4 files 3x +51 rc 0 and the full core again +2917 ~2 rc 0 (.toolchain/scratch/qcli-apply/summary2.txt, summary3.txt). Treated as a one-off contention flake (other agents were running test processes); if it recurs it is a bug, not noise.

# Inc 4 acceptance tests (tester deliverable)

Written FIRST against the CURRENT real tree (clone `.toolchain/scratch/inc4-acc/clone`, re-synced 2026-11-07 19:24). No file under `lib/` was touched. See `report.md` for first-run results.

Destination paths (copy as they are; all paths relative to `packages/libreshare_core/`):

| File here | Destination |
|---|---|
| `helpers/inc4_http_recorder.dart` | `test/helpers/inc4_http_recorder.dart` |
| `helpers/inc4_rig.dart` | `test/helpers/inc4_rig.dart` |
| `helpers/inc4_receiver_main.dart` | `test/helpers/inc4_receiver_main.dart` |
| `integration/ladder_fault_test.dart` | `test/integration/ladder_fault_test.dart` |
| `integration/receiver_restart_test.dart` | `test/integration/receiver_restart_test.dart` |
| `integration/random_faults_test.dart` (tag `slow`) | `test/integration/random_faults_test.dart` |
| `integration/chunk_retry_integrity_test.dart` | `test/integration/chunk_retry_integrity_test.dart` |
| `security/ladder_pin_test.dart` | `test/security/ladder_pin_test.dart` |
| `unit/inc4_negatives_test.dart` | `test/unit/inc4_negatives_test.dart` |

Run one file at a time, from `packages/libreshare_core`, e.g.
`flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/integration/ladder_fault_test.dart`.
`receiver_restart_test.dart` starts child processes with `dart test/helpers/inc4_receiver_main.dart` (needs `dart` on PATH, as the other tests do) and must run with the package directory as cwd.
`random_faults_test.dart` takes about 5 minutes (20 seeds, tag `slow`); a failing seed replays with `dart test --tags slow test/integration/random_faults_test.dart -N "seed 7"`.

Helpers: `inc4_http_recorder.dart` is a TCP proxy that parses just enough HTTP/1.1 to log every request that reaches the receiver (method, path, body bytes forwarded, status) - the "receiver log" for the PUT-per-chunk counts. It sits behind / next to `test/helpers/faulty_tcp_proxy.dart` (unchanged).

Not covered (needs a TLS-aware recorder or an app/Docker run): secure-profile receiver restart with the same identity directory (inc4.md D3), the PIN guard state across a restart (`security/restart_guard_test.dart`), Docker steps m/n/o of `tools/docker/e2e.sh`.

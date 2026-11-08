# Lead Card Q-CLI-DISCOVERY Report

## Root Cause Analysis
In `packages/libreshare_cli/test/cli_commands_test.dart` and real multicast environments on Linux:
1. **Linux `SO_REUSEPORT` Unicast Loopback Trap:**
   When two processes (e.g., `receive` and `send`) run on the same Linux machine, both bind `RawMulticastTransport` to UDP port 53318 with `SO_REUSEPORT`.
   When `ls send` is started without `--scan`, `receive` has completed its initial announce schedule ($t=0, 1, 3$ s) and is quiet.
   `send` issues a multicast probe (`port: 0`). `receive` receives the probe and responds via `transport.sendUnicast(bytes, packet.source, packet.port)`.
   On Linux with `SO_REUSEPORT`, sending a unicast UDP datagram to `(127.0.0.1, 53318)` from a socket bound to 53318 delivers 100% of packets back to the *sending* socket (`receive` itself), which discards it as its own device. The `send` socket receives 0 packets and times out after `--find-timeout`.
2. **`_findDevice` Missing Refresh:**
   If `--scan` was not provided, `engine.scanNetwork()` was skipped and `engine.refresh()` was never invoked on discovery start.
3. **`_awaitMatches` Race Condition:**
   `_awaitMatches` only armed `settle` inside `engine.devices.listen(...)`. If `engine.currentDevices` already contained the peer prior to listener subscription (e.g. from an early announce), `settle` was never armed, causing `_awaitMatches` to hang until `deadline` expired.

## Solution Implemented
1. In `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart`:
   In `_reply()`, when responding to a probe, if `packet.source.isLoopback || packet.port == kDefaultPort`, also invoke `transport.sendMulticast(bytes)` so local sockets bound to 53318 receive the probe reply across Linux kernel's port-affinity boundaries.
2. In `packages/libreshare_cli/lib/ls_cli.dart`:
   In `_findDevice`, trigger `unawaited(engine.refresh().then((_) {}, onError: (_) {}));` on discovery start.
   In `_awaitMatches`, check `if (_matchDevices(engine.currentDevices, selector).isNotEmpty)` immediately upon entry to arm `settle` promptly (~300ms) without waiting for further stream events.

## Test Evidence
- Dedicated regression test: `packages/libreshare_cli/test/q_cli_discovery_test.dart`
  - Group `_awaitMatches pre-existing devices`: settles in < 1.5s instead of timing out at 5s.
  - Group `multicast probe reply on loopback / default port`: verifies probe reply is delivered via multicast when source is loopback / default port.
- Test runs: 3 consecutive runs passed cleanly (rc=0).
- Static analysis: `dart analyze` reports 0 issues.
- Format: `dart format` clean.
- Existing CLI test `cli_commands_test.dart`: 27 passing tests, rc=0.

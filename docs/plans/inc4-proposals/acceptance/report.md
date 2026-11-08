# Inc 4 acceptance tests: tester report (verbatim from the tester's hand-back, saved by the orchestrator 2026-11-07 ~20:08)

Written against the unchanged tree in clone `.toolchain/scratch/inc4-acc/clone`. 53 test cases: 36 green, 17 red. A tester's numbers are claims until the orchestrator re-runs them (see STATUS.md).

| File | Maps to | Green / red | First-run rc | Repeat-run rc |
|---|---|---|---|---|
| ladder_fault_test | FR-12, FR-13 | 6 / 6 | 1 | 1 (5 repeats, identical) |
| receiver_restart_test | FR-15 | 6 / 1 | 1 | 1 (2 repeats) |
| random_faults_test (tag slow) | NFR-03 | 20 / 0 | 0 | 0 (2 repeats) |
| ladder_pin_test | D6 | 1 / 1 | 1 | 1 (2 repeats) |
| chunk_retry_integrity_test | data integrity after a cut | 0 / 2 | 1 | 1 (2 repeats) |
| inc4_negatives_test | section 4.1 negatives | 3 / 7 | 1 | 1 (3 repeats) |

Green: FR-12 ordering (3), FR-13 precondition and two flap tests, FR-15 (6: real SIGKILL receiver, 24 h stale sidecar discarded, changed manifest restarts), all 20 NFR-03 seeds, D6 pin-not-in-events, negatives truncated-longer-than-declared / duplicate-put-idempotent / resume-diskfull-keeps-state.

Defects the red tests expose (tester's reading):
1. FR-13 not implemented (5 red): a tier-1 cut gives FAILED/NO_CONNECTION, no ChannelTierSwitched, tier 2 never contacted. `_findEndpointWithLadder` (libreshare_engine.dart ~1240, `find:` ~869) only picks an endpoint before the send; no mid-transfer fallback.
2. Data loss from a poisoned running hash (5 red): `file_receiver.dart` putChunk ~700-760 feeds `runningHasher` (~733) and does not reset it when a chunk is truncated (~744) or its stream errors; the retry of that chunk then ends VERIFY_FAILED and the partial file is deleted. Fix: reset canUseRunningHash and the hasher on every non-complete exit.
3. Acked chunks re-sent when the ack is lost (1 red, flap-no-acked-chunk-resent): `file_sender.dart` retry ~660-690 re-PUTs without checking /state. Receiver is idempotent so data stays correct.
4. Bad /state ranges are not rejected (5 red variants of state-ranges-rejected): `_receivedSet` (~696) clamps or skips them; out-of-range, negative and overlapping ranges still send complete; inverted and wrong-shape ranges end COMPLETED. Expected FAILED(PROTOCOL_ERROR).
5. D6 gap (1 red, fallback-other-identity-refused): when tier 2 answers with another key the result is plain NO_CONNECTION without PeerKeyChanged; the pin check in `_plan` (~944-980) is not applied to ladder candidates. The PIN is not sent to the wrong peer.
6. FR-15 strict wording (1 red, no-put-for-acked-chunk): after SIGKILL chunks 8 and 9 were acked but PUT again because the sidecar is persisted every 8 chunks (kResumePersistEvery). Spec decision: say "persisted" or persist per ack. The test was not weakened.

Changes after the first run: the flap assertion `resentAfterAck` was split unchanged into its own test; harness fix (recording proxy leaked a "Broken pipe" error; error handlers on Socket.done/close() added in inc4_http_recorder.dart, no assertion touched); extra negative `aborted-chunk-keeps-file-hash-valid` (red, defect 2).

Not covered: secure-profile receiver restart with the same identity dir (D3), PIN guard across a restart, Docker steps m/n/o.

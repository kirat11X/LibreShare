# Fix wave F-A (coder report)

Files edited (clone only, patch in `patch.diff`): `packages/libreshare_core/lib/src/transfer/file_receiver.dart`, `packages/libreshare_core/lib/src/transfer/file_sender.dart`. `resume_store.dart` is unchanged (item 4 reverted).

## Per item
1. Running-hash poisoning: putChunk has `var chunkOk`, set true after the success path; a `finally` drops `canUseRunningHash`, the running hasher and capture when `!chunkOk && inOrderForRunning`. Error codes/messages unchanged. GREEN.
2. Bad /state ranges: `_receivedSet` throws `_SendFailure(protocolError, notifyPeer)` for wrong shape, negative, out of range (>= chunkCount), inverted, or overlapping ranges. GREEN.
3. Lost-ack re-PUT: `_uploadChunk` calls `fileState` before any re-attempt (inside the existing `_retry`, same bounded budget/backoff) and skips the PUT if the chunk is already acked. GREEN (flap-no-acked-chunk-resent).
4. Persist per ack: NOT APPLIED (conflict, see below). `kResumePersistEvery` is only mentioned in a comment in receiver_restart_test.dart, no assertion on 8.

## Test table (run from packages/libreshare_core, one file at a time, `dart test -j 1`)
| file | rc | result |
|---|---|---|
| test/integration/chunk_retry_integrity_test.dart | 0 | +2 |
| test/unit/inc4_negatives_test.dart | 0 | +10 (state-ranges x5, aborted-chunk GREEN) |
| test/integration/receiver_restart_test.dart | 1 | +6 -1 (no-put-for-acked-chunk RED, item 4) |
| test/integration/ladder_fault_test.dart | 1 | +7 -5 (flap-no-acked GREEN; 5 FR-13 RED, out of scope) |
| existing: file_receiver, file_sender, file_sender_sas, resume_store, receiver_session_wait, send_result_refusal, k1_storage_unusable, atomic_file_adoption, outgoing_send, two_engine | 0 each | all pass (+60 +47 +34 +28 +13 +16 +5 +12 +17 +19) |

`dart analyze lib/src/transfer/`: clean.

## Not done / conflict
- Item 4 conflicts with acceptance test `unit/inc4_negatives_test.dart` 'resume-diskfull-keeps-state' (line ~400): it asserts the sidecar holds `[[0,7]]` after 9 acks, i.e. the 8-chunk batch. Per-ack persistence yields `[[0,8]]` and that test goes RED (I saw it: Expected [[0,7]], Actual [[0,8]]). Item 4 was therefore reverted. Options for the orchestrator: a separate per-ack journal next to the sidecar (keeps the sidecar at batch-8 semantics), or a test change by its author. Not my call.
- Per-ack persistence also needs the sidecar write without the `atomicWriteBytes` fsync (it flushes); the attempt used temp+rename without fsync, which survives SIGKILL but not power loss. Note for the design choice.
- FR-13 ladder items and ladder_pin_test were not attempted (other wave). random_faults_test not run.

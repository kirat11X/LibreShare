# F-A2 (coder report): per-ack journal for item 4. STOPPED: conflicts with two acceptance tests

Patch: docs/plans/inc4-proposals/F-A2/patch.diff (2 entries: file_receiver.dart, resume_store.dart; built against the current real tree). NOT for gating as is.

Implementation: `<partial>.json.acks` append-only journal (one index per line, no fsync). Appended in markReceived after each ack. On open, loaded only when the sidecar validates (union with the bitmap, indices clamped to chunkCount, torn trailing record cut). Deleted with the sidecar (discard, cancel, invalid sidecar, sweep, no-sidecar open). Sidecar cadence unchanged.

Results (single files, flock -o, dart test -j 1):
- chunk_retry_integrity_test.dart: rc=0, +2 (GREEN)
- inc4_negatives_test.dart: rc=1, +9 -1, 'resume-diskfull-keeps-state' RED.
- receiver_restart_test.dart: rc=1, +6 -1. 'no-put-for-acked-chunk' GREEN. 'sends-only-the-missing' RED.

Why stopped: both red tests assert the resumed set equals the sidecar bitmap only.
- resume-diskfull-keeps-state (negatives ~line 409): after the restart, receivedRanges expected [[0,7]]; journal gives [[0,8]].
- sends-only-the-missing (receiver_restart ~line 167-180): expected PUT set {9..19} (sidecar-persisted view); actual {12..19}, since the journal also covers acks 9-11 that the sidecar had not persisted.
Both assertions encode the sidecar-only resume view. Keeping them green and no-put-for-acked-chunk green together needs an orchestrator/test-author decision.

Not run after the journal change: ladder, existing resume/receiver tests (they would be re-run once the decision is made).
Note: clone file_sender.dart was stale in formatting; replaced with the real tree copy (no semantic change, not in patch).

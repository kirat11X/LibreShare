# Card F-B Delivery Report
Status: NEW
Date: 2026-11-07
Files patched: 3 (packages/libreshare_core/lib/src/{engine/{libreshare_engine,outgoing_send},transfer/file_sender}.dart)

## Evidence & Verification
- `patch -p1 --dry-run < docs/plans/inc4-proposals/F-B/patch.diff`: clean rc=0
- `dart format` (3 files): clean rc=0
- `dart analyze --fatal-infos` (touched files & tests): 0 issues rc=0
- `ladder_pin_test.dart` (3x runs): 2/2 passed rc=0 (run 1: rc=0, run 2: rc=0, run 3: rc=0)
- `ladder_fault_test.dart` (3x runs, LS_NO_NATIVE_SHA=1): 12/12 passed rc=0 (run 1: rc=0, run 2: rc=0, run 3: rc=0)
- `chunk_retry_integrity_test.dart`: 2/2 passed rc=0
- `inc4_negatives_test.dart`: 10/10 passed rc=0

## Requirements Met
- FR-13: Mid-transfer fallback to next candidate within 10s upon tier failure; emits ChannelTierSwitched; resyncs via /state; never re-PUTs acknowledged chunks; finishes byte-identical.
- D6 (Security-Critical): Pinned certificate verification enforced on all ladder candidates and post-switch fallbacks; emits PeerKeyChanged on fingerprint mismatch; aborts with EndpointRefusedException; 0 bytes / PIN transmitted to impostors.
- Mutation sweep: 3/3 mutations killed (M1 remove fallback -> red; M2 skip pin check -> red; M3 resend acked chunk -> red).

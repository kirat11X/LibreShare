# Inc 3 / P4 tests (tester, 2026-11-05): FileReceiver secure behaviour, SAS, consent, pairing

Tests only; nothing under `lib/` touched. Helpers: `test/helpers/p4_support.dart` (rig, identities, fakes, log scanner), `test/helpers/p4_fake_time.dart` (zone with virtual timers + ManualClock: the real 120 s / 30 s / 125 s constants are tested without sleeping; the receiver and service MUST be created inside the test body and use plain `Timer`/`Future.timeout`/`clock.now()`).

## Files and groups
| File | Groups |
|---|---|
| `unit/receiver_secure_session_test.dart` (46) | sender match (step 8: no proof, empty/foreign fp, deviceId vs CN, null CN, unauthenticated `createSession` on a secure receiver); plaintext profile unchanged; trust (blocked); check order pairs (400>401>BLOCKED/KEY_CHANGED>PIN>507>429>409, PIN verifier not consulted when an earlier check fails); PIN integration (args, exempt, propagation, consume once, no consume on later refusal); storage; pending caps 3/8 and slot release |
| `unit/permission_test.dart` (43) | auto-accept matrix trust x commit x policy; proof required; operator flag vs commit; blocked; reject; 120 s timeout, accept after timeout 409, accept-vs-timeout race (exactly one wins); pinning on accept; no auto-block after repeated rejects; `incomingInfo` |
| `security/sas_binding_receiver_test.dart` (32) | 202 with `sas.nonce` (16 B, stable, fresh); Accept refused until reveal; reveal ok -> `SasReady(outgoing:false)` with the right code; commit mismatch / MITM / replayed commit -> 401 + FAILED(PROTOCOL_ERROR); reveal preconditions (400/401/404/409/410); 30 s and 120 s deadlines; commit => no auto-accept |
| `security/key_change_test.dart` (15) | KEY_CHANGED 403 + `PeerKeyChanged`, never auto-accepted (trusted, flag, commit, PIN), pin never replaced, explicit removal then SAS restores flow |
| `security/log_hygiene_receiver_test.dart` (12) | Level.ALL capture through session/SAS/mismatch/wrong PIN/throwing verifier/key change/10k files; sentinels, 64-hex, base64url >= 40, full session id, envelopes; id prefix of 8 chars (secure and plaintext) |
| `unit/receiver_secure_dir_test.dart` (14) | defect 6 (unwritable/missing download dir refused up front); defect 7 (`sessionTtl` expiry, name release, eviction on secure create, caps) |
| `unit/block_suggestion_test.dart` (22) | `BlockSuggested` after 3 user rejects of one fingerprint in 10 min: threshold, reset (6th), no aggregation across fingerprints, window boundary +-1 ms (exactly 10:00.000 deliberately untested), accept/cancel/timeout/SAS failures do not count, contacts count, plaintext none, blocked none, never blocks by itself, no full fingerprint in logs |
| `unit/pairing_test.dart` (about 45) | vectors (request MAC, ack MAC, K_pair, domain separation); invite; happy path; wrong MAC (does not consume); request must match the proof; shape/426; decline; scanner ack verification; expiry (10 min); 125 s hold; one held request (409); trust conflicts; `FileReceiver.pair` delegation; log hygiene |

## New symbols (minimal expected signatures)
`lib/src/security/pairing_service.dart` (test imports it by path; barrel export is the orchestrator's):
```dart
Uint8List pairRequestMac({required List<int> secret, required String scannerFingerprint, required String inviterFingerprint, required List<int> scannerNonce});
Uint8List pairAckMac({required List<int> secret, required String inviterFingerprint, required String scannerFingerprint, required List<int> inviterNonce, required List<int> scannerNonce});
Uint8List derivePairKey({required List<int> secret, required List<int> inviterNonce, required List<int> scannerNonce, required String fingerprintA, required String fingerprintB});
final class PairInvite { Uint8List get secret; String get secretB64; DateTime get expiresAt; }
final class PairPrompt { DeviceInfo get sender; String get fingerprint; }   // fingerprint = proven one
class PairScan { PairRequest get request; Future<bool> complete(PairResponse r); } // false on accepted:false; LsException(authInvalid) on bad ack
class PairingService {
  PairingService({required IdentityProvider identity, required TrustStore trust, required SecretStore secrets,
    required DeviceInfo Function() self, Clock clock = const SystemClock(), Duration inviteTtl = const Duration(minutes: 10),
    Duration holdTimeout = kPairTimeout, Uint8List Function(int length)? randomBytes, void Function(LsEvent)? onEvent});
  PairInvite createInvite();  bool get hasActiveInvite;  PairPrompt? get pendingPrompt;
  Future<PairResponse> handlePair(PairRequest request, {required AuthenticatedPeer peer});
  void decide({required bool accept});
  PairScan startScan({required String inviteSecretB64, required DeviceInfo inviter});
}
```
`FileReceiver({..., PairingService? pairing})`; `pair()` delegates, 404 without service or invite. Secure `FileReceiver.createSession` (no proof) -> 401. No consent API is pinned: `consent_policy.dart` is free-form (tests drive it through the receiver).

## Red state (before implementation, 3 runs identical)
| File | tests | failing | reason |
|---|---|---|---|
| receiver_secure_session_test | 46 | 33 | wrong status (stub = plaintext path), PIN verifier never called |
| permission_test | 43 | 17 | no sas in 202, `SAS is not supported` stub, incomingInfo null, auto-accept/blocked not enforced |
| sas_binding_receiver_test | 32 | 30 | stub `revealSas` -> NOT_FOUND, no `sas` member |
| key_change_test | 15 | 12 | no KEY_CHANGED / PeerKeyChanged |
| log_hygiene_receiver_test | 12 | 9 | full session id logged, no SAS challenge, PIN verifier unused |
| receiver_secure_dir_test | 14 | 7 | raw `FileSystemException`, no 507 |
| block_suggestion_test | 22 | 19 | no `BlockSuggested` emitted (stub); 3 harness twins pass |
| pairing_test | - | all | compile error: `pairing_service.dart` / `PairingService` missing |
Pre-existing tests: no old file fails (verified with the full `dart test`; the only failures are new red files of this and other packages).
Validation: a throwaway reference implementation (scratch copy outside the repo) made all 207 tests green; the mutations below each turned tests red there.

## SPEC-GAPs (safer reading chosen, marked `// SPEC-GAP:` in the files)
1. `--auto-accept` operator flag vs `sasCommit`: commit always forces PENDING (LSP-1 says "whatever the trust level"). Without a commit the flag still auto-accepts.
2. `Accept` before the code exists -> 409 WRONG_STATE (code not specified).
3. Unauthenticated `createSession` on a secure receiver -> 401; proof with null CN -> 401.
4. Foreign proof / missing proof on `/sas` -> 401 but the session survives (only a commit mismatch is fatal).
5. Pin on Accept only when a SAS flow happened; plain unknown sender is not pinned.
6. PIN `consume()` when the session is created (not at Accept), only if a PIN was needed and not exempt.
7. Defect 6: no rule in LSP-1; asserted `INSUFFICIENT_STORAGE` (507, non-retryable; `INTERNAL` would be retried), at the storage step, both profiles. Unwritable-after-prompt (at Accept) not tested; proposal: re-check in `accept`, FAILED(DISK_FULL).
8. Defect 7: LSP-1 4.4 defers the chunk idle timeout to Inc 4 [I4]. Only `sessionTtl` is tested (lazy eviction on next call, name released, secure create evicts). Not tested, proposal: an idle timer (60 s without a chunk, `FailureReason.timeout`, `SessionFinished`) so nobody has to poll; shorter default than 24 h; partial kept for resume.
9. (closed) BlockSuggested rule fixed by the orchestrator: 3 rejects / 10 min, counter reset, never blocks; see block_suggestion_test.
10. Pairing: blocked fingerprint -> 403 BLOCKED, known deviceId with another key -> 403 KEY_CHANGED (pin untouched); late `decide` after timeout is ignored; the scanner refuses a responder whose fingerprint differs from the QR's.
11. Observation (not tested): an expired session's unawaited sidecar flush can race a new session on the same name (`Cannot rename file ... lspart.json` -> INTERNAL "cannot prepare download" when resuming right after expiry under a jumped clock).

## Mutation checks for the verifier (each must turn the named tests red; restore by `diff`)
1. `accept()` ignores SAS readiness -> sas_binding "accept before the reveal", "never reveals"; permission "a SAS code of one session...".
2. auto-accept although `sasCommit` is set -> "commit_present_means_no_auto_accept", matrix `trusted commit=true`, "operator autoAccept flag does not bypass".
3. skip the sender-vs-proof match -> "AUTH_INVALID beats ...", "valid proof of ANOTHER key", key_change "clone".
4. no KEY_CHANGED refusal (or replace the pin) -> key_change group, "never replaced".
5. log the PIN / full session id / commit -> log_hygiene tests.
6. skip commit verification -> mismatch/MITM/replayed-commit tests. Use the sender's fingerprint instead of the receiver's own in the commit check -> most reveal tests.
7. SAS reveal timer 30 s changed / consent timer 120 s changed -> deadline and timeout tests.
8. PIN before trust; storage before PIN; caps `>` instead of `>=`; consume always; exempt always -> check-order / PIN integration tests.
9. pin on Accept without SAS -> "WITHOUT a SAS flow does not pin".
10. remove the download-dir check -> receiver_secure_dir_test defect 6.
11. block suggestion: threshold 2, window ignored, counter not reset, counts timeouts/cancels, blocks automatically (all caught; `>=` vs `>` at exactly 10:00.000 is unspecified and not caught).
12. pairing: skip MAC check, wrong MAC consumes the invite, skip ack check, no spend on decline, no hold timeout, ignore expiry, swap nonce order in HKDF salt, persist S, pin as known instead of trusted.

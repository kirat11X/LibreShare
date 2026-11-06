# Increment 3 Mutation Sweep Report (Card G3)

Date: 2026-11-06 ~10:45 IST  
Role: Inc 3 Mutation Sweep Engineer (Card G3)  
Environment: Scratch clone at `.toolchain/scratch/g3-clone/` (pristine snapshot at `.toolchain/scratch/g3-pristine/`)  
Execution Lock: `/tmp/libreshare-heavy.lock` (`flock -o` serialized execution)  
Scope: Mutations M1 through M10 defined in `docs/plans/inc3.md` section 9.

---

## 1. Executive Summary

All 10 security mutations were individually applied to the scratch clone, evaluated against their target test suite under the heavy lock, verified to turn specific named tests RED (exit code 1), and then cleanly reverted with `diff -r -x '.dart_tool'` returning rc=0 against the pristine snapshot.

**Score: 10/10 mutations killed. 0 survivors.**

---

## 2. Mutation Sweep Results Table

| ID | Target File & Line | Mutation Description | Test Suite File | First Named Failing Test | Test Result |
|---|---|---|---|---|---|
| **M1** | `packages/libreshare_core/lib/src/client/api_client.dart:110` | Skip pin comparison in `badCertificateCallback` / `_checkCertificate` (accept any cert) | `test/security/pinning_test.dart` | `pinned peer with another certificate is refused before any HTTP byte pinned_peer_with_other_certificate_refused_before_any_http_byte` | **KILLED** (rc=1, 25 failed) |
| **M2** | `packages/libreshare_core/lib/src/security/identity_proof.dart:180` | Drop `serverFp` from signed text in `IdentityProof.buildAuthMessage` | `test/unit/identity_proof_test.dart` | `valid proof the signature covers exactly the documented text` | **KILLED** (rc=1, 8 failed) |
| **M3** | `packages/libreshare_core/lib/src/security/sas.dart:114` | Let SAS ignore nonces in `sasCode` computation | `test/unit/sas_test.dart` | `sasCode known_answer_vectors` | **KILLED** (rc=1, 5 failed) |
| **M4** | `packages/libreshare_core/lib/src/security/pin_guard.dart:116` | Count PIN strikes on success in `PinGuard.check` | `test/security/pin_test.dart` | `per-IP throttle: 5 failures in 10 minutes (5.2) a success is never a strike: 4 failures, 20 successes, then 1 failure still does not block` | **KILLED** (rc=1, 3 failed) |
| **M5** | `packages/libreshare_core/lib/src/security/pin_guard.dart:94` | Log the PIN in `PinGuard.check` via `Logger` | `test/security/pin_test.dart` | `the PIN never appears in logs, exceptions or toString (5.2) nothing is logged or thrown with the PIN in it, through every code path` | **KILLED** (rc=1, 1 failed) |
| **M6** | `packages/libreshare_core/lib/src/transfer/file_receiver.dart:438` | Let `accept()` ignore SAS readiness in `FileReceiver` (bypass `sasCommit != null && sasCode == null`) | `test/security/sas_binding_receiver_test.dart` | `Accept needs the code (receiver_cannot_accept_before_reveal) accept before the reveal is refused (409) and the session stays PENDING` | **KILLED** (rc=1, 3 failed) |
| **M7** | `packages/libreshare_core/lib/src/server/api_server.dart:365` | Answer 403 instead of 404 to Contacts-only strangers in `ApiServer` | `test/security/contacts_only_server_test.dart` | `stranger (5.4: no X-LS-Auth, or a certificate that is not a contact) GET /info, /register and /sessions: 404 identical to an unknown route, handler untouched` | **KILLED** (rc=1, 9 failed) |
| **M8** | `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart:478` | Skip `bye` signature check in `MulticastDiscovery._handleBye` | `test/unit/goodbye_test.dart` | `receiving a bye forged_signature_ignored` | **KILLED** (rc=1, 2 failed) |
| **M9** | `packages/libreshare_core/lib/src/transfer/file_receiver.dart:352` | Auto-accept session when a commit is present (`auto = commit != null || ...`) | `test/security/sas_binding_receiver_test.dart` | `202 with the receiver nonce PENDING with sas.nonce of 16 bytes and no tokens` | **KILLED** (rc=1, 26 failed) |
| **M10** | `packages/libreshare_core/lib/src/storage/credential_store.dart:163` | Regenerate identity silently when key is missing in `CredentialStore.loadOrCreate` | `test/unit/credential_store_test.dart` | `IdentityLost: never a silent regeneration key deleted -> keyMissing` | **KILLED** (rc=1, 2 failed) |

---

## 3. Detailed Mutation Log

### Mutation M1: Skip pin comparison in ApiClient badCertificateCallback
- **Target File**: `packages/libreshare_core/lib/src/client/api_client.dart`
- **Line**: 110 (`_checkCertificate`)
- **Diff Applied**:
  ```diff
  @@ -110,2 +110,3 @@
     bool _checkCertificate(X509Certificate cert) {
  +    return true; // M1: accept any cert without verifying against expected pin
       final presented = fingerprintHex(cert.der);
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/pinning_test.dart`
- **Result**: rc=1 (25 failed).
- **Failing Test**: `pinned peer with another certificate is refused before any HTTP byte pinned_peer_with_other_certificate_refused_before_any_http_byte`
- **Error**: `Expected: <Instance of 'PeerFingerprintMismatchException'>, Actual: InsecurePeerException:<InsecurePeerException: peer does not offer the secure profile>`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M2: Drop serverFp from signed text in IdentityProof
- **Target File**: `packages/libreshare_core/lib/src/security/identity_proof.dart`
- **Line**: 180 (`buildAuthMessage`)
- **Diff Applied**:
  ```diff
  @@ -179,3 +179,2 @@
         nonceB64,
  -      _normalizeFp(serverFingerprint),
         _normalizeFp(clientFingerprint),
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/unit/identity_proof_test.dart`
- **Result**: rc=1 (8 failed).
- **Failing Test**: `valid proof the signature covers exactly the documented text` (also `tampered_serverFingerprint (channel binding)`, `proof_for_server_A_rejected_by_server_B (a relaying MITM cannot replay it)`)
- **Error**: `Expected: true, Actual: <false>`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M3: Let SAS ignore nonces in sasCode
- **Target File**: `packages/libreshare_core/lib/src/security/sas.dart`
- **Line**: 114 (`sasCode`)
- **Diff Applied**:
  ```diff
  @@ -114,4 +114,2 @@
       domainSeparate(SigDomain.sasValue, [
  -      ...ns,
  -      ...nr,
         ...ascii.encode(lo),
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/unit/sas_test.dart`
- **Result**: rc=1 (5 failed).
- **Failing Test**: `sasCode known_answer_vectors`
- **Error**: `Expected: '060044', Actual: '700798'`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M4: Count PIN strikes on success in PinGuard
- **Target File**: `packages/libreshare_core/lib/src/security/pin_guard.dart`
- **Line**: 116 (`PinGuard.check`)
- **Diff Applied**:
  ```diff
  @@ -115,2 +115,5 @@
       final matches = constantTimeEquals(utf8.encode(pin), utf8.encode(_pin!));
  -    if (matches && !expired && !_consumed) return;
  +    if (matches && !expired && !_consumed) {
  +      _recordStrike(remoteAddress, now);
  +      return;
  +    }
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/pin_test.dart`
- **Result**: rc=1 (3 failed).
- **Failing Test**: `per-IP throttle: 5 failures in 10 minutes (5.2) a success is never a strike: 4 failures, 20 successes, then 1 failure still does not block`
- **Error**: `Expected: null, Actual: LsErrorCode:<LsErrorCode.blocked>`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M5: Log the PIN in PinGuard / ApiServer
- **Target File**: `packages/libreshare_core/lib/src/security/pin_guard.dart`
- **Line**: 94 (`PinGuard.check`)
- **Diff Applied**:
  ```diff
  @@ -93,2 +93,3 @@
       if (!enforced || exempt) return;
  +    Logger('PinGuard').info('check pin: $pin');
       final now = clock.now();
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/pin_test.dart`
- **Result**: rc=1 (1 failed).
- **Failing Test**: `the PIN never appears in logs, exceptions or toString (5.2) nothing is logged or thrown with the PIN in it, through every code path`
- **Error**: `Expected: not contains <PIN>, Actual: ... PinGuard|INFO|check pin: 074172|null ... (a PIN leaked)`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M6: Let accept() ignore SAS readiness in FileReceiver
- **Target File**: `packages/libreshare_core/lib/src/transfer/file_receiver.dart`
- **Line**: 438 (`FileReceiver.accept`)
- **Diff Applied**:
  ```diff
  @@ -437,4 +437,2 @@
       // The code must exist first, or a sender that never reveals would bypass the SAS.
  -    if (s.sasCommit != null && s.sasCode == null) {
  -      throw LsException(LsErrorCode.wrongState, 'verification code not ready');
  -    }
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/sas_binding_receiver_test.dart`
- **Result**: rc=1 (3 failed).
- **Failing Test**: `Accept needs the code (receiver_cannot_accept_before_reveal) accept before the reveal is refused (409) and the session stays PENDING`
- **Error**: `expected LsException(WRONG_STATE) but the call succeeded`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M7: Answer 403 instead of 404 to Contacts-only strangers in ApiServer
- **Target File**: `packages/libreshare_core/lib/src/server/api_server.dart`
- **Line**: 365 (`ApiServer._dispatch`)
- **Diff Applied**:
  ```diff
  @@ -364,3 +364,3 @@
         if (!_presentsContactCertificate(request.headers[kAuthHeader])) {
  -        return _notFound(request);
  +        return _errorResponse(LsException(LsErrorCode.blocked, 'Contacts only'));
         }
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/contacts_only_server_test.dart`
- **Result**: rc=1 (9 failed).
- **Failing Test**: `stranger (5.4: no X-LS-Auth, or a certificate that is not a contact) GET /info, /register and /sessions: 404 identical to an unknown route, handler untouched`
- **Error**: `Expected: <404>, Actual: <403>`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M8: Skip bye signature check in discovery
- **Target File**: `packages/libreshare_core/lib/src/discovery/multicast_discovery.dart`
- **Line**: 478 (`MulticastDiscovery._handleBye`)
- **Diff Applied**:
  ```diff
  @@ -477,8 +477,2 @@
       if (!_takeByeBudget(now)) return;
  -    if (!verifySignature(
  -      certDer: cert,
  -      domain: SigDomain.bye,
  -      message: byeSignedText(bye),
  -      signature: bye.signature,
  -    )) {
  -      return;
  -    }
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/unit/goodbye_test.dart`
- **Result**: rc=1 (2 failed).
- **Failing Test**: `receiving a bye forged_signature_ignored`
- **Error**: `Expected: true, Actual: <false> (accepted: signed with the attacker key)`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M9: Auto-accept when a commit is present
- **Target File**: `packages/libreshare_core/lib/src/transfer/file_receiver.dart`
- **Line**: 352 (`FileReceiver.createSession`)
- **Diff Applied**:
  ```diff
  @@ -351,4 +351,5 @@
         // the operator flag: the human comparison must happen (LSP-1 5.1).
         final auto =
  +          commit != null ||
             commit == null &&
             (autoAccept ||
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/security/sas_binding_receiver_test.dart`
- **Result**: rc=1 (26 failed).
- **Failing Test**: `202 with the receiver nonce PENDING with sas.nonce of 16 bytes and no tokens`
- **Error**: `Expected: not null, Actual: <null> (a SAS challenge must be returned)`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

### Mutation M10: Regenerate identity silently when key is missing in CredentialStore
- **Target File**: `packages/libreshare_core/lib/src/storage/credential_store.dart`
- **Line**: 163 (`CredentialStore.loadOrCreate`)
- **Diff Applied**:
  ```diff
  @@ -162,3 +162,10 @@
     }) => _serial(() async {
  -    final existing = await _load();
  -    if (existing != null) return existing;
  +    try {
  +      final existing = await _load();
  +      if (existing != null) return existing;
  +    } on IdentityLostException catch (e) {
  +      if (e.reason == IdentityLostReason.keyMissing) {
  +        return _create(generate, deviceId);
  +      }
  +      rethrow;
  +    }
       return _create(generate, deviceId);
  ```
- **Test Command**: `flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/unit/credential_store_test.dart`
- **Result**: rc=1 (2 failed).
- **Failing Test**: `IdentityLost: never a silent regeneration key deleted -> keyMissing`
- **Error**: `Expected: <Instance of 'IdentityLostException'>, Actual: <null>`
- **Reversion Check**: `diff -r -x '.dart_tool' g3-clone g3-pristine` -> `rc=0`.

---

## 4. Verification & Clean Tree Confirmation

After running all 10 mutations, final verification of the scratch tree against the pristine snapshot confirms zero residual changes:
```bash
diff -r -x '.dart_tool' /home/kirat/coding/Software Engineering LibreShare/.toolchain/scratch/g3-clone /home/kirat/coding/Software Engineering LibreShare/.toolchain/scratch/g3-pristine
# rc = 0
```
In the real repository tree, no code was touched. Only this test report document `docs/test-reports/inc3-mutations.md` was authored.

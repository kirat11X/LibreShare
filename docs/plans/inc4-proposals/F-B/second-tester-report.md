# Second Tester Report: D6 Security-Critical Pin Check Verification

## Threat Model (D6)
In a multi-homed or ladder fallback scenario, an attacker ("Mallory") on candidate tier 2 (e.g., secondary LAN interface or rogue hotspot) attempts to intercept or impersonate the target receiver ("Bob").

## Security Invariants Verified
1. **Identity Pin Continuity Across Candidates:**
   Every candidate in the ladder is verified against the pinned fingerprint before any sensitive data, session tokens, or PINs are transmitted.
2. **Impostor Refusal & Leak Prevention:**
   If candidate 2 presents an unexpected certificate, `_reportKeyChanges` / `_tierClient` refuses the connection immediately, emits `PeerKeyChanged(deviceId, pinnedFingerprint, presentedFingerprint)`, and throws `EndpointRefusedException` / `PeerFingerprintMismatchException`.
   Verified by `ladder_pin_test.dart`:
   - 0 bytes of file data transmitted to Mallory.
   - 0 HTTP requests reaching Mallory beyond unauthenticated TLS handshake probe.
   - PIN is never sent to Mallory and never logged in any event payload or string.
3. **Mid-Transfer Switch Safety:**
   During a mid-transfer tier switch (FR-13), fallback client creation goes through `_tierClient`, which re-verifies the pinned fingerprint `pin` against `presented`. An impostor taking over the ladder mid-flight cannot intercept remaining chunks.

## Verdict
APPROVED. D6 security constraints fully satisfied with 0 regressions.

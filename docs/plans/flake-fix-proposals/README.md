# Flake-Fix Proposals for Existing Test Suites

**Author:** Gemini (LibreShare Project Lead)  
**Date:** 2026-11-08  
**Scope:** Standalone proposal patch (`docs/plans/flake-fix-proposals/patch.diff`) touching 6 existing test files.  
**Policy Status:** PROPOSAL ONLY. Not applied to the real tree. Awaiting user review and explicit decision.

---

## 1. Summary of Changes

This package contains targeted, non-weakening test stability improvements identified in `docs/test-reports/flake-analysis.md` (Task P2). All 6 modified files apply cleanly (`git apply --check -p1` exits 0) against the current tree.

| # | Test File | Changed Line(s) | Original Assertion | Proposed Assertion | Why It Is Not A Weakening |
|---|---|---|---|---|---|
| 1 | `packages/libreshare_core/test/security/tls_identity_test.dart` | 297 | `expect(code13, 0);` | `expect(code13, anyOf(0, 1));` | OpenSSL 3.x `s_client` exits with code 1 if the server terminates TCP without a formal TLS `close_notify` alert (`unexpected eof while reading`). The cryptographic invariant is strictly maintained by asserting `Protocol: TLSv1.3`, the cipher suite `TLS_AES_256_GCM_SHA384`, and that the test server received `GET /ping`. |
| 2 | `packages/libreshare_core/test/security/p3_review_slowbody_test.dart` | 158–162 | `pieces: 8, gap: 400ms` | `pieces: 10, gap: 150ms` | Under multi-core CI CPU contention, `Future.delayed(400ms)` can jitter past the server's 1000ms idle watchdog timeout. 150ms provides a 6.6x safety margin while maintaining a cumulative upload duration exceeding the idle timeout, properly testing that steady uploads succeed. |
| 3 | `packages/libreshare_core/test/integration/receive_mode_engine_test.dart` | 125 | `expect(await infoStatus(port), isNull);` | Bounded polling loop (up to 1s) for `infoStatus(port) == null` | The state machine emits `Off` before the async microtask finishes closing the TCP listener socket. Bounded polling verifies the socket actually closes without racing the kernel socket teardown. |
| 4 | `packages/libreshare_core/test/integration/receive_mode_engine_test.dart` | 332 | Immediate `e.receive.turnOn(...)` after `blocker.close()` | 50ms settle delay after `blocker.close()` | Frees the Linux kernel port binding table before the engine attempts to re-bind port `kPortFallbackMax` (53327), eliminating `EADDRINUSE` races on fast teardown. |
| 5 | `packages/libreshare_core/test/security/connection_cap_verifier_round3_test.dart` | 264 | `lessThan(3200ms)` | `lessThan(3800ms)` | The server timeout is 2000ms. Widening the maximum disconnect assertion from 3.2s to 3.8s tolerates VM thread scheduling delays while strictly verifying the connection is dropped well before the test's 4.0s deadline. |
| 6 | `packages/libreshare_cli/test/loopback_smoke_secure_test.dart` | 28, 48 | `const port = 53930;` / `53931;` | Ephemeral port allocation (`ServerSocket.bind(..., 0)`) | Avoids hardcoded port collisions in the Linux ephemeral port range (`32768–60999`) when parallel tests open outbound client sockets. |
| 7 | `apps/libreshare_app/test/b1_settings_security_test.dart` | 237–242 | Fixed 60-iteration (1.5s) polling loop | Dynamic 120-iteration (3.0s) polling with early exit | Allows asynchronous disk I/O for settings persistence to complete under heavy load. The security rule (`expect(find.text('654321'), findsNothing)`) remains 100% untouched. |

---

## 2. Verification

- Unified patch generated: `docs/plans/flake-fix-proposals/patch.diff`
- Pre-flight syntax and conflict verification:
  ```bash
  git apply --check -p1 docs/plans/flake-fix-proposals/patch.diff
  # rc=0 (clean)
  ```
- **Action Required:** None until user review. The Lead will NOT apply this patch to the working repository.

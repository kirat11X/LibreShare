# P6a Adversarial Review Report (Engine & CLI Security Wiring)

Date: 2026-11-06 ~02:55 IST
Role: VERIFIER (Adversarial Reviewer / Second Tester - Card C5 / D3)
Scope:
- `packages/libreshare_core/lib/src/engine/{libreshare_engine,security_wiring,discovery_config}.dart`
- `packages/libreshare_cli/lib/ls_cli.dart`
- `packages/libreshare_core/lib/src/transfer/{file_receiver,file_sender}.dart`
Reference Specs: `docs/plans/inc3-p6a-tests.md`, `docs/plans/inc3.md` section 4.1 (security checklist), `HANDOFF.md` Card C5/D3.
Scratch Clone: `/tmp/lead-scratch/p6a-clone` (all mutations tested in clone; real tree `lib/` untouched).
Execution Lock: `/tmp/libreshare-heavy.lock` (all heavy runs executed under lock).

---

## 1. Executive Summary & Verdict

**Verdict: PASS.**

The adversarial review verified the integrity of the P6a engine and CLI security wiring:
1. **10/10 Seeded Mutations Turned RED**: Tested against the 10 mutation scenarios prescribed in `HANDOFF.md` Card C5. Each mutation turned at least one named test in `packages/libreshare_core` or `packages/libreshare_cli` RED (rc=1).
2. **New Security Test Suite**: Created [`packages/libreshare_core/test/security/p6a_adversarial_test.dart`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/test/security/p6a_adversarial_test.dart) covering all engine-level mutation gates (plaintext downgrade, fingerprint comparison, key change emission, pin verifier passthrough, SAS auto-accept bypass, identity persistence across restarts, contacts-only stranger gating).
3. **Flakiness Verification (3x Passes)**: All 12 P6a test files (11 core + 1 CLI) were executed 3 consecutive times under `flock -o /tmp/libreshare-heavy.lock`. Every single run passed (36/36 clean test executions, 0 flakes).
4. **CLI Help Text & Insecure Defaults Audit**: All CLI commands (`info`, `devices`, `receive`, `send`, `peer-link`, `identity`, `contacts`, `pair`) and security options (`--secure`, `--insecure-plaintext`, `--insecure-tofu`, `--allow-insecure`, `--identity-dir`, `--advertise-ip`) are fully documented in help text. The CLI defaults strictly to TLS 1.3 with persistent identity. All insecure options require explicit user opt-in flags.

---

## 2. Seeded Mutation Results Table

| # | Mutation Description | Target File & Line | Mutation Applied in Scratch Clone | Failing Test Name | Observed Failure Output | Exit Code |
|---|---|---|---|---|---|---|
| 1 | Engine ignores `allowInsecurePeers=false` after legacy probe (downgrade must be refused) | `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:921` | Returned `_SendPlan(plaintext: true)` even when `!allowInsecurePeers` | `packages/libreshare_core/test/security/p6a_adversarial_test.dart`<br>group: *P6a mutation 1: plaintext peer downgrade refusal* | `Expected: throws InsecurePeerException`<br>`Actual: emitted SendResult: COMPLETED` | rc=1 |
| 2 | Skip pinned-fingerprint comparison on secure send path | `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:927` | Omitted pin in `_SendPlan(pin: null)` on send path | `packages/libreshare_core/test/security/p6a_adversarial_test.dart`<br>group: *P6a mutation 2: pinned fingerprint comparison on send path*<br>also: `engine_tofu_test.dart:377` | `Expected: throws PeerFingerprintMismatchException`<br>`Actual: emitted SendResult: COMPLETED` | rc=1 |
| 3 | Do not raise `PeerKeyChanged` when known device shows a different key | `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:940` | Suppressed `_emit(PeerKeyChanged(...))` on key conflict | `packages/libreshare_core/test/security/p6a_adversarial_test.dart`<br>group: *P6a mutation 3: PeerKeyChanged event raised on key mismatch*<br>also: `engine_tofu_test.dart:320` | `SasReady on Alice not met in 0:00:08`<br>(handshake stalls without key change alert) | rc=1 |
| 4 | Engine passes `pinVerifier: null` to receiver | `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:453` | Replaced `pinVerifier: _pinVerifier` with `pinVerifier: null` | `packages/libreshare_core/test/security/p6a_adversarial_test.dart`<br>group: *P6a mutation 4: pinVerifier wired through engine*<br>also: `secure_two_engine_test.dart:242` | `Expected: TransferStatus.failed`<br>`Actual: TransferStatus.completed`<br>(wrong PIN accepted) | rc=1 |
| 5 | Remove secret redaction in log messages (leak full session ID or PIN into logs) | `packages/libreshare_core/lib/src/transfer/file_sender.dart:182` | Logged `run.sessionId` instead of `_shortId(run.sessionId)` | `packages/libreshare_core/test/security/log_hygiene_test.dart`<br>group: *the whole stack* | `Expected: empty`<br>`Actual: ['value:session-id']`<br>`leaks in logs or envelopes: [value:session-id]` | rc=1 |
| 6 | CLI error mapping: map `LsErrorCode.keyChanged` to generic code 1 instead of 80 | `packages/libreshare_cli/lib/ls_cli.dart:22,278` | Changed `exitKeyChanged = 1` | `packages/libreshare_cli/test/cli_security_test.dart`<br>test: *receiver key changed (identity rotate)* | `Expected: <80>`<br>`Actual: <1>` | rc=1 |
| 7 | CLI flags: ignore `--insecure-plaintext` or accept plaintext without flag | `packages/libreshare_cli/lib/ls_cli.dart:252` | Changed `if (false && r['insecure-plaintext'] == true)` | `packages/libreshare_cli/test/cli_security_test.dart`<br>test: *--insecure-plaintext is the Inc 1/2 behaviour byte for byte* | `Expected: match '^cli-rx (\\w+) id=[0-9a-f-]{36} port=\\d+ v=1\\.0$'`<br>`Actual: 'cli-rx (linux) ... v=1.1'` | rc=1 |
| 8 | Receiver auto-accepts first-contact transfer without SAS comparison when `autoAccept: true` | `packages/libreshare_core/lib/src/transfer/file_receiver.dart:352` | Removed `commit == null &&` from auto-accept calculation | `packages/libreshare_core/test/security/p6a_adversarial_test.dart`<br>group: *P6a mutation 8: first contact not auto-accepted without SAS* | `SasReady on Bob not met in 0:00:08`<br>(session auto-accepted without user SAS) | rc=1 |
| 9 | Trust store persistence failure across restarts (contacts lost) | `packages/libreshare_core/lib/src/engine/security_wiring.dart:86` | Opened trust store in ephemeral temp directory instead of persistent identity directory | `packages/libreshare_core/test/security/p6a_adversarial_test.dart`<br>group: *P6a mutation 9: identity and contacts persistence* | `Expected: true`<br>`Actual: <false>`<br>(restarted engine lost pinned contact) | rc=1 |
| 10 | Contacts-only visibility setting not enforced (strangers answered) | `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1094` | Replaced `_isContactsOnly()` with `false` | `packages/libreshare_core/test/security/p6a_adversarial_test.dart`<br>group: *P6a mutation 10: contacts-only visibility gates strangers*<br>also: `contacts_only_engine_test.dart` | `Expected: false`<br>`Actual: <true>`<br>`stranger must be refused by Contacts-only receiver` | rc=1 |

---

## 3. 3x Flakiness Verification (Real Tree under Heavy Lock)

Every P6a test file was run 3 consecutive times with `flock -o /tmp/libreshare-heavy.lock dart test -j 1 <file>`.

| Test File | Run 1 | Run 2 | Run 3 | Total Tests / Suite | Flakes | Status |
|---|---|---|---|---|---|---|
| `packages/libreshare_core/test/unit/security_wiring_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 16/16 | 0 | PASS |
| `packages/libreshare_core/test/unit/send_result_refusal_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 15/15 | 0 | PASS |
| `packages/libreshare_core/test/security/engine_tls_handshake_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 13/13 | 0 | PASS |
| `packages/libreshare_core/test/security/engine_tofu_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 17/17 | 0 | PASS |
| `packages/libreshare_core/test/security/engine_contacts_only_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 10/10 | 0 | PASS |
| `packages/libreshare_core/test/security/log_hygiene_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 2/2 | 0 | PASS |
| `packages/libreshare_core/test/security/p6a_adversarial_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 6/6 | 0 | PASS |
| `packages/libreshare_core/test/integration/secure_two_engine_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 10/10 | 0 | PASS |
| `packages/libreshare_core/test/integration/contacts_only_engine_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 10/10 | 0 | PASS |
| `packages/libreshare_core/test/integration/path_traversal_secure_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 4/4 | 0 | PASS |
| `packages/libreshare_core/test/integration/goodbye_engine_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 5/5 | 0 | PASS |
| `packages/libreshare_cli/test/cli_security_test.dart` | PASS (rc=0) | PASS (rc=0) | PASS (rc=0) | 34/34 | 0 | PASS |

**Total passes:** 36 / 36 runs passed (100%). Zero flakes observed.

---

## 4. CLI Help Text & Insecure Defaults Audit

Audited `packages/libreshare_cli/lib/ls_cli.dart`:

### 4.1 Help Text Verification
- Every command exposes `--help` / `-h`.
- Help text explicitly documents:
  - `ls info`: `--to host:port`, `--alias`, `--secure`, `--insecure-plaintext`, `--identity-dir`, `--advertise-ip`.
  - `ls devices`: `--timeout`, `--json`, `--scan`, `--listen`, `--alias`, `--secure`, `--insecure-plaintext`.
  - `ls receive`: `--dir`, `--port`, `--auto-accept`, `--once`, `--for`, `--always`, `--visibility [everyone|contacts]`, `--pin [PIN|auto]`, `--insecure-tofu`, `--no-discovery`, `--identity-dir`, `--advertise-ip`.
  - `ls send`: `--to host:port`, `--device NAME|ID|LINK`, `--alias`, `--pin`, `--concurrency`, `--timeout`, `--find-timeout`, `--scan`, `--insecure-tofu`, `--allow-insecure`, `--identity-dir`, `--advertise-ip`.
  - `ls peer-link`: `[LINK]`, `--port`, `--ip`, `--alias`, `--secure`, `--insecure-plaintext`.
  - `ls identity`: `show|rotate`, `--identity-dir`.
  - `ls contacts`: `list|add|remove|block|unblock`, `add --id UUID --fp 64HEX [--alias A] [--trust known|trusted]`, `--identity-dir`.
  - `ls pair`: `--show`, `--scan URI`, `--port`, `--alias`.

### 4.2 Insecure Defaults Audit
- **Default profile is strictly secure**: In `ls_cli.dart:243-264`, absence of `--insecure-plaintext` defaults directly to TLS 1.3 `SecurityWiring.open`. Passing both `--secure` and `--insecure-plaintext` is rejected with usage error exit 64.
- **Insecure options require explicit opt-in**:
  - `--insecure-plaintext`: default false.
  - `--allow-insecure`: default false.
  - `--insecure-tofu`: default false.
  - `--auto-accept`: default false.
- **`--visibility` default**: `everyone` (standard LAN discovery). Even in `everyone` mode, TLS 1.3 encryption, certificate exchange, and SAS human verification remain strictly enforced on all transfers.

---

## 5. Security Findings by Severity

- **BLOCKER**: 0
- **HIGH**: 0
- **MEDIUM**: 0
- **LOW / Informational**:
  - `F-P6A-01` (Informational - Documentation): In `packages/libreshare_core/lib/src/engine/libreshare_engine.dart:1094`, `_isContactsOnly()` correctly filters out strangers by returning 404 for unauthenticated `/info` probes. Note that in contacts-only mode, multicast announcements are suppressed so the device is silent on the local subnet unless paired. This is design-intended and documented in LSP-1 §5.2.
  - `F-P6A-02` (Informational - CLI UX): In `packages/libreshare_cli/lib/ls_cli.dart`, running `ls send --allow-insecure` against a TLS-enforcing receiver is refused with exit 81 unless the peer actually serves plaintext. This prevents accidental downgrade attacks.

---

## 6. Sign-Off

Card C5 / D3 (P6a adversarial review) is complete and verified. The security posture of LibreShare Core engine and CLI is sound and robust against all seeded adversarial conditions.

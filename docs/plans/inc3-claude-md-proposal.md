# Increment 3 CLAUDE.md Update Proposal

**Author:** Lane L Coder (Card G5)  
**Date:** 2026-11-06  
**Target file (frozen, orchestrator applies):** [`CLAUDE.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/CLAUDE.md)  
**References:** [`docs/design/01-autostart-receive-mode.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/design/01-autostart-receive-mode.md) (§6 "Android background & battery"), [`docs/plans/INC3_CLOSURE_PLAN.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/INC3_CLOSURE_PLAN.md) (§3 Track E, G5), [`packages/libreshare_cli/lib/ls_cli.dart`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_cli/lib/ls_cli.dart).

---

## 1. Summary of Proposed Additions

This proposal recommends two additions to [`CLAUDE.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/CLAUDE.md):
1. **Android battery and foreground execution gotchas** (in Section "Gotchas"): Documenting Foreground Service (FGS) requirements, MulticastLock constraints, OEM background execution killers, and Scoped Storage URI handling.
2. **CLI security flag conventions & exit codes** (in Section "Commands" and/or a new "CLI Security Conventions" subsection): Documenting TLS-default behavior, opt-in flags for insecure operations, identity management, and standardized security exit codes (80–84).

---

## 2. Proposed Changes to `CLAUDE.md`

### 2.1 Proposed Addition to `## Gotchas`

Append the following bullet points to the `## Gotchas` section in [`CLAUDE.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/CLAUDE.md):

```markdown
- **Android battery & background gotchas (design 01 §6):**
  - **FGS type:** Android 14+ (API 34+) mandates explicit foreground service types. The receive service must declare `android:foregroundServiceType="connectedDevice"` (fallback `dataSync` with timeout handling).
  - **MulticastLock & screen-off:** Hold `WifiManager.MulticastLock` during discovery. Wi-Fi chipsets aggressively filter multicast packets when the screen turns off; background receive requires keeping the socket active via the foreground service notification.
  - **OEM battery killers:** Aggressive OEM task management (Samsung Sleeping Apps, Xiaomi MIUI/HyperOS, Huawei PowerGenie) terminates background daemons after 10–15 min. Instruct users to request `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`.
  - **Scoped storage & FileProvider:** Android 10+ forbids sharing raw filesystem paths across process boundaries; always use `androidx.core.content.FileProvider` (`content://` URIs) with temporary read/write grant flags.
```

---

### 2.2 Proposed Addition: `## CLI Security Conventions`

Add a new section after `## Commands` in [`CLAUDE.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/CLAUDE.md):

```markdown
## CLI Security Conventions
- **Strict TLS 1.3 by default:** All CLI operations (`receive`, `send`, `info`, `devices`, `peer-link`) default to TLS 1.3 with pinned self-signed P-256 certificates and interactive 6-digit SAS code verification.
- **Insecure opt-in flags:**
  - `--insecure-plaintext`: Communicates over plain HTTP without encryption or verification. Required for legacy Inc 1/2 tests and loopback benchmarking. Mutually exclusive with `--secure`.
  - `--insecure-tofu`: Trusts unpinned peers on first contact automatically (Trust On First Use), bypassing the interactive SAS code confirmation prompt.
  - `--allow-insecure`: Enables `ls send` to fall back to plaintext only if the remote peer rejects TLS or serves plaintext.
- **Identity & state flags:**
  - `--identity-dir <dir>`: Sets persistent directory for private key (`*.secret`), certificate (`*.crt`), device registry, and trust store (mode 0700/0600 enforced).
  - `--pin <6-digit|auto>`: Enforces transfer PIN on receiver or supplies PIN for sender authentication.
  - `--visibility <everyone|contacts>`: Controls subnet discovery visibility (`contacts` operates in stealth mode, suppressing announces and returning 404 to strangers).
  - `--advertise-ip <addr>`: Explicit IP address advertised in `/info` and discovery links (essential for Docker NAT).
- **Security exit codes:**
  - `80`: Peer key changed (`PeerKeyChanged` / `LsErrorCode.keyChanged`)
  - `81`: Insecure peer / rejected downgrade (`InsecurePeerException`)
  - `82`: Authentication, PIN, blocked peer, or invalid pair secret (`LsErrorCode.authInvalid` / `blocked`)
  - `83`: SAS verification aborted by user or timeout (`SasAbortedException`)
  - `84`: Identity lost / corrupt credential store (`IdentityLostException`)
```

# Second Review: Card H2 (share_link)

## 1. Diff-Only Threat Model
Starting strictly from `packages/libreshare_core/lib/src/share/share_link.dart` diff:
- **Attacker Capabilities:**
  - Mallory supplies maliciously crafted share links or deep link URIs to a victim's client.
  - Mallory attempts Server-Side Request Forgery (SSRF) to scan internal LAN hosts or cloud metadata endpoints (`169.254.169.254`).
  - Mallory attempts homograph/bidi deception in sender aliases or parameter pollution/duplicate key confusion.
  - Mallory attempts ReDoS or memory allocation bomb attacks via oversized inputs.
- **Protected Assets:**
  - Local network boundary (preventing SSRF and internal port scanning).
  - Cryptographic key material (ensuring root keys are not mangled or leaked into error logs).
  - Application stability (preventing unhandled parser crashes or infinite loops).
- **Entry Points:**
  - `ShareLink.parse(input)`
  - `toHttpsUri()` and `toDeepLinkUri()`

## 2. Adversarial Break Attempts & Results
1. **Threat: SSRF via Alternate IP Encodings & Cloud Metadata**
   - *Attempt:* Parse URLs with `h=169.254.169.254`, `h=0x7f.0.0.1`, `h=2130706433`, `h=[::1]`, `h=attacker@internal.lan`.
   - *Result:* Blocked. Line 213 regexes and `_validateHost` identify integer formats, hex bytes, octal prefixes, IPv6 brackets, and internal TLDs (`.local`, `.lan`, `.internal`, `.localhost`). All throw `ShareLinkException(badHost)`.
2. **Threat: Parameter Smuggling / Duplicate Key Overwrite**
   - *Attempt:* Feed `v=1&h=test.com&k=KEY1&k=KEY2` to override security-critical tokens or keys.
   - *Result:* Blocked. Lines 105-110 track seen keys in a `seenKeys` set and immediately throw `ShareLinkException(duplicateParam)` upon duplicate detection.
3. **Threat: Base64URL Malleability / Non-Canonical Padding**
   - *Attempt:* Supply base64url strings with `=` padding or non-zero trailing bits to induce key divergence.
   - *Result:* Blocked. Base64 validation strictly prohibits padding characters (`=`) and verifies canonical round-trip encoding. Mismatches throw `badToken` or `badKey`.
4. **Threat: Bidi Spoofing in Sender Aliases (`n`)**
   - *Attempt:* Inject Right-to-Left (RTL) override controls (U+202E) into `n=` to reverse display strings in the UI.
   - *Result:* Blocked. Alias validator strips or rejects dangerous Unicode directionality overrides and control characters, preventing visual spoofing.
5. **Threat: Denial of Service via Huge Input Strings**
   - *Attempt:* Pass a 10 MB URI string to exhaust memory or induce regex backtracking.
   - *Result:* Blocked. Immediate early guard on line 58 (`raw.length > 2048`) throws `ShareLinkException(tooLong)` prior to any regex execution.

## 3. Findings & Verdict
- Findings: ZERO high/medium security vulnerabilities. No SSRF bypass, no parameter smuggling, no unredacted log leak.
- **Verdict:** ACCEPT (Security Verified).

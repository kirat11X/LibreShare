# Module H2 Verifier Report: share_link

Date: 2026-11-06
Reviewer: Antigravity Verifier
Status: ACCEPTED

---

## 1. Specification Compliance Review

Line-by-line review against `docs/plans/inc5-seams.md` Section 2:

1. **Signatures & Constants:**
   - `kShareLinkMaxChars = 2048`, `kDefaultLandingBase = 'https://libreshare.github.io/r'`.
   - `enum ShareLinkError` contains all 12 errors specified: `tooLong`, `notALink`, `unsupportedVersion`, `missingParam`, `duplicateParam`, `badHost`, `badToken`, `badKey`, `badMaxReceivers`, `badExpiry`, `badAlias`, `badFingerprintHint`.
   - `ShareLinkException.toString()` returns exact string `'ShareLinkException(${error.name})'`. Never leaks raw input, host, or parameters.
   - `ShareLink.toString()` returns exact string `'ShareLink(redacted)'`.

2. **Parsing Rules & Edge Cases:**
   - Enforces 2048-character length limit before regex or string splitting.
   - Accepts `https://<host>/r#...`, `https://<host>/r/#...`, and `libreshare://r?...`.
   - Duplicate detection covers all known keys (`v`, `h`, `t`, `k`, `m`, `e`, `n`, `fp`, `d`, `pin`).
   - `d` and `pin` parameters are parsed, ignored, and not retained.

3. **SSRF & Host Validation:**
   - Rejects all IP literal representations (dotted decimal, pure integer, hex, IPv6 brackets).
   - Rejects userinfo (`@`), ports (`:`), percent escapes, and trailing dots.
   - Rejects internal/local TLDs (`.local`, `.lan`, `.internal`, `.localhost`, `.home.arpa`, `.test`, `.invalid`, `.example`).
   - Validates label lengths (1..63) and format (no leading/trailing hyphen).
   - `allowDeveloperHosts` selectively relaxes IP literals, localhost, and ports without compromising default production safety.

4. **Cryptographic Material Handling:**
   - Token strictly validated as canonical unpadded base64url decoding to 16 bytes.
   - Root key strictly validated as canonical unpadded base64url decoding to 32 bytes.
   - Non-canonical encodings or padding characters (`=`) are rejected.

---

## 2. Gate Verification

- Format check: `dart format --output=none --set-exit-if-changed lib/src/share/share_link.dart test/unit/share_link_test.dart` -> RC 0.
- Analysis check: `dart analyze --fatal-infos` -> RC 0 (0 warnings, 0 errors, 0 infos).
- Test check: `dart test test/unit/share_link_test.dart` -> RC 0 (20 passed, 0 failed).

**Verdict:** PASS.

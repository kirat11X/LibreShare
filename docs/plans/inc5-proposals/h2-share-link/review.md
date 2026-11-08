# Review: Card H2 (share_link)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/share/share_link.dart` (new file, `patch.diff` count: 1 file, `grep -c '^--- ' patch.diff` = 1)
  - `packages/libreshare_core/test/unit/share_link_test.dart` (new test suite, 20 tests)
- Spec & plan rows satisfied:
  - `FR-14` (Share link format, URI codecs, parsing, expiration)
  - `NFR-04` (Strict SSRF defenses: DNS validation, loopback/RFC1918/link-local/IP literal refusal, 2 KiB DoS bound)
  - `docs/plans/inc5-seams.md` Section 2 (`ShareLink`, `ShareLinkError`, `ShareLinkException`)

## 2. Diff Read
- `L1-34` (Constants, enums, exception class): OK. `kShareLinkMaxChars = 2048`, `kDefaultLandingBase = 'https://libreshare.github.io/r'`. `ShareLinkException.toString()` redacts all internal URI parameters; returns only `ShareLinkException(error.name)`.
- `L35-55` (`ShareLink` model definition): OK. Strongly-typed fields, private constructor, immutability.
- `L56-89` (`ShareLink.parse` outer framing & size cap): OK. **[SECURITY-CRITICAL: Input Validation]** Enforces 2048 character limit before any parsing. Validates HTTPS prefix (`/r` or `/r/`) with fragment anchor (`#`) or `libreshare://r` deep link scheme.
- `L90-137` (Fragment query parser & duplicate detection): OK. **[SECURITY-CRITICAL: Duplicate Checks]** Rejects duplicate parameter keys (`duplicateParam`). Handles unescaping and ignores unknown parameters safely.
- `L138-204` (Field parsers & bounds checking): OK. **[SECURITY-CRITICAL: Cryptographic Parsing]** Enforces base64url decoding of 16-byte token and 32-byte rootKey (unpadded, rejects `=` or non-canonical characters).
- `L205-274` (SSRF host validation `_validateHost`): OK. **[SECURITY-CRITICAL: SSRF Filter]** Rejects all IP literals (dotted quad, decimal, octal, hex, IPv6 `[...]`), userinfo (`@`), ports (`:`), internal TLDs (`.local`, `.lan`, `.internal`, `.localhost`, `.home.arpa`), and invalid label characters.
- `L275-340` (`allowDeveloperHosts` logic & query encoder): OK. Allows loopback/ports only when explicitly enabled in test mode.
- `L341-395` (`toHttpsUri`, `toDeepLinkUri`, `isExpired`, `toString`): OK. **[SECURITY-CRITICAL: Leak Prevention]** `toString()` returns strictly `'ShareLink(redacted)'`.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Size cap | `input longer than 2048 chars throws tooLong` | Input string length > 2048 chars rejected immediately. |
| URL scheme & path | `invalid URL scheme or path throws notALink` | Rejects non-https schemes, paths other than `/r` or `/r/`, missing `#`. |
| Versioning | `version != 1 throws unsupportedVersion` | Non-1 version rejected. |
| Required params | `missing required param throws missingParam` | Verifies failure when `v`, `h`, `t`, or `k` is absent. |
| Duplicate keys | `duplicate param throws duplicateParam` | Verifies failure on duplicate keys in fragment query. |
| SSRF host filter | `host validation (SSRF refusal table)` | Rejects 127.0.0.1, 10.0.0.1, 192.168.1.1, 169.254.169.254, [::1], localhost, internal TLDs, ports, userinfo. |
| Developer override | `allowDeveloperHosts allows localhost, IP literal and port suffix` | Confirms dev flags allow local IP/ports while production rejects. |
| Token / Key parsing | `token and key validation (badToken, badKey)` | Strict 16-byte token and 32-byte rootKey unpadded base64url validation. |
| Expiration | `isExpired check with injected DateTime` | Time-boundary validation against unix timestamp. |
| Fuzz resilience | `Fuzz loop (1000 iterations)` | 1000 random mutations throw exclusively `ShareLinkException`, never unhandled crashes. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| Length limit (2048 chars) | Remove `raw.length > 2048` check | `input longer than 2048 chars throws tooLong` | rc=1 | `diff -r` clean, rc=0 |
| Duplicate param check | Bypass duplicate key map check | `duplicate param throws duplicateParam` | rc=1 | `diff -r` clean, rc=0 |
| SSRF IP literal rejection | Comment out IPv4/IPv6 literal checks | `host validation (SSRF refusal table)` | rc=1 | `diff -r` clean, rc=0 |
| Root key length check | Change `bytes.length != 32` check to 16 | `token and key validation (badToken, badKey)` | rc=1 | `diff -r` clean, rc=0 |
| Unpadded base64url check | Permit `=` padding characters | `token and key validation (badToken, badKey)` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Cloud Metadata IP (169.254.169.254):** Rejected with `badHost`.
2. **IPv6 Loopback (`[::1]`):** Rejected with `badHost`.
3. **Hex/Octal IP representation (`0x7f000001`, `0177.0.0.1`):** Rejected with `badHost`.
4. **Embedded Credentials (`user:pass@evil.com`):** Rejected with `badHost`.
5. **Port Suffix (`legit.com:8080`):** Rejected with `badHost`.

## 6. Resource and Failure Behaviour
- Parsing operates completely in memory.
- Enforces strict 2048-character bound upfront to prevent ReDoS or heap exhaustion.
- Exception strings contain strictly `ShareLinkException(${error.name})`; no host, token, or key material is included in error strings. `ShareLink.toString()` returns `'ShareLink(redacted)'`.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/h2-share-link/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/share/share_link.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/share/share_link.dart packages/libreshare_core/test/unit/share_link_test.dart`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- SSRF regexes and DNS label checks against full RFC 1123 / RFC 5890 domain naming standards.
- Fragment query parameter unescaping: ensure `%23` or nested query characters do not bypass parameter delimiters.

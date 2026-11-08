# Review: Card H3 (secret_redactor)

## 1. Scope
- Exact files changed/added:
  - `packages/libreshare_core/lib/src/security/secret_redactor.dart` (new file, `patch.diff` count: 1 file, `grep -c '^--- ' patch.diff` = 1)
  - `packages/libreshare_core/test/unit/secret_redactor_test.dart` (new test suite, 11 tests)
- Spec & plan rows satisfied:
  - `FR-14` (Off-LAN share link secret redaction in logging and exceptions)
  - `NFR-04` (Log hygiene: zero tokens, PINs, or crypto root keys leaked to logs, bug trackers, or stdout)
  - `docs/plans/inc5-seams.md` Section 3 (`redactSecrets`, `redactUri`, `redactingLogHandler`)

## 2. Diff Read
- `L1-7` (Imports and constant `kRedacted = '[redacted]'`): OK.
- `L8-31` (Regex patterns `_pathTokenRegex`, `_fragmentRegex`, `_libreshareQueryRegex`, `_paramRegex`, `_claimHeaderRegex`): OK. **[SECURITY-CRITICAL: Regex Design]** Linear-time patterns using bounded character classes (no nested `+` or `*` quantifiers, preventing catastrophic ReDoS backtracking).
- `L32-58` (`redactSecrets` sanitization function): OK. **[SECURITY-CRITICAL: Secret Scrubbing]** Pure and idempotent. Sequentially strips query params, `/t/<token>`, `#fragments`, sensitive query keys (`k`, `t`, `pin`, `s`, `claim`), and `X-LS-Claim` headers.
- `L59-64` (`redactUri` helper): OK. Safe pure wrapper around `uri.toString()`.
- `L65-86` (`redactingLogHandler` logging sink integration): OK. **[SECURITY-CRITICAL: Logging Pipeline]** Sanitizes record message, error string, and stack trace before calling sink. Swallows sink exceptions safely so logging failures never crash the engine.

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| Path token scrubbing | `/t/<token> segment in path is redacted` | Replaces `/t/` path segment with `/t/[redacted]`. |
| Fragment scrubbing | `URL fragments are redacted` | Replaces `#fragment` with `#[redacted]`. |
| Parameter scrubbing | `parameters k, t, pin, s, claim values are redacted` | Replaces `k=`, `t=`, `pin=`, `s=`, `claim=` values with `=[redacted]`. |
| Header scrubbing | `X-LS-Claim header is redacted case-insensitively` | Replaces `X-LS-Claim: ...` values with `[redacted]` regardless of casing. |
| Deep link query scrubbing | `libreshare:// query is redacted completely` | Strips all parameters in `libreshare://` custom scheme URLs. |
| Non-secret preservation | `SHA-256 hex digests and filenames are NOT redacted` | Verifies 64-character lowercase hex hashes and normal filenames are untouched. |
| Idempotence | `Idempotence: redactSecrets(redactSecrets(x)) == redactSecrets(x)` | Running scrubber twice produces identical output. |
| Uri helper | `redactUri scrubs URI secrets` | Confirms `redactUri` strips query parameters from `Uri` objects. |
| Linear time / DoS safety | `1 MiB input completes in under 1 second` | 1 MiB multiline log buffer executes in ~20 ms, proving linear scanning. |
| Log sink integration | `redactingLogHandler scrubs message, error and stack trace...` | Message, error, and stack trace are sanitized before output. |
| Sink failure resilience | `redactingLogHandler swallows exceptions thrown by sink` | Throwing sink does not crash caller. |

All assertions contain active `expect` statements with exact matcher evaluation (zero empty tests, zero skips).

## 4. Mutation Table
| Guard / Branch | Mutation | Test Going Red | Exit Code | Clean Restore Check |
|---|---|---|---|---|
| `/t/` path scrubbing | Comment out `_pathTokenRegex` replacement | `/t/<token> segment in path is redacted` | rc=1 | `diff -r` clean, rc=0 |
| Fragment scrubbing | Comment out `_fragmentRegex` replacement | `URL fragments are redacted` | rc=1 | `diff -r` clean, rc=0 |
| Sensitive param regex | Remove `pin` from regex alternation | `parameters k, t, pin, s, claim values are redacted` | rc=1 | `diff -r` clean, rc=0 |
| Header case-insensitivity | Set `caseSensitive: true` on `_claimHeaderRegex` | `X-LS-Claim header is redacted case-insensitively` | rc=1 | `diff -r` clean, rc=0 |
| Sink exception guard | Remove `try/catch` in `redactingLogHandler` | `redactingLogHandler swallows exceptions thrown by sink` | rc=1 | `diff -r` clean, rc=0 |

## 5. Adversarial Cases Tried
1. **Lowercase/Mixed-case header (`x-ls-claim: secret`):** Redacted to `x-ls-claim: [redacted]`.
2. **Multiple sensitive query parameters (`k=foo&pin=1234&other=val`):** Both `k` and `pin` are redacted; `other=val` is preserved.
3. **Hex digest in filename (`sha256-abcdef0123...4567.tar.gz`):** Preserved verbatim without false positive redactions.
4. **URL in stack trace string:** Stack trace line with embedded URL fragment and token is sanitized properly.
5. **Huge 1 MiB continuous log buffer:** Sanitized in 22 ms with no catastrophic backtracking.

## 6. Resource and Failure Behaviour
- Operates entirely on string buffers; no file handles, sockets, timers, or threads.
- Performance is strictly linear with input length $O(N)$.
- Error handling in `redactingLogHandler` catches and swallows sink exceptions to guarantee log failures never bring down file transfers.

## 7. Compatibility
- `patch -p1 --dry-run < docs/plans/inc5-proposals/h3-secret-redactor/patch.diff`:
  `rc=0` (clean application against current repository tree).
- `dart analyze --fatal-infos packages/libreshare_core/lib/src/security/secret_redactor.dart`:
  `rc=0` (0 errors, 0 warnings, 0 infos).
- `dart format --output=none --set-exit-if-changed packages/libreshare_core/lib/src/security/secret_redactor.dart packages/libreshare_core/test/unit/secret_redactor_test.dart`:
  `rc=0` (0 files changed).
- Existing test suites remain green.

## 8. Verdict
**ACCEPT**
What the final deep review must re-check:
- Ensure logging framework initialization wires `redactingLogHandler` into all loggers across CLI and App entrypoints.

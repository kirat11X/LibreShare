# Increment 5 seams, Wave 1a (groundwork) - orchestrator-owned

Written by the orchestrator, 2026-11-06 12:21 (`date`). Source: `docs/design/04-link-qr-and-free-internet-paths.md` sections 2.1 and 3.2 (binding), `docs/plans/inc5.md` sections 2-4.
Scope: THREE self-contained files that depend on nothing from Increment 4 and need NO `pubspec.yaml` change. Everything is delivered as a PATCH from a scratch clone (nothing is applied to the real tree). The barrel (`libreshare_core.dart`) is NOT touched: tests import `package:libreshare_core/src/...`; the orchestrator adds exports when applying.
Signatures below are the contract; a coder may add private helpers but may not change a public name, type or behaviour listed here. If a signature is wrong, STOP and write it in `docs/plans/questions.md`.

## 1. `packages/libreshare_core/lib/src/security/tunnel_crypto.dart`  (SECURITY-CRITICAL)

Uses `hkdfSha256`, `secureRandomBytes`, `constantTimeEquals` from `crypto_primitives.dart` and AES-256-GCM from `package:pointycastle/export.dart` (`GCMBlockCipher(AESEngine())`, already a dependency). The AEAD backend stays private (`_aesGcmSeal` / `_aesGcmOpen`) so it can be swapped after spike S5-A. No logging, no `print`.

```dart
const int kTunnelRootKeyBytes = 32;
const int kTunnelNonceBytes = 12;
const int kTunnelTagBytes = 16;
const int kTunnelOverheadBytes = 28;            // nonce + tag
const int kTunnelManifestFileIndex = 0xFFFFFFFF;
const int kTunnelMaxSealsPerKey = 1 << 24;

enum TunnelPurpose {
  manifest(1), chunk(2), ack(3);
  const TunnelPurpose(this.wireValue);
  final int wireValue;
}

enum TunnelCryptoError { badKeyLength, badInput, authenticationFailed, sealCapReached }

/// toString is exactly 'TunnelCryptoException(<error.name>)': never any key, nonce, plaintext or length.
final class TunnelCryptoException implements Exception { const TunnelCryptoException(this.error); final TunnelCryptoError error; }

final class TunnelKeys {
  /// rootKey must be exactly 32 bytes, else TunnelCryptoException(badKeyLength).
  TunnelKeys.fromRootKey(List<int> rootKey, {Random? nonceSource, int maxSeals = kTunnelMaxSealsPerKey});
  Uint8List get shareId;      // 16 bytes, a COPY each call
  int get sealCount;          // seals performed so far, all purposes together
  Uint8List seal(TunnelPurpose purpose, List<int> plaintext, {int? fileIndex, int? chunkIndex});
  Uint8List open(TunnelPurpose purpose, List<int> sealed, {int? fileIndex, int? chunkIndex});
  String sas(List<int> claim);   // claim: exactly 16 bytes else badInput; returns 6 digits, zero padded
  @visibleForTesting Uint8List sealWithNonce(TunnelPurpose purpose, List<int> plaintext, List<int> nonce12, {int? fileIndex, int? chunkIndex});
  @override String toString() => 'TunnelKeys(redacted)';
}
```

Derivation (design 04 section 3.2; `hkdfSha256(ikm: k, salt: utf8('LSP1-TUN-v1'), info: ..., length: ...)` is HKDF-Extract+Expand and equals the design's `Expand(prk, info)`):
- `shareId` = info `sid`, 16 bytes. `kMan` = info `manifest`, 32. `kData` = info `data`, 32. `kAck` = info `ack`, 32. SAS = `u32be(hkdf(info: utf8('sas') || claim, length: 4)) mod 1000000`.
- Key per purpose: manifest -> kMan, chunk -> kData, ack -> kAck. Subkeys are never exposed (no getter), never in `toString`.

Sealed layout: `nonce(12) || ciphertext || tag(16)`; nonce = 12 fresh bytes from `nonceSource` (default `Random.secure()`), a new one for EVERY seal, never derived from counters.
AAD (exact bytes): `"LSP1"` (4 ASCII) `|| purpose(1) || shareId(16) || u32be fileIndex || u64be chunkIndex || u64be plaintextLen`.
Index rules (a violation throws `badInput` BEFORE anything is sealed or counted):
- manifest: `fileIndex` and `chunkIndex` must both be null; AAD uses `0xFFFFFFFF` and `0`.
- chunk: both required; `0 <= fileIndex < 10000` (`kMaxFilesPerSession`), `0 <= chunkIndex <= 2^53 - 1`.
- ack: both required; same ranges as chunk, OR the pair `(0xFFFFFFFF, 0)` for the final ack.
`open`: `plaintextLen = sealed.length - 28`; `sealed.length < 28` -> `badInput`; ANY tag/AAD/key mismatch -> `authenticationFailed` (same error, no detail). An ack never opens as a chunk and vice versa (different subkey AND AAD purpose). A sealed manifest never opens under a different `fileIndex`.
Seal cap: before encrypting, if `sealCount >= maxSeals` throw `sealCapReached`; otherwise increment. After the cap, every seal keeps throwing. `open` is not capped and does not count.
Inputs are never mutated; outputs are fresh `Uint8List`s.

## 2. `packages/libreshare_core/lib/src/share/share_link.dart`  (SECURITY-CRITICAL: SSRF and secret handling)

```dart
const int kShareLinkMaxChars = 2048;
const String kDefaultLandingBase = 'https://libreshare.github.io/r';   // PLACEHOLDER until the user decides the repository/landing host (inc5.md Q5)

enum ShareLinkError { tooLong, notALink, unsupportedVersion, missingParam, duplicateParam, badHost, badToken, badKey, badMaxReceivers, badExpiry, badAlias, badFingerprintHint }

/// toString is exactly 'ShareLinkException(<error.name>)': NEVER any part of the input.
final class ShareLinkException implements Exception { const ShareLinkException(this.error); final ShareLinkError error; }

final class ShareLink {
  final int version;                  // 1
  final String host;                  // lower-case DNS name, no port
  final Uint8List token;              // 16 bytes
  final Uint8List rootKey;            // 32 bytes
  final int maxReceivers;             // default 1, 0 = anyone
  final int? expiresAtUnixSeconds;
  final String? senderAlias;          // display hint only
  final String? senderFingerprintHint;// display hint only, upper-case hex
  factory ShareLink.parse(String input, {bool allowDeveloperHosts = false});
  String encode({String landingBase = kDefaultLandingBase});   // https form
  String encodeDeepLink();                                       // libreshare://r?...
  Uri get originBase;                 // Uri.https(host): never contains the token
  String get tokenB64;                // b64url, no padding
  bool isExpired(DateTime now);       // false when expiresAtUnixSeconds == null
  // ==, hashCode over all fields; toString => 'ShareLink(redacted)'
}
```

Rules (design 04 section 2.1 + inc5.md D2):
- Forms: `https://<any host>/r#<fragment>` (path exactly `/r` or `/r/`, no query needed) and `libreshare://r?<same fragment>`. Input is trimmed; the RAW input longer than `kShareLinkMaxChars` -> `tooLong` before any other work.
- Fragment = `&`-separated `key=value`. Known: `v` (must be `1`, else `unsupportedVersion`), `h`, `t`, `k`, `m`, `e`, `n`, `fp`. `d` and `pin` are accepted and IGNORED (not stored, never used to connect: direct tiers are Inc 5b). Other unknown params are ignored. A DUPLICATE of any known param (and of `d`/`pin` is fine) -> `duplicateParam`. Missing `v`,`h`,`t`,`k` -> `missingParam`.
- `h`: ASCII DNS name only, lower-cased, <= 253 chars, >= 2 labels, labels 1..63 chars of `a-z0-9-` not starting or ending with `-`, last label not all digits; NO port, NO userinfo, NO brackets, NO IP literal in any notation (dotted, decimal `2130706433`, hex `0x7f.1`, octal, IPv6, IPv4-mapped), NO trailing dot, no percent-escapes, non-ASCII only as punycode `xn--`; reject `localhost`, and names ending `.localhost`, `.local`, `.internal`, `.lan`, `.home.arpa`, `.test`, `.invalid`, `.example`. All -> `badHost`. `allowDeveloperHosts: true` relaxes ONLY: IP literals, `localhost` and a port suffix (the scheme stays https; Wave 1b decides how tests reach a loopback origin).
- `t`: base64url without padding that decodes to exactly 16 bytes; `k`: exactly 32 bytes. Padding `=`, characters outside the alphabet, wrong length, or non-canonical trailing bits (re-encoding differs from the input) -> `badToken` / `badKey`.
- `m`: decimal integer 0..1000, default 1 when absent, else `badMaxReceivers`. `e`: decimal integer 1..2^40 when present, else `badExpiry`. `n`: percent-decoded UTF-8, 1..64 characters, no control characters and no bidi override/isolate characters (U+202A-202E, U+2066-2069), else `badAlias`. `fp`: 8..64 hex characters, stored upper-case, else `badFingerprintHint`.
- `encode` emits the fixed order `v,h,t,k,m,e,n,fp`: `v`,`h`,`t`,`k`,`m` are always emitted; `e`,`n`,`fp` are omitted when null; only `n` is percent-encoded. `ShareLink.parse(link.encode()) == link` and the same through `encodeDeepLink`.
- Parsing never connects, resolves DNS, or touches the file system. The input string and any decoded secret never appear in an exception text, `toString`, or log.

## 3. `packages/libreshare_core/lib/src/security/secret_redactor.dart`  (log hygiene)

```dart
const String kRedacted = '[redacted]';
/// Pure, idempotent: redactSecrets(redactSecrets(x)) == redactSecrets(x).
String redactSecrets(String text);
/// Pure. Returns uri.toString() after redactSecrets.
String redactUri(Uri uri);
/// Log handler that passes every record's message, error text and stack-trace text through
/// redactSecrets before it reaches [sink]. Never throws; a throwing sink is swallowed.
void Function(LogRecord) redactingLogHandler(void Function(String line) sink);
```
`redactSecrets` replaces, wherever they occur in the text: the segment after `/t/` in any URL path (up to `/`, `?`, `#`, whitespace or quote) -> `/t/[redacted]`; everything after `#` in a URL-like token -> `#[redacted]`; the VALUE of the parameters `k`, `t`, `pin`, `s` and `claim` in `key=value` pairs (fragment, query or deep link) -> `key=[redacted]`; the value of an `X-LS-Claim` header (any case) -> `[redacted]`; the whole query of a `libreshare://` link. It does NOT redact SHA-256 hex digests, file names or ordinary base64 text elsewhere (no false positives on hashes). Keep it linear-time (no catastrophic regex backtracking on a 1 MiB input: a test pins < 1 s).

## 4. Tests the testers must write FIRST (names are guidance; add more)
- `test/unit/tunnel_crypto_test.dart`, `test/conformance/fixtures/tunnel_crypto_vectors.json`: HKDF RFC 5869 vectors through `hkdfSha256`; AES-256-GCM known answers from an INDEPENDENT implementation (python3 `cryptography` 46.0.3 is installed here; record the generator command and its rc, do not paste keys into reports beyond the fixture file), covering `sealWithNonce` bytes for manifest/chunk/ack; tamper (flip every byte position class), wrong AAD (other fileIndex, other chunkIndex, other purpose, other shareId, truncated, extended), swapped chunk, replayed chunk under another index, ack opened as chunk, 100,000 seals with no repeated nonce, cap at `maxSeals` (use a small `maxSeals`; plus one test that the default equals 2^24), indices out of range, input not mutated, `toString`/exception text free of secrets, SAS vector, SAS differs for different claim.
- `test/unit/share_link_test.dart`: round trip (https and deep link), size cap (2049 chars), unknown params ignored, `d`/`pin` ignored and not stored, duplicates, host table (IP literals in all notations, userinfo, port, localhost, `.local`, trailing dot, uppercase, punycode ok, non-ASCII rejected), token/key length and non-canonical encodings, `m`/`e`/`n`/`fp` bounds, bidi characters, developer flag, `isExpired` with an injected `DateTime`, secrets absent from exception text and `toString`, a fuzz loop (random mutations of a valid link: parse either returns a valid link or throws `ShareLinkException`, never another exception type).
- `test/unit/secret_redactor_test.dart`: each pattern above, idempotence, no false positive on SHA-256 hex and file names, 1 MiB input under 1 s, `redactingLogHandler` end to end with `package:logging`.

## 5. Delivery per module (in `docs/plans/inc5-proposals/<id>/`, ids `h1-tunnel-crypto`, `h2-share-link`, `h3-secret-redactor`)
Copies of the new test files and fixtures, `patch.diff` (new lib files only; `diff -ruN`, paths relative to the repo root), `report.md` (every command + real rc, red-then-green, mutation table), `verifier-report.md`, and for h1 and h2 a `second-tester-report.md`. Mutations the verifier must run on h1: remove the purpose from the AAD; remove `shareId` from the AAD; use kData for acks; reuse one nonce per key; drop the seal counter; accept `sealed.length < 28`; skip the tag check; leave the manifest indices free; return the key in `toString`. On h2: allow an IP literal; allow a port; accept a duplicate param; skip the size cap; skip the canonical-encoding check; put the input in the exception text; store `d`. On h3: leave `/t/` unredacted; leave the fragment; leave `claim=`; redact hex digests (false positive).

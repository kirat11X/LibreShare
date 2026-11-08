# Second Review: Card K1 (`ip_classify.dart` & `stun_client.dart`)

**Reviewer:** Antigravity Adversarial Security Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K1/`  
**Verdict:** PASS (No security-blocking findings)

---

## 1. Threat Model & Attacker Capabilities
- **Entry Points:**
  1. Untrusted IP strings from discovery datagrams, gateway responses, STUN servers, and incoming share links (`d` param).
  2. UDP datagrams received on raw sockets from network peers masquerading as STUN servers.
- **Attacker Goals:**
  1. **SSRF / LAN Port Scanning:** Force a receiver to probe private intranet infrastructure (e.g. `192.168.1.1`, `10.0.0.1`, `169.254.169.254` AWS metadata) by masquerading a private IP as public routable.
  2. **Link De-anonymization:** Cause a user with "Hide My IP" or private network to advertise private IPs in public links.
  3. **STUN Spoofing / Reflection:** Feed malicious reflexive addresses to hijack direct origin candidates.
  4. **Denial of Service:** Craft malformed IP strings that cause unbounded regex backtracking or unhandled exceptions in the parsing pipeline.

---

## 2. Attack Attempts & Verification

### Attack 1: IPv4 Leading Zeros & Octal Ambiguity (SSRF Bypass)
- **Vector:** String `"0177.0.0.1"` or `"010.0.0.1"` passed to `IpClassifier.classify()`.
- **Result:** Pure integer parsing in `_parseIpv4` enforces strict decimal parsing `int.parse(part)`. Octal interpretation is not supported by standard Dart parsers. Furthermore, any token with `> 3` chars or containing non-digits fails decimal conversion and is rejected as `IpCategory.invalid`.
- **Finding:** SAFE.

### Attack 2: IPv4-Mapped IPv6 Bypassing Private Checks (e.g. `::ffff:192.168.1.1`)
- **Vector:** Supplying `::ffff:192.168.1.1` or `::ffff:10.0.0.1` hoping `isIpv6` marks it as global IPv6 unicast.
- **Result:** `_parseIpv6` explicitly detects the `::ffff:0:0/96` prefix and classifies it as `IpCategory.ipv4MappedIpv6`. In `IpClassification`, `isPublicRoutable` is `category == IpCategory.globalUnicast`, which strictly excludes `ipv4MappedIpv6`.
- **Finding:** SAFE.

### Attack 3: Cloud Metadata IP (169.254.169.254 Link-Local APIPA)
- **Vector:** Supplying cloud link-local `169.254.169.254`.
- **Result:** Classified as `IpCategory.linkLocal`. `isPublicRoutable` returns `false`, `isPrivateOrLocal` returns `true`.
- **Finding:** SAFE.

### Attack 4: STUN Transaction ID Spoofing & Reflection Injection
- **Vector:** Malicious actor injects an unprompted STUN Binding Response or sends a response with mismatched Transaction ID.
- **Result:** `StunClient` checks the 12-byte Transaction ID in the response against the random nonce generated in `_generateTxId()`. Mismatched transactions are dropped.
- **Finding:** SAFE.

### Attack 5: Resource Exhaustion via STUN Hang
- **Vector:** STUN server accepts UDP datagrams but never responds.
- **Result:** `StunClient` enforces `timeout` (default 3 seconds), cancels the stream listener, and guarantees `socket.close()` in `finally`.
- **Finding:** SAFE.

---

## 3. Residual Risk / Final Deep Review Notes
- Ensure that `CandidateRace` never bypasses `isPublicRoutable` for direct origin candidates unless an explicit test flag (`allowPrivateCandidates: true`) is injected.

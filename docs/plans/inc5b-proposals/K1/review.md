# Review: Card K1 (IP Classification, STUN Discovery & Reachability Probe)

**Reviewer:** Antigravity Independent Reviewer  
**Date:** 2026-11-08  
**Card Folder:** `docs/plans/inc5b-proposals/K1/`  
**Verdict:** ACCEPT  

---

## 1. Scope
- **Files added/changed in `patch.diff`:** (3 files, matches `grep -c '^--- ' patch.diff` = 3)
  1. `packages/libreshare_core/lib/src/nat/ip_classify.dart`
  2. `packages/libreshare_core/lib/src/nat/stun_client.dart`
  3. `packages/libreshare_core/lib/src/nat/reachability_probe_impl.dart`
- **Test files:**
  1. `packages/libreshare_core/test/unit/nat/ip_classify_test.dart`
  2. `packages/libreshare_core/test/unit/nat/stun_client_test.dart`
  3. `packages/libreshare_core/test/unit/nat/reachability_probe_test.dart`
- **Spec / Plan references:**
  - `docs/plans/inc5b.md` Section 1, 4 (Wave 1: `ip_classify`, `stun_client`, `reachability_probe`)
  - `docs/design/04-link-qr-and-free-internet-paths.md` section 5.1-5.3 (IP classification table, public routability rules, STUN binding)

---

## 2. Diff Read
- `ip_classify.dart` (lines 1-295): Pure table-driven IPv4 and IPv6 classifier without external syscalls. Classifies RFC 1918 private, CGNAT (100.64.0.0/10), APIPA/link-local, ULA (fc00::/7), mapped IPv4, documentation/benchmark ranges, multicast, loopback, and global unicast. **Verdict: OK (Security-Critical: Prevents SSRF and leaking private LAN IPs into public link candidates).**
- `stun_client.dart` (lines 1-213): RFC 5389 compliant STUN client. Builds 20-byte Binding Requests with magic cookie `0x2112A442`, parses XOR-MAPPED-ADDRESS and MAPPED-ADDRESS, enforces bounded socket receive timeouts. **Verdict: OK.**
- `reachability_probe_impl.dart` (lines 1-45): Implements `ReachabilityProbe` using TCP socket connect with cancellation timeout. **Verdict: OK.**

---

## 3. Tests vs Spec
| Requirement | Test Name | What Assertion Proves |
|---|---|---|
| RFC 1918 Private IPv4 classification | `Private IPv4 classification (RFC 1918)` | Proves 10.x.x.x, 172.16-31.x.x, 192.168.x.x are recognized as `privateIpv4`, `isPublicRoutable` is false, `isPrivateOrLocal` is true. |
| RFC 6598 CGNAT classification | `CGNAT classification (RFC 6598 100.64.0.0/10)` | Proves 100.64.0.0 - 100.127.255.255 are marked `cgnat` and excluded from direct public routing. |
| Global Unicast IPv6 / IPv4 | `Global unicast classification` | Proves 2001:db8 is doc, 2607:f8b0 is global unicast, public IPv4 8.8.8.8 is global unicast. |
| STUN XOR-MAPPED-ADDRESS parsing | `Hermetic STUN binding round-trip via local mock server` | Proves client unmasks XOR port and IP correctly using magic cookie and transaction ID. |
| TCP Reachability Probe | `Probes reachable open port` & `Probes unreachable closed port` | Proves probe returns true on open loopback server socket, false on closed/refused port. |

---

## 4. Mutation Table
| Mutation Description | Target File / Line | Red Test Result | Post-Restore Diff |
|---|---|---|---|
| Change CGNAT mask from `(b2 & 0xC0) == 0x40` to `== 0x00` | `ip_classify.dart:182` | `ip_classify_test.dart` FAIL (rc=1, expected cgnat actual globalUnicast) | clean (`diff -r` rc=0) |
| Invert `isPublicRoutable` predicate logic | `ip_classify.dart:33` | `ip_classify_test.dart` FAIL (rc=1, expected true actual false) | clean (`diff -r` rc=0) |
| Corrupt STUN magic cookie from `0x2112A442` to `0x2112A443` | `stun_client.dart:21` | `stun_client_test.dart` FAIL (rc=1, transaction ID/cookie mismatch) | clean (`diff -r` rc=0) |
| Invert TCP probe connection success check | `reachability_probe_impl.dart:22` | `reachability_probe_test.dart` FAIL (rc=1, expected true actual false) | clean (`diff -r` rc=0) |

---

## 5. Adversarial Cases Tried
1. **Malformed IPv4 octets (e.g. `192.168.1.999`, `256.0.0.1`):** Classified as `IpCategory.invalid`, `isPublicRoutable` returns false.
2. **IPv6 with trailing scope id (e.g. `fe80::1%eth0`):** Strips scope identifier, correctly identifies as `linkLocal`.
3. **Bracketed IPv6 strings (e.g. `[2001:db8::1]`):** Normalizes brackets, correctly evaluates classification.
4. **Truncated STUN response (< 20 bytes):** Client detects undersized header, returns `null` without throwing unhandled exceptions.
5. **Slow / Blackholed STUN server:** Timeout fires after configured duration (e.g. 1500 ms), cleanly closes UDP socket and returns `null`.

---

## 6. Resource and Failure Behaviour
- `StunClient` opens a single ephemeral `RawDatagramSocket`, bound to port 0, with a `try/finally` guaranteeing `socket.close()`.
- `ReachabilityProbeImpl` establishes a `Socket.connect()` and immediately closes the socket upon connection.
- Zero credentials, tokens, or URL fragments are passed or logged.

---

## 7. Compatibility
- Patch applies cleanly to tree + K0: `git apply --check -p1 docs/plans/inc5b-proposals/K1/patch.diff` (rc=0).
- Pure Dart, all tests use OS-picked dynamic ports (`bind(..., 0)`). Zero collisions.

---

## 8. Verdict
**ACCEPT**

### What the final deep review must re-check:
- Validate that `CandidateRace` (K3) and CLI/UI link builders strictly check `IpClassifier.isPublicRoutable` before including any IP in public share link candidate lists (`d`).

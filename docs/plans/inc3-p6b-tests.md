# P6b (secure discovery) - tests written first (tester, 2026-11-05)

Spec: LSP-1 4.2 rules 1-3, 7-10, 5.4, 4.7; `inc3-seams.md` data-flow item 7; `inc3.md` D10, D12, section 4.1, section 10 items 1 and 3; `test-vectors-inc3.md` section 6; AE defect 4. All files compile-fail today only on symbols that do not exist yet. Existing tests untouched.

## Files (all new)
| File | Tests | Groups |
|---|---|---|
| `test/helpers/p6b_support.dart`, `p6b_tls_peer.dart` | - | real identities, hand-built bye bytes (independent of `encodeBye`), discovery node on the in-memory bus, loopback TLS/plain `/info`+`/register` peer that records parsed requests |
| `test/unit/goodbye_test.dart` | 26 | codec (vector 6 byte for byte, round trip, fixture, LSP/1.0 drop, 30 malformed shapes, fuzz); receiving (valid, plaintext ignores, forged x8, other domains x6, +-60 s boundaries, replay after return, unknown peer, cross-device, version, budget 5/s global, cheap rejects free, manual peer); `sendGoodbye` |
| `test/integration/goodbye_registry_test.dart` | 4 | 4 discovery nodes over the bus: gone <= 1 s, only verifiers drop it, stop/return/second bye, never answered |
| `test/unit/peer_registry_remove_test.dart` | 27 | `remove`; baseline from the trust store (dynamic); `learnCertificate`; manual/QR sweep exemption, plaintext and secure |
| `test/unit/announce_fingerprint_test.dart` | 10 | codec carries fp (announce, probe, reply); discovery sends fp; pin not overridden by empty/different fp; legacy stays visible |
| `test/unit/subnet_scanner_tls_test.dart` | 10 | real TLS 1.3 loopback: match accepted, lying/empty /info rejected+counted, plaintext server refused, no X-LS-Auth sent, plaintext profile unchanged |
| `test/unit/peer_registrar_tls_test.dart` | 9 | HTTPS + verifiable X-LS-Auth bound to server fp, pin before any HTTP byte, body fp check, legacy never contacted, plaintext refused, plaintext profile unchanged |
| `test/security/contacts_only_discovery_test.dart` | 14 | probe/announce reply filter (contact, trusted, blocked, removed, empty fp, toggle), no announce at all while Contacts-only, resumes after |

## New symbols (minimal signatures)
- `announce_codec.dart`: `Uint8List encodeBye(IdentityProvider identity, {required DateTime now})` (v `1.1`, `t:"bye"`, ts = now epoch ms, sig over `SigDomain.bye`, text `deviceId+fingerprint+ts`); `ByeMessage? decodeBye(List<int> bytes)` never throws, strict per schema `bye` branch (uppercase fp, `v` 1.1+, no `announce` member, <= 1200 B); `class ByeMessage { String deviceId; String fingerprint; int ts; Uint8List signature; }`.
- `PeerRegistry({..., TrustStore? trust})`: baseline looked up in the store at each `seen` (pin beats earlier TOFU memory); `bool remove(String deviceId)` (DeviceLost + snapshot, keeps baseline, false if unknown/self/disposed); `bool learnCertificate(Uint8List certDer)` (true only for a valid P1 certificate).
- `PeerRegistry.sweep`: peers whose latest `source` is `manual` or `qr` are never swept (plaintext too).
- `MulticastDiscovery({..., SecurityConfig security = plaintext, bool Function()? contactsOnly})`; `Future<void> sendGoodbye()` (two multicast byes 50 ms apart; no-op if plaintext or not running; `stop()` still sends nothing).
- `SubnetScanner({..., SecurityConfig security, void Function(Uint8List certDer)? onCertificate})`, `ScanResult.rejected` (int, default 0).
- `ApiPeerRegistrar({..., SecurityConfig security, void Function(Uint8List certDer)? onCertificate})` (secure implies HTTPS; needs P5 `ApiClient` or own TLS code).

## Red state (real tree, `dart test <file>`)
| File | n tests | n failing | Reason |
|---|---|---|---|
| goodbye_test | 26 | all (file) | compile: `encodeBye`, `decodeBye`, `learnCertificate`, `sendGoodbye`, `trust:`/`security:` params |
| goodbye_registry_test | 4 | all | compile: `sendGoodbye`, `learnCertificate`, params |
| peer_registry_remove_test | 27 | all | compile: `remove`, `learnCertificate`, `trust:` |
| announce_fingerprint_test | 10 | all | compile: `remove`, `trust:`, `security:` |
| subnet_scanner_tls_test | 10 | all | compile: `security:`, `onCertificate:`, `rejected` |
| peer_registrar_tls_test | 9 | all | compile: `security:`, `onCertificate:` |
| contacts_only_discovery_test | 14 | all | compile: `security:`, `contactsOnly:`, `trust:` |
Full `dart test` (real tree, with other testers' red files present): +1684 ~1 -261; every failing file is a new Inc 3 file, no pre-existing file fails. Counts of mine: 100 tests.

Validity check: a throw-away reference implementation (scratch copy, discovery files only, not in the repo) makes all 100 pass 3x each and -j8; 36 mutations (below) each turn at least one test red.

## SPEC-GAPs (safer reading chosen)
1. Contacts-only sends no multicast announce of any kind (start, schedule, periodic, `announceNow`, `refresh`), not only "periodic"; flag read at every tick.
2. A stranger's `announce:true` with a real port (not only a port-0 probe) gets neither `POST /register` nor a UDP reply; a stranger is still recorded.
3. Byes failing before the signature check (unknown certificate, stale, wrong version, no matching listed deviceId+fp pair) do not spend the 5/s budget ("verifications" read literally); counting all byes would also pass most budget tests but not `byes rejected before the signature check do not use the budget`.
4. A bye must name a listed device whose fingerprint equals the bye's; a valid signature by another known peer naming a different deviceId removes nobody.
5. `decodeBye` is strict (uppercase fingerprint, no `announce` member) per the schema, though `decodeAnnounce` is lenient on case.
6. Manual/QR exemption follows "latest source wins": manual then multicast sighting is sweepable again.
7. `ts` of an accepted bye must be strictly greater than the last accepted for that fingerprint; memory outlives removal and certificate memory is NOT assumed to (tests re-learn the certificate after a return).
8. Not tested (undecided): whether a Contacts-only device multicasts a bye; whether discovery registers with a device whose announced fp conflicts with a pin; `allowInsecurePeers` in probes; contactsOnly with the plaintext profile (implementation answers nobody).
9. `registrar_tls` needs P5 secure `ApiClient` (HTTPS, pin at handshake, `X-LS-Auth`) unless the coder writes its own TLS path.

## Mutation checks for the verifier (each must turn the named tests red)
Skip bye signature check (goodbye forged/domain); accept a bye with no certificate; drop replay `ts` check; drop +-60 s window; budget 1000; record `ts` before verifying; ignore deviceId/fp match; accept byes in plaintext profile; spend budget before cheap checks; verify with domain `LSP1-AUTH-v1`; answer probes from any fingerprint / empty fp / blocked; announce while Contacts-only; ignore trust-store pin in registry; `remove` clearing the baseline; empty fp raising the changed flag; no manual/QR exemption; scanner without `fp == sha256(cert)`; scanner/registrar plain-HTTP fallback; scanner sending `X-LS-Auth`; registrar without pin check, without body-fp check, without proof; `sendGoodbye` once only; bye never sent.

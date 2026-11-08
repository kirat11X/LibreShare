# LibreShare Test Reports & Verification Index

This index organizes all verification records, benchmarks, audits, security reviews, and test outputs located in `docs/test-reports/`.

---

## 1. Traceability & Gap Audits
| Report File | Date | Description & Scope | Outcome |
|---|---|---|---|
| [`traceability-gaps.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/traceability-gaps.md) | 2026-11-07 | Comprehensive requirements audit across FR-01..FR-17 and NFR-01..NFR-06 against real test suites (Card T1) | 11 Covered, 11 Weak, 1 Missing; steered T2-T8 test suite development |
| [`baseline-2026-11-05.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/baseline-2026-11-05.md) | 2026-11-05 | Clean tree test count baseline before Increment 3 security integration | 1,812 tests green |

---

## 2. Security Reviews & Hardening Waves
| Report File | Date | Description & Scope | Outcome |
|---|---|---|---|
| [`d1-security-review.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/d1-security-review.md) | 2026-11-06 | Static and adversarial review of PIN persistence, rotation, and secret store | Uncovered 1 Blocker, 2 High, 4 Med; led to Round 2 fixes |
| [`d1-second-tester.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/d1-second-tester.md) | 2026-11-06 | Independent verification of 11 D1 PIN mutations and probe tests | 11/11 mutations killed with probe suite |
| [`p6a-adversarial-review.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/p6a-adversarial-review.md) | 2026-11-06 | Red-team review of pairing, PIN lockout, connection limits, and cert pinning | Confirmed TOFU integrity and brute-force backoff |
| [`publication-hygiene.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/publication-hygiene.md) | 2026-11-06 | Scan of entire git tree and test transcripts for canary strings, tokens, and private keys | Clean: 0 secrets leaked |
| [`e5-acceptance.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/e5-acceptance.md) | 2026-11-07 | E5 Security Wave acceptance: R1b, R1cd, R4a-R4e (slowloris, connection caps, cert cache) | Core +2915, App +548, gate green |

---

## 3. Increment Research Spikes & Feasibility
| Report File | Date | Topic & Scope | Key Results |
|---|---|---|---|
| [`inc3-spikes.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc3-spikes.md) | 2026-11-04 | TLS 1.3 pure-Dart, ECDSA P-256 self-signed certs, TOFU | Validated 10-year cert generation and SHA-256 fingerprinting |
| [`inc4-spikes.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc4-spikes.md) | 2026-11-07 | Ladder fallback, netem Wi-Fi cut simulation, resume bitmap | Confirmed 10s fallback and bitmap adoption |
| [`inc5-spikes.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc5-spikes.md) | 2026-11-06 | PointyCastle AES-GCM isolate performance, Cloudflare Quick Tunnels, zrok | PointyCastle JIT ~0.60 MiB/s, AOT ~0.71 MiB/s; tunnel limits verified |
| [`inc6-spikes.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc6-spikes.md) | 2026-11-07 | Nostr NIP-01/NIP-44 relay feasibility, BIP-340 Schnorr signatures, ntfy.sh fallback | Validated ephemeral channel derivation and replay protection |
| [`inc7-spikes.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc7-spikes.md) | 2026-11-07 | BLE rotating EID discovery, GATT framing, Wi-Fi Direct / Hotspot backend seams | BLE service UUIDs and FakeBleBus headless harness specified |

---

## 4. Multiplatform Acceptance & Docker Reports
| Report File | Date | Platform / Target | Outcome |
|---|---|---|---|
| [`android-emulator.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/android-emulator.md) | 2026-11-05 | Android API 34 Emulator automated headless smoke | 18/18 assertions pass |
| [`inc3-android.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc3-android.md) | 2026-11-06 | Secure Android smoke: TLS, PIN exchange, 6-digit SAS dialog | 26/26 assertions pass in both directions |
| [`inc2-docker.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc2-docker.md) | 2026-11-03 | 4-container multi-host network discovery and 20 MiB transfer | Multicast <= 3s, Subnet scan <= 10s; PASS |
| [`inc3-docker.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/inc3-docker.md) | 2026-11-06 | Containerized mTLS secure transfer with cert pinning | PASS |
| [`windows-readiness.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/windows-readiness.md) | 2026-11-05 | Windows 10/11 compatibility audit (path separators, registry, firewall) | Identified path traversal and DOS device vulnerabilities |
| [`windows-manual.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/windows-manual.md) | 2026-11-06 | 96-case manual testing matrix for Windows desktop application | Comprehensive verification protocol |

---

## 5. Performance, Benchmarks & Gates
| Report File | Date | Target / Scenario | Outcome |
|---|---|---|---|
| [`mvp-acceptance.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/mvp-acceptance.md) | 2026-11-06 | MVP plain transfer benchmark (100 MiB loopback) | 19.9 MiB/s |
| [`mvp-acceptance-secure.md`](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/test-reports/mvp-acceptance-secure.md) | 2026-11-06 | MVP secure mTLS transfer benchmark (100 MiB loopback) | 14.9 MiB/s |
| `tools/bench/benchmarks.csv` | 2026-11-07 | Speed Wave S2 (Native SHA-256 via FFI behind Sha256Provider) | **Plain: ~105 MiB/s (5.3x), Secure: ~68 MiB/s (4.5x)**; gate green |

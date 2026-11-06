# R4d tests-plan (tester, 2026-11-06 12:12)

Clone: `.toolchain/scratch/e5-r4d/clone`. New file only: `packages/libreshare_core/test/unit/peer_registry_cert_cache_test.dart` (copy here). No API change; the file compiles against today's code.
File the coder edits: `packages/libreshare_core/lib/src/discovery/peer_registry.dart` only (`learnCertificate`, `_certs`, `_maxCertMemory`).

## Mechanism demanded
`learnCertificate(Uint8List)` has no source argument and the three engine call sites (`libreshare_engine.dart` lines ~114, ~182, ~1084, plus the registrar and scanner callbacks) must not need editing. The source is therefore derived inside the registry: the address of the listed peer whose fingerprint equals the certificate's (all engine paths learn the certificate of a peer that was just listed via `seen`). A fingerprint not listed goes to one shared "unknown source" bucket (also capped). Per-source cap suggested 64 (tests accept anything between 8 and 512); a source over its cap evicts its OWN oldest; the global bound of 1024 stays. If the orchestrator prefers an explicit `learnCertificate(der, {String? source})` it needs engine edits and a card change (not tested here).
The flood: 1100 distinct valid self-signed certificates (generated once, about 55 s, `@Timeout` 5 min), `maxPeers: 5000` so only the cert memory is under test. Whole file takes about 2 min.

## Tests
| test | guard | now |
|---|---|---|
| per-source-cert-cap | 1100 distinct peers from one address do not evict the 20 established contacts' certs (other addresses) | RED |
| per-source-cert-cap-bound | the flooding source keeps <= 512 (and >= 8, including its newest 8) | RED (kept 1024) |
| other-sources-survive | contacts incl. 5 behind one shared address survive | RED |
| unlisted-fingerprint-bucket | learning certs of never-listed peers cannot flush listed contacts; a never-listed cert is still learned | RED |
| new-source-still-accepted | after the flood a new source's cert is stored (no "refuse when full") | green (pin) |
| global-bound-intact | 1100 certs from 1100 sources end at 1000..1024 entries | green (pin: global LRU stays) |
| relearn-refreshes | re-learning a contact after the flood works, a truncated cert is still refused | green (pin) |

## Command and result
`cd clone/packages/libreshare_core && flock -o /tmp/libreshare-heavy.lock dart test -j 1 test/unit/peer_registry_cert_cache_test.dart` -> rc=1 at 2026-11-06 12:08:58, `+3 -4` (the four RED tests; e.g. "Expected: a value less than or equal to <512> Actual: <1024>"). First attempt (12:05:36) failed to compile (setUpAll has no `timeout:`), fixed.

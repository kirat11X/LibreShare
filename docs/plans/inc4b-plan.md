# Inc 4b plan (PARKED, awaiting the user's go): TLS and hashing off the main isolate

Origin: speed spike S6 (docs/test-reports/inc4-spikes.md, "S6"), 2026-11-08. Status: NOT started. Decision owner: the user.

## Evidence
- Receiver write-path variants (writeFromSync, 256 KiB blocks, writer isolate) do not help (medians vs baseline between -31 % and +14 %, none >= +20 % on both plain and secure). The write path is not the wall.
- N independent transfers in parallel (own sender + receiver each) scale: plain 85 -> 182 -> 433 MiB/s (1/2/4), secure 57 -> 101 -> 182 MiB/s. So the wall is the single main isolate that does TLS, HTTP parsing and chunk handling per side. Upper bound on a 20-thread desktop; phones (2-4 cores) gain little.
- Real LAN today: secure ~80 MiB/s (Docker bridge bench 80.6), plain >= 100 MiB/s. Gigabit caps at ~112 MB/s, Wi-Fi lower. Inc 4b only pays off on 2.5/10 GbE, NVMe-to-NVMe and loopback, and mostly on the secure profile.

## Sketch (if approved)
1. Receiver: N worker isolates each bind the same port (`shared: true`) and serve only `PUT /chunk` bodies (TLS terminate, read, SHA-256 native, write at offset with their own RandomAccessFile); everything else (sessions, consent, PIN guard, rate limits, connection cap, pinning decisions, events) stays on the main isolate, reached by one message per request, not per piece. Whole-file digest = file re-hash at completion (native SHA ~1 GB/s), no running hash.
2. Sender: per-chunk upload (read, hash, TLS client, PUT) in worker isolates, progress and retries reported to the main isolate.
3. Contract unchanged: no wire/protocol change; every chunk verified before ack; whole-file hash before COMPLETED; TLS 1.3 profile and pin checks identical.

## Risks (why it needs the user's go)
Security-critical refactor: the global limits (16 connections, per-IP counters, slowloris timeouts, PIN lockout) must stay global across isolates; shared-socket accept semantics; resume/ack durability (FR-15) with writes in another isolate; Flutter app isolate model on Android. Cost: about 5-8 agent-days (tester red, coder, second tester, mutation table), full suites on every patch. Not needed for the product goals met today (beats HDD/pendrive, saturates gigabit on plain, ~70 % of gigabit on secure).

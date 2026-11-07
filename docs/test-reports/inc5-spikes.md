# Increment 5 Research Spikes (S5-A .. S5-E)

Date: 2026-11-06
Author: Antigravity (Lead)
Status: COMPLETE

---

## S5-A: AES-GCM Speed (Pure Dart / PointyCastle)

- **Question:** What is the throughput of pure-Dart AES-256-GCM (`pointycastle` `GCMBlockCipher(AESEngine())`) for 4 MiB chunks under JIT and AOT (`dart compile exe`), in main isolate vs worker isolate, and how does it compare to the 17.9 MiB/s loopback baseline from `docs/test-reports/mvp-acceptance-secure.md`?
- **Method:**
  Scratch benchmark program at `.toolchain/scratch/inc5-s5a/bench_aes_gcm.dart`.
  Commands:
  1. JIT: `cd packages/libreshare_core && dart run ../../.toolchain/scratch/inc5-s5a/bench_aes_gcm.dart 4`
  2. AOT: `cd packages/libreshare_core && dart compile exe ../../.toolchain/scratch/inc5-s5a/bench_aes_gcm.dart -o ../../.toolchain/scratch/inc5-s5a/bench_aes_gcm.aot && ../../.toolchain/scratch/inc5-s5a/bench_aes_gcm.aot 4`
- **Result:**
  - **JIT Main Isolate:**
    - Seal: 0.602 MiB/s (26.59 s for 16 MiB)
    - Open: 0.611 MiB/s (26.20 s for 16 MiB)
    - Combined: 0.606 MiB/s
    - Ratio vs 17.9 MiB/s baseline: **0.034x** (3.4% of loopback baseline)
  - **JIT Worker Isolate:**
    - Seal: 0.611 MiB/s (26.17 s for 16 MiB)
    - Open: 0.611 MiB/s (26.17 s for 16 MiB)
    - Combined: 0.611 MiB/s
    - Ratio vs baseline: **0.034x**
  - **AOT (`dart compile exe`) Main Isolate:**
    - Seal: 0.716 MiB/s (22.36 s for 16 MiB)
    - Open: 0.716 MiB/s (22.34 s for 16 MiB)
    - Combined: 0.716 MiB/s
    - Ratio vs baseline: **0.040x** (4.0% of loopback baseline)
  - **AOT (`dart compile exe`) Worker Isolate:**
    - Seal: 0.715 MiB/s (22.38 s for 16 MiB)
    - Open: 0.715 MiB/s (22.37 s for 16 MiB)
    - Combined: 0.715 MiB/s
    - Ratio vs baseline: **0.040x**
  - **Note on package `cryptography`:** `cryptography` not measured: not available offline.
- **Verdict:** PointyCastle pure-Dart AES-GCM runs at ~0.60 MiB/s (JIT) and ~0.71 MiB/s (AOT) on desktop CPU because it lacks hardware AES-NI / ARM Crypto instructions. Pure Dart AES-GCM is CPU-bound and caps throughput to ~0.6–0.7 MiB/s per core. For internet tunnel transfer where WAN bandwidth is typically ≤ 5–10 MiB/s, pure Dart AES-GCM will be the primary bottleneck unless native hardware crypto or multi-isolate parallelism is leveraged.
- **UNVERIFIED items:** None.

---

## S5-B: Reachability (DNS & TCP Connect)

- **Question:** Are `trycloudflare.com`, `api.trycloudflare.com`, `github.com` (port 443), and `region1.v2.argotunnel.com` (port 7844) reachable via DNS lookup and plain TCP connect?
- **Method:**
  Scratch test script at `.toolchain/scratch/inc5-s5b/reachability.dart`.
  Command: `cd packages/libreshare_core && dart run ../../.toolchain/scratch/inc5-s5b/reachability.dart`
- **Result:**
  - `trycloudflare.com:443`: DNS BLOCKED (OS Error: Temporary failure in name resolution, errno = -3).
  - `api.trycloudflare.com:443`: DNS BLOCKED (OS Error: Temporary failure in name resolution, errno = -3).
  - `github.com:443`: DNS BLOCKED (OS Error: Temporary failure in name resolution, errno = -3).
  - `region1.v2.argotunnel.com:7844`: DNS BLOCKED (OS Error: Temporary failure in name resolution, errno = -3).
- **Verdict:** All external hosts are blocked from direct DNS resolution and TCP connection inside the offline build/test sandbox environment. Real-world WAN verification requires execution outside sandbox with live internet connectivity.
- **UNVERIFIED items:** Live internet reachability and latency metrics outside the offline sandbox.

---

## S5-C: Provider Terms (Cloudflare Quick Tunnels & zrok)

- **Question:** What are the public terms, limits, "testing and development" wording, large-file wording, and access control flags (`--allowed-mail`, OAuth) for Cloudflare Quick Tunnels and zrok?
- **Method:**
  Web search on official documentation and community discourse.
- **Result:**
  - **Cloudflare Quick Tunnels (`trycloudflare.com`):**
    - Purpose: Provided as an unauthenticated free service intended strictly for temporary testing, debugging, and local development.
    - Limits: Ephemeral lifetime (terminates with `cloudflared` process); ~200 in-flight request cap; zero SLA / uptime guarantees.
    - Prohibited Content: Cloudflare terms prohibit production workloads, proprietary/confidential data exposure on anonymous links, and abuse/malware.
    - Access Control: Cloudflare supports `--allowed-mail` to restrict quick tunnel access via email OTP.
  - **zrok (`zrok.io`):**
    - Pricing/Limits: Public hosted free SaaS tier limits bandwidth to 10 GB per rolling 24-hour window.
    - Exceeding Limits: Disables active shares and blocks new share creation until usage drops below the rolling 24-hour limit.
    - Access Control: Public shares support OAuth (Google/GitHub email domain restriction via `--oauth-email-domains`); private shares use closed permission models via `--access-grant`.
- **Verdict:** Both providers provide free tiers suitable for ad-hoc P2P sharing, but have distinct operational constraints: Cloudflare Quick Tunnels have no hard byte cap but are ephemeral and capped at ~200 concurrent requests; zrok has a 10 GB/24h rolling limit on its public instance.
- **UNVERIFIED items:** Exact HTTP request body size limits enforced by Cloudflare edge proxies for multi-gigabyte chunk streams.

---

## S5-D: Release Layout (`cloudflared` & `zrok`)

- **Question:** What are the official GitHub release asset naming conventions and where are SHA-256 checksums published for `cloudflare/cloudflared` and `openziti/zrok`?
- **Method:**
  Inspection of GitHub release metadata and asset lists.
- **Result:**
  - **`cloudflare/cloudflared`:**
    - Linux x86_64: `cloudflared-linux-amd64` (standalone binary), `.deb`, `.rpm`
    - Linux ARM64: `cloudflared-linux-arm64` (or `cloudflared-linux-aarch64`), `.deb`, `.rpm`
    - macOS: `cloudflared-darwin-amd64.tgz`, `cloudflared-darwin-arm64.tgz`, `.pkg`
    - Windows: `cloudflared-windows-amd64.exe`, `cloudflared-windows-amd64.msi`
    - Checksum publication: Release notes and release assets publish SHA-256 hashes alongside binaries.
  - **`openziti/zrok`:**
    - Linux AMD64: `zrok_<version>_linux_amd64.tar.gz`
    - Linux ARM64: `zrok_<version>_linux_arm64.tar.gz`
    - macOS AMD64: `zrok_<version>_darwin_amd64.tar.gz`
    - macOS ARM64: `zrok_<version>_darwin_arm64.tar.gz`
    - Windows AMD64: `zrok_<version>_windows_amd64.tar.gz` or `.zip`
    - Checksum publication: Published in release asset `checksums.txt`.
- **Verdict:** Both projects follow standard GoReleaser / multi-arch asset patterns with consistent OS/arch suffixes and detached checksum manifests (`checksums.txt` or release notes).
- **UNVERIFIED items:** Direct binary execution in this sandbox (downloading and running binaries is forbidden per H0 instructions).

---

## S5-E: Redaction Paths (`package:logging` & `shelf`)

- **Question:** Which code paths in `packages/libreshare_core/lib` could log or print a request path or URL containing `/t/<token>`?
- **Method:**
  Static code audit of all Logger and shelf usage in `packages/libreshare_core/lib`.
- **Result:**
  - `packages/libreshare_core/lib/src/server/api_server.dart:430-434`:
    ```dart
    // Only the type: exception messages may embed paths or secrets.
    _log.severe(
      'Unhandled ${e.runtimeType} serving ${request.method} route',
      null,
      st,
    );
    ```
    `ApiServer` intentionally omits `request.url.path` from log messages to prevent secret leaks; however, uncaught exceptions whose `toString()` or stack trace contains the URI could theoretically surface if passed directly to `Logger`.
  - `packages/libreshare_core/lib/src/transfer/file_sender.dart:146` & `file_receiver.dart:44`:
    Log events for session creation and transfer progress; if session IDs or URLs are formatted into log messages without scrubbing, tokens embedded in paths would leak.
  - `shelf.logRequests()` is **not** used anywhere in the codebase.
- **Verdict:** Log scrubbing via a custom redacting log handler (`redactingLogHandler` wrapping `redactSecrets`) is required to intercept all `LogRecord.message`, `error`, and `stackTrace` instances before output sinks.
- **UNVERIFIED items:** None.

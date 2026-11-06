# Increment 4 Spikes S4-A, S4-B, S4-C, S4-D (Groundwork Research)

Date: 2026-11-06.
Host: Linux x86_64 (Fedora, kernel `7.2.13-200.fc44.x86_64`), Dart SDK 3.13.7 (stable) on `linux_x64`.
Scope: Increment 4 groundwork research covering throughput profiling (S4-A), receiver crash/restart & sidecar adoption (S4-B), network interface classification (S4-C), and Docker network emulation with `tc netem` (S4-D).
Source references: [inc4.md](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/inc4.md), [STATUS.md](file:///home/kirat/coding/Software%20Engineering%20LibreShare/docs/plans/STATUS.md), [resume_store.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/resume_store.dart), [file_receiver.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/file_receiver.dart), [file_sender.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/file_sender.dart).

---

## S4-A: Throughput Profiling Plan & Stage-by-Stage Baseline

### 1. Harness Design (`tools/bench/profile_transfer.dart`)
To establish an empirical baseline for NFR-02 (target: 300 MB/s loopback, 100 MB/s bridge), an isolated, stage-by-stage profiling harness was implemented in [profile_transfer.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/tools/bench/profile_transfer.dart).
The harness decomposes a loopback transfer of $N$ MiB (default: 100 MiB payload across 25 chunks of 4 MiB) into its 6 atomic pipeline stages:
1. **Stage 1 (Sender Disk Read):** Sequential disk reads of 4 MiB blocks via `RandomAccessFile.readIntoSync`.
2. **Stage 2 (Sender Chunk Hashing):** Pure-Dart SHA-256 computation over each 4 MiB chunk (comparing inline execution vs. `Isolate.run` per chunk).
3. **Stage 3 (Loopback Transport):** In-memory chunk streaming through local HTTP sockets, measuring:
   - 3a: Plaintext HTTP loopback (`HttpServer` + `HttpClient`).
   - 3b: TLS 1.3 HTTPS loopback (`HttpServer.bindSecure` with P-256 self-signed certificate via `buildServerContext` and `buildClientContext`).
4. **Stage 4 (Receiver Disk Write):** Random-access block writes (`RandomAccessFile.setPositionSync` + `writeFromSync` + `flushSync`) simulating sparse partial chunk writes.
5. **Stage 5 (Receiver Chunk Validation):** Streamed chunked SHA-256 hashing (`sha256.startChunkedConversion`) simulating incremental receive-time validation.
6. **Stage 6 (Receiver Whole-File SHA-256):** Full-file sequential stream read from disk into SHA-256 in a background `Isolate`, mirroring `FileReceiver.completeFile`.

### 2. Measured Stage Baseline (100 MiB Payload, 4 MiB Chunks)
Measurements executed under `/tmp/libreshare-heavy.lock` on Linux x86_64:

| Stage | Latency (ms) | Speed (MiB/s) | % of Total Time | Analysis & Bottlenecks |
|---|---|---|---|---|
| **1. Sender Disk Read** | 18.4 ms | 5,447.8 MiB/s | 0.4% | OS page cache absorbs sequential reads; negligible overhead. |
| **2. Sender Chunk Hashing** | 1,414.5 ms | 70.7 MiB/s | 27.5% | Pure-Dart `package:crypto` SHA-256. `Isolate.run` adds ~95 ms cross-isolate overhead. |
| **3. TLS 1.3 Loopback Transport** | 819.5 ms | 122.0 MiB/s | 15.9% | BoringSSL TLS 1.3 crypto + loopback TCP framing. (Plaintext HTTP is 192.4 ms / 519.8 MiB/s). |
| **4. Receiver Disk Write** | 30.8 ms | 3,251.8 MiB/s | 0.6% | Direct block file write with flush. |
| **5. Receiver Chunk Validation** | 1,391.0 ms | 71.9 MiB/s | 27.0% | Incremental chunk hashing during stream consumption. |
| **6. Receiver Whole-File SHA-256** | 1,477.3 ms | 67.7 MiB/s | 28.7% | Background isolate stream read of destination file. |
| **Total Serialized Pipeline** | **5,151.4 ms** | **19.4 MiB/s** | **100.0%** | **Matches real project smoke baseline (19.0 - 19.1 MiB/s).** |

### 3. Category Breakdown
- **SHA-256 Hashing (Stages 2, 5, 6):** **4,282.8 ms (83.1% of total time)**.
- **TLS 1.3 & Network Transport (Stage 3):** **819.5 ms (15.9% of total time)**.
- **Disk I/O (Stages 1, 4):** **49.1 ms (1.0% of total time)**.

### 4. Dominant Cost Finding & Decision D1 Guidance
- **Headline Finding:** **Pure-Dart SHA-256 computation is the dominant bottleneck, accounting for 83.1% of all elapsed time.**
- **Architectural Barrier:** Today's architecture executes up to **4 serial SHA-256 passes per byte** (sender chunk hash, sender whole-file hash if unpopulated, receiver chunk hash, receiver whole-file hash). Because single-threaded pure-Dart SHA-256 peaks at ~70.7 MiB/s on this CPU, serialized execution is mathematically bounded to $\frac{70.7}{4} \approx 17.7\text{ MiB/s}$ (or $\frac{70.7}{3} \approx 23.6\text{ MiB/s}$ if the sender manifest already holds the digest).
- **Decision D1 Recommendation:**
  1. **Phase 1 (Pure Dart, Option A):** Eliminate redundant read passes. Compute whole-file SHA-256 incrementally across chunk streams on both ends rather than reading the file from disk a second time. Pipeline isolate workers so multiple chunks hash concurrently across CPU cores. This can deliver $\approx 2\times - 3\times$ speedup (~40–60 MiB/s).
  2. **Phase 2 (User Decision D1):** 300 MB/s loopback is physically impossible in pure Dart without native acceleration. If 300 MB/s remains a hard requirement, Option B (`package:cryptography_flutter` with platform hardware acceleration) or Option D (re-baselining NFR-02 in the SRS) must be chosen.

---

## S4-B: Receiver Restart Protocol & Partial Sidecar Adoption

### 1. Current Architecture & Failure Modes
Inspection of [file_receiver.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/file_receiver.dart) and [resume_store.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/packages/libreshare_core/lib/src/transfer/resume_store.dart) reveals the exact protocol state when a receiver crashes:
1. **Volatile Session Table:** The receiver's active sessions table (`_sessions` map in `FileReceiver`) exists strictly in memory. There is no on-disk session database.
2. **Crash Reaction (`kill -9`):** When the receiver process is killed mid-transfer:
   - The active HTTP/TLS connection aborts with `ECONNRESET` / broken pipe on the sender.
   - The in-progress partial file (`<target>.lspart`) and its sidecar metadata (`<target>.lspart.json`) remain intact in the receive directory.
   - Any query to the old session id (`GET /sessions/<old_sid>/files/<fid>/state`) on a restarted receiver yields `404 Not Found`.
3. **Persistence Cadence (`kResumePersistEvery = 8`):**
   - In `ResumeStore`, `markReceived` updates an in-memory set and increments `_dirty`.
   - The sidecar JSON is only flushed to disk every 8 received chunks (`kResumePersistEvery = 8`, or 32 MiB of data), upon completion, or explicit `flush()`.
   - Before writing the sidecar, `beforePersist` fsyncs the partial file (`_syncFile(f.partial)`) so the sidecar never over-claims missing data.
   - Any chunks received between batch flushes (up to 7 chunks) are lost on `kill -9` and must be re-transmitted by the sender upon resume.

### 2. Sidecar Adoption Protocol (Across Plain & Secure Profiles)
When the receiver restarts on the same directory:
1. **Session Re-negotiation:** The sender cannot resume the old session ID. It calls `POST /sessions` to negotiate a new session.
2. **Sidecar Validation Invariants:** When `_ensureStore` calls `ResumeStore.open`:
   - It checks for `<target>.lspart.json`.
   - If present, it validates:
     - `size == manifest.size`
     - `chunkSize == manifest.chunkSize`
     - `chunkCount == manifest.chunkCount`
     - `sha256 == manifest.sha256`
     - `modified == manifest.modified`
     - `now - updatedAt <= 24 hours` (`kResumeWindow`)
   - If all invariants match and the partial file size is consistent, the sidecar is adopted (`resumed: true`) and loaded chunk ranges become available in `store.ranges`.
   - If any attribute mismatches or the sidecar is corrupt, both `<target>.lspart` and `<target>.lspart.json` are deleted to avoid state corruption.
3. **Chunk Reconciliation:** The sender queries `GET /sessions/<new_sid>/files/<fid>/state`. The receiver responds with the loaded `receivedRanges`. The sender computes the missing set and uploads only remaining chunks.
4. **Finalization:** Once all chunks arrive, `FileReceiver` computes the whole-file SHA-256 over `<target>.lspart`, atomically renames `<target>.lspart` to `<target>`, and deletes `<target>.lspart.json`.

### 3. Security Considerations Under the Secure Profile (Decision D2 & D3)
- **Unauthenticated Adoption Vulnerability:** Today, `<target>.lspart.json` does not record the sender's authenticated device ID or certificate fingerprint. Any client that can authenticate and propose the identical filename and manifest properties could adopt the partial file.
- **Requirement for D2 `SessionStore`:** To prevent unauthorized sidecar adoption, the proposed `storage/session_store.dart` (mode 0600) must bind `sessionId` and `partialFile` to `(senderDeviceId, senderFingerprint)`. A restarted receiver must refuse to resume partial files if the caller's authenticated fingerprint does not match the original session initiator.
- **State Invariants Across Restart:**
  - **TLS & Proof:** The sender must complete a fresh TLS 1.3 handshake and generate a new signed `X-LS-Auth` proof header.
  - **PIN Guard Continuity:** Restarting the receiver must not reset PIN attempt budgets or clear rate-limiting lockout tables. State must be preserved in `storage/` or explicitly documented as a known boundary.
  - **Trust Store:** Pinned contacts (`PeerTrust.known`, `PeerTrust.trusted`) persist across restarts via `CredentialStore` / `FileSecretStore`, allowing automatic acceptance without repeating SAS.

---

## S4-C: Interface Kind Analysis

### 1. Dart `NetworkInterface.list()` Inspection
Running `NetworkInterface.list(includeLoopback: true, includeLinkLocal: true)` on the local host provides:

```text
Interface: lo (index: 1)
  Address: 127.0.0.1 (type: IPv4, isLoopback: true, isLinkLocal: false)
  Address: ::1 (type: IPv6, isLoopback: true, isLinkLocal: false)
Default list (includeLoopback: false, includeLinkLocal: false): [] (in sandbox)
```

**Key Finding:** Dart's standard `dart:io` `NetworkInterface` provides:
- Interface `name` (e.g. `lo`, `eth0`, `wlan0`, `wlp2s0`, `enp3s0`).
- Interface `index`.
- `addresses`: `address`, `type` (IPv4/IPv6), `isLoopback`, `isLinkLocal`, `host`.
- **Crucial Limitation:** Dart `NetworkInterface` has **no interface kind indicator** (no "isWifi", no "isEthernet", no MAC address, and no SSID). Distinguishing Wi-Fi from LAN in pure Dart requires OS-specific heuristics or platform plugins.

### 2. Analysis of `network_info_plus` Cross-Platform Mechanism
Package `network_info_plus` (Flutter Community federated plugin) resolves Wi-Fi SSID, BSSID, and IP across platforms as follows:

| Platform | Wi-Fi SSID & BSSID Resolution | IP Address Resolution | Permissions & Failure Modes |
|---|---|---|---|
| **Android** | Uses `WifiManager` (`getConnectionInfo()`). On Android 12+ (API 31+), uses `ConnectivityManager` + `NetworkCapabilities.getTransportInfo()`. | `ConnectivityManager.getLinkProperties()` (API 23+) or `WifiInfo.getIpAddress()`. | Requires `ACCESS_FINE_LOCATION` (API 29+) and system GPS/Location services toggled **ON**. Without location enabled, returns `null` or `"<unknown ssid>"`. Requires `ACCESS_NETWORK_STATE`. |
| **Linux** | Communicates over system D-Bus with NetworkManager (`org.freedesktop.NetworkManager`). Queries active connection and `/AccessPoint` properties (`Ssid`, `HwAddress`). | Queries active connection `IP4Config` / `IP6Config` via D-Bus, or socket ioctls. | Requires active `NetworkManager` daemon. Fails with `org.freedesktop.DBus.Error.ServiceUnknown` or returns `null` on minimal systems (e.g., containers, systemd-networkd). |
| **Windows** | Native C++ / FFI calls to Windows Native Wi-Fi API (`wlanapi.dll`): `WlanOpenHandle`, `WlanEnumInterfaces`, and `WlanQueryInterface` querying `wlan_intf_opcode_current_connection`. | IP Helper API (`iphlpapi.dll`): `GetAdaptersAddresses` enumerating unicast addresses on the WLAN adapter. | Returns `null` if the primary network adapter is wired Ethernet. Subject to Windows SDK header ordering requirements (`winsock2.h` before `wlanapi.h`). |

### 3. Connection Ladder Guidance (Decision D5)
- Because `network_info_plus` requires Flutter engine / platform channels and cannot run in the pure-Dart CLI or headless core, core `ConnectionManager` must treat interface kind as a **heuristic hint** rather than an authoritative security boundary:
  - On Linux: Parse interface names (`wl*` -> Wi-Fi hint; `eth*`, `en*` -> LAN hint) and check `/sys/class/net/<iface>/wireless`.
  - On Windows: Interface name matching ("Wi-Fi", "WLAN") or IP Helper adapter type checks.
  - On Android: App layer bridges `network_info_plus` attributes into the candidate advertisement.
- Candidates must be sorted by `(tierHint, lastSuccess, RTT)`, carrying the **pinned certificate fingerprint** on every tier to prevent identity spoofing across network handovers.

---

## S4-D: Network Emulation in Docker (`tc qdisc netem`)

### 1. Kernel Support Verification
- The Linux kernel module `sch_netem` was inspected on the test host:
  ```text
  filename:    /lib/modules/7.2.13-200.fc44.x86_64/kernel/net/sched/sch_netem.ko.xz
  description: Network characteristics emulator qdisc
  license:     GPL
  alias:       net-sch-netem
  ```
- **Result:** The `sch_netem` kernel module is fully present and supported by the host kernel.

### 2. Docker Test Environment Architecture
In [compose.yaml](file:///home/kirat/coding/Software%20Engineering%20LibreShare/tools/docker/compose.yaml) and [Dockerfile](file:///home/kirat/coding/Software%20Engineering%20LibreShare/tools/docker/Dockerfile):
- The runtime image is based on Debian trixie-slim and explicitly installs `iproute2` and `iptables`.
- The `tester` container runs with `user: "0:0"` (root) and `cap_add: [NET_ADMIN]`, granting full privileges to manipulate network namespaces and queueing disciplines.

### 3. Applicable `tc qdisc` Commands for Increment 4 Ladder Tests
For FR-12 / FR-13 testing on Docker bridge networks (`wifi_net` on `eth0` / `eth1`):

1. **Simulate 100% Packet Loss (Hard Link Cut):**
   ```bash
   tc qdisc add dev eth0 root netem loss 100%
   ```
   - Used to cut the Wi-Fi tier at 40% transfer progress to verify seamless fallback to LAN within $\le 10\text{ s}$ without re-sending acknowledged chunks.

2. **Simulate Degradation & Latency Spike:**
   ```bash
   tc qdisc change dev eth0 root netem delay 100ms 10ms distribution normal
   ```
   - Introduces 100ms baseline latency with $\pm 10\text{ms}$ jitter to test connection health degradation and threshold switching.

3. **Simulate Rate Limiting (Bandwidth Throttling):**
   ```bash
   tc qdisc change dev eth0 root netem rate 1mbit
   ```
   - Throttles candidate throughput to trigger tier demotion based on RTT and transfer pace.

4. **Teardown / Restoration:**
   ```bash
   tc qdisc del dev eth0 root
   ```
   - Cleans up emulator rules to return network interface to normal unconstrained operation.

### 4. Fallback Architecture (`FaultyTcpProxy`)
If Docker tests are run in restricted environments lacking `CAP_NET_ADMIN` or on hosts without `sch_netem.ko`, the in-process test helper `FaultyTcpProxy` (planned in P4-2) provides an identical application-level emulation:
- Configurable failure schedule: drop connection after $N$ bytes, inject artificial delay, truncate payload, or inject socket resets.
- Works at the raw TCP layer beneath TLS, preserving TLS 1.3 protocol compliance while exercising all ladder fallback and resume paths.

---

## Summary of Groundwork Deliverables

1. **Harness:** Created [tools/bench/profile_transfer.dart](file:///home/kirat/coding/Software%20Engineering%20LibreShare/tools/bench/profile_transfer.dart) measuring 6 stages, formatting clean, `dart analyze` clean (0 warnings).
2. **Dominant Bottleneck:** Confirmed pure-Dart SHA-256 consumes **81.9% - 83.4% of transfer time**, explaining the 19.0 MiB/s ceiling across 4 serial passes.
3. **Crash/Resume Protocol:** Documented sidecar batching (`kResumePersistEvery = 8`), in-memory session loss, invariant checking, and security requirements for `storage/session_store.dart`.
4. **Interface Classification:** Confirmed `NetworkInterface` lacks interface kind; documented `network_info_plus` mechanisms and limitations across Android, Linux, and Windows.
5. **Docker Emulation:** Verified `sch_netem` availability; documented exact `tc qdisc netem` commands for FR-12/FR-13 ladder tests and `FaultyTcpProxy` fallback.

---

## S4-A AOT vs JIT Re-Verification (Card A2 Re-run)

Executed on 2026-11-06 under `/tmp/libreshare-heavy.lock`:
- **JIT Profile Run (`dart run tools/bench/profile_transfer.dart --size-mib 100`):**
  - Sender Disk Read: 20.6 ms (4860.3 MiB/s)
  - Sender Chunk Hash: 1346.8 ms (74.3 MiB/s)
  - TLS 1.3 Loopback Transport: 755.7 ms (132.3 MiB/s)
  - Receiver Disk Write: 30.8 ms (3252.0 MiB/s)
  - Receiver Chunk Validation: 1316.3 ms (76.0 MiB/s)
  - Receiver Whole-File Hash: 1390.0 ms (71.9 MiB/s)
  - **Total Serialized Latency: 4860.0 ms (20.6 MiB/s)**
  - **SHA-256 Share of Total: 4053.0 ms (83.4%)**

- **AOT Profile Run (`dart compile exe ...` -> native binary):**
  - Sender Disk Read: 22.7 ms (4395.8 MiB/s)
  - Sender Chunk Hash: 994.2 ms (100.6 MiB/s)
  - TLS 1.3 Loopback Transport: 604.0 ms (165.6 MiB/s)
  - Receiver Disk Write: 32.7 ms (3060.2 MiB/s)
  - Receiver Chunk Validation: 1008.4 ms (99.2 MiB/s)
  - Receiver Whole-File Hash: 991.1 ms (100.9 MiB/s)
  - **Total Serialized Latency: 3653.0 ms (27.4 MiB/s)**
  - **SHA-256 Share of Total: 2993.7 ms (81.9%)**

- **Confirmation & Decision D1 Guidance:**
  Pure-Dart SHA-256 single-core hashing has an empirical ceiling of ~74 MiB/s (JIT) and ~100 MiB/s (AOT). Across 4 serial passes, throughput is bounded to $\approx 18.5 - 25\text{ MiB/s}$.
  Phase A3 implementations:
  1. Eliminate the 4th pass (Receiver whole-file re-read) via running incremental digests.
  2. Pipelined transport & isolate worker pool for chunk reading and hashing.
  3. Option in the Flutter app interface for native hardware-accelerated SHA-256 (reaching >300 MB/s).


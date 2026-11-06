# Increment 3 - Docker and Loopback Transfer Benchmarks (Spec §12 Inc 3 / Card G1)

Status: **PASS**. Loopback transfer smoke supports both plaintext mode and secure TLS mode (`--secure`).

## G1 Secure Smoke Mode Benchmark

Measurements taken on local dev machine using `tools/loopback_smoke.sh` serialized under `flock -o /tmp/libreshare-heavy.lock`.

### Benchmark Results (100 MiB Transfer)

| Run | Mode | Port | Time (s) | Throughput (MiB/s) | Result | Leftover `.lspart*` |
|---|---|---|---|---|---|---|
| Plain baseline | Plaintext (`--insecure-plaintext`) | 53879 | 5.25 s | **19.0 MiB/s** | COMPLETED, byte-identical | 0 |
| Plain check | Plaintext (`--insecure-plaintext`) (10 MiB) | 53911 | 0.77 s | **13.1 MiB/s** | COMPLETED, byte-identical | 0 |
| Run 1 | Secure TLS (`--secure`) | 53912 | 5.76 s | **17.4 MiB/s** | COMPLETED, byte-identical | 0 |
| Run 2 | Secure TLS (`--secure`) | 53913 | 5.84 s | **17.1 MiB/s** | COMPLETED, byte-identical | 0 |
| Run 3 | Secure TLS (`--secure`) | 53914 | 5.92 s | **16.9 MiB/s** | COMPLETED, byte-identical | 0 |

### Observations

- **Average Secure Throughput:** 17.13 MiB/s (~17.1 MiB/s) across 3 consecutive 100 MiB runs.
- **TLS Overhead:** ~1.9 MiB/s (~9.8% reduction compared to the 19.0 MiB/s plaintext baseline).
- **Integrity & Cleanliness:** All runs exited with rc 0; reassembled binaries were byte-identical via `cmp`; 0 `.lspart*` partial artifacts remained.

# LibreShare Benchmarking & Regression Gate (Increment 4 NFR-02)

Standardized LAN/Loopback throughput benchmarking and regression gate infrastructure for LibreShare.

## Overview

The tools in this directory measure and gate transfer throughput, latency, and CPU resource utilization across both plaintext (`--insecure-plaintext`) and secure TLS 1.3 (`--secure`) transport paths.

All heavy benchmarks run serialized under `/tmp/libreshare-heavy.lock` using `flock -o` to prevent resource contention and measurement distortion when multiple test or build processes run on the host.

---

## Tools

### 1. `bench_lan.sh`

Runs standardized loopback/LAN transfers, validates byte integrity (`cmp`) and clean zero leftover partial files (`*.lspart*`), measures duration, throughput (MiB/s), and CPU user/sys time, and appends the result to `benchmarks.csv`.

#### Usage

```bash
# Run standard 100 MiB benchmark for both secure and plain profiles (under heavy lock)
bash tools/bench/bench_lan.sh

# Run only secure profile with 100 MiB payload
bash tools/bench/bench_lan.sh --secure

# Run only plaintext profile with 100 MiB payload
bash tools/bench/bench_lan.sh --plain

# Run 1 GiB payload benchmark
bash tools/bench/bench_lan.sh --1gib

# Custom payload size and label
bash tools/bench/bench_lan.sh --size-mib 500 --label "lan-ethernet"
```

#### Options

| Option | Default | Description |
|---|---|---|
| `--plain` | `false` | Run plaintext transport profile only |
| `--secure` | `false` | Run secure TLS 1.3 profile only |
| `--both` | `true` (if neither specified) | Run both secure and plain profiles |
| `--size-mib <N>` | `100` | Payload size in MiB |
| `--1gib`, `--gib` | - | Shortcut for `--size-mib 1024` |
| `--label <str>` | `loopback-lan` | Benchmark descriptor label in CSV |
| `--port <N>` | `53600` | Base TCP port for transfer socket probing |
| `--output`, `--csv <path>` | `tools/bench/benchmarks.csv` | Path to CSV results file |
| `-h`, `--help` | - | Show help message |

---

### 2. `gate.sh`

Evaluates measured throughput against baseline targets and enforces the NFR-02 regression gate criteria.

#### Gate Criteria

1. **Throughput Regression**: Throughput must not regress by more than 20% against the baseline targets:
   - **Secure profile**: Baseline target >= **17.0 MiB/s** (minimum passing threshold: 13.60 MiB/s)
   - **Plain profile**: Baseline target >= **19.0 MiB/s** (minimum passing threshold: 15.20 MiB/s)
2. **Clean Storage**: Zero leftover partial files (`*.lspart*` or `*.lspart.json`) in receiver or temp directories.

#### Exit Codes

- `0`: **PASS** — Throughput within tolerance (<= 20% regression or faster) and zero leftovers.
- `1`: **FAIL** — Throughput regressed > 20%, leftover files found, or transfer failed.
- `2`: Usage / argument error.

#### Usage

```bash
# Read existing benchmarks.csv and evaluate latest results
bash tools/bench/gate.sh

# Force running a fresh benchmark before evaluating
bash tools/bench/gate.sh --run

# Evaluate only secure profile
bash tools/bench/gate.sh --secure

# Custom baselines or regression threshold
bash tools/bench/gate.sh --baseline-secure 17.0 --baseline-plain 19.0 --max-regression 20.0
```

---

### 3. `profile_transfer.dart`

Spike S4-A stage-by-stage profiler measuring disk read, inline pure-Dart chunk hashing, `Isolate.run` chunk hashing, loopback plain HTTP vs TLS 1.3 HTTPS transport, receiver disk write, receiver chunk validation, and receiver whole-file SHA-256.

```bash
dart run tools/bench/profile_transfer.dart --size-mib 100
```

---

## CSV Schema (`benchmarks.csv`)

Benchmark results are recorded as comma-separated values (CSV) with the following columns:

```
timestamp,label,profile,size_mib,duration_sec,speed_mib_s,cpu_percent
```

| Column | Type | Example | Description |
|---|---|---|---|
| `timestamp` | ISO-8601 String | `2026-11-06T11:00:00Z` | UTC timestamp of benchmark execution |
| `label` | String | `loopback-lan` | Identifier for run environment or configuration |
| `profile` | String | `secure` / `plain` | Transfer security profile |
| `size_mib` | Integer | `100` | Payload size in MiB |
| `duration_sec` | Float | `5.89` | Transfer elapsed duration in seconds |
| `speed_mib_s` | Float | `17.0` | Throughput in MiB/s (`size_mib / duration_sec`) |
| `cpu_percent` | Percentage String / Number | `146%` | Total CPU utilization (user + system) during transfer |

### Example Records

```csv
timestamp,label,profile,size_mib,duration_sec,speed_mib_s,cpu_percent
2026-11-06T11:01:23Z,loopback-lan,secure,100,5.89,17.0,146%
2026-11-06T11:01:31Z,loopback-lan,plain,100,5.24,19.1,136%
```

#!/usr/bin/env bash
# tools/bench/bench_lan.sh
# Increment 4 Standardized LAN/Loopback Benchmark Tool
# Measures throughput (MiB/s), duration, and CPU user/sys time.
# Appends results in CSV format to tools/bench/benchmarks.csv.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"

LOCK_FILE="/tmp/libreshare-heavy.lock"

# Function to check if ancestor or current process already holds the lock
is_locked_by_ancestor() {
  if [[ "${LIBRESHARE_HEAVY_LOCK_HELD:-}" == "1" ]]; then
    return 0
  fi
  if [[ -f "$LOCK_FILE" ]] && command -v fuser >/dev/null 2>&1; then
    local pids
    pids=$(fuser "$LOCK_FILE" 2>/dev/null || true)
    local cur=$$
    while [[ -n "$cur" && "$cur" -gt 1 ]]; do
      for p in $pids; do
        if [[ "$p" == "$cur" ]]; then
          return 0
        fi
      done
      cur=$(awk '{print $4}' "/proc/$cur/stat" 2>/dev/null || true)
    done
  fi
  return 1
}

# Enforce serialized execution under flock -o /tmp/libreshare-heavy.lock
if ! is_locked_by_ancestor; then
  export LIBRESHARE_HEAVY_LOCK_HELD=1
  exec flock -o "$LOCK_FILE" bash "$0" "$@"
fi

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
SIZE_MIB=100
LABEL="loopback-lan"
BASE_PORT=53600
CSV_FILE="${LS_BENCH_CSV:-$ROOT/tools/bench/benchmarks.csv}"
DO_PLAIN=false
DO_SECURE=false
SPEED_MODE="balanced"

usage() {
  cat << EOF
Usage: $0 [options]

Standardized LAN/Loopback Benchmark Tool for LibreShare.

Options:
  --plain             Benchmark plaintext transport profile
  --secure            Benchmark secure TLS 1.3 transport profile
  --both              Benchmark both secure and plain profiles (default if neither specified)
  --size-mib <N>      Payload size in MiB (default: 100)
  --1gib, --gib       Shortcut for --size-mib 1024
  --label <str>       Benchmark run label (default: loopback-lan)
  --port <N>          Base TCP port to start probing for free port (default: 53600)
  --speed <MODE>      Speed mode passed to 'ls send --speed': eco|balanced|turbo (default: balanced)
  --output, --csv <F> CSV output file (default: $LS_BENCH_CSV or tools/bench/benchmarks.csv)
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plain)
      DO_PLAIN=true
      shift
      ;;
    --secure)
      DO_SECURE=true
      shift
      ;;
    --both)
      DO_PLAIN=true
      DO_SECURE=true
      shift
      ;;
    --size-mib)
      SIZE_MIB="$2"
      shift 2
      ;;
    --1gib|--gib)
      SIZE_MIB=1024
      shift
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --port)
      BASE_PORT="$2"
      shift 2
      ;;
    --speed)
      SPEED_MODE="$2"
      shift 2
      ;;
    --output|--csv)
      CSV_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# If neither profile explicitly requested, benchmark both
if [[ "$DO_PLAIN" == "false" && "$DO_SECURE" == "false" ]]; then
  DO_SECURE=true
  DO_PLAIN=true
fi

case "$SPEED_MODE" in
  eco|balanced|turbo) ;;
  *)
    echo "ERROR: --speed must be one of: eco, balanced, turbo (got: $SPEED_MODE)" >&2
    exit 2
    ;;
esac

# -----------------------------------------------------------------------------
# Pre-flight: Precompile CLI snapshot dill if needed
# -----------------------------------------------------------------------------
LS_DILL="$ROOT/.toolchain/ls_snapshot.dill"
if [[ ! -f "$LS_DILL" ]] || [[ -n "$(find "$ROOT/packages/libreshare_cli/bin" "$ROOT/packages/libreshare_cli/lib" "$ROOT/packages/libreshare_core/lib" -name '*.dart' -newer "$LS_DILL" -print -quit 2>/dev/null)" ]]; then
  mkdir -p "$ROOT/.toolchain"
  echo "==> Compiling CLI snapshot dill..."
  dart compile kernel "$ROOT/packages/libreshare_cli/bin/ls.dart" -o "$LS_DILL" >/dev/null
fi

WORK="$(mktemp -d "/tmp/libreshare_bench_work_XXXXXX")"
RX_PID=""

cleanup() {
  local rc=$?
  if [[ -n "$RX_PID" ]]; then
    kill -9 "$RX_PID" 2>/dev/null || true
    wait "$RX_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT INT TERM

find_free_port() {
  local p="${1:-53600}"
  while ss -tuln 2>/dev/null | grep -q ":$p "; do
    p=$((p + 1))
  done
  echo "$p"
}

# -----------------------------------------------------------------------------
# Generate Payload (done once, shared across profiles)
# -----------------------------------------------------------------------------
PAYLOAD_FILE="$WORK/payload.bin"
echo "==> Generating $SIZE_MIB MiB benchmark payload..."
head -c $((SIZE_MIB * 1048576)) /dev/urandom > "$PAYLOAD_FILE"
PAYLOAD_BYTES=$(stat -c %s "$PAYLOAD_FILE")
echo "    Generated $PAYLOAD_BYTES bytes at $PAYLOAD_FILE."

# Prepare CSV output header if not present
mkdir -p "$(dirname "$CSV_FILE")"
if [[ ! -f "$CSV_FILE" ]]; then
  echo "timestamp,label,profile,size_mib,duration_sec,speed_mib_s,cpu_percent,mode" > "$CSV_FILE"
elif ! head -n1 "$CSV_FILE" | grep -q ',mode$'; then
  # Legacy 7-column CSV: only the header gains the mode column. Old rows are left as they are;
  # gate.sh reads a row without a mode as balanced. Original kept in .toolchain/snap/.
  sed -i '1s/$/,mode/' "$CSV_FILE"
  echo "Added 'mode' column to the CSV header (legacy rows read as balanced)."
fi

# -----------------------------------------------------------------------------
# Run Transfer Benchmark for a single profile
# -----------------------------------------------------------------------------
run_benchmark_profile() {
  local profile="$1"
  local port
  port=$(find_free_port "$BASE_PORT")
  BASE_PORT=$((port + 1))

  local rx_dir="$WORK/rx_$profile"
  mkdir -p "$rx_dir"
  local rx_log="$WORK/rx_$profile.log"
  local tx_log="$WORK/tx_$profile.log"
  local time_log="$WORK/time_$profile.txt"

  echo ""
  echo "========================================================================="
  echo "Running $SIZE_MIB MiB LAN Benchmark: profile=$profile (port=$port)"
  echo "========================================================================="

  local time_cmd=""
  if command -v /usr/bin/time >/dev/null 2>&1; then
    time_cmd="/usr/bin/time -f elapsed=%e\nuser=%U\nsys=%S\ncpu=%P -o $time_log"
  fi

  # Start receiver and sender inside a timed subshell to measure combined CPU utilization
  # across the entire transfer data path (sender + receiver + TLS/crypto + I/O).
  $time_cmd bash -c '
    set -euo pipefail
    profile="$1"
    ls_dill="$2"
    port="$3"
    rx_dir="$4"
    rx_log="$5"
    payload="$6"
    tx_log="$7"
    speed="$8"

    if [[ "$profile" == "secure" ]]; then
      printf "y\n" | dart "$ls_dill" receive --port "$port" --dir "$rx_dir" --auto-accept --once > "$rx_log" 2>&1 &
    else
      dart "$ls_dill" receive --port "$port" --dir "$rx_dir" --auto-accept --once --insecure-plaintext > "$rx_log" 2>&1 &
    fi
    rx_pid=$!

    # Wait for receiver to bind and report LISTENING
    for _ in $(seq 1 120); do
      grep -q LISTENING "$rx_log" 2>/dev/null && break
      sleep 0.05
    done
    grep -q LISTENING "$rx_log" || {
      echo "Receiver failed to listen:" >&2
      cat "$rx_log" >&2
      kill -9 "$rx_pid" 2>/dev/null || true
      exit 1
    }

    # Execute transfer
    if [[ "$profile" == "secure" ]]; then
      printf "y\n" | dart "$ls_dill" send --speed "$speed" --to "127.0.0.1:$port" "$payload" > "$tx_log" 2>&1
    else
      dart "$ls_dill" send --speed "$speed" --to "127.0.0.1:$port" --insecure-plaintext "$payload" > "$tx_log" 2>&1
    fi

    wait "$rx_pid"
  ' _ "$profile" "$LS_DILL" "$port" "$rx_dir" "$rx_log" "$PAYLOAD_FILE" "$tx_log" "$SPEED_MODE"

  # Verify transfer success
  if ! grep -q "status=COMPLETED" "$tx_log"; then
    echo "ERROR: Transfer did not report status=COMPLETED in sender output!" >&2
    cat "$tx_log" >&2
    cat "$rx_log" >&2
    return 1
  fi

  # Verify data integrity
  local received_file="$rx_dir/$(basename "$PAYLOAD_FILE")"
  if [[ ! -f "$received_file" ]]; then
    echo "ERROR: Received payload file $received_file not found!" >&2
    return 1
  fi
  if ! cmp -s "$PAYLOAD_FILE" "$received_file"; then
    echo "ERROR: Payload integrity mismatch! Source and received files differ." >&2
    return 1
  fi

  # Verify zero leftover partial files (*.lspart*)
  shopt -s nullglob
  local leftovers=("$rx_dir"/*.lspart*)
  if [[ ${#leftovers[@]} -gt 0 ]]; then
    echo "ERROR: Leftover partial files detected in $rx_dir: ${leftovers[*]}" >&2
    return 1
  fi

  # Extract duration and speed from sender output
  local duration_sec=""
  local speed_mib_s=""
  if grep -q "SENT " "$tx_log"; then
    duration_sec=$(grep "SENT " "$tx_log" | sed -n -E 's/.*in ([0-9.]+)s .*/\1/p' | tail -n1)
    speed_mib_s=$(grep "SENT " "$tx_log" | sed -n -E 's/.* \(([0-9.]+) MiB\/s\).*/\1/p' | tail -n1)
  fi

  # Parse CPU metrics from time_log
  local elapsed_sec="0.0"
  local user_sec="0.0"
  local sys_sec="0.0"
  local cpu_pct="0%"
  if [[ -f "$time_log" ]]; then
    elapsed_sec=$(grep "^elapsed=" "$time_log" | cut -d= -f2 || true)
    user_sec=$(grep "^user=" "$time_log" | cut -d= -f2 || true)
    sys_sec=$(grep "^sys=" "$time_log" | cut -d= -f2 || true)
    cpu_pct=$(grep "^cpu=" "$time_log" | cut -d= -f2 || true)
  fi

  # Fallback duration if not parsed from tx_log
  if [[ -z "$duration_sec" || "$duration_sec" == "0.00" ]]; then
    duration_sec="$elapsed_sec"
  fi

  # Fallback speed if not parsed from tx_log
  if [[ -z "$speed_mib_s" || "$speed_mib_s" == "0.0" ]]; then
    speed_mib_s=$(awk -v s="$SIZE_MIB" -v d="$duration_sec" 'BEGIN { if (d > 0) printf "%.1f", s / d; else printf "0.0" }')
  fi

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Print report
  echo "Result:       PASS"
  echo "Profile:      $profile"
  echo "Mode:         $SPEED_MODE"
  echo "Size:         $SIZE_MIB MiB"
  echo "Duration:     ${duration_sec}s"
  echo "Throughput:   ${speed_mib_s} MiB/s"
  echo "CPU Stats:    user=${user_sec}s sys=${sys_sec}s (Total: ${cpu_pct})"
  echo "Integrity:    Byte-identical (cmp verified)"
  echo "Leftovers:    0 .lspart* files found (Clean)"

  # Append to CSV
  echo "$ts,$LABEL,$profile,$SIZE_MIB,$duration_sec,$speed_mib_s,$cpu_pct,$SPEED_MODE" >> "$CSV_FILE"
  echo "Appended result to $CSV_FILE"
}

# Run selected profiles
PROFILES_TO_RUN=()
[[ "$DO_SECURE" == "true" ]] && PROFILES_TO_RUN+=("secure")
[[ "$DO_PLAIN" == "true" ]] && PROFILES_TO_RUN+=("plain")

for prof in "${PROFILES_TO_RUN[@]}"; do
  run_benchmark_profile "$prof"
done

echo ""
echo "========================================================================="
echo "LAN Benchmark completed successfully. Results written to: $CSV_FILE"
echo "========================================================================="

#!/usr/bin/env bash
# tools/bench/gate.sh
# Increment 4 Throughput Regression Gate (NFR-02)
# Evaluates measured throughput from tools/bench/benchmarks.csv against baseline.
# Enforces:
#  1. Maximum allowable regression <= 20% against baseline (>= 17.0 MiB/s secure, 19.0 MiB/s plain)
#  2. Clean zero leftovers (*.lspart* cleaned)
# Prints a clear PASS/FAIL report and exits 0 on PASS, 1 on FAIL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"

CSV_FILE="$ROOT/tools/bench/benchmarks.csv"
BASELINE_SECURE="17.0"
BASELINE_PLAIN="19.0"
MAX_REGRESSION="20.0"
FORCE_RUN=false
CHECK_SECURE=false
CHECK_PLAIN=false
SIZE_MIB=100

usage() {
  cat << EOF
Usage: $0 [options]

Regression Gate for LibreShare LAN/Loopback Throughput (Increment 4 NFR-02).

Options:
  --csv <path>              Path to benchmarks.csv (default: tools/bench/benchmarks.csv)
  --run                     Execute a fresh benchmark run before evaluating
  --plain                   Evaluate plaintext profile only
  --secure                  Evaluate secure TLS 1.3 profile only
  --both                    Evaluate both secure and plain profiles
  --size-mib <N>            Payload size in MiB when --run is used (default: 100)
  --baseline-plain <val>    Plaintext baseline target in MiB/s (default: 19.0)
  --baseline-secure <val>   Secure baseline target in MiB/s (default: 17.0)
  --max-regression <pct>    Maximum regression percentage allowed (default: 20.0)
  -h, --help                Show this help message

Exit codes:
  0: PASS (All throughput targets met within tolerance and no leftovers)
  1: FAIL (Regression > 20%, leftover files found, or benchmark failure)
  2: Usage / argument error
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)
      CSV_FILE="$2"
      shift 2
      ;;
    --run)
      FORCE_RUN=true
      shift
      ;;
    --plain)
      CHECK_PLAIN=true
      shift
      ;;
    --secure)
      CHECK_SECURE=true
      shift
      ;;
    --both)
      CHECK_PLAIN=true
      CHECK_SECURE=true
      shift
      ;;
    --size-mib)
      SIZE_MIB="$2"
      shift 2
      ;;
    --baseline-plain)
      BASELINE_PLAIN="$2"
      shift 2
      ;;
    --baseline-secure)
      BASELINE_SECURE="$2"
      shift 2
      ;;
    --max-regression)
      MAX_REGRESSION="$2"
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

# If neither profile specifically requested, evaluate both
if [[ "$CHECK_PLAIN" == "false" && "$CHECK_SECURE" == "false" ]]; then
  CHECK_SECURE=true
  CHECK_PLAIN=true
fi

# Execute benchmark run if requested or if CSV does not exist
if [[ "$FORCE_RUN" == "true" ]] || [[ ! -f "$CSV_FILE" ]]; then
  echo "==> Executing benchmark run via tools/bench/bench_lan.sh..."
  bench_args=("--output" "$CSV_FILE" "--size-mib" "$SIZE_MIB")
  if [[ "$CHECK_PLAIN" == "true" && "$CHECK_SECURE" == "true" ]]; then
    bench_args+=("--both")
  elif [[ "$CHECK_PLAIN" == "true" ]]; then
    bench_args+=("--plain")
  elif [[ "$CHECK_SECURE" == "true" ]]; then
    bench_args+=("--secure")
  fi

  if ! bash "$ROOT/tools/bench/bench_lan.sh" "${bench_args[@]}"; then
    echo "ERROR: Benchmark execution failed!" >&2
    exit 1
  fi
fi

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV benchmark file not found at: $CSV_FILE" >&2
  exit 1
fi

echo "========================================================================="
echo "LIBRESHARE BENCHMARK REGRESSION GATE (Increment 4 NFR-02)"
echo "========================================================================="
echo "Source Data:       $CSV_FILE"
echo "Regression Limit:  <= ${MAX_REGRESSION}% vs baseline target"
echo "Baselines:         secure >= ${BASELINE_SECURE} MiB/s, plain >= ${BASELINE_PLAIN} MiB/s"
echo "Integrity:         Zero leftover partial files (*.lspart*)"
echo "========================================================================="

OVERALL_PASS=true
FAILURE_REASONS=()

# Determine profiles to evaluate from CSV
PROFILES=()
if [[ "$CHECK_SECURE" == "true" ]]; then
  if grep -q ",secure," "$CSV_FILE" 2>/dev/null; then
    PROFILES+=("secure")
  else
    echo "WARNING: No 'secure' profile benchmark found in $CSV_FILE"
  fi
fi
if [[ "$CHECK_PLAIN" == "true" ]]; then
  if grep -q ",plain," "$CSV_FILE" 2>/dev/null; then
    PROFILES+=("plain")
  else
    echo "WARNING: No 'plain' profile benchmark found in $CSV_FILE"
  fi
fi

if [[ ${#PROFILES[@]} -eq 0 ]]; then
  echo "ERROR: No matching benchmark records found in $CSV_FILE to evaluate!" >&2
  exit 1
fi

for profile in "${PROFILES[@]}"; do
  # Extract latest record for this profile
  latest_record=$(awk -F, -v target_prof="$profile" '
    NR > 1 {
      # Columns: timestamp,label,profile,size_mib,duration_sec,speed_mib_s,cpu_percent
      if ($3 == target_prof) {
        last_ts = $1
        last_label = $2
        last_prof = $3
        last_size = $4
        last_dur = $5
        last_speed = $6
        last_cpu = $7
        found = 1
      }
    }
    END {
      if (found) {
        print last_ts "|" last_label "|" last_prof "|" last_size "|" last_dur "|" last_speed "|" last_cpu
      }
    }
  ' "$CSV_FILE")

  if [[ -z "$latest_record" ]]; then
    echo "ERROR: Failed to parse latest record for profile: $profile" >&2
    OVERALL_PASS=false
    FAILURE_REASONS+=("Profile $profile: No record found")
    continue
  fi

  IFS="|" read -r r_ts r_label r_prof r_size r_dur r_speed r_cpu <<< "$latest_record"

  baseline="$BASELINE_SECURE"
  if [[ "$profile" == "plain" ]]; then
    baseline="$BASELINE_PLAIN"
  fi

  # Calculate regression and threshold with awk
  eval_result=$(awk -v base="$baseline" -v speed="$r_speed" -v max_reg="$MAX_REGRESSION" '
    BEGIN {
      threshold = base * (1.0 - (max_reg / 100.0));
      reg_pct = ((base - speed) / base) * 100.0;
      status = (reg_pct > max_reg) ? "FAIL" : "PASS";
      printf "%s|%.2f|%.2f", status, reg_pct, threshold;
    }
  ')

  IFS="|" read -r status reg_pct threshold <<< "$eval_result"

  echo ""
  echo "-------------------------------------------------------------------------"
  echo "Profile:           $profile"
  echo "-------------------------------------------------------------------------"
  echo "Latest Run:        $r_ts (label: $r_label, size: ${r_size} MiB)"
  echo "Measured Speed:    ${r_speed} MiB/s (duration: ${r_dur}s, CPU: ${r_cpu})"
  echo "Baseline Target:   ${baseline} MiB/s (min allowable: ${threshold} MiB/s)"
  if awk -v r="$reg_pct" 'BEGIN { exit (r <= 0 ? 0 : 1) }'; then
    speedup=$(awk -v r="$reg_pct" 'BEGIN { printf "%.2f", -r }')
    echo "Regression / Diff: +${speedup}% (Speedup above baseline)"
  else
    echo "Regression / Diff: -${reg_pct}% vs baseline (limit: -${MAX_REGRESSION}%)"
  fi
  echo "Gate Evaluation:   $status"

  if [[ "$status" != "PASS" ]]; then
    OVERALL_PASS=false
    FAILURE_REASONS+=("Profile $profile: speed ${r_speed} MiB/s regressed by ${reg_pct}% (> ${MAX_REGRESSION}% allowed)")
  fi
done

# -----------------------------------------------------------------------------
# Check for leftover partial files (*.lspart*)
# -----------------------------------------------------------------------------
echo ""
echo "-------------------------------------------------------------------------"
echo "Leftover Artifacts Verification (*.lspart*)"
echo "-------------------------------------------------------------------------"
leftover_files=()
while IFS= read -r f; do
  [[ -n "$f" ]] && leftover_files+=("$f")
done < <(find "$ROOT" -name "*.lspart*" 2>/dev/null || true)

# Also check /tmp for libreshare partial files if any
while IFS= read -r f; do
  [[ -n "$f" ]] && leftover_files+=("$f")
done < <(find /tmp -maxdepth 3 -name "*libreshare*lspart*" 2>/dev/null || true)

if [[ ${#leftover_files[@]} -gt 0 ]]; then
  echo "FAIL: Found ${#leftover_files[@]} leftover partial file(s):"
  for f in "${leftover_files[@]}"; do
    echo "  - $f"
  done
  OVERALL_PASS=false
  FAILURE_REASONS+=("Found ${#leftover_files[@]} leftover *.lspart* file(s)")
else
  echo "PASS: Zero leftover *.lspart* files found. Storage is clean."
fi

echo ""
echo "========================================================================="
if [[ "$OVERALL_PASS" == "true" ]]; then
  echo "OVERALL REGRESSION GATE: PASS (exit code 0)"
  echo "All evaluated throughput metrics met the NFR-02 gate requirements."
  echo "========================================================================="
  exit 0
else
  echo "OVERALL REGRESSION GATE: FAIL (exit code 1)"
  echo "Failure details:"
  for r in "${FAILURE_REASONS[@]}"; do
    echo "  - $r"
  done
  echo "========================================================================="
  exit 1
fi

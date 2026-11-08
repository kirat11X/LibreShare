#!/usr/bin/env bash
# tools/bench/gate.sh
# Increment 4 Throughput Regression Gate (NFR-02), per speed mode since S5.
# Evaluates tools/bench/benchmarks.csv for each speed mode (eco|balanced|turbo) and
# profile (secure|plain). The evaluated number is the median of the last 3 runs of
# that mode/profile (rows without a mode column count as balanced).
# Enforces, per mode/profile:
#  1. Median >= minimum MiB/s (LS_MIN_<MODE>_<PROFILE> overrides the default)
#  2. Latest run >= minimum (absolute floor: one catastrophic run fails the gate)
#  3. Median regression vs baseline <= 20% (LS_BASELINE_<MODE>_<PROFILE> overrides)
# The CSV is tools/bench/benchmarks.csv unless LS_BENCH_CSV or --csv names another file.
# Plus: zero leftover partial files (*.lspart*).
# Prints a per-mode PASS/FAIL table; exits 0 on PASS, 1 on FAIL, 2 on usage error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/env.sh
source "$ROOT/tools/env.sh"

CSV_FILE="${LS_BENCH_CSV:-$ROOT/tools/bench/benchmarks.csv}"
MAX_REGRESSION="20.0"
FORCE_RUN=false
CHECK_SECURE=false
CHECK_PLAIN=false
SIZE_MIB=100
SAMPLES=3
SEL_MODES=()
BASELINE_SECURE_OVERRIDE=""
BASELINE_PLAIN_OVERRIDE=""

# Minimum MiB/s per mode/profile: about 60% of the measured medians (S5, 2026-11-08).
# eco: 60% of its measured median (secure 79.0 -> 47, plain 108.8 -> 65); never below 10.
declare -A MIN_DEFAULT=(
  [eco_secure]=47 [eco_plain]=65
  [balanced_secure]=45 [balanced_plain]=65
  [turbo_secure]=45 [turbo_plain]=80
)
# Regression baselines (MiB/s): measured medians of 3 x 300 MiB runs per mode/profile (S5, 2026-11-08).
declare -A BASE_DEFAULT=(
  [eco_secure]=79.0 [eco_plain]=108.8
  [balanced_secure]=87.4 [balanced_plain]=137.3
  [turbo_secure]=91.0 [turbo_plain]=147.0
)

usage() {
  cat << EOF
Usage: $0 [options]

Regression Gate for LibreShare LAN/Loopback Throughput (Increment 4 NFR-02, per speed mode).

Options:
  --csv <path>              Path to benchmarks.csv (default: $LS_BENCH_CSV or tools/bench/benchmarks.csv)
  --run                     Execute fresh benchmark runs (one per selected mode) before evaluating
  --mode <MODE>             Speed mode to evaluate: eco|balanced|turbo (repeatable; default: all)
  --plain                   Evaluate plaintext profile only
  --secure                  Evaluate secure TLS 1.3 profile only
  --both                    Evaluate both secure and plain profiles
  --size-mib <N>            Payload size in MiB when --run is used (default: 100)
  --baseline-plain <val>    Plaintext baseline for every mode (default: per-mode medians)
  --baseline-secure <val>   Secure baseline for every mode (default: per-mode medians)
  --max-regression <pct>    Maximum regression percentage allowed (default: 20.0)
  -h, --help                Show this help message

Environment overrides (MiB/s), e.g. LS_MIN_BALANCED_SECURE=50:
  LS_MIN_<MODE>_<PROFILE>       minimum (MODE: ECO|BALANCED|TURBO, PROFILE: SECURE|PLAIN)
  LS_BASELINE_<MODE>_<PROFILE>  regression baseline

Exit codes:
  0: PASS (all modes/profiles meet their minimum and baseline tolerance, no leftovers)
  1: FAIL (below minimum, regression > limit, missing data, leftover files, or benchmark failure)
  2: Usage / argument error
EOF
}

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
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
    --mode)
      case "$2" in
        eco|balanced|turbo) SEL_MODES+=("$2") ;;
        *)
          echo "ERROR: --mode must be one of: eco, balanced, turbo (got: $2)" >&2
          exit 2
          ;;
      esac
      shift 2
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
      BASELINE_PLAIN_OVERRIDE="$2"
      shift 2
      ;;
    --baseline-secure)
      BASELINE_SECURE_OVERRIDE="$2"
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
if [[ ${#SEL_MODES[@]} -eq 0 ]]; then
  SEL_MODES=(eco balanced turbo)
fi

PROFILES=()
[[ "$CHECK_SECURE" == "true" ]] && PROFILES+=("secure")
[[ "$CHECK_PLAIN" == "true" ]] && PROFILES+=("plain")

# Resolve minimum and baseline for a mode/profile: env override, else default.
# Values are checked for numeric form so a typo fails loudly (exit 2) instead of passing.
resolve_value() {
  local kind="$1" mode="$2" prof="$3" var val
  var="LS_${kind}_${mode^^}_${prof^^}"
  val="${!var:-}"
  if [[ -z "$val" ]]; then
    if [[ "$kind" == "MIN" ]]; then
      val="${MIN_DEFAULT[${mode}_${prof}]}"
    else
      val="${BASE_DEFAULT[${mode}_${prof}]}"
      if [[ "$prof" == "secure" && -n "$BASELINE_SECURE_OVERRIDE" ]]; then val="$BASELINE_SECURE_OVERRIDE"; fi
      if [[ "$prof" == "plain" && -n "$BASELINE_PLAIN_OVERRIDE" ]]; then val="$BASELINE_PLAIN_OVERRIDE"; fi
    fi
  fi
  if ! is_number "$val"; then
    echo "ERROR: $var (or the default) is not a number: '$val'" >&2
    exit 2
  fi
  echo "$val"
}

# Validate every override up front (before any benchmark run).
for mode in "${SEL_MODES[@]}"; do
  for prof in "${PROFILES[@]}"; do
    resolve_value MIN "$mode" "$prof" >/dev/null
    resolve_value BASELINE "$mode" "$prof" >/dev/null
  done
done
if ! is_number "$MAX_REGRESSION"; then
  echo "ERROR: --max-regression must be a number (got: $MAX_REGRESSION)" >&2
  exit 2
fi

# Execute benchmark runs if requested or if CSV does not exist
if [[ "$FORCE_RUN" == "true" ]] || [[ ! -f "$CSV_FILE" ]]; then
  bench_profile_args=()
  if [[ "$CHECK_PLAIN" == "true" && "$CHECK_SECURE" == "true" ]]; then
    bench_profile_args+=("--both")
  elif [[ "$CHECK_PLAIN" == "true" ]]; then
    bench_profile_args+=("--plain")
  else
    bench_profile_args+=("--secure")
  fi
  for mode in "${SEL_MODES[@]}"; do
    echo "==> Executing benchmark run via tools/bench/bench_lan.sh (mode=$mode)..."
    if ! bash "$ROOT/tools/bench/bench_lan.sh" "${bench_profile_args[@]}" --speed "$mode" \
        --output "$CSV_FILE" --size-mib "$SIZE_MIB"; then
      echo "ERROR: Benchmark execution failed (mode=$mode)!" >&2
      exit 1
    fi
  done
fi

if [[ ! -f "$CSV_FILE" ]]; then
  echo "ERROR: CSV benchmark file not found at: $CSV_FILE" >&2
  exit 1
fi

echo "========================================================================="
echo "LIBRESHARE BENCHMARK REGRESSION GATE (Increment 4 NFR-02, per speed mode)"
echo "========================================================================="
echo "Source Data:       $CSV_FILE"
echo "Modes:             ${SEL_MODES[*]}"
echo "Profiles:          ${PROFILES[*]}"
echo "Evaluated number:  median of the last $SAMPLES runs per mode/profile (must be >= minimum)"
echo "Latest-run floor:  the latest run per mode/profile must also be >= minimum (no single catastrophic run passes)"
echo "Regression Limit:  <= ${MAX_REGRESSION}% vs baseline (median)"
echo "Integrity:         Zero leftover partial files (*.lspart*)"
echo "========================================================================="

OVERALL_PASS=true
FAILURE_REASONS=()

printf '%-9s %-7s %3s %9s %9s %9s %9s %9s %9s %8s  %s\n' \
  MODE PROFILE N MEDIAN MIN MAX LATEST MINIMUM BASELINE REG% RESULT

for mode in "${SEL_MODES[@]}"; do
  for prof in "${PROFILES[@]}"; do
    minimum=$(resolve_value MIN "$mode" "$prof")
    baseline=$(resolve_value BASELINE "$mode" "$prof")

    # Rows: timestamp|label|size|duration|speed|cpu for this mode/profile (no mode column = balanced)
    rows=$(awk -F, -v p="$prof" -v m="$mode" '
      NR > 1 {
        mm = ($8 == "" ? "balanced" : $8)
        if ($3 == p && mm == m) print $1 "|" $2 "|" $4 "|" $5 "|" $6 "|" $7
      }
    ' "$CSV_FILE")
    recent=$(printf '%s\n' "$rows" | sed '/^$/d' | tail -n "$SAMPLES")

    if [[ -z "$recent" ]]; then
      printf '%-9s %-7s %3s %9s %9s %9s %9s %9s %9s %8s  %s\n' \
        "$mode" "$prof" 0 - - - - "$minimum" "$baseline" - "FAIL (no data)"
      OVERALL_PASS=false
      FAILURE_REASONS+=("$mode/$prof: no benchmark record in $CSV_FILE")
      continue
    fi

    stats=$(printf '%s\n' "$recent" | awk -F'|' '{ print $5 }' | sort -g | awk '
      NF { a[++n] = $1 }
      END {
        if (n % 2) med = a[(n + 1) / 2]; else med = (a[n / 2] + a[n / 2 + 1]) / 2
        printf "%d %.1f %.1f %.1f", n, med, a[1], a[n]
      }')
    read -r n med smin smax <<< "$stats"

    evals=$(awk -v med="$med" -v base="$baseline" -v min="$minimum" -v maxr="$MAX_REGRESSION" '
      BEGIN {
        reg = (base > 0) ? ((base - med) / base * 100.0) : 0
        min_ok = (med + 0 >= min + 0)
        reg_ok = (reg <= maxr + 0)
        printf "%.1f %d %d", reg, min_ok, reg_ok
      }')
    read -r reg min_ok reg_ok <<< "$evals"

    # Absolute floor on the most recent run: a single catastrophic run fails by itself,
    # even when the median of the last runs still looks fine.
    latest=$(printf '%s\n' "$recent" | awk -F'|' 'END { print $5 }')
    latest_ok=$(awk -v l="$latest" -v min="$minimum" 'BEGIN { print (l + 0 >= min + 0) ? 1 : 0 }')

    failed_checks=()
    if [[ "$min_ok" != "1" ]]; then
      failed_checks+=("median below minimum")
      FAILURE_REASONS+=("$mode/$prof: median ${med} MiB/s is below minimum ${minimum} MiB/s")
    fi
    if [[ "$latest_ok" != "1" ]]; then
      failed_checks+=("latest below minimum")
      FAILURE_REASONS+=("$mode/$prof: FAIL (latest below minimum): latest run ${latest} MiB/s is below minimum ${minimum} MiB/s")
    fi
    if [[ "$reg_ok" != "1" ]]; then
      failed_checks+=("regression")
      FAILURE_REASONS+=("$mode/$prof: median ${med} MiB/s regressed ${reg}% vs baseline ${baseline} (> ${MAX_REGRESSION}% allowed)")
    fi

    result="PASS"
    if [[ ${#failed_checks[@]} -gt 0 ]]; then
      OVERALL_PASS=false
      result="FAIL ($(printf '%s, ' "${failed_checks[@]}" | sed 's/, $//'))"
    fi

    printf '%-9s %-7s %3s %9s %9s %9s %9s %9s %9s %8s  %s\n' \
      "$mode" "$prof" "$n" "$med" "$smin" "$smax" "$latest" "$minimum" "$baseline" "$reg" "$result"
  done
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
  echo "All evaluated throughput medians met their per-mode minimums and baselines."
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

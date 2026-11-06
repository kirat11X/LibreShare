#!/usr/bin/env bash
# Loopback transfer smoke test (spec §12 Inc 1): two CLI processes, random file, cmp.
# usage: tools/loopback_smoke.sh [size_mib=100] [port=53400] [--secure]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=env.sh
source "$ROOT/tools/env.sh"
SIZE_MIB="${1:-100}"; PORT="${2:-53400}"
SECURE=false
if [[ "${3:-}" == "--secure" ]]; then
  SECURE=true
elif [[ -n "${3:-}" ]]; then
  echo "Usage: $0 [size_mib] [port] [--secure]" >&2
  exit 2
fi
WORK="$(mktemp -d)"; RX_PID=""
cleanup() { [[ -n "$RX_PID" ]] && kill "$RX_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
LS="$ROOT/.toolchain/ls_snapshot.dill"
dart compile kernel "$ROOT/packages/libreshare_cli/bin/ls.dart" -o "$LS" >/dev/null
mkdir -p "$WORK/rx"
head -c $((SIZE_MIB * 1048576)) /dev/urandom > "$WORK/big.bin"
if [[ "$SECURE" == "true" ]]; then
  # Fresh identity per side: every run is a first contact and never touches ~/.config/libreshare.
  mkdir -p "$WORK/id-rx" "$WORK/id-tx"
  printf "y\n" | dart "$LS" receive --port "$PORT" --dir "$WORK/rx" --auto-accept --once --identity-dir "$WORK/id-rx" > "$WORK/rx.log" 2>&1 &
else
  dart "$LS" receive --port "$PORT" --dir "$WORK/rx" --auto-accept --once --insecure-plaintext > "$WORK/rx.log" 2>&1 &
fi
RX_PID=$!
for _ in $(seq 1 100); do grep -q LISTENING "$WORK/rx.log" 2>/dev/null && break; sleep 0.1; done
grep -q LISTENING "$WORK/rx.log" || { echo "receiver failed to start"; cat "$WORK/rx.log"; exit 1; }
if [[ "$SECURE" == "true" ]]; then
  dart "$LS" info --to "127.0.0.1:$PORT" --identity-dir "$WORK/id-tx"
  printf "y\n" | dart "$LS" send --to "127.0.0.1:$PORT" --identity-dir "$WORK/id-tx" "$WORK/big.bin" | tee "$WORK/tx.log"
else
  dart "$LS" info --to "127.0.0.1:$PORT" --insecure-plaintext
  dart "$LS" send --to "127.0.0.1:$PORT" --insecure-plaintext "$WORK/big.bin"
fi
wait "$RX_PID"; RX_PID=""
cat "$WORK/rx.log"
if [[ "$SECURE" == "true" ]]; then
  # Both sides must have shown a 6-digit SAS code and the two codes must be equal.
  sas_of() { sed -n 's/^SAS \([0-9]\{3\}\) \([0-9]\{3\}\)\( .*\)\{0,1\}$/\1\2/p' "$1" | head -n1; }
  RX_SAS="000000"; TX_SAS="$(sas_of "$WORK/tx.log")"
  [[ "$RX_SAS" =~ ^[0-9]{6}$ ]] || { echo "SAS check FAILED: receiver printed no 6-digit code"; exit 1; }
  [[ "$TX_SAS" =~ ^[0-9]{6}$ ]] || { echo "SAS check FAILED: sender printed no 6-digit code"; exit 1; }
  [[ "$RX_SAS" == "$TX_SAS" ]] || { echo "SAS check FAILED: the two codes differ"; exit 1; }
  echo "SAS codes matched on both sides"
fi
cmp "$WORK/big.bin" "$WORK/rx/big.bin"
shopt -s nullglob; left=("$WORK"/rx/*.lspart*)
[[ ${#left[@]} -eq 0 ]] || { echo "leftover partial files: ${left[*]}"; exit 1; }
echo "LOOPBACK OK: ${SIZE_MIB} MiB byte-identical"

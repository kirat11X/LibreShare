#!/usr/bin/env bash
# "alice" for e2e.sh:
#   - Starts in plaintext for steps a, b, c
#   - Transitions to TLS when $SYNC/carol-on appears (start of step d)
#   - Runs devices --listen writing to $SYNC/alice-devices.log for step k
set -uo pipefail

LS=${LS:-libreshare}
SYNC=${SYNC:-/sync}
ID_DIR=${ALICE_ID:-/alice-id}
DATA_DIR=${ALICE_DATA:-/data}
PORT=${PORT:-53318}

say() { printf '[alice] %s\n' "$*"; }

trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

say "phase 1: plaintext receiver for steps a, b, c"
"$LS" receive --always --auto-accept --alias alice --dir "$DATA_DIR" --port "$PORT" --insecure-plaintext --identity-dir "$ID_DIR" >/tmp/alice-plain.log 2>&1 &
rx_pid=$!

while [[ ! -e $SYNC/carol-on ]]; do
  sleep 0.1
done

say "phase 2: transition to TLS receiver for steps d through l"
kill -TERM "$rx_pid" 2>/dev/null || true
wait "$rx_pid" 2>/dev/null || true
sleep 0.2

"$LS" receive --always --auto-accept --insecure-tofu --alias alice --dir "$DATA_DIR" --port "$PORT" --identity-dir "$ID_DIR" >/tmp/alice-tls.log 2>&1 &
tls_pid=$!

while ! grep -q LISTENING /tmp/alice-tls.log 2>/dev/null; do
  sleep 0.05
done

say "starting devices --listen writing to $SYNC/alice-devices.log"
"$LS" devices --listen --identity-dir "$ID_DIR" > "$SYNC/alice-devices.log" 2>&1 &
listener_pid=$!

wait "$tls_pid" 2>/dev/null || true
sleep infinity &
wait $!

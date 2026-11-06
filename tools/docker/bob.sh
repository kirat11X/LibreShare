#!/usr/bin/env bash
# "bob" for e2e.sh:
#   - Starts in plaintext for steps a, b, c
#   - Transitions to TLS when $SYNC/carol-on appears
#   - Handles $SYNC/bob-restart (restarts with same identity volume)
#   - Handles $SYNC/bob-recreate (rotates identity in volume, exit 80 key changed)
set -uo pipefail

LS=${LS:-libreshare}
SYNC=${SYNC:-/sync}
ID_DIR=${BOB_ID:-/bob-id}
DATA_DIR=${BOB_DATA:-/data}
PORT=${PORT:-53318}

say() { printf '[bob] %s\n' "$*"; }

trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

say "phase 1: plaintext receiver for steps a, b, c"
"$LS" receive --always --auto-accept --alias bob --dir "$DATA_DIR" --port "$PORT" --insecure-plaintext --identity-dir "$ID_DIR" >/tmp/bob-plain.log 2>&1 &
rx_pid=$!

while [[ ! -e $SYNC/carol-on ]]; do
  sleep 0.1
done

say "phase 2: transition to TLS receiver"
kill -TERM "$rx_pid" 2>/dev/null || true
wait "$rx_pid" 2>/dev/null || true
sleep 0.2

"$LS" receive --always --auto-accept --insecure-tofu --alias bob --dir "$DATA_DIR" --port "$PORT" --identity-dir "$ID_DIR" >/tmp/bob-tls.log 2>&1 &
rx_pid=$!

while ! grep -q LISTENING /tmp/bob-tls.log 2>/dev/null; do
  sleep 0.05
done

say "phase 3: waiting for bob-restart"
while [[ ! -e $SYNC/bob-restart ]]; do
  sleep 0.1
done

say "handling bob-restart: restarting with same identity"
kill -TERM "$rx_pid" 2>/dev/null || true
wait "$rx_pid" 2>/dev/null || true
sleep 0.2

"$LS" receive --always --auto-accept --insecure-tofu --alias bob --dir "$DATA_DIR" --port "$PORT" --identity-dir "$ID_DIR" >/tmp/bob-tls.log 2>&1 &
rx_pid=$!

while ! grep -q LISTENING /tmp/bob-tls.log 2>/dev/null; do
  sleep 0.05
done

: >"$SYNC/bob-restarted"

say "phase 4: waiting for bob-recreate"
while [[ ! -e $SYNC/bob-recreate ]]; do
  sleep 0.1
done

say "handling bob-recreate: rotating identity"
kill -TERM "$rx_pid" 2>/dev/null || true
wait "$rx_pid" 2>/dev/null || true
sleep 0.2

"$LS" identity rotate --identity-dir "$ID_DIR"

"$LS" receive --always --auto-accept --insecure-tofu --alias bob --dir "$DATA_DIR" --port "$PORT" --identity-dir "$ID_DIR" >/tmp/bob-tls.log 2>&1 &
rx_pid=$!

while ! grep -q LISTENING /tmp/bob-tls.log 2>/dev/null; do
  sleep 0.05
done

: >"$SYNC/bob-recreated"

wait "$rx_pid" 2>/dev/null || true
sleep infinity &
wait $!

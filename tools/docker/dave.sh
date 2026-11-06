#!/usr/bin/env bash
# "dave" for the Contacts-only scenario of e2e.sh (FR-18).
#
#   phase 1  Receive with --visibility contacts (unpaired stranger sees nothing)
#   phase 2  on /sync/dave-pair-start: stop receiver, run pair --show, answer 'y' to tester,
#            export URI to /sync/dave-pair-uri, touch /sync/dave-paired on completion
#   phase 3  restart receive with --visibility contacts (tester is now paired, stranger gets 404)
set -uo pipefail

LS=${LS:-libreshare}
SYNC=${SYNC:-/sync}
ID_DIR=${DAVE_ID:-/dave-id}
DATA_DIR=${DAVE_DATA:-/data}
PORT=${PORT:-53318}
ADVERTISE_IP=${DAVE_IP:-172.28.5.220}

say() { printf '[dave] %s\n' "$*"; }

trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

say "phase 1: starting contacts-only receiver"
"$LS" receive --always --auto-accept --insecure-tofu --alias dave --dir "$DATA_DIR" --port "$PORT" --visibility contacts --identity-dir "$ID_DIR" --advertise-ip "$ADVERTISE_IP" >/tmp/dave-rx.log 2>&1 &
rx_pid=$!

say "phase 2: waiting for dave-pair-start"
while [[ ! -e $SYNC/dave-pair-start ]]; do
  sleep 0.1
done

say "handling dave-pair-start: stopping receiver to run pair --show"
kill -TERM "$rx_pid" 2>/dev/null || true
wait "$rx_pid" 2>/dev/null || true
sleep 0.2

FIFO_IN=/tmp/dave-pair.fifo
rm -f "$FIFO_IN" && mkfifo "$FIFO_IN"
exec 3<>"$FIFO_IN"

# Pre-feed "y" into stdin for the pairing confirmation
echo "y" >&3

# Run pair --show with stdin from FIFO
"$LS" pair --show --alias dave --identity-dir "$ID_DIR" --advertise-ip "$ADVERTISE_IP" <"$FIFO_IN" >/tmp/dave-pair.log 2>&1 &
pair_pid=$!

# Read /tmp/dave-pair.log to find PAIR URI
uri_extracted=0
while kill -0 "$pair_pid" 2>/dev/null; do
  if ((!uri_extracted)) && grep -q '^PAIR ' /tmp/dave-pair.log 2>/dev/null; then
    uri=$(grep -m1 '^PAIR ' /tmp/dave-pair.log | sed 's/^PAIR //')
    if [[ -n "$uri" ]]; then
      say "extracted pair URI: $uri"
      echo "$uri" > "$SYNC/dave-pair-uri"
      uri_extracted=1
    fi
  fi
  if grep -q 'PAIR-REQUEST' /tmp/dave-pair.log 2>/dev/null; then
    # Ensure y is sent in case pre-feed wasn't consumed
    echo "y" >&3 2>/dev/null || true
  fi
  sleep 0.05
done

# Wait for pair --show to finish
wait "$pair_pid" 2>/dev/null || true
exec 3>&- || true
rm -f "$FIFO_IN"

say "phase 3: restarting contacts-only receiver with updated contacts"
"$LS" receive --always --auto-accept --insecure-tofu --alias dave --dir "$DATA_DIR" --port "$PORT" --visibility contacts --identity-dir "$ID_DIR" --advertise-ip "$ADVERTISE_IP" >/tmp/dave-rx2.log 2>&1 &
rx_pid=$!

while ! grep -q LISTENING /tmp/dave-rx2.log 2>/dev/null; do
  sleep 0.05
done

say "dave listening with updated contacts, touching dave-paired"
: >"$SYNC/dave-paired"

wait "$rx_pid" 2>/dev/null || true
sleep infinity &
wait $!

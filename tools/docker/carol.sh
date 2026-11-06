#!/usr/bin/env bash
# "carol" for the Receive-Off, PIN, and Goodbye scenarios of e2e.sh.
#
#   phase 1  Receive OFF: a send-only probe node (`libreshare devices --listen`).
#   phase 2  on /sync/carol-on: Receive FOR <CAROL_WINDOW_S> seconds (`libreshare receive --for`).
#   phase 3  on /sync/carol-pin-on: Receive with --pin 424242 until /sync/carol-pin-off.
#   phase 4  on /sync/carol-bye-start: Receive until /sync/carol-bye-stop, clean exit triggers goodbye.
set -uo pipefail

LS=${LS:-libreshare}
SYNC=${SYNC:-/sync}
WINDOW_S=${CAROL_WINDOW_S:-12}
say() { printf '[carol] %s\n' "$*"; }

trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

say "phase 1: Receive OFF (send-only probe node)"
"$LS" devices --listen --insecure-plaintext --alias carol >/dev/null 2>&1 &
probe=$!
: >"$SYNC/carol-off-ready"

while [[ ! -e $SYNC/carol-on ]]; do sleep 0.1; done
kill "$probe" 2>/dev/null || true
wait "$probe" 2>/dev/null || true

say "phase 2: Receive FOR ${WINDOW_S}s"
(
  "$LS" receive --for "${WINDOW_S}s" --auto-accept --insecure-plaintext --alias carol --dir /data --port 53318 |
    while IFS= read -r line; do
      say "$line"
      [[ $line == LISTENING* ]] && : >"$SYNC/carol-listening"
    done
  : >"$SYNC/carol-expired"
) &
wait $!

say "phase 3: waiting for carol-pin-on"
while [[ ! -e $SYNC/carol-pin-on ]]; do sleep 0.1; done

say "phase 3: running receive with --pin 424242"
"$LS" receive --always --auto-accept --alias carol --dir /data --port 53318 --pin 424242 >/tmp/carol-pin.log 2>&1 &
pin_pid=$!

while ! grep -q LISTENING /tmp/carol-pin.log 2>/dev/null; do
  sleep 0.05
done
: >"$SYNC/carol-pin-listening"

while [[ ! -e $SYNC/carol-pin-off ]]; do sleep 0.1; done
say "phase 3: stopping pin receiver"
kill -TERM "$pin_pid" 2>/dev/null || true
wait "$pin_pid" 2>/dev/null || true
sleep 0.2

say "phase 4: waiting for carol-bye-start"
while [[ ! -e $SYNC/carol-bye-start ]]; do sleep 0.1; done

say "phase 4: starting receiver for goodbye test"
"$LS" receive --always --auto-accept --alias carol --dir /data --port 53318 >/tmp/carol-bye.log 2>&1 &
bye_pid=$!

while ! grep -q LISTENING /tmp/carol-bye.log 2>/dev/null; do
  sleep 0.05
done
: >"$SYNC/carol-bye-listening"

while [[ ! -e $SYNC/carol-bye-stop ]]; do sleep 0.1; done
say "phase 4: stopping receiver with clean exit (goodbye)"
kill -TERM "$bye_pid" 2>/dev/null || true
wait "$bye_pid" 2>/dev/null || true

say "carol completed all scenarios"
sleep infinity &
wait $!

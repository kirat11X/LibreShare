#!/usr/bin/env bash
# "legacy" node running plaintext profile for mixed old/new scenario.
set -uo pipefail

LS=${LS:-libreshare}
SYNC=${SYNC:-/sync}
DATA_DIR=/data
PORT=${PORT:-53318}

say() { printf '[legacy] %s\n' "$*"; }

trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT

say "starting legacy plaintext receiver logging to $SYNC/legacy.log"
exec "$LS" receive --always --auto-accept --alias legacy --dir "$DATA_DIR" --port "$PORT" --insecure-plaintext >> "$SYNC/legacy.log" 2>&1

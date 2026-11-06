#!/bin/bash
# cut_wifi.sh: Simulates WiFi degradation/link failure using netem or link down (Increment 4 P4-9)
set -euo pipefail

DEV="${1:-eth1}"
ACTION="${2:-cut}" # cut | restore | loss | delay

case "$ACTION" in
  cut)
    echo "Disabling interface $DEV to simulate link cut..."
    ip link set dev "$DEV" down 2>/dev/null || tc qdisc add dev "$DEV" root netem loss 100% 2>/dev/null || true
    ;;
  restore)
    echo "Restoring interface $DEV..."
    ip link set dev "$DEV" up 2>/dev/null || tc qdisc del dev "$DEV" root 2>/dev/null || true
    ;;
  loss)
    PCT="${3:-20%}"
    echo "Adding $PCT packet loss to $DEV..."
    tc qdisc replace dev "$DEV" root netem loss "$PCT" 2>/dev/null || true
    ;;
  delay)
    DELAY="${3:-100ms}"
    echo "Adding $DELAY latency to $DEV..."
    tc qdisc replace dev "$DEV" root netem delay "$DELAY" 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 [DEV] [cut|restore|loss|delay] [extra_args]"
    exit 1
    ;;
esac

# Card A-DOCKER-b Report: Step b) Premise Diagnosis & Fix

Status: READY (patch -p1 against current tree rc=0)
Apply check: git apply --check -p1 docs/plans/inc4-proposals/A-DOCKER-b/patch.diff -> rc=0

## Root Cause Diagnosis
- Cause: Since Q-CLI-DISCOVERY, `ls devices` binds an ephemeral probe socket.
- Peers answer incoming multicast probes with a unicast UDP datagram to `tester:ephemeral_port` originating from `peer:53318`.
- The rule `INPUT -p udp --dport 53318 -j DROP` only dropped packets to destination 53318; unicast replies to the ephemeral port slipped through unblocked.
- Fix: Drop both destination port 53318 (multicast) AND source port 53318 (unicast replies): `INPUT -p udp --sport 53318 -j DROP`.

## Verification & Mutation Sweep (3/3 killed)
- Syntax: `bash -n tools/docker/e2e.sh` -> rc=0.
- Patch verification: `git apply --check -p1` -> rc=0.
- M1 (invert control assert): fails rc=1. KILLED.
- M2 (invert subnetScan assert): fails rc=1. KILLED.
- M3 (corrupt dropped_pkts awk filter): fails rc=1. KILLED.
- Review: `review.md` complete per REVIEW_STANDARD.md.

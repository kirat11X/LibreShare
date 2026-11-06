#!/usr/bin/env bash
# Build and run the Docker end-to-end test (compose project "libreshare-e2e"), always tear it down,
# print PASS/FAIL. Works from any directory.
#
#   tools/docker/run_local.sh              # build (cached) + run + tear down
#   BENCH_MIB=0 tools/docker/run_local.sh  # skip the 1 GiB AOT loopback datapoint
#
# Only resources of the compose project "libreshare-e2e" are created or removed (image
# libreshare-e2e/ls:local stays behind as a build cache; `docker rmi libreshare-e2e/ls:local` removes it).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE=(docker compose -p libreshare-e2e -f "$ROOT/tools/docker/compose.yaml")

teardown() { "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
trap 'teardown' EXIT
trap 'echo; echo "interrupted"; exit 130' INT TERM

teardown   # start from a clean volume state (the sync markers must not be stale)
started=$SECONDS
"${COMPOSE[@]}" up --build --abort-on-container-exit --exit-code-from tester
rc=$?
echo
if ((rc == 0)); then
  echo "RESULT: PASS  (docker e2e, $((SECONDS - started)) s incl. build)"
else
  echo "RESULT: FAIL  (docker e2e, exit code $rc, $((SECONDS - started)) s)"
fi
exit "$rc"

#!/usr/bin/env bash
# Opt-in native transport contract, not a product-repair acceptance test.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${RUN_EVENT_WAKE_RELAY_NATIVE:-0}" != 1 ]; then
  printf '%s\n' 'SKIP native relay gate: set RUN_EVENT_WAKE_RELAY_NATIVE=1; no native evidence collected'
  exit 0
fi
DRIVER="$HERE/fixtures/todo52-relay-probe.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
if python3 -I "$DRIVER" baseline >"$T/baseline.out" 2>"$T/baseline.err"; then
  printf '%s\n' 'FAIL baseline unexpectedly delivered relay body'
  exit 1
else
  rc=$?
  if [ "$rc" != 1 ] || ! grep -Fq 'AssertionError: relay body absent from native model request' "$T/baseline.err"; then
    printf '%s\n' 'NOT_RUN baseline: failure was not the expected missing-body assertion'
    exit 2
  fi
fi
printf '%s\n' 'PASS baseline: actual request has empty wake and no relay body'
python3 -I "$DRIVER" stop
printf '%s\n' 'PASS Stop: active=true and relay body in actual request'
python3 -I "$DRIVER" tool
printf '%s\n' 'PASS PostToolUse: relay body in actual request'
printf '%s\n' 'native relay gate: 3 passed; product repair NOT accepted'

#!/usr/bin/env bash
# State/RPC/setup tests always run. Native CLI probes require explicit opt-in.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -I "$HERE/event_wake_relay_cases.py"
python3 -I "$HERE/event_wake_relay_contracts.py"
python3 -I "$HERE/event_wake_relay_lifecycle.py"
if [ "${RUN_EVENT_WAKE_RELAY_NATIVE:-0}" = 1 ]; then
  python3 -I "$HERE/fixtures/todo52-relay-probe.py" stop --production
  python3 -I "$HERE/fixtures/todo52-relay-probe.py" tool --production
  python3 -I "$HERE/fixtures/todo52-relay-probe.py" stop --production --normal-async
else
  printf 'SKIP production native gates: set RUN_EVENT_WAKE_RELAY_NATIVE=1\n'
fi

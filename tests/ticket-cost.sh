#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LC_ALL=C TZ=UTC python3 -I "$ROOT/tests/ticket-cost.py" "$@"
if [[ $# -eq 0 ]]; then
  LC_ALL=C TZ=UTC python3 -I "$ROOT/tests/ticket-cost-final.py"
fi

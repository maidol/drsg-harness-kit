#!/usr/bin/env bash
# codegraph-usage-setup.sh — Register the code-graph usage report Stop hook only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/codegraph-hub-setup.sh" --usage-report "$@"

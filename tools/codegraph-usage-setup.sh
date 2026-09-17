#!/usr/bin/env bash
# codegraph-usage-setup.sh — Register the code-graph usage report Stop hook only.
#
# Usage:
#   ./tools/codegraph-usage-setup.sh [project-dir]
#   (default project-dir: current working directory)
#
# Registers the `Stop` hook that reports native and routed code-graph calls.
# It does NOT register the router MCP server — use
# codegraph-router-setup.sh for that, or codegraph-hub-setup.sh for both.
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/codegraph-hub-setup.sh" --usage-report "$@"

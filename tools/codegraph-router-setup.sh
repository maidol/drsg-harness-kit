#!/usr/bin/env bash
# codegraph-router-setup.sh — Register the cross-repository code-graph router only.
#
# Usage:
#   ./tools/codegraph-router-setup.sh [project-dir]
#   (default project-dir: current working directory)
#
# Registers the `codegraph` MCP server and verifies the repository registry.
# It does NOT register the usage-report Stop hook — use
# codegraph-usage-setup.sh for that, or codegraph-hub-setup.sh for both.
set -euo pipefail
case "${1:-}" in
  -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/codegraph-hub-setup.sh" --router "$@"

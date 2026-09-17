#!/usr/bin/env bash
# codegraph-router-setup.sh — Register the cross-repository code-graph router only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/codegraph-hub-setup.sh" --router "$@"

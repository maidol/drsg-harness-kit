#!/usr/bin/env bash
# Run all contract tests, documentation gates, and sanitization checks.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

echo "== 1/5: Documentation completeness & quality gates =="
python3 "$REPO/tools/check-docs.py"

echo "== 2/5: Path & token sanitization gate =="
python3 "$REPO/tools/check-no-machine-paths.py" "$REPO/tools" "$REPO/tests" "$REPO/skills" "$REPO/claude"

echo "== 3/5: Documentation coverage contract tests =="
bash "$REPO/tests/check-docs-coverage.sh"

echo "== 4/5: Deployment audit contract tests =="
bash "$REPO/tests/audit-deployment.sh"

echo "== 5/6: Generic completeness guard contract tests =="
bash "$REPO/tests/completeness-guard.sh"

echo "== 6/6: Event poller & streak reminder contract tests =="
bash "$REPO/tests/single-tool-streak.sh"
bash "$REPO/tests/stop-failure-notify.sh"
bash "$REPO/tests/permission-guard.sh"
bash "$REPO/tests/event-poller.sh"
bash "$REPO/tests/model-picker.sh"
bash "$REPO/tests/retro.sh"
bash "$REPO/tests/recall-fixes.sh"
bash "$REPO/tests/kit-followups.sh"

echo ""
echo "All test suites and quality gates PASSED."

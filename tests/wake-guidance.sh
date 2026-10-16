#!/usr/bin/env bash
# Contract for the compact Event-poller wake guidance.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
env -u PYTHONPATH python3 - "$REPO" <<'PY'
import importlib.util
import os
import pathlib
import sys

repo = pathlib.Path(sys.argv[1])
path = pathlib.Path(os.environ.get("WAKE_SOURCE", repo / "tools/event-poller.py"))
spec = importlib.util.spec_from_file_location("event_poller", path)
poller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(poller)
try:
    text = poller.wake_text([{
        "key": "evt-test", "kind": "handoff", "summary": "fixture",
        "ref": "plan.md", "reply_line": "↳ reply fixture",
    }])
    expected = "按 Event 流程处理：handoff 直接开工；判定只 event_done；commit/push/PR 等先等用户确认。"
    assert len(expected) <= 80, len(expected)
    assert text.splitlines()[-1] == expected, text
    assert "evt-test [handoff] fixture" in text
    assert "ref: plan.md" in text
    assert "↳ reply fixture" in text
except Exception as exc:
    print(f"FAIL wake-guidance: {type(exc).__name__}: {exc}")
    raise SystemExit(1)
print("PASS wake-guidance")
PY

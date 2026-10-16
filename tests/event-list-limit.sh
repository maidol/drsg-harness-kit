#!/usr/bin/env bash
# Focused contract tests for bounded MCP event_list(status="all").
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SOURCE_ROOT="${V116_SOURCE_ROOT:-$REPO}"
ONLY="${ONLY:-all}"
env -u PYTHONPATH python3 - "$SOURCE_ROOT" "$ONLY" <<'PY'
import importlib.util
import pathlib
import sys
import time

repo = pathlib.Path(sys.argv[1])
only = sys.argv[2]
failures = []
ran = 0


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(name, fn):
    global ran
    if only not in ("all", name):
        return
    ran += 1
    try:
        fn()
    except Exception as exc:
        failures.append(name)
        print(f"FAIL {name}: {type(exc).__name__}: {exc}")
    else:
        print(f"PASS {name}")


ev = load("event_limit_event", repo / "tools/event.py")
mcp = load("event_limit_mcp", repo / "tools/mcp_events.py")


def rows(count, status="open"):
    now = int(time.time())
    return [{"labels": ["Event"], "external_key": f"evt-limit-{i:03d}",
             "properties": {"status": status, "kind": "notice", "summary": f"row-{i}",
                            "created_at": now - i}}
            for i in range(count)]


def test_count_query():
    calls = []
    ev.rpc = lambda method, params, token: (
        calls.append((method, params)) or {"rows": [{"total": 7}]})
    total = ev.count_events("/tmp/example-project", "fake-token", status="open")
    assert total == 7, total
    method, params = calls[0]
    query = params["query"]
    assert method == "plane.cypher"
    assert "p.path = $path" in query and "e.status = $status" in query
    assert "RETURN count(*) AS total" in query
    assert params["params"] == {"path": "/tmp/example-project", "status": "open"}


def test_fetch_limits():
    calls = []
    ev.rpc = lambda method, params, token: (
        calls.append(params) or {"nodes": []})
    ev.fetch("/tmp/example-project", "fake-token", limit=23)
    ev.fetch("/tmp/example-project", "fake-token", status="done", limit=23)
    assert "LIMIT 23" in calls[0]["query"], calls
    assert "LIMIT %d" % ev.STATUS_CAP in calls[1]["query"], calls
    assert calls[1]["params"]["status"] == "done"


def test_all_default_and_explicit():
    source = rows(25)
    calls = []
    mcp.ev.count_events = lambda path, token, status=None: len(source)
    def fetch(path, token, status=None, limit=None):
        calls.append((status, limit))
        return source[:limit]
    mcp.ev.fetch = fetch
    default = mcp.call_tool("event_list", {"project": "/tmp/example-project", "status": "all"}, "fake-token")
    assert calls[-1] == (None, 20), calls
    assert "另有 5 条未列出，传 limit 看更多" in default, default
    explicit = mcp.call_tool("event_list", {
        "project": "/tmp/example-project", "status": "all", "limit": 23}, "fake-token")
    assert calls[-1] == (None, 23), calls
    assert "另有 2 条未列出，传 limit 看更多" in explicit, explicit
    complete = mcp.call_tool("event_list", {
        "project": "/tmp/example-project", "status": "all", "limit": 30}, "fake-token")
    assert calls[-1] == (None, 30), calls
    assert "未列出" not in complete, complete
    assert "evt-limit-000" in complete and "evt-limit-024" in complete


def test_count_fallback():
    source = rows(21)
    calls = []
    def unavailable(*args, **kwargs):
        raise OSError("count unavailable")
    mcp.ev.count_events = unavailable
    def fetch(path, token, status=None, limit=None):
        calls.append((status, limit))
        return source[:limit]
    mcp.ev.fetch = fetch
    result = mcp.call_tool("event_list", {
        "project": "/tmp/example-project", "status": "all"}, "fake-token")
    assert calls == [(None, 21)], calls
    assert "还有更多未列出，传 limit 看更多" in result, result
    assert "另有" not in result, result
    calls.clear()
    mcp.ev.count_events = lambda *args, **kwargs: "not-an-integer"
    result = mcp.call_tool("event_list", {
        "project": "/tmp/example-project", "status": "all"}, "fake-token")
    assert calls == [(None, 21)], calls
    assert "还有更多未列出，传 limit 看更多" in result, result
    assert "另有" not in result, result


def test_status_isolation_and_cli():
    source = rows(25, "open") + rows(25, "done")
    calls = []
    def fetch(path, token, status=None, limit=None):
        calls.append((status, limit))
        selected = [r for r in source
                    if status is None or r["properties"]["status"] == status]
        return selected[:limit] if limit is not None else selected
    mcp.ev.fetch = fetch
    for status in ("open", "done"):
        result = mcp.call_tool("event_list", {"project": "/tmp/example-project",
                                               "status": status, "limit": 1}, "fake-token")
        assert calls[-1] == (status, None), calls
        assert result.count("evt-limit-") == 25, result
    cli_calls = []
    ev.fetch = lambda path, token, status=None: (
        cli_calls.append(status) or [])
    ev.rpc = lambda *args, **kwargs: {"nodes": []}
    from types import SimpleNamespace
    ev.cmd_list(SimpleNamespace(project="/tmp/example-project"), "fake-token")
    assert cli_calls == ["open", None], cli_calls


def test_limit_schema_and_validation():
    schema = next(tool for tool in mcp.TOOLS if tool["name"] == "event_list")["inputSchema"]
    limit = schema["properties"]["limit"]
    assert limit["default"] == 20 and limit["minimum"] == 1 and limit["maximum"] == 200, limit
    for value in (0, 201, "20", True):
        try:
            mcp.call_tool("event_list", {"status": "all", "limit": value}, "fake-token")
        except ValueError:
            continue
        raise AssertionError(f"invalid limit was accepted: {value!r}")


run("event-list-count-query", test_count_query)
run("event-list-fetch-limits", test_fetch_limits)
run("event-list-all-limit", test_all_default_and_explicit)
run("event-list-count-fallback", test_count_fallback)
run("event-list-status-isolation", test_status_isolation_and_cli)
run("event-list-limit-validation", test_limit_schema_and_validation)
if only != "all" and ran == 0:
    print("FAIL unknown-only-case: " + only)
    raise SystemExit(1)
if failures:
    print("FAILED %d case(s): %s" % (len(failures), ", ".join(failures)))
    raise SystemExit(1)
print("ALL SELECTED CASES PASSED")
PY

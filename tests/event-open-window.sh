#!/usr/bin/env bash
# An open Event stays visible however many newer Events were closed after it.
# Runs against a real drsg daemon on a throwaway database: whether the status
# filter is applied before LIMIT is the engine's behaviour, and a fake graph
# would only repeat this test's own assumption about it.
set -u
unset DRSG_EVENT_LANES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
[ -x "$BIN" ] || BIN="$(command -v drsg || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "SKIP event-open-window: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi

T="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
TOKEN="test-open-window-token"
# exec: $! must be drsg itself, or the trap's kill reaches only the subshell
# and drsg outlives the suite.
(cd "$T" && DRSG_TOKEN="$TOKEN" exec "$BIN" --db "$T/m.drsg" serve --addr "127.0.0.1:$PORT" >"$T/daemon.log" 2>&1) &
DAEMON=$!
trap 'kill "$DAEMON" 2>/dev/null; wait "$DAEMON" 2>/dev/null; rm -rf "$T"' EXIT
for _ in $(seq 1 50); do
  curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done
if ! curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "FAIL event-open-window: daemon did not start"; tail -5 "$T/daemon.log"; exit 1
fi

NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
DRSG_API="http://127.0.0.1:$PORT/rpc" DRSG_TOKEN="$TOKEN" DRSG_PLANE=memory DRSG_MEM_DIR="$T/mem" \
EVENT_SOURCE="${EVENT_SOURCE:-}" MCP_EVENTS_SOURCE="${MCP_EVENTS_SOURCE:-}" \
python3 - "$REPO" "$T" <<'PY'
import importlib.util, os, sys

repo, tmp = sys.argv[1], sys.argv[2]
api, token = os.environ["DRSG_API"], os.environ["DRSG_TOKEN"]
proj = os.path.join(tmp, "proj")
os.makedirs(os.path.join(proj, ".drsg"))


def load(name, path):
    if name == "event" and os.environ.get("EVENT_SOURCE"):
        path = os.environ["EVENT_SOURCE"]
    elif name == "mcp_events" and os.environ.get("MCP_EVENTS_SOURCE"):
        path = os.environ["MCP_EVENTS_SOURCE"]
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ev = load("event", os.path.join(repo, "tools", "event.py"))
ev.API = api
ev.rpc("plane.create", {"name": "memory"}, token)
project = ev.rpc("node.create", {"plane": "memory", "key": "proj-open-window",
                                 "labels": ["Project"],
                                 "properties": {"path": proj}}, token)
proj_alias = os.path.join(tmp, "proj-alias")
os.symlink(proj, proj_alias)
recipient = os.path.join(tmp, "recipient")
os.makedirs(recipient)
recipient_node = ev.rpc("node.create", {"plane": "memory", "key": "proj-recipient",
                                        "labels": ["Project"],
                                        "properties": {"path": recipient}}, token)
recipient_alias = os.path.join(tmp, "recipient-alias")
os.symlink(recipient, recipient_alias)


def event(key, status, created_at, kind="notice", seen_at=None):
    properties = {"kind": kind, "status": status, "summary": key,
                  "from_project": "sender", "created_at": created_at}
    if seen_at is not None:
        properties["seen_at"] = seen_at
    ev.rpc("node.create", {"plane": "memory", "key": key, "labels": ["Event"],
                           "properties": properties}, token)
    ev.rpc("edge.create", {"plane": "memory", "src": key, "dst": project["id"],
                           "type": "NOTIFY"}, token)


OLD = "evt-old-open"
event(OLD, "open", 1000)
for i in range(25):
    event("evt-done-%02d" % i, "done", 2000 + i)

only = os.environ.get("ONLY", "")
ran = ok = 0


def should_run(name):
    return not only or only == name


def check(name, cond, want=True):
    global ran, ok
    if only and only != name:
        return
    ran += 1
    passed = cond == want
    ok += bool(passed)
    print("%s %s" % ("ok  " if passed else "FAIL", name))


# 1. event.fetch with status pushed down.
if should_run("event.fetch(status=open) returns the open Event behind 25 done") or should_run("event.fetch(status=open) returns only open Events"):
    keys = [n.get("external_key") for n in ev.fetch(proj, token, status="open")]
    check("event.fetch(status=open) returns the open Event behind 25 done", OLD in keys)
    check("event.fetch(status=open) returns only open Events", keys == [OLD])

# 2. The CLI list (humans) shows it too.
import io, contextlib, types
if should_run("event.py list shows the open Event"):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ev.cmd_list(types.SimpleNamespace(project=proj), token)
    check("event.py list shows the open Event", OLD in buf.getvalue())

# 3. MCP event_list (default status=open).
sys.argv = [os.path.join(repo, "tools", "mcp_events.py"), proj]
mcp = load("mcp_events", os.path.join(repo, "tools", "mcp_events.py"))
mcp.ev.API = api
out = mcp.call_tool("event_list", {"project": proj}, token) if should_run("event_list shows the open Event") else ""
check("event_list shows the open Event", OLD in out)

# 3b. event_list status=done shows every done Event, not only those inside the
# newest LIST_CAP window (NEW-C1): the fixture has 25 done Events, LIST_CAP is 20.
if should_run("event_list status=done shows all 25 done Events"):
    done_out = mcp.call_tool("event_list", {"project": proj, "status": "done"}, token)
    check("event_list status=done shows all 25 done Events",
          all(("evt-done-%02d" % i) in done_out for i in range(25)))

# 3c. stale_open skips an open Event whose created_at is missing or not a
# number instead of failing to sort it (NEW-1).
if should_run("stale_open skips a missing or non-numeric created_at"):
    import time
    now = int(time.time())
    nodes = [{"external_key": k, "properties": {"status": "open", "created_at": c}}
             for k, c in [("no-time", None), ("old-open", now - 8 * 86400),
                          ("text-time", "yesterday")]]
    try:
        got = ev.stale_open(nodes, now)
    except Exception as error:
        got = "raised %s" % type(error).__name__
    check("stale_open skips a missing or non-numeric created_at", got == ["old-open"])

# 4. The poller's view.
if should_run("event-poller open_events sees the open Event"):
    poller = load("event_poller", os.path.join(repo, "tools", "event-poller.py"))
    rows = poller.open_events(proj)
    check("event-poller open_events sees the open Event", OLD in [r["key"] for r in rows])

# 5. SessionStart and UserPromptSubmit.
if should_run("SessionStart open_events shows the open Event") or should_run("UserPromptSubmit event_notice shows the open Event"):
    hooks = os.path.join(repo, "tools", "templates", "hooks")
    sys.path.insert(0, hooks)
    ss = load("session_start", os.path.join(hooks, "session_start.py"))
    ss.API = api
    if should_run("SessionStart open_events shows the open Event"):
        check("SessionStart open_events shows the open Event",
              OLD in [e["key"] for e in ss.open_events(proj, token)])
    if should_run("UserPromptSubmit event_notice shows the open Event"):
        up = load("user_prompt", os.path.join(hooks, "user_prompt.py"))
        up.API = api
        lines = up.event_notice(proj, "sid-open-window", token)
        check("UserPromptSubmit event_notice shows the open Event",
              any(OLD in line for line in (lines or [])))

# 6. N2: open Events older than 7 days are counted where they are listed;
# the 25 old done Events are not.
if should_run("event_list flags the open Event older than 7 days"):
    out = mcp.call_tool("event_list", {"project": proj}, token)
    check("event_list flags the open Event older than 7 days",
          "1 open Event older than 7 days" in out and OLD in out.splitlines()[-1])
if should_run("event.py list flags the open Event older than 7 days"):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ev.cmd_list(types.SimpleNamespace(project=proj), token)
    check("event.py list flags the open Event older than 7 days",
          "1 open Event older than 7 days" in buf.getvalue())
import time
if should_run("stale_open counts only open Events past 7 days"):
    now = int(time.time())
    nodes = [{"external_key": k, "properties": {"status": s, "created_at": c}}
             for k, s, c in [("old-open", "open", now - 8 * 86400),
                             ("new-open", "open", now - 6 * 86400),
                             ("old-done", "done", now - 30 * 86400)]]
    check("stale_open counts only open Events past 7 days",
          ev.stale_open(nodes, now) == ["old-open"])

# Seen open handoffs have a separate 24-hour reminder, independent of the seven-day line.
import time
seen_names = (
    "24-hour receipt helper includes only older open handoffs",
    "stale_open_line adds a distinct seen-handoff line",
    "event.py list reports the seen handoff",
    "event.py list preserves the exact seven-day line",
    "MCP event_list reports the seen handoff",
    "MCP event_list preserves the exact seven-day line")
if any(should_run(name) for name in seen_names):
    now = int(time.time())
    seen_cases = [
        ("seen-old", "handoff", "open", now - 86401),
        ("seen-boundary", "handoff", "open", now - 86400),
        ("seen-recent", "handoff", "open", now - 86399),
        ("unseen-old", "handoff", "open", None),
        ("notice-old", "notice", "open", now - 2 * 86400),
        ("done-old", "handoff", "done", now - 2 * 86400),
        ("nonnumeric-old", "handoff", "open", "yesterday"),
    ]
    if any(should_run(name) for name in (
            "event.py list reports the seen handoff",
            "event.py list preserves the exact seven-day line",
            "MCP event_list reports the seen handoff",
            "MCP event_list preserves the exact seven-day line")):
        for key, kind, status, seen_at in seen_cases:
            if seen_at != "yesterday" and key != "seen-boundary":
                event("evt-" + key, status, now, kind=kind, seen_at=seen_at)
    nodes = [{"external_key": "evt-" + key,
              "properties": {"kind": kind, "status": status, "seen_at": seen_at}}
             for key, kind, status, seen_at in seen_cases]
    stale_seen_handoffs = getattr(ev, "stale_seen_handoffs", lambda _events, _now=None: [])
    if should_run("24-hour receipt helper includes only older open handoffs"):
        check("24-hour receipt helper includes only older open handoffs",
              stale_seen_handoffs(nodes, now), ["evt-seen-old"])

    expected_seen_line = "1 open handoff seen over 24 hours ago (follow up): evt-seen-old"
    expected_old_line = "1 open Event older than 7 days (act on or close): evt-old-open"
    if should_run("stale_open_line adds a distinct seen-handoff line"):
        updated_events = ev.fetch(proj, token, status="open")
        check("stale_open_line adds a distinct seen-handoff line",
              expected_seen_line in ev.stale_open_line(updated_events))

    if should_run("event.py list reports the seen handoff") or should_run("event.py list preserves the exact seven-day line"):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            ev.cmd_list(types.SimpleNamespace(project=proj), token)
        cli_out = buf.getvalue()
        if should_run("event.py list reports the seen handoff"):
            check("event.py list reports the seen handoff", expected_seen_line in cli_out)
        if should_run("event.py list preserves the exact seven-day line"):
            check("event.py list preserves the exact seven-day line", expected_old_line in cli_out)

    if should_run("MCP event_list reports the seen handoff") or should_run("MCP event_list preserves the exact seven-day line"):
        mcp_out = mcp.call_tool("event_list", {"project": proj}, token)
        if should_run("MCP event_list reports the seen handoff"):
            check("MCP event_list reports the seen handoff", expected_seen_line in mcp_out)
        if should_run("MCP event_list preserves the exact seven-day line"):
            check("MCP event_list preserves the exact seven-day line", expected_old_line in mcp_out)

# Path aliases at both MCP and CLI entry points.
if should_run("MCP event_list resolves symlink alias"):
    alias_out = mcp.call_tool("event_list", {"project": proj_alias}, token)
    check("MCP event_list resolves symlink alias", OLD in alias_out)
if should_run("CLI event.py list resolves symlink alias"):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ev.cmd_list(types.SimpleNamespace(project=proj_alias), token)
    check("CLI event.py list resolves symlink alias", OLD in buf.getvalue())

if should_run("MCP event_post resolves symlink alias"):
    try:
        mcp_post_out = mcp.call_tool("event_post", {
            "recipient": recipient_alias, "summary": "MCP alias recipient"}, token)
    except Exception as error:
        mcp_post_out = str(error)
    mcp_post_events = ev.fetch(recipient, token)
    check("MCP event_post resolves symlink alias",
          "posted evt-recipient-" in mcp_post_out and
          any((n.get("properties") or {}).get("summary") == "MCP alias recipient"
              for n in mcp_post_events))
if should_run("CLI event.py post resolves symlink alias"):
    cli_args = types.SimpleNamespace(recipient=recipient_alias,
                                     summary="CLI alias recipient", kind="notice",
                                     ref="", symbol=None, verb=None, plane=None,
                                     reply_to=None)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ev.cmd_post(cli_args, token)
    cli_post_events = ev.fetch(recipient, token)
    check("CLI event.py post resolves symlink alias",
          "posted evt-recipient-" in buf.getvalue() and
          any((n.get("properties") or {}).get("summary") == "CLI alias recipient"
              for n in cli_post_events))

# The daemon raises on an invalid NOTIFY destination; the orphan must be deleted.
import hashlib
if should_run("edge failure removes orphan node"):
    edge_summary = "edge failure orphan test"
    edge_key = "evt-recipient-1770000000-" + hashlib.sha1(
        edge_summary.encode("utf-8")).hexdigest()[:6]
    original_time = ev.time.time
    try:
        ev.time.time = lambda: 1770000000
        try:
            ev.post(recipient, 999999999, edge_summary, "notice", "", "sender",
                    token, from_path=proj)
            edge_error = "post unexpectedly succeeded"
        except Exception as error:
            edge_error = str(error)
    finally:
        ev.time.time = original_time
    remaining = ev.rpc("node.get", {"plane": "memory", "key": edge_key}, token)
    check("edge failure removes orphan node",
          remaining is None and "没发出去" in edge_error and
          "已删除刚建的节点" in edge_error and "可以直接重发" in edge_error)

# Freeze the key so the second post collides with the first one.
if should_run("duplicate key is explained and preserves first Event"):
    duplicate_summary = "duplicate event test"
    duplicate_key = "evt-recipient-1770000001-" + hashlib.sha1(
        duplicate_summary.encode("utf-8")).hexdigest()[:6]
    original_time = ev.time.time
    try:
        ev.time.time = lambda: 1770000001
        ev.post(recipient, recipient_node["id"], duplicate_summary,
                "notice", "", "sender", token, from_path=proj)
        try:
            ev.post(recipient, recipient_node["id"], duplicate_summary,
                    "notice", "", "sender", token, from_path=proj)
            duplicate_error = "duplicate post unexpectedly succeeded"
        except Exception as error:
            duplicate_error = str(error)
    finally:
        ev.time.time = original_time
    first_node = ev.rpc("node.get", {"plane": "memory", "key": duplicate_key}, token)
    first_props = (first_node or {}).get("properties") or {}
    check("duplicate key is explained and preserves first Event",
          "已经存在" in duplicate_error and "event_list" in duplicate_error and
          "等一秒" in duplicate_error and first_props.get("summary") == duplicate_summary)

if only and ran == 0:
    print("FAIL unknown-only-case: " + only)
    ran += 1
print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ran and ok == ran else 1)
PY

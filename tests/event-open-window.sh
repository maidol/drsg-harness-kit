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
(cd "$T" && DRSG_TOKEN="$TOKEN" "$BIN" --db "$T/m.drsg" serve --addr "127.0.0.1:$PORT" >"$T/daemon.log" 2>&1) &
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
python3 - "$REPO" "$T" <<'PY'
import importlib.util, os, sys

repo, tmp = sys.argv[1], sys.argv[2]
api, token = os.environ["DRSG_API"], os.environ["DRSG_TOKEN"]
proj = os.path.join(tmp, "proj")
os.makedirs(os.path.join(proj, ".drsg"))


def load(name, path):
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


def event(key, status, created_at):
    ev.rpc("node.create", {"plane": "memory", "key": key, "labels": ["Event"],
                           "properties": {"kind": "notice", "status": status,
                                          "summary": key, "from_project": "sender",
                                          "created_at": created_at}}, token)
    ev.rpc("edge.create", {"plane": "memory", "src": key, "dst": project["id"],
                           "type": "NOTIFY"}, token)


OLD = "evt-old-open"
event(OLD, "open", 1000)
for i in range(25):
    event("evt-done-%02d" % i, "done", 2000 + i)

ran = ok = 0


def check(name, cond):
    global ran, ok
    ran += 1
    ok += bool(cond)
    print("%s %s" % ("ok  " if cond else "FAIL", name))


# 1. event.fetch with status pushed down.
keys = [n.get("external_key") for n in ev.fetch(proj, token, status="open")]
check("event.fetch(status=open) returns the open Event behind 25 done", OLD in keys)
check("event.fetch(status=open) returns only open Events", keys == [OLD])

# 2. The CLI list (humans) shows it too.
import io, contextlib, types
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ev.cmd_list(types.SimpleNamespace(project=proj), token)
check("event.py list shows the open Event", OLD in buf.getvalue())

# 3. MCP event_list (default status=open).
sys.argv = [os.path.join(repo, "tools", "mcp_events.py"), proj]
mcp = load("mcp_events", os.path.join(repo, "tools", "mcp_events.py"))
mcp.ev.API = api
out = mcp.call_tool("event_list", {"project": proj}, token)
check("event_list shows the open Event", OLD in out)

# 4. The poller's view.
poller = load("event_poller", os.path.join(repo, "tools", "event-poller.py"))
rows = poller.open_events(proj)
check("event-poller open_events sees the open Event", OLD in [r["key"] for r in rows])

# 5. SessionStart and UserPromptSubmit.
hooks = os.path.join(repo, "tools", "templates", "hooks")
sys.path.insert(0, hooks)
ss = load("session_start", os.path.join(hooks, "session_start.py"))
ss.API = api
check("SessionStart open_events shows the open Event",
      OLD in [e["key"] for e in ss.open_events(proj, token)])
up = load("user_prompt", os.path.join(hooks, "user_prompt.py"))
up.API = api
lines = up.event_notice(proj, "sid-open-window", token)
check("UserPromptSubmit event_notice shows the open Event",
      any(OLD in line for line in (lines or [])))

print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ok == ran else 1)
PY

#!/usr/bin/env bash
# Verify SessionStart reports local hook drift through its human-visible channel.
set -u
unset DRSG_EVENT_LANES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK_SOURCE="${SESSION_START_SOURCE:-$REPO/tools/templates/hooks/session_start.py}"
MEM_BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
if [ ! -x "$MEM_BIN" ]; then MEM_BIN="$(command -v drsg || true)"; fi
if [ -z "$MEM_BIN" ] || [ ! -x "$MEM_BIN" ]; then
  echo "SKIP session-start-hook-drift: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi
for tool in curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP session-start-hook-drift: missing $tool"
    exit 0
  fi
done

T="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
TOKEN="hook-drift-token"
MEM_DIR="$T/memory tools"
API="http://127.0.0.1:$PORT/rpc"
mkdir -p "$MEM_DIR/tools/templates/hooks" "$T/home"
cp "$HOOK_SOURCE" "$MEM_DIR/tools/templates/hooks/session_start.py"
printf '#!/bin/sh\nexit 0\n' > "$MEM_DIR/tools/install.sh"
chmod +x "$MEM_DIR/tools/install.sh"

DRSG_TOKEN="$TOKEN" "$MEM_BIN" --db "$T/memory.drsg" serve --addr "127.0.0.1:$PORT" >"$T/daemon.log" 2>&1 &
DAEMON=$!
cleanup() {
  kill "$DAEMON" 2>/dev/null || true
  wait "$DAEMON" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done
if ! curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "FAIL session-start-hook-drift: temporary drsg daemon did not start"
  exit 1
fi

NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
DRSG_API="$API" DRSG_TOKEN="$TOKEN" DRSG_MEM_DIR="$MEM_DIR" \
SESSION_START_SOURCE="$HOOK_SOURCE" python3 - "$REPO" "$T" <<'PY'
import importlib.util
import io
import json
import os
import shlex
import shutil
import sys
import time
import urllib.request

repo, tmp = sys.argv[1:]
api, token = os.environ["DRSG_API"], os.environ["DRSG_TOKEN"]
mem_dir = os.environ["DRSG_MEM_DIR"]
hook_source = os.environ["SESSION_START_SOURCE"]
spec = importlib.util.spec_from_file_location("session_start", hook_source)
ss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ss)


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=5) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError("fixture RPC failed: " + str(result["error"].get("code")))
    return result.get("result")


rpc("plane.create", {"name": "memory"})
checks = []
only = os.environ.get("ONLY", "")
ran = ok = 0

def check(name, condition):
    global ran, ok
    if only and name != only:
        return
    ran += 1
    ok += bool(condition)
    print(("ok   " if condition else "FAIL ") + name)


def make_project(name, with_env=True, with_hooks=True):
    project = os.path.join(tmp, name)
    os.makedirs(project)
    if with_hooks:
        project_hooks = os.path.join(project, ".claude", "hooks")
        os.makedirs(project_hooks)
        template = os.path.join(mem_dir, "tools", "templates", "hooks", "session_start.py")
        deployed = os.path.join(project_hooks, "session_start.py")
        shutil.copyfile(template, deployed)
        with open(deployed, "ab") as fh:
            fh.write(b"\n# deliberately drifted\n")
    if with_env:
        os.makedirs(os.path.join(project, ".drsg"), exist_ok=True)
    return project


def write_env(project, address, secret):
    with open(os.path.join(project, ".drsg", "env"), "w", encoding="utf-8") as fh:
        fh.write("DRSG_TOKEN=" + secret + "\nDRSG_API=" + address + "\nDRSG_PLANE=memory\n")


def invoke(project, source, sid):
    for key in ("DRSG_TOKEN", "DRSG_API", "DRSG_PLANE"):
        os.environ.pop(key, None)
    os.environ["CLAUDE_PROJECT_DIR"] = project
    os.environ["DRSG_MEM_DIR"] = mem_dir
    ss.API = "http://127.0.0.1:7700/rpc"
    ss.PLANE = "memory"
    stdout, stderr = io.StringIO(), io.StringIO()
    old_in, old_out, old_err = sys.stdin, sys.stdout, sys.stderr
    try:
        sys.stdin = io.StringIO(json.dumps({"session_id": sid, "source": source,
                                           "cwd": project}))
        sys.stdout, sys.stderr = stdout, stderr
        ss.main()
    finally:
        sys.stdin, sys.stdout, sys.stderr = old_in, old_out, old_err
    lines = stdout.getvalue().splitlines()
    if len(lines) != 1:
        raise AssertionError("expected exactly one SessionStart JSON object")
    return json.loads(lines[0])


# Missing/empty runtime templates, no project hooks, and template read errors fail silently.
no_hooks = make_project("no project hooks", with_env=False, with_hooks=False)
check("project-without-hooks-is-silent", ss.hook_drift_message(no_hooks) == "")
drift_probe = make_project("drift probe")
original_mem_dir = os.environ["DRSG_MEM_DIR"]
empty_runtime = os.path.join(tmp, "empty runtime")
os.makedirs(os.path.join(empty_runtime, "tools", "templates", "hooks"))
os.environ["DRSG_MEM_DIR"] = empty_runtime
check("empty-runtime-template-set-is-silent", ss.hook_drift_message(drift_probe) == "")
missing_runtime = os.path.join(tmp, "missing runtime")
os.environ["DRSG_MEM_DIR"] = missing_runtime
check("missing-runtime-template-dir-is-silent", ss.hook_drift_message(drift_probe) == "")
os.environ["DRSG_MEM_DIR"] = original_mem_dir
broken = os.path.join(mem_dir, "tools", "templates", "hooks", "broken.py")
os.symlink(os.path.join(tmp, "missing-template-target"), broken)
check("unreadable-runtime-template-is-silent", ss.hook_drift_message(drift_probe) == "")
os.unlink(broken)

# The no-token path must still expose drift to the human without requiring a daemon.
no_token = make_project("no token project", with_env=False)
out = invoke(no_token, "startup", "n5-no-token")
payload = out["hookSpecificOutput"]
check("no-token-path-reports-drift", bool(out.get("systemMessage")))
check("no-token-path-has-no-additional-context", "additionalContext" not in payload)
check("no-token-path-emits-one-json-object", payload.get("hookEventName") == "SessionStart")

# A bad daemon address exercises the second early return; only user-facing drift survives.
down = make_project("daemon down project")
write_env(down, "http://127.0.0.1:1/rpc", "fixture-dead-token")
out = invoke(down, "startup", "n5-daemon-down")
check("daemon-down-path-reports-drift", bool(out.get("systemMessage")))
check("daemon-down-path-has-no-briefing-context",
      out["hookSpecificOutput"].get("additionalContext") ==
      "DrSG memory is unavailable; this session's Event list is not "
      "trustworthy. Restore the daemon before checking open Events.")

# The normal path runs against a real temporary daemon and includes a briefing.
normal = make_project("normal project")
write_env(normal, api, token)
project_key = os.path.basename(normal)
project = rpc("node.create", {"plane": "memory", "key": project_key,
                              "labels": ["Project"], "properties": {"path": normal}})
fact_key = "n5-hook-drift-fact"
rpc("node.create", {"plane": "memory", "key": fact_key, "labels": ["Fact"],
                    "properties": {"kind": "test", "summary": "drift fixture briefing",
                                   "detail": "visible only in this temporary graph",
                                   "created_at": int(time.time())}})
rpc("edge.create", {"plane": "memory", "src": fact_key, "dst": project["id"], "type": "ABOUT"})
out = invoke(normal, "startup", "n5-normal")
payload = out["hookSpecificOutput"]
context = payload.get("additionalContext", "")
refresh = out.get("systemMessage", "")
installer = shlex.quote(os.path.join(mem_dir, "tools", "install.sh"))
check("normal-path-reports-drift", bool(refresh))
check("normal-path-has-existing-briefing", "Briefing:" in context and "drift fixture" in context)
check("drift-refresh-command-quotes-spaced-paths",
      installer in refresh and shlex.quote(normal) in refresh)
check("drift-prompt-stays-out-of-model-context", installer not in context)

# Existing Event systemMessage and drift prompt must both survive the merge.
event_key = "n5-drift-system-message-event"
rpc("node.create", {"plane": "memory", "key": event_key, "labels": ["Event"],
                     "properties": {"kind": "handoff", "status": "open",
                                    "summary": "drift event sentinel",
                                    "from_project": "fixture", "created_at": int(time.time())}})
rpc("edge.create", {"plane": "memory", "src": event_key, "dst": project["id"], "type": "NOTIFY"})
out = invoke(normal, "startup", "n5-event-merge")
merged = out.get("systemMessage", "")
check("event-system-message-is-preserved-with-drift",
      "drift event sentinel" in merged and installer in merged)
rpc("node.update", {"plane": "memory", "key": event_key, "set": {"status": "done"}})

# Restoring the deployed hook makes the drift prompt disappear. Disable the
# independent backup reminder for this one invocation so this check stays about drift.
shutil.copyfile(os.path.join(mem_dir, "tools", "templates", "hooks", "session_start.py"),
                os.path.join(normal, ".claude", "hooks", "session_start.py"))
old_max_age = os.environ.get("DRSG_BACKUP_MAX_AGE_DAYS")
os.environ["DRSG_BACKUP_MAX_AGE_DAYS"] = "0"
try:
    out = invoke(normal, "startup", "n5-restored")
finally:
    if old_max_age is None:
        os.environ.pop("DRSG_BACKUP_MAX_AGE_DAYS", None)
    else:
        os.environ["DRSG_BACKUP_MAX_AGE_DAYS"] = old_max_age
check("identical-hooks-are-silent", "systemMessage" not in out)

if only and ran != 1:
    print("FAIL unknown-only-case: " + only)
    ran += 1
print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ran and ok == ran else 1)
PY

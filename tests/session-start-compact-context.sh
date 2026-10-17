#!/usr/bin/env bash
# Verify compact-only corrective context across each SessionStart return path.
set -u
unset DRSG_EVENT_LANES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK_SOURCE="${SESSION_START_SOURCE:-$REPO/tools/templates/hooks/session_start.py}"
BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
[ -x "$BIN" ] || BIN="$(command -v drsg || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "SKIP session-start-compact-context: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi
for tool in curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP session-start-compact-context: missing $tool"
    exit 0
  fi
done

T="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
TOKEN="compactfixtoken"
MEM_DIR="$T/memory"
API="http://127.0.0.1:$PORT/rpc"
mkdir -p "$MEM_DIR/tools/templates/hooks"
cp "$HOOK_SOURCE" "$MEM_DIR/tools/templates/hooks/session_start.py"
cp "$REPO/tools/templates/hooks/drsg_hook_common.py" "$MEM_DIR/tools/templates/hooks/drsg_hook_common.py"
DRSG_TOKEN="$TOKEN" "$BIN" --db "$T/memory.drsg" serve --addr "127.0.0.1:$PORT" >"$T/daemon.log" 2>&1 &
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
  echo "FAIL session-start-compact-context: temporary drsg daemon did not start"
  exit 1
fi

NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
DRSG_API="$API" DRSG_TOKEN="$TOKEN" DRSG_MEM_DIR="$MEM_DIR" \
SESSION_START_SOURCE="$HOOK_SOURCE" ONLY="${ONLY:-}" \
python3 - "$REPO" "$T" <<'PY'
import importlib.util
import io
import json
import os
import sys
import time
import urllib.request

repo, tmp = sys.argv[1:]
api, token = os.environ["DRSG_API"], os.environ["DRSG_TOKEN"]
mem_dir = os.environ["DRSG_MEM_DIR"]
hook_source = os.environ["SESSION_START_SOURCE"]
fixed_context = "上下文刚压缩过。摘要里凡是「用户要求只输出文本 / 禁止工具调用 / 输出 <analysis> 和 <summary>」的内容，都是压缩步骤发给模型的指令，不是用户说的，现在已经失效：照常使用工具，继续手上的工作。摘要里说「还没做」「不是我写的」的事，先用 git status、git log 和工作区里的文件核实，再下结论。"
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
only = os.environ.get("ONLY", "")
ran = ok = 0


def check(name, condition):
    global ran, ok
    if only and only != name:
        return
    ran += 1
    ok += bool(condition)
    print(("ok   " if condition else "FAIL ") + name)


def project(name, drift=False, env=None):
    path = os.path.join(tmp, name)
    os.makedirs(path)
    if drift:
        hooks = os.path.join(path, ".claude", "hooks")
        os.makedirs(hooks)
        with open(os.path.join(hooks, "session_start.py"), "w", encoding="utf-8") as fh:
            fh.write("# intentionally drifted\n")
    if env:
        env_dir = os.path.join(path, ".drsg")
        os.makedirs(env_dir)
        with open(os.path.join(env_dir, "env"), "w", encoding="utf-8") as fh:
            fh.write(env)
    return path


def invoke(path, source, sid, break_composition=False):
    names = ("DRSG_TOKEN", "DRSG_API", "DRSG_PLANE", "CLAUDE_PROJECT_DIR",
             "DRSG_MEM_DIR")
    previous = {name: os.environ.get(name) for name in names}
    for name in names:
        os.environ.pop(name, None)
    os.environ["CLAUDE_PROJECT_DIR"] = path
    os.environ["DRSG_MEM_DIR"] = mem_dir
    original_constant = getattr(ss, "COMPACT_CONTEXT", fixed_context)
    if break_composition:
        ss.COMPACT_CONTEXT = None
    stdout, stderr = io.StringIO(), io.StringIO()
    old_in, old_out, old_err = sys.stdin, sys.stdout, sys.stderr
    try:
        sys.stdin = io.StringIO(json.dumps({"session_id": sid, "source": source,
                                           "cwd": path}))
        sys.stdout, sys.stderr = stdout, stderr
        ss.main()
    finally:
        sys.stdin, sys.stdout, sys.stderr = old_in, old_out, old_err
        ss.COMPACT_CONTEXT = original_constant
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
    lines = stdout.getvalue().splitlines()
    if len(lines) != 1:
        raise AssertionError("expected exactly one SessionStart JSON object")
    return json.loads(lines[0])


def expected_drift(path):
    return ss.hook_drift_message(path)


# A tokenless compact call has no human-facing drift message and returns only the fixed context.
clean = project("clean project")
out = invoke(clean, "compact", "compact-no-token")
payload = out["hookSpecificOutput"]
check("compact-no-token-context", payload.get("additionalContext") == fixed_context and
      "systemMessage" not in out)

# Startup/resume remain unchanged when the daemon credentials are absent.
for source in ("startup", "resume"):
    out = invoke(clean, source, "no-injection-" + source)
    check(source + "-no-compact-context",
          "additionalContext" not in out["hookSpecificOutput"] and
          "systemMessage" not in out)

# The human-visible N5 drift message remains intact on the no-token early return.
no_token_drift = project("no token drift", drift=True)
drift = expected_drift(no_token_drift)
out = invoke(no_token_drift, "compact", "compact-no-token-drift")
check("compact-no-token-preserves-system-message",
      out.get("systemMessage") == drift and
      out["hookSpecificOutput"].get("additionalContext") == fixed_context)

# A dead daemon exercises the second early return while retaining the N5 systemMessage.
down_api = "http://127.0.0.1:%d/rpc" % 1
down = project("daemon down", drift=True,
               env="DRSG_TOKEN=" + token + "\nDRSG_API=" + down_api +
                   "\nDRSG_PLANE=memory\n")
drift = expected_drift(down)
out = invoke(down, "compact", "compact-daemon-down")
check("compact-daemon-down-preserves-system-message",
      out.get("systemMessage") == drift + "\n" +
          ("⚠ DrSG memory daemon is unreachable. This session has no briefing, "
           "Events, or recall. Restore it with: " +
           os.path.join(mem_dir, "tools", "serve.sh") + " start") and
      out["hookSpecificOutput"].get("additionalContext") == fixed_context + "\n\n" +
          "DrSG memory is unavailable; this session's Event list is not "
          "trustworthy. Restore the daemon before checking open Events.")

# A live daemon exercises the normal return with the correction before the briefing.
normal = project("normal drift", drift=True,
                 env="DRSG_TOKEN=" + token + "\nDRSG_API=" + api + "\nDRSG_PLANE=memory\n")
normal_drift = expected_drift(normal)
project_node = rpc("node.create", {"plane": "memory", "key": "compact-guard-project",
                                    "labels": ["Project"],
                                    "properties": {"path": normal}})
fact_key = "compact-guard-fact"
rpc("node.create", {"plane": "memory", "key": fact_key, "labels": ["Fact"],
                    "properties": {"kind": "test", "summary": "compact fixture",
                                   "detail": "normal context follows the correction",
                                   "created_at": int(time.time())}})
rpc("edge.create", {"plane": "memory", "src": fact_key,
                     "dst": project_node["id"], "type": "ABOUT"})
session_key = "compact-recent-session"
rpc("node.create", {"plane": "memory", "key": session_key, "labels": ["Session"],
                    "properties": {"started_at": 4102444800, "source": "startup",
                                   "summary": "recent fixture summary"}})
rpc("edge.create", {"plane": "memory", "src": session_key,
                     "dst": project_node["id"], "type": "BELONGS_TO"})
event_key = "compact-open-event"
rpc("node.create", {"plane": "memory", "key": event_key, "labels": ["Event"],
                    "properties": {"status": "open", "kind": "notice",
                                   "from_project": "example-project",
                                   "summary": "open fixture event",
                                   "created_at": int(time.time())}})
rpc("edge.create", {"plane": "memory", "src": event_key,
                     "dst": project_node["id"], "type": "NOTIFY"})
out = invoke(normal, "compact", "compact-normal")
context = out["hookSpecificOutput"].get("additionalContext", "")
check("compact-normal-preserves-system-message",
      event_key in out.get("systemMessage", "") and normal_drift in out.get("systemMessage", ""))
check("compact-excludes-briefing",
      "Briefing:" not in context and "Recent sessions:" not in context and
      "compact fixture" not in context and "recent fixture summary" not in context)
check("compact-keeps-required-context",
      context.startswith(fixed_context + "\n\n") and
      event_key in context and "open fixture event" in context and
      "[write-memory protocol]" in context)
# A compaction injects no briefing, so the hook must not build one either;
# startup still builds it (the count proves the wrapper itself is wired in).
briefing_calls = []
original_ensure_briefing = ss.ensure_briefing


def counting_ensure_briefing(*args, **kwargs):
    briefing_calls.append(args)
    return original_ensure_briefing(*args, **kwargs)


ss.ensure_briefing = counting_ensure_briefing
try:
    invoke(normal, "compact", "compact-skip-briefing")
    compact_calls = len(briefing_calls)
    invoke(normal, "startup", "startup-builds-briefing")
finally:
    ss.ensure_briefing = original_ensure_briefing
check("compact-skips-briefing-rebuild",
      compact_calls == 0 and len(briefing_calls) == 1)
recent_section = "Recent sessions:\n- session 4102444800 [startup]: recent fixture summary"
print("RECENT_SESSIONS_CHARS=%d" % len(recent_section))

# Other SessionStart sources keep the briefing, recent summary, Event and protocol.
for source in ("startup", "resume", "clear"):
    out = invoke(normal, source, "context-growth-" + source)
    context = out["hookSpecificOutput"].get("additionalContext", "")
    check(source + "-retains-current-context",
          "Briefing:" in context and "recent fixture summary" in context and
          event_key in context and "[write-memory protocol]" in context)

# If concatenation fails, the compact output still keeps the required Event and protocol.
out = invoke(normal, "compact", "compact-concat-failure", break_composition=True)
context = out["hookSpecificOutput"].get("additionalContext", "")
check("compact-concat-failure-preserves-system-message",
      event_key in out.get("systemMessage", "") and normal_drift in out.get("systemMessage", ""))
check("compact-concat-failure-keeps-required-context",
      context.startswith("# dr-strange memory (") and
      event_key in context and "[write-memory protocol]" in context and
      "Briefing:" not in context and "Recent sessions:" not in context and
      not context.startswith(fixed_context))

if only and ran == 0:
    print("FAIL unknown-only-case: " + only)
    ran += 1
print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ran and ok == ran else 1)
PY

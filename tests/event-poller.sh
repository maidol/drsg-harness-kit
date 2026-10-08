#!/usr/bin/env bash
# Lease takeover checks for tools/event-poller.py, driven by its test hooks
# (EVENT_POLL_FAKE, EVENT_POLL_OWNER_PID): no daemon, no Claude Code needed.
# The last line is "PASS n/n" only when every check ran and passed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="${POLLER:-$HERE/../tools/event-poller.py}"
T="$(mktemp -d)"
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/proj/.drsg" "$T/mem"; touch "$T/proj/.drsg/env"
echo '[{"key":"e1","kind":"handoff","summary":"x","status":"open"}]' > "$T/events.json"
export DRSG_MEM_DIR="$T/mem" EVENT_POLL_TICK=1 EVENT_POLL_FAKE="$T/events.json" CLAUDE_PROJECT_DIR="$T/proj"
LEASE="$T/mem/poller/$(python3 -c 'import hashlib,os,sys; print(hashlib.sha1(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:12])' "$T/proj")/lease.json"
RAN=0; OK=0
check() { RAN=$((RAN+1)); if [ "$2" = "$3" ]; then OK=$((OK+1)); echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fi; }
holder() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session_id",""))' "$LEASE" 2>/dev/null; }
# Owners keep no stdout, or `tests/event-poller.sh | tail` waits for them.
# Detached from this shell's ancestry: run from inside a background Claude Code session,
# an ancestor carries --bg-pty-host and every owner would count as background.
fg_owner() { OWNER=$( (sleep 300 >/dev/null 2>&1 & echo $!) ); PIDS+=($OWNER); }
bg_owner() {   # a process whose parent's argv carries --bg-pty-host, like claude's bg sessions
  python3 -c 'import subprocess; subprocess.run(["sleep", "300"])' --bg-pty-host >/dev/null 2>&1 & PIDS+=($!)
  for _ in $(seq 50); do OWNER=$(pgrep -P $! sleep) && break; sleep 0.1; done
  PIDS+=($OWNER)
}
run() { echo "{\"session_id\":\"$1\",\"hook_event_name\":\"${3:-Stop}\"}" | EVENT_POLL_OWNER_PID=$2 timeout "${4:-5}" python3 "$POLLER" 2>/dev/null; echo $?; }
reset() { rm -rf "$T/mem/poller"; }

# 1. a foreground holder is not taken over while it lives; kill -9 hands it on
reset; fg_owner; A=$OWNER; fg_owner; B=$OWNER
check "first session wakes"            "$(run A $A)" 2
check "second waits while holder lives" "$(run B $B Stop 3)" 124
check "lease still with A"             "$(holder)" A
kill -9 $A
check "kill -9 holder: B wakes"        "$(run B $B)" 2
check "lease moved to B"               "$(holder)" B
run B $B SessionEnd >/dev/null
check "SessionEnd releases"            "$([ -e "$LEASE" ] && echo kept || echo released)" released

# 2. a background holder yields to a foreground session, never to another background one
reset; bg_owner; A=$OWNER; bg_owner; C=$OWNER; fg_owner; B=$OWNER
check "background session wakes"      "$(run A $A)" 2
check "background does not take from background" "$(run C $C Stop 3)" 124
check "lease still with A"             "$(holder)" A
check "foreground takes from background" "$(run B $B)" 2
check "lease moved to B"               "$(holder)" B
run A $A Stop 3 >/dev/null   # A has seen e1, so its exit code says nothing; the lease does
check "background does not take it back" "$(holder)" B

# 3. seen.json lives exactly as long as its session; a dead session's leftovers age out
STATE="$(dirname "$LEASE")"
reset; fg_owner; A=$OWNER
run A $A >/dev/null
check "Stop after a wake does not wake again" "$(run A $A Stop 3)" 124
check "seen.json is named by session and process" "$([ -e "$STATE/A.$A.seen.json" ] && echo named || echo missing)" named
run A $A SessionEnd >/dev/null
check "SessionEnd removes seen.json"   "$([ -e "$STATE/A.$A.seen.json" ] && echo kept || echo removed)" removed
reset; fg_owner; A=$OWNER; mkdir -p "$STATE"
echo '[]' > "$STATE/old.seen.json"; touch -d '20 days ago' "$STATE/old.seen.json"
echo '[]' > "$STATE/new.seen.json"
run A $A Stop 3 >/dev/null
check "old orphan swept, recent one kept" "$([ -e "$STATE/old.seen.json" ] && echo old-kept || echo old-gone),$([ -e "$STATE/new.seen.json" ] && echo new-kept || echo new-gone)" old-gone,new-kept

# 4. poller.log stays bounded and the newest lines survive the rotation
reset; fg_owner; A=$OWNER; mkdir -p "$STATE"
head -c 2000 /dev/zero | tr '\0' x > "$STATE/poller.log"
EVENT_POLL_LOG_MAX=1000 run A $A >/dev/null
check "log rotated, old lines kept in .1" "$([ "$(stat -c %s "$STATE/poller.log")" -lt 1000 ] && grep -q xxxx "$STATE/poller.log.1" && echo rotated || echo not)" rotated
check "newest lease line is in the live log" "$(grep -c 'lease ->' "$STATE/poller.log")" 1

# 5. a sender's kick cuts the wait to about a second; without it the INTERVAL holds
EVENT_PY="$HERE/../tools/event.py"
post_to() {   # event.py post() with the daemon faked out, so only its kick reaches the disk
  python3 - "$EVENT_PY" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ev", sys.argv[1])
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
ev.rpc = lambda method, params, token: {"id": 1}
ev.post(sys.argv[2], 1, "x", "notice", "", "test", "")
PY
}
late_event() {   # $1 = post|quiet; prints the exit code of a poller that sees e1 appear 2s after it started
  reset; echo '[]' > "$T/later.json"
  ( echo '{"session_id":"A","hook_event_name":"Stop"}' \
      | EVENT_POLL_FAKE="$T/later.json" EVENT_POLL_INTERVAL=3600 EVENT_POLL_TICK=60 \
        EVENT_POLL_OWNER_PID=$LA timeout 8 python3 "$POLLER" 2>/dev/null
    echo $? > "$T/rc" ) &
  local job=$!
  sleep 2
  cp "$T/events.json" "$T/later.json"
  if [ "$1" = post ]; then post_to "$T/proj"; fi
  wait $job
  cat "$T/rc"
}
fg_owner; LA=$OWNER
check "post wakes a waiting poller within seconds" "$(late_event post)" 2
check "no post, no early look (INTERVAL holds)"   "$(late_event quiet)" 124
reset; post_to "$T/elsewhere"
check "post to an unpolled project writes nothing" "$(ls "$T/mem/poller" 2>/dev/null | wc -l)" 0

# 6. a stopped holder (Ctrl+Z, terminal gone) counts as gone: it can act on no wake-up
reset; fg_owner; A=$OWNER; fg_owner; B=$OWNER
run A $A >/dev/null
kill -STOP $A
check "stopped holder: B takes over and wakes" "$(run B $B)" 2
check "lease moved off the stopped holder"     "$(holder)" B
check "a stopped session's own poller exits"   "$(run A $A Stop 3)" 0
kill -CONT $A

# 7. setup.sh registers the poller on StopFailure too: a turn that ends in an API error
#    fires StopFailure, not Stop, and the poller it woke must still be started again
HOME="$T/home" DRSG_MEM_DIR="$T/setup-mem" CLAUDE_CONFIG_DIR="$T/claude" \
  bash "$HERE/../setup.sh" --no-skills >/dev/null 2>&1
stopfailure_hook() {
  python3 - "$T/claude/settings.json" <<'PY'
import json, sys
try:
    groups = json.load(open(sys.argv[1])).get("hooks", {}).get("StopFailure", [])
except (OSError, ValueError):
    groups = []
hooks = [h for g in groups for h in g.get("hooks", []) if "event-poller.py" in h.get("command", "")]
print("missing" if not hooks else "asyncRewake" if hooks[0].get("asyncRewake") else "sync")
PY
}
check "setup registers StopFailure as asyncRewake" "$(stopfailure_hook)" asyncRewake

# 8. the wake-up text tells a verdict apart from work: "验收通过：" gets event_done, no reply
reset; fg_owner; A=$OWNER
check "wake text says verdicts need no reply" "$(echo '{"session_id":"A","hook_event_name":"Stop"}' \
  | EVENT_POLL_OWNER_PID=$A timeout 5 python3 "$POLLER" 2>&1 >/dev/null | grep -c '验收通过：」开头的判定只需 event_done')" 1

# 9. the wake-up text says a handoff needs no "read it" reply before the work
reset; fg_owner; A=$OWNER
check "wake text says handoffs need no read receipt" "$(echo '{"session_id":"A","hook_event_name":"Stop"}' \
  | EVENT_POLL_OWNER_PID=$A timeout 5 python3 "$POLLER" 2>&1 >/dev/null | grep -c '收到 handoff 直接开工，不要先回「已读」')" 1

# 10. two processes on one session id (two terminals resuming it): one owner, and the
#     first to exit neither kills the other's poller nor hides an Event from it
lease_pid() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$LEASE" 2>/dev/null; }
reset; fg_owner; A=$OWNER; fg_owner; B=$OWNER
check "same sid: first process wakes"   "$(run S $A)" 2
( run S $B Stop 15 > "$T/rc-b" ) &
WAITER=$!
sleep 2
check "same sid: second process does not take the lease" "$(lease_pid)" "$A"
run S $A SessionEnd >/dev/null
kill -9 $A
wait $WAITER
check "same sid: first one's exit leaves the other's poller, which wakes" "$(cat "$T/rc-b")" 2
check "same sid: lease moved to the second process" "$(lease_pid)" "$B"

# 11. taking the lease back re-announces what is still open: the owner in between may not have done it
reset; bg_owner; A=$OWNER; fg_owner; B=$OWNER
check "background owner wakes"          "$(run A $A)" 2
check "foreground takes over and wakes" "$(run B $B)" 2
run B $B SessionEnd >/dev/null
kill -9 $B
check "background takes it back and is told again" "$(run A $A)" 2

# 12. the session hooks say which session executes the Events, read from the poller's lease
TPL="$HERE/../tools/templates/hooks"
owner_line() {   # $1 = hook template, $2 = session id; EVENT_POLL_OWNER_PID is "this" Claude Code
  python3 - "$TPL/$1" "$T/proj" "$2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.event_owner(sys.argv[2], sys.argv[3]))
PY
}
hook_main() {   # $1 = hook template, $2 = output field; one open Event, the daemon faked out
  python3 - "$TPL/$1" "$T/proj" "$2" <<'PY'
import importlib.util, io, json, os, sys
spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def rpc(method, params, token):
    if "NOTIFY" in (params or {}).get("query", ""):
        return {"nodes": [{"external_key": "e1", "properties": {
            "status": "open", "kind": "handoff", "summary": "x", "seen_at": 1}}]}
    return {"nodes": [], "id": 1}
m.rpc = rpc
os.environ["DRSG_TOKEN"] = "t"
os.environ["CLAUDE_PROJECT_DIR"] = sys.argv[2]
sys.stdin = io.StringIO(json.dumps({"session_id": "B", "source": "resume", "prompt": "hello there"}))
out = io.StringIO()
real, sys.stdout = sys.stdout, out
try:
    m.main()
finally:
    sys.stdout = real
d = json.loads(out.getvalue())
print(d.get(sys.argv[3]) or (d.get("hookSpecificOutput") or {}).get(sys.argv[3]) or "")
PY
}
reset; fg_owner; A=$OWNER; fg_owner; B=$OWNER
for h in session_start.py user_prompt.py; do
  check "$h: no owner yet, read-only until woken" "$(EVENT_POLL_OWNER_PID=$A owner_line $h A | grep -c '现在没有 Event owner')" 1
done
run A $A >/dev/null
for h in session_start.py user_prompt.py; do
  check "$h: the lease holder is the owner"       "$(EVENT_POLL_OWNER_PID=$A owner_line $h A | grep -c '本会话是这个项目的 Event owner')" 1
  check "$h: same sid, other process, read-only" "$(EVENT_POLL_OWNER_PID=$B owner_line $h A | grep -c '本会话只读')" 1
  check "$h: another session, read-only"         "$(EVENT_POLL_OWNER_PID=$B owner_line $h B | grep -c '本会话只读')" 1
done
check "session_start puts the owner line in the model's context" "$(EVENT_POLL_OWNER_PID=$B hook_main session_start.py additionalContext | grep -c '本会话只读')" 1
check "session_start puts the owner line on the terminal"        "$(EVENT_POLL_OWNER_PID=$B hook_main session_start.py systemMessage | grep -c '本会话只读')" 1
check "user_prompt puts the owner line on the terminal"          "$(EVENT_POLL_OWNER_PID=$B hook_main user_prompt.py systemMessage | grep -c '本会话只读')" 1

# 13. only the owner closes: event_done (MCP) and event.py done refuse another Claude Code session
close_as() {   # $1 = mcp|cli, $2 = force|plain; EVENT_POLL_OWNER_PID is the caller (0 = a person's shell)
  python3 - "$HERE/../tools" "$T/proj" "$1" "$2" <<'PY'
import contextlib, importlib.util, io, os, sys
tools, proj, path, force = sys.argv[1:5]
os.environ["DRSG_TOKEN"] = "t"
os.environ["CLAUDE_PROJECT_DIR"] = proj
calls = []
def rpc(method, params, token):
    calls.append(method)
    return {"labels": ["Event"], "properties": {"status": "done"}}
def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(tools, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
if path == "mcp":
    sys.argv = ["mcp_events.py", proj]
    m = load("mcp_events")
    m.ev.rpc = rpc
    try:
        m.call_tool("event_done", {"key": "e1", "force": force == "force"}, "t")
        out = "closed"
    except RuntimeError as e:
        out = "refused" if "not the Event owner" in str(e) else "error: %s" % e
else:
    m = load("event")
    m.rpc = rpc
    sys.argv = ["event.py", "done", "e1"] + (["--force"] if force == "force" else [])
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            m.main()
        out = "closed"
    except SystemExit as e:
        out = "refused" if "not the Event owner" in str(e.code) else "error: %s" % e.code
if (out == "closed") != bool(calls):
    out += " (daemon %s)" % ("called" if calls else "not called")
print(out)
PY
}
reset; fg_owner; A=$OWNER; fg_owner; B=$OWNER
run A $A >/dev/null
for p in mcp cli; do
  check "$p: the owner closes"                  "$(EVENT_POLL_OWNER_PID=$A close_as $p plain)" closed
  check "$p: another session is refused"        "$(EVENT_POLL_OWNER_PID=$B close_as $p plain)" refused
  check "$p: force closes from another session" "$(EVENT_POLL_OWNER_PID=$B close_as $p force)" closed
  check "$p: a person's shell closes"           "$(EVENT_POLL_OWNER_PID=0 close_as $p plain)" closed
done
kill -9 $A
for p in mcp cli; do
  check "$p: owner gone, anyone closes"         "$(EVENT_POLL_OWNER_PID=$B close_as $p plain)" closed
done

echo "PASS $OK/$RAN"
[ "$RAN" -eq 55 ] && [ "$OK" -eq "$RAN" ]

#!/usr/bin/env bash
# Event lanes (DRSG_EVENT_LANES): one project's Events split between sessions
# by sender, driven by the poller's test hooks (EVENT_POLL_FAKE,
# EVENT_POLL_OWNER_PID). A fake Claude Code process declares its lanes in its
# own environment, which is where the poller, the hooks and event_done read them.
# ONLY=L4 runs one section. The last line is "PASS n/n" only when every check
# ran and passed.
set -u
# the fake owners inherit this shell's environment: a session started with lanes must not change which lane they hold
unset DRSG_EVENT_LANES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="${TOOLS:-$HERE/../tools}"
POLLER="$TOOLS/event-poller.py"
TPL="$TOOLS/templates/hooks"
T="$(mktemp -d)"
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/proj/.drsg" "$T/mem"; touch "$T/proj/.drsg/env"
EVENTS='[{"key":"e_kit","kind":"handoff","summary":"k","from_project":"drsg-harness-kit","status":"open"},
 {"key":"e_aar","kind":"handoff","summary":"a","from_project":"aar","status":"open"}]'
echo "$EVENTS" > "$T/events.json"
export DRSG_MEM_DIR="$T/mem" EVENT_POLL_TICK=1 EVENT_POLL_FAKE="$T/events.json" CLAUDE_PROJECT_DIR="$T/proj"
STATE="$T/mem/poller/$(python3 -c 'import hashlib,os,sys; print(hashlib.sha1(os.path.realpath(sys.argv[1]).encode()).hexdigest()[:12])' "$T/proj")"
RAN=0; OK=0
check() { RAN=$((RAN+1)); if [ "$2" = "$3" ]; then OK=$((OK+1)); echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fi; }
# $1 = lanes ("" = none). Detached, so no ancestor of this shell counts as background.
owner() { OWNER=$( (env ${1:+DRSG_EVENT_LANES=$1} sleep 300 >/dev/null 2>&1 & echo $!) ); PIDS+=($OWNER); }
run() { echo "{\"session_id\":\"$1\",\"hook_event_name\":\"Stop\"}" | EVENT_POLL_OWNER_PID=$2 timeout "${3:-5}" python3 "$POLLER" 2>/dev/null; echo $?; }
woke() { grep "wake $1:" "$STATE/poller.log" 2>/dev/null | tail -1 | sed "s/.*wake $1: //"; }
reset() { rm -rf "$T/mem/poller"; echo "$EVENTS" > "$T/events.json"; }
want() { [ -z "${ONLY:-}" ] || [ "$ONLY" = "$1" ]; }

# L1. no lane declared anywhere: one session gets every Event, and only lease.json exists
if want L1; then
reset; owner ""; A=$OWNER
check "L1 default session wakes"             "$(run A $A)" 2
check "L1 it is woken for every Event"       "$(woke A)" e_kit,e_aar
check "L1 only the default lease exists"     "$(cd "$STATE" && ls lease*.json | tr '\n' ' ')" "lease.json "
fi

# L2. a lane session gets its sender's Events, the default session the rest
if want L2; then
reset; owner aar; B=$OWNER; owner ""; A=$OWNER
check "L2 aar lane wakes"                    "$(run B $B)" 2
check "L2 aar lane is woken for aar only"    "$(woke B)" e_aar
check "L2 aar lane holds lease.aar.json"     "$([ -e "$STATE/lease.aar.json" ] && echo held || echo none)" held
check "L2 default wakes"                     "$(run A $A)" 2
check "L2 default is woken for the rest"     "$(woke A)" e_kit
check "L2 aar lane is not woken again"       "$(run B $B 3)" 124
fi

# L3. the lane session dies: its Events fall back to the default lane, which is told
if want L3; then
reset; owner aar; B=$OWNER; owner ""; A=$OWNER
run B $B >/dev/null; run A $A >/dev/null
kill -9 $B
check "L3 lane gone: default wakes"          "$(run A $A)" 2
check "L3 default is woken for the aar Event" "$(woke A)" e_aar
fi

# L4. sticky claim: an Event the default lane was woken for stays there
if want L4; then
reset; owner ""; A=$OWNER; owner aar; B=$OWNER
run A $A >/dev/null
check "L4 default took e_aar first"          "$(woke A)" e_kit,e_aar
check "L4 late aar lane is not woken for it" "$(run B $B 3)" 124
python3 - "$T/events.json" <<'PY'
import json, sys
ev = json.load(open(sys.argv[1]))
ev.append({"key": "e_aar2", "kind": "handoff", "summary": "a2", "from_project": "aar", "status": "open"})
json.dump(ev, open(sys.argv[1], "w"))
PY
check "L4 a new aar Event goes to the lane"  "$(run B $B)" 2
check "L4 lane is woken for the new one only" "$(woke B)" e_aar2
check "L4 default is not woken for it"       "$(run A $A 3)" 124
echo "$EVENTS" > "$T/events.json"
run A $A 3 >/dev/null
check "L4 closed Events leave claims.json"   "$(python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])))))' "$STATE/claims.json")" e_aar,e_kit
fi

# L5. event_done: only the owner of the Event's lane closes it; force still works
close_as() {   # $1 = key, $2 = force|plain; EVENT_POLL_OWNER_PID is the caller
  python3 - "$TOOLS" "$T/proj" "$1" "$2" <<'PY'
import importlib.util, os, sys
tools, proj, key, force = sys.argv[1:5]
os.environ["DRSG_TOKEN"] = "t"
senders = {"e_kit": "drsg-harness-kit", "e_aar": "aar"}
def rpc(method, params, token):
    if method == "plane.cypher":
        return {"nodes": [{"properties": {"from_project": senders[params["params"]["key"]]}}]}
    return {"labels": ["Event"], "properties": {"status": "done"}}
spec = importlib.util.spec_from_file_location("event", os.path.join(tools, "event.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.rpc = rpc
try:
    m.close(key, "t", project=proj, force=force == "force")
    print("closed")
except RuntimeError as e:
    s = str(e)
    print("refused" + (" lane aar" if " lane aar " in s else "") if "not the Event owner" in s else "error: %s" % s)
PY
}
if want L5; then
reset; owner aar; B=$OWNER; owner ""; A=$OWNER
run B $B >/dev/null; run A $A >/dev/null
check "L5 default closes its own Event"      "$(EVENT_POLL_OWNER_PID=$A close_as e_kit plain)" closed
check "L5 lane may not close a default Event" "$(EVENT_POLL_OWNER_PID=$B close_as e_kit plain)" refused
check "L5 lane closes its own Event"         "$(EVENT_POLL_OWNER_PID=$B close_as e_aar plain)" closed
check "L5 default may not close a lane Event, told which lane" "$(EVENT_POLL_OWNER_PID=$A close_as e_aar plain)" "refused lane aar"
check "L5 force closes across lanes"         "$(EVENT_POLL_OWNER_PID=$A close_as e_aar force)" closed
kill -9 $B
check "L5 lane gone: default closes it"      "$(EVENT_POLL_OWNER_PID=$A close_as e_aar plain)" closed
fi

# L6. the hooks' owner line says which lanes this session executes
owner_line() {   # $1 = hook template, $2 = session id
  python3 - "$TPL/$1" "$T/proj" "$2" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.event_owner(sys.argv[2], sys.argv[3]))
PY
}
if want L6; then
reset; owner ""; A=$OWNER
run A $A >/dev/null
check "L6 no lanes: owner line is unchanged" "$(EVENT_POLL_OWNER_PID=$A owner_line session_start.py A)" "本会话是这个项目的 Event owner：按 Event 流程处理。"
reset; owner aar; B=$OWNER; owner ""; A=$OWNER; owner aar; C=$OWNER; owner drsg-harness-kit; K=$OWNER
run B $B >/dev/null; run A $A >/dev/null
for h in session_start.py user_prompt.py; do
  check "L6 $h: default owner is told aar is not its" "$(EVENT_POLL_OWNER_PID=$A owner_line $h A | grep -c '车道 aar 的 Event 归各自的车道会话')" 1
  check "L6 $h: lane owner"                  "$(EVENT_POLL_OWNER_PID=$B owner_line $h B | grep -c '本会话是车道 aar 的 Event owner')" 1
  check "L6 $h: second aar session is read-only" "$(EVENT_POLL_OWNER_PID=$C owner_line $h C | grep -c '由别的会话持有，本会话只读')" 1
  check "L6 $h: lane without an owner yet"   "$(EVENT_POLL_OWNER_PID=$K owner_line $h K | grep -c '车道 drsg-harness-kit 现在没有 Event owner')" 1
done
export CLAUDE_CONFIG_DIR="$T/claude"
TR="$CLAUDE_CONFIG_DIR/projects/$(printf %s "$(realpath "$T/proj")" | tr -c 'A-Za-z0-9' '-')"
mkdir -p "$TR"; touch -d '-5 hours -5 minutes' "$TR/B.jsonl"
for h in session_start.py user_prompt.py; do
  check "L6 $h: idle lane owner, hours shown" "$(EVENT_POLL_OWNER_PID=$C owner_line $h C | grep -c 'aar（会话 B，已空闲 5 小时）')" 1
done
rm -rf "$CLAUDE_CONFIG_DIR"; unset CLAUDE_CONFIG_DIR
fi

# L7. --take --lane: names are checked; the agent is still blocked from running it
if want L7; then
reset
check "L7 bad lane name is a usage error"    "$(EVENT_POLL_OWNER_PID=1 python3 "$POLLER" --take --lane 'a/b' </dev/null >/dev/null 2>&1; echo $?)" 2
check "L7 unknown option is a usage error"   "$(EVENT_POLL_OWNER_PID=1 python3 "$POLLER" --take --bogus </dev/null >/dev/null 2>&1; echo $?)" 2
check "L7 pre_tool_use denies --take --lane" "$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"python3 ~/.drsg-memory/tools/event-poller.py --take --lane aar"}}' | python3 "$TPL/pre_tool_use.py" 2>/dev/null | grep -c '"deny"')" 1
fi

echo "PASS $OK/$RAN"
[ "$OK" -eq "$RAN" ] && { [ -n "${ONLY:-}" ] || [ "$RAN" -eq 37 ]; }

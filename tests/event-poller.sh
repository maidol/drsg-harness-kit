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
fg_owner() { sleep 300 >/dev/null 2>&1 & PIDS+=($!); OWNER=$!; }
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

echo "PASS $OK/$RAN"
[ "$RAN" -eq 12 ] && [ "$OK" -eq "$RAN" ]

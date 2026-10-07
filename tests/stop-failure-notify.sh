#!/usr/bin/env bash
# Contract tests for tools/stop-failure-notify.py and its setup.sh registration.
# Synthetic hook input only. The last line is "PASS n/n" only when every check ran.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../tools/stop-failure-notify.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/myproj"

RAN=0
OK=0
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
  fi
}

# Prints: whether stdout is one JSON object whose terminalSequence uses only
# OSC 0/1/2/9/99/777 and BEL (the allowlist Claude Code enforces), then the
# printable text inside it.
inspect() {
  python3 -c '
import json, re, sys
raw = sys.stdin.read()
try:
    seq = json.loads(raw)["terminalSequence"]
except Exception:
    print("no-json"); sys.exit()
allowed = re.fullmatch(r"(?:\x1b\](?:0|1|2|9|99|777);[^\x00-\x1f\x7f]*\x07|\x07)+", seq)
print("allowlisted" if allowed else "rejected")
print(re.sub(r"[\x00-\x1f]", "|", seq))
'
}
run() {  # stdin json -> inspect output
  (cd "$T/myproj" && python3 "$HOOK") | inspect
}

OUT="$(printf '%s' '{"session_id":"s","hook_event_name":"StopFailure","error":"model_not_found","error_details":"There is an issue with the selected model"}' | run)"
check "output is allowlisted terminalSequence" "$(echo "$OUT" | head -1)" allowlisted
check "names the project and error type"       "$(echo "$OUT" | grep -c 'Claude stopped: myproj (model_not_found)')" 1
check "carries an OSC 9 notification"          "$(echo "$OUT" | grep -c ']9;Claude stopped')" 1
check "carries an OSC 777 notification"        "$(echo "$OUT" | grep -c ']777;notify;Claude stopped')" 1
check "carries the error details"              "$(echo "$OUT" | grep -c 'There is an issue with the selected model')" 1

# Escape sequences and ';' inside the error text must not leak into the field.
OUT="$(printf '%s' '{"error":"unknown","error_details":"bad \u001b[31mred\u001b]52;c;x\u0007 a;b"}' | run)"
check "hostile details stay allowlisted"       "$(echo "$OUT" | head -1)" allowlisted

OUT="$(printf 'not json' | run)"
check "garbage stdin still notifies"           "$(echo "$OUT" | head -1)" allowlisted
OUT="$(printf '{}' | DRSG_STOP_FAILURE_NOTIFY_DISABLED=1 python3 "$HOOK")"
check "disabled by env prints nothing"         "${OUT:-empty}" empty

# setup.sh registers it as a plain (not asyncRewake) StopFailure hook, next to the poller.
HOME="$T/home" DRSG_MEM_DIR="$T/setup-mem" CLAUDE_CONFIG_DIR="$T/claude" \
  bash "$HERE/../setup.sh" --no-skills >/dev/null 2>&1
REG="$(python3 - "$T/claude/settings.json" <<'PY'
import json, sys
try:
    groups = json.load(open(sys.argv[1])).get("hooks", {}).get("StopFailure", [])
except (OSError, ValueError):
    groups = []
hooks = [h for g in groups for h in g.get("hooks", []) if "stop-failure-notify.py" in h.get("command", "")]
print("missing" if not hooks else "async" if hooks[0].get("asyncRewake") else "sync")
PY
)"
check "setup registers it as a sync StopFailure hook" "$REG" sync
check "setup copies it into the tools dir" "$([ -f "$T/setup-mem/tools/stop-failure-notify.py" ] && echo yes || echo no)" yes

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$RAN" -eq 10 ] && [ "$OK" -eq "$RAN" ]

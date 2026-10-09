#!/usr/bin/env bash
# Contract tests for tools/templates/hooks/pre_tool_use.py
# Synthetic inputs via stdin.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../tools/templates/hooks/pre_tool_use.py"

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

call_hook() {
  local tool="$1"
  local cmd="$2"
  python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' "$tool" "$cmd" | python3 "$HOOK"
}

# 1. Non-bash tool passes
OUT="$(call_hook "Edit" "python3 event.py list")"
check "non-bash tool allowed" "$OUT" ""

# 2. Ordinary bash commands pass
OUT="$(call_hook "Bash" "git status")"
check "git status allowed" "$OUT" ""
OUT="$(call_hook "Bash" "bash tests/event-poller.sh")"
check "test script allowed" "$OUT" ""

# 3. event.py --help and -h pass
OUT="$(call_hook "Bash" "python3 tools/event.py --help")"
check "event.py --help allowed" "$OUT" ""
OUT="$(call_hook "Bash" "python3 /path/to/event.py -h")"
check "event.py -h allowed" "$OUT" ""
OUT="$(call_hook "Bash" "python3 tools/event.py list --help")"
check "event.py list --help allowed" "$OUT" ""

# 4. event.py list / done / post blocked with exact JSON fields
OUT="$(call_hook "Bash" "python3 ~/.drsg-memory/tools/event.py list")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
REASON="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecisionReason',''))" "$OUT")"
check "event.py list decision is deny" "$DECISION" "deny"
check "event.py list reason mentions mcp__drsg-events__event_list" "$(echo "$REASON" | grep -c "mcp__drsg-events__event_list")" 1

OUT="$(call_hook "Bash" "python3 /path/to/event.py done e123")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
check "event.py done decision is deny" "$DECISION" "deny"

OUT="$(call_hook "Bash" "python3 event.py post /path 'summary'")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
check "event.py post decision is deny" "$DECISION" "deny"

# 5. Compound command with cd tests/ blocked (C2 requirement)
OUT="$(call_hook "Bash" "cd tests && python3 ~/.drsg-memory/tools/event.py list")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
check "cd tests && event.py list is denied" "$DECISION" "deny"

# 6. R1 test cases (15 live tested cases from acceptance review)
OUT="$(call_hook "Bash" "DRSG_RAW=1 python3 ~/.drsg-memory/tools/event.py list")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
check "env prefix DRSG_RAW=1 python3 event.py list is denied" "$DECISION" "deny"

OUT="$(call_hook "Bash" "~/.drsg-memory/tools/event.py done k")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
check "direct executable invocation event.py done is denied" "$DECISION" "deny"

OUT="$(call_hook "Bash" "echo x; /usr/bin/python3 /h/event.py list /p")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
check "semicolon chained python3 event.py list is denied" "$DECISION" "deny"

OUT="$(call_hook "Bash" "for k in a b; do python3 event.py done \$k; done")"
DECISION="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('hookSpecificOutput',{}).get('permissionDecision',''))" "$OUT")"
check "for-loop do python3 event.py done is denied" "$DECISION" "deny"

# Safe non-execution commands that mention event.py in arguments must be allowed
OUT="$(call_hook "Bash" "grep -n 'event.py done --force' tools/README.md")"
check "grep mentioning event.py done allowed" "$OUT" ""

OUT="$(call_hook "Bash" "git commit -m 'block event.py list in sessions'")"
check "git commit -m mentioning event.py list allowed" "$OUT" ""

OUT="$(call_hook "Bash" "rg \"event.py list\" docs/")"
check "rg with double quotes mentioning event.py list allowed" "$OUT" ""

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$RAN" -eq 18 ] && [ "$OK" -eq "$RAN" ]

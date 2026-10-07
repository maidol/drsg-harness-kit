#!/usr/bin/env bash
# Synthetic contract tests for skills/agent-efficiency-retro/retro.py.
# No real transcript content is used; the transcript is generated below.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETRO="$HERE/../skills/agent-efficiency-retro/retro.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

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

# One reply with three code-graph calls (codegraph router, drsg-watch, drsg),
# two Event calls (drsg-events) and one Read.
mkdir -p "$T/home/.claude/projects/-synthetic"
python3 - "$T/home/.claude/projects/-synthetic/s.jsonl" <<'PY'
import json
import sys

names = ["mcp__codegraph__graph_impact", "mcp__drsg-watch__context",
         "mcp__drsg__snippet", "mcp__drsg-events__event_list",
         "mcp__drsg-events__event_done", "Read"]
content = [{"type": "tool_use", "id": f"u-{i}", "name": n, "input": {}}
           for i, n in enumerate(names)]
row = {"type": "assistant", "timestamp": "2026-10-07T00:00:00Z",
       "message": {"id": "m1", "content": content}}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps(row) + "\n")
PY

OUT="$(HOME="$T/home" python3 "$RETRO" --project='-synthetic' 2>&1)"
check retro_runs "$(echo "$OUT" | grep -c '^## 4\.')" 1
check graph_count_excludes_events "$(echo "$OUT" | grep -o '代码图调用 [0-9]* 次')" "代码图调用 3 次"
check event_count_listed "$(echo "$OUT" | grep -o 'Event 调用 [0-9]* 次')" "Event 调用 2 次"

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

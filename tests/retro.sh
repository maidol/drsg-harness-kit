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

# Verdicts a reviewer posted. Project a: fail, escalated fail, pass (3 rounds).
# Project b: an event_post that errored (must not count), then a structured
# commit authorization (first-pass). Project c: one untagged fail, still open.
# Plus two staged design/plan reviews, one returned at the design layer.
mkdir -p "$T/home/.claude/projects/-verdicts"
python3 - "$T/home/.claude/projects/-verdicts/s.jsonl" <<'PY'
import json
import sys

posts = [
    ("event_post", {"recipient": "/p/a", "kind": "handoff", "summary": "验收不通过：[漏测边界] 2 不通过"}),
    ("event_post", {"recipient": "/p/a", "kind": "handoff", "summary": "验收不通过（转主模型出计划）：[判据缺失、范围偏移] 又没过"}),
    ("event_post", {"recipient": "/p/a", "kind": "notice", "summary": "验收通过：好了"}),
    ("event_post", {"recipient": "/p/b", "kind": "handoff", "summary": "验收不通过：[约定不符] 发送失败"}),
    ("commit_auth_post", {"recipient": "/p/b", "tree": "t", "parent": "p"}),
    ("event_post", {"recipient": "/p/c", "kind": "handoff", "summary": "验收不通过：没写类别"}),
    ("event_post", {"recipient": "/p/c", "kind": "handoff", "summary": "设计需修订：降级没写"}),
    ("event_post", {"recipient": "/p/c", "kind": "handoff", "summary": "设计通过，计划需修订：第 2 步过大"}),
    ("event_post", {"recipient": "/p/c", "kind": "notice", "summary": "已按授权提交"}),
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for i, (name, inp) in enumerate(posts):
        t = "2026-10-07T00:%02d:00Z" % i
        use = {"type": "tool_use", "id": f"v-{i}", "name": "mcp__drsg-events__" + name, "input": inp}
        fh.write(json.dumps({"type": "assistant", "timestamp": t,
                             "message": {"id": f"m{i}", "content": [use]}}, ensure_ascii=False) + "\n")
        res = {"type": "tool_result", "tool_use_id": f"v-{i}", "content": "ok"}
        if i == 3:
            res["is_error"] = True
        fh.write(json.dumps({"type": "user", "timestamp": t,
                             "message": {"content": [res]}}, ensure_ascii=False) + "\n")
PY

OUT="$(HOME="$T/home" python3 "$RETRO" --project='-verdicts' 2>&1)"
check verdict_totals "$(echo "$OUT" | grep -o '验收判定 [0-9]* 次：通过 [0-9]*，不通过 [0-9]*（其中升级 [0-9]*）')" "验收判定 5 次：通过 2，不通过 3（其中升级 1）"
check verdict_tasks "$(echo "$OUT" | grep -o '结单 [0-9]* 单，首次验收通过 [0-9]* 单（[0-9]*%），平均 [0-9.]* 轮；未结 [0-9]* 单')" "结单 2 单，首次验收通过 1 单（50%），平均 2.0 轮；未结 1 单"
check verdict_reasons "$(echo "$OUT" | grep '^原因类别:')" "原因类别: 漏测边界 1, 判据缺失 1, 范围偏移 1, 未标类别 1"
check verdict_layers "$(echo "$OUT" | grep '^按层:')" "按层: 计划/验收测试 2, 判据 1"
check plan_reviews "$(echo "$OUT" | grep -o '设计/计划评审 [0-9]* 次，设计层退回 [0-9]* 次')" "设计/计划评审 2 次，设计层退回 1 次"

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

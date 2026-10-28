#!/usr/bin/env bash
# Synthetic contract tests for retro.py escape-rate output.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RETRO="${RETRO_SCRIPT:-$HERE/../skills/agent-efficiency-retro/retro.py}"
python3 - "$RETRO" "${ONLY_CASE:-}" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

retro, only = sys.argv[1:]
all_cases = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
cases = [only] if only else all_cases


def run(posts):
    with tempfile.TemporaryDirectory() as temp:
        project = Path(temp, "home/.claude/projects/-escape-fixture")
        project.mkdir(parents=True)
        transcript = project / "fixture.jsonl"
        with transcript.open("w", encoding="utf-8") as stream:
            for i, (when, name, inp) in enumerate(posts):
                tool_id = f"synthetic-{i}"
                tool = {"type": "tool_use", "id": tool_id,
                        "name": f"mcp__drsg-events__{name}", "input": inp}
                row = {"type": "assistant", "timestamp": when,
                       "message": {"id": f"message-{i}", "content": [tool]}}
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
                result = {"type": "tool_result", "tool_use_id": tool_id,
                          "content": "ok"}
                row = {"type": "user", "timestamp": when,
                       "message": {"content": [result]}}
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
        env = dict(os.environ, HOME=str(Path(temp, "home")))
        return subprocess.run(
            [sys.executable, retro, "--project=-escape-fixture",
             "--since=2026-10-01T00:00:00Z"],
            env=env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, check=True).stdout.splitlines()


def passed(when, recipient="drsg-harness-kit"):
    return when, "event_post", {
        "recipient": recipient, "kind": "notice", "summary": "验收通过：已通过"}


def escape(when, ref, summary, recipient="drsg-harness-kit"):
    return when, "event_post", {
        "recipient": recipient, "kind": "notice", "summary": "验收逃逸：" + summary,
        "ref": ref,
    }


key = "evt-drsg-harness-kit-1791169200-abcdef"
old_key = "evt-drsg-harness-kit-1790726400-abcdef"
when = "2026-10-05T03:00:00Z"
summary = "原判据第 2 条的输出换行未被断言"
expected_escape_detail = (
    "  10-05 03:00 drsg-harness-kit 验收逃逸：" + summary + " " + key
)

def check(case, posts, stats=None, details=None, preserve=False):
    lines = run(posts)
    if stats is not None:
        actual = [line for line in lines if line.startswith("验收逃逸：")]
        if actual != [stats]:
            raise AssertionError(f"统计行：got {actual!r}, want {[stats]!r}")
    if details is not None:
        actual = [line for line in lines if line.startswith("  10-")]
        if actual != details:
            raise AssertionError(f"明细行：got {actual!r}, want {details!r}")
    if preserve:
        baseline = run([passed(when), ("2026-10-05T03:01:00Z", "event_post", {
            "recipient": "drsg-harness-kit", "kind": "notice", "summary": "验收不通过：[漏测边界] 示例",
        })])
        prefixes = ("验收判定 ", "结单 ", "原因类别:", "按层:", "设计/计划评审 ")
        before = [line for line in baseline if line.startswith(prefixes)]
        after = [line for line in lines if line.startswith(prefixes)]
        if before != after:
            raise AssertionError(f"既有输出变化：before {before!r}, after {after!r}")
        if not any(line.startswith("验收逃逸：1 次，") for line in lines):
            raise AssertionError("缺少新增逃逸行")


try:
    for case in cases:
        if case == "1":
            check(case, [passed(when), passed("2026-10-05T03:01:00Z"),
                         escape(when, key, summary)],
                  "验收逃逸：1 次，涉及 1 张原单；逃逸率 1/2 = 50%",
                  [expected_escape_detail])
        elif case == "2":
            check(case, [passed(when)],
                  "验收逃逸：0（只认「验收逃逸：」前缀；窗口内没有标注）", [])
        elif case == "3":
            detail = ("  10-05 03:00 drsg-harness-kit 验收逃逸：" + summary + " " + old_key)
            check(case, [passed(when), escape(when, old_key, summary)],
                  "验收逃逸：1 次，涉及 1 张原单；逃逸率 1/1 = 100%（含窗口外原单）",
                  [detail])
        elif case == "4":
            check(case, [passed(when), escape(when, key, "同一原单再次发现问题"),
                         escape("2026-10-05T03:01:00Z", key, "同一原单又发现问题")],
                  "验收逃逸：2 次，涉及 1 张原单；逃逸率 1/1 = 100%",
                  ["  10-05 03:00 drsg-harness-kit 验收逃逸：同一原单再次发现问题 " + key,
                   "  10-05 03:01 drsg-harness-kit 验收逃逸：同一原单又发现问题 " + key])
        elif case == "5":
            check(case, [passed(when), (when, "event_post", {
                "recipient": "drsg-harness-kit", "kind": "notice",
                "summary": "补充：验收逃逸：不应命中", "ref": key,
            })], "验收逃逸：0（只认「验收逃逸：」前缀；窗口内没有标注）", [])
        elif case == "6":
            detail = "  10-05 03:00 drsg-harness-kit 验收逃逸：没有通过单 " + key
            check(case, [escape(when, key, "没有通过单")],
                  "验收逃逸：1 次，涉及 1 张原单；逃逸率 n/a", [detail])
        elif case == "7":
            check(case, [passed(when), ("2026-10-05T03:01:00Z", "event_post", {
                "recipient": "drsg-harness-kit", "kind": "notice",
                "summary": "验收不通过：[漏测边界] 示例",
            }), escape("2026-10-05T03:02:00Z", key, "独立统计")], preserve=True)
        elif case == "8":
            detail = "  10-05 03:00 drsg-harness-kit 验收逃逸：从 ref 中解析窗口外 key " + old_key[:-6] + "fedcba"
            check(case, [passed(when), escape(when, old_key[:-6] + "fedcba", "从 ref 中解析窗口外 key")],
                  "验收逃逸：1 次，涉及 1 张原单；逃逸率 1/1 = 100%（含窗口外原单）",
                  [detail])
        elif case == "9":
            sha = "abc1234"
            detail = "  10-05 03:00 drsg-harness-kit 验收逃逸：原单只有 SHA " + sha + "（时间未知）"
            check(case, [passed(when), escape(when, "ref: 第 20261028 批，提交 " + sha,
                                                "原单只有 SHA")],
                  "验收逃逸：1 次，涉及 1 张原单；逃逸率 1/1 = 100%", [detail])
        else:
            raise AssertionError(f"未知 case: {case}")
        print(f"ok   case {case}")
except (AssertionError, subprocess.CalledProcessError) as exc:
    print(f"FAIL case {case}: {exc}", file=sys.stderr)
    if isinstance(exc, subprocess.CalledProcessError):
        print(exc.stdout, file=sys.stderr)
    sys.exit(1)

print(f"PASS {len(cases)}/{len(cases)}")
PY

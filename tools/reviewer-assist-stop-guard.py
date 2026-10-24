#!/usr/bin/env python3
"""Remind a downstream session to request reviewer help before stopping."""

import json
import os
import re
import sys

import superpowers_docs

MAX_BYTES = 8 * 1024 * 1024
MAX_LINES = 3000
BLOCK_REASON = (
    "你在等审核方协助，先用 event_post 发『请求协助：』，再停；"
    "如果只在等用户本人拍板，直接结束即可"
)

GROUPS = {
    "G1": re.compile(
        r"拦|拒绝|denied|[Bb]locked|代跑|权限检查|分类器|PreToolUse|hook error|不再重跑|不会.{0,6}重试"
    ),
    "G2": re.compile(
        r"审核方仓库|my-agent-workspace/reviews|reviews/drsg|审核方.{0,8}(文件|计划|文档)|计划文件"
    ),
    "G3": re.compile(r"审核方|验收|放行|条件已满足|判定|评审|reviewer"),
    "G4": re.compile(
        r"起点|不认识|归属|不是(我|本会话)(改|做)|来源不明|tree 不(符|一致)|父提交不(符|一致)"
    ),
    "G5": re.compile(r"commit_auth_apply"),
    "G6": re.compile(
        r"push|发布|请你确认|请确认|是否授权|明确授权|由你决定|等你|请用户|你来定|要不要|是否提交"
    ),
}


def _user_input_boundary(row):
    if not isinstance(row, dict) or row.get("type") != "user":
        return False
    message = row.get("message")
    if not isinstance(message, dict):
        return False
    content = message.get("content")
    if isinstance(content, str):
        return True
    if not isinstance(content, list):
        return False
    block_types = [block.get("type") for block in content if isinstance(block, dict)]
    return "text" in block_types and "tool_result" not in block_types


def _read_rows(path):
    with open(path, "rb") as stream:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        start = max(0, size - MAX_BYTES)
        stream.seek(start)
        data = stream.read(MAX_BYTES)

    if start:
        newline = data.find(b"\n")
        if newline < 0:
            return None
        data = data[newline + 1:]

    lines = data.splitlines()
    if len(lines) > MAX_LINES:
        lines = lines[-MAX_LINES:]

    rows = []
    for line in lines:
        if not line.strip():
            rows.append(None)
            continue
        try:
            row = json.loads(line.decode("utf-8", errors="replace"))
        except (UnicodeError, ValueError):
            row = None
        rows.append(row if isinstance(row, dict) else None)

    last_nonempty = next((i for i in range(len(lines) - 1, -1, -1)
                          if lines[i].strip()), None)
    if last_nonempty is None or rows[last_nonempty] is None:
        return None
    return rows


def _last_assistant_text(rows):
    assistant_index = next(
        (i for i in range(len(rows) - 1, -1, -1)
         if isinstance(rows[i], dict) and rows[i].get("type") == "assistant"),
        None,
    )
    if assistant_index is None or any(row is None for row in rows[assistant_index + 1:]):
        return None

    last = rows[assistant_index]
    message = last.get("message")
    message_id = message.get("id") if isinstance(message, dict) else None
    if not isinstance(message_id, str) or not message_id:
        return None

    blocks = []
    for row in rows:
        if not isinstance(row, dict) or row.get("type") != "assistant":
            continue
        record = row.get("message")
        if not isinstance(record, dict) or record.get("id") != message_id:
            continue
        content = record.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if (isinstance(block, dict) and block.get("type") == "text"
                    and isinstance(block.get("text"), str)):
                blocks.append(block["text"])
    return "\n".join(blocks) if blocks else None


def _has_event_post(rows):
    boundary = -1
    for i, row in enumerate(rows):
        if _user_input_boundary(row):
            boundary = i

    for row in rows[boundary + 1:]:
        if not isinstance(row, dict) or row.get("type") != "assistant":
            continue
        message = row.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if not isinstance(content, list):
            continue
        if any(isinstance(block, dict) and block.get("type") == "tool_use"
               and block.get("name") == "mcp__drsg-events__event_post"
               for block in content):
            return True
    return False


def _should_block(text):
    hits = {name: bool(pattern.search(text)) for name, pattern in GROUPS.items()}
    user_only = hits["G6"] and not any(hits[name] for name in ("G1", "G2", "G3", "G4", "G5"))
    c6 = hits["G1"] or hits["G5"] or (hits["G2"] and hits["G3"])
    return c6 and not user_only


def _current_project(hook):
    candidate = hook.get("cwd")
    if not isinstance(candidate, str) or not candidate:
        candidate = os.environ.get("CLAUDE_PROJECT_DIR")
    if not isinstance(candidate, str) or not candidate:
        candidate = os.getcwd()
    return os.path.realpath(os.path.expanduser(candidate))


def main():
    raw = sys.stdin.read()
    if not raw.strip():
        return
    try:
        hook = json.loads(raw)
    except (TypeError, ValueError):
        return
    if not isinstance(hook, dict) or hook.get("hook_event_name") != "Stop":
        return
    if hook.get("stop_hook_active") is True:
        return

    transcript_path = hook.get("transcript_path")
    if not isinstance(transcript_path, str) or not transcript_path:
        return
    reviewer = superpowers_docs.configured_reviewer(superpowers_docs._config_path())
    if not reviewer or _current_project(hook) == reviewer:
        return

    rows = _read_rows(transcript_path)
    if rows is None:
        return
    final_text = _last_assistant_text(rows)
    if final_text is None or _has_event_post(rows) or not _should_block(final_text):
        return
    print(json.dumps({"decision": "block", "reason": BLOCK_REASON}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass

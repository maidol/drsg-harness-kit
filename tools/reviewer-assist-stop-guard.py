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

ASSIST_REQUEST = re.compile(
    r"(?:需要|需|请|等待|等|交给|交由)\s*(?:由|让|请|用户(?:同时)?联系)?"
    r"(?:(?:审核方|评审方|reviewer).{0,16}(?:代跑|协助|处理|修复|修改|放行|解除|更新|补充)|代跑)"
    r"|\b(?:need|waiting for|ask)\b.{0,16}\breviewer\b.{0,16}\b(?:help|run|fix|update|unblock)\b",
    re.IGNORECASE,
)
NON_CURRENT = re.compile(r"如果|假如|\bif\b", re.IGNORECASE)
NOT_PENDING = re.compile(
    r"之前|此前|曾经|示例|例如|(?:脚本|守卫).{0,12}(?:会|用于)|文档.{0,6}(?:写|说明)"
    r"|不再|不会|不(?:需要|需|用|必|等)|无需|已(?:经)?(?:请|发|交|解决|完成|处理|解除|恢复)"
    r"|\b(?:previously|formerly|already|no longer|do not|don't)\b"
    r"|\b(?:hook|guard)\b.{0,32}\b(?:checks|matches|detects|reminds|triggers|blocks|will)\b",
    re.IGNORECASE,
)


def _user_input_boundary(row):
    if not isinstance(row, dict) or row.get("type") != "user":
        return False
    if row.get("isMeta") is True:
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


def _is_event_post(block):
    if not isinstance(block, dict) or block.get("type") != "tool_use":
        return False
    names = ("mcp__drsg-events__event_post", "functions.mcp__drsg-events__event_post")
    if block.get("name") in names:
        return True
    if block.get("name") != "multi_tool_use.parallel":
        return False
    payload = block.get("input")
    calls = payload.get("tool_uses") if isinstance(payload, dict) else None
    return isinstance(calls, list) and any(
        isinstance(call, dict) and call.get("recipient_name") in names
        for call in calls
    )


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
        if any(_is_event_post(block) for block in content):
            return True
    return False


def _should_block(text):
    text = re.sub(r"```.*?(?:```|\Z)|~~~.*?(?:~~~|\Z)", " ", text, flags=re.DOTALL)
    text = re.sub(r"(?m)^[ \t]*>[^\n]*", " ", text)
    text = re.sub(r'`[^`\n]*`|“[^“”\n]*”|‘[^‘’\n]*’|"[^"\n]*"', " ", text)
    for sentence in re.split(r"[\n。！？!?；;.]+|但是|但|不过|然而|\bbut\b", text, flags=re.IGNORECASE):
        if NON_CURRENT.search(sentence):
            continue
        for clause in re.split(r"[，,]+", sentence):
            if not NOT_PENDING.search(clause) and ASSIST_REQUEST.search(clause):
                return True
    return False


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

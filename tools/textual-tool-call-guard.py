#!/usr/bin/env python3
"""textual-tool-call-guard.py — Stop hook to catch and block textual tool calls.

When a model outputs tool calls purely as textual markup like:
  <mcp__tool_name>{"arg": "value"}</mcp__tool_name>
instead of structured tool_use blocks, Claude Code treats it as a completed turn.
This Stop hook blocks turn completion and prompts the model to reissue the call
as a real structured tool call.

Fail-open: any error, invalid payload, or unparseable input silently allows
turn completion without breaking the session.
"""
import json
import os
import re
import sys

# Matches a single well-formed XML-like tool call wrapping arbitrary inner content
TAG_PATTERN = re.compile(r"^<([a-zA-Z0-9_:\-]+)>(.*)</\1>$", re.DOTALL)
BLOCK_REASON = "你把工具调用写成了文本，没有真正调用。请用真正的工具调用重发同一个调用。"


def extract_last_assistant_text(hook):
    """Retrieve the last assistant message text from hook input or transcript."""
    # 1. First priority: direct hook input field
    msg = hook.get("last_assistant_message")
    if isinstance(msg, str) and msg.strip():
        return msg.strip()

    # 2. Fallback: read transcript if available
    transcript_path = hook.get("transcript_path")
    if not transcript_path or not os.path.exists(transcript_path):
        return None

    # Read transcript lines to find the last assistant message
    with open(transcript_path, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()

    target_message_id = None
    # Scan backward to find the last assistant message ID
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except Exception:
            continue
        if not isinstance(row, dict) or row.get("type") != "assistant":
            continue
        msg_id = (row.get("message") or {}).get("id")
        if msg_id:
            target_message_id = msg_id
            break

    if not target_message_id:
        return None

    # Collect and concatenate text blocks for this message ID
    text_parts = []
    for line in lines:
        try:
            row = json.loads(line)
        except Exception:
            continue
        if not isinstance(row, dict) or row.get("type") != "assistant":
            continue
        message = row.get("message") or {}
        if message.get("id") != target_message_id:
            continue
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text")
                    if isinstance(text, str):
                        text_parts.append(text)
        elif isinstance(content, str):
            text_parts.append(content)

    combined = "".join(text_parts).strip()
    return combined if combined else None


def is_textual_tool_call(text):
    """Determine whether text is purely a single textual tool call."""
    if not text:
        return False
    match = TAG_PATTERN.match(text.strip())
    if not match:
        return False
    payload_str = match.group(2).strip()
    try:
        payload = json.loads(payload_str)
        # Must be a JSON dictionary (tool parameters)
        return isinstance(payload, dict)
    except Exception:
        return False


def main():
    if os.environ.get("DRSG_STOP_TEXTUAL_TOOL_CALL_GUARD_DISABLED") == "1":
        return

    raw = sys.stdin.read()
    if not raw or not raw.strip():
        return
    hook = json.loads(raw)

    if not isinstance(hook, dict):
        return

    # Anti-loop protection: if already blocked by Stop hook in this turn, allow
    if hook.get("stop_hook_active") is True:
        return

    text = extract_last_assistant_text(hook)
    if is_textual_tool_call(text):
        print(json.dumps({"decision": "block", "reason": BLOCK_REASON}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass

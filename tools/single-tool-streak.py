#!/usr/bin/env python3
"""Fail-open PostToolUse reminder for repeated single-tool turns."""
import json
import os
import sys

MAX_BYTES = 1024 * 1024
COOLDOWN_MESSAGES = 5
ALLOWED_TOOLS = {"Edit", "Write", "Read"}
REMINDER = (
    "最近几轮都只发了一个调用。下一步如果有几处互不依赖的修改或读取，"
    "在同一轮里一起发；改完跑测试的那一步照旧单独发。"
)


def transcript_tail(path):
    """Return at most the final MAX_BYTES complete UTF-8 lines."""
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        end = fh.tell()
        start = max(0, end - MAX_BYTES)
        fh.seek(start, os.SEEK_SET)
        data = fh.read(end - start)
    if start:
        newline = data.find(b"\n")
        if newline < 0:
            return []
        data = data[newline + 1:]
    return data.decode("utf-8", "replace").splitlines()


def assistant_messages(path):
    """Return [(message_id, qualifying)] in transcript order."""
    uses_by_id = {}
    order = []
    for line in transcript_tail(path):
        try:
            row = json.loads(line)
        except (TypeError, ValueError):
            continue
        if row.get("type") != "assistant":
            continue
        message = row.get("message") or {}
        message_id = message.get("id")
        if not message_id:
            continue
        if message_id not in uses_by_id:
            uses_by_id[message_id] = {}
            order.append(message_id)
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_id = block.get("id")
                if not tool_id:
                    tool_id = f"anonymous-{len(uses_by_id[message_id])}"
                uses_by_id[message_id][tool_id] = block.get("name")
    return [
        (message_id, len(uses_by_id[message_id]) == 1
         and next(iter(uses_by_id[message_id].values())) in ALLOWED_TOOLS)
        for message_id in order
    ]


def state_path(session_id):
    root = (os.environ.get("XDG_STATE_HOME")
            or os.environ.get("XDG_CACHE_HOME")
            or os.path.expanduser("~/.cache"))
    safe = "".join(
        char if char.isalnum() or char in "-_." else "_"
        for char in session_id
    )[:200] or "unknown"
    return os.path.join(root, "drsg", "single-tool-streak", safe + ".json")


def load_state(path):
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
        return (value if isinstance(value, dict) else {}), True
    except FileNotFoundError:
        return {}, True
    except (OSError, ValueError, TypeError):
        return {}, False


def save_state(path, value):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    try:
        os.chmod(directory, 0o700)
    except OSError:
        pass
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as fh:
        json.dump(value, fh, separators=(",", ":"))
    try:
        os.chmod(temporary, 0o600)
    except OSError:
        pass
    os.replace(temporary, path)


def cooldown_allows(path, ids, final_id):
    state, readable = load_state(path)
    if not readable:
        return False
    previous = state.get("last_message_id")
    if previous == final_id:
        return False
    if previous in ids:
        if len(ids) - ids.index(previous) - 1 < COOLDOWN_MESSAGES:
            return False
    return True


def main():
    if os.environ.get("DRSG_SINGLE_TOOL_STREAK_DISABLED") == "1":
        return
    data = json.load(sys.stdin)
    session_id = data.get("session_id")
    transcript_path = data.get("transcript_path")
    if not session_id or not transcript_path:
        return
    messages = assistant_messages(transcript_path)
    if len(messages) < 3:
        return
    ids = [message_id for message_id, _ in messages]
    recent = messages[-3:]
    if not all(qualifying for _, qualifying in recent):
        return
    path = state_path(session_id)
    final_id = ids[-1]
    if not cooldown_allows(path, ids, final_id):
        return
    save_state(path, {"last_message_id": final_id})
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": REMINDER,
        }
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Hooks are advisory. A transcript, cache, or state failure must never
        # block the tool call that caused this hook to run.
        pass

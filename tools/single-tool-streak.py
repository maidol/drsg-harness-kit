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
EXTRA_TAB_REMINDER = (
    "Read 输出中行号后的分隔 tab 不是缩进；每行少一个前导 tab 后重发。"
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
    return assistant_messages_from_lines(transcript_tail(path))


def transcript_data(lines):
    """Return assistant-message classifications and matched tool calls."""
    uses_by_id = {}
    message_order = []
    calls = []
    calls_by_id = {}
    order = 0
    for line in lines:
        try:
            row = json.loads(line)
        except (TypeError, ValueError):
            continue
        if not isinstance(row, dict):
            continue
        message = row.get("message") or {}
        if not isinstance(message, dict):
            continue
        message_id = message.get("id") if row.get("type") == "assistant" else None
        if message_id:
            if message_id not in uses_by_id:
                uses_by_id[message_id] = {}
                message_order.append(message_id)
        content = message.get("content")
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                order += 1
                continue
            if block.get("type") == "tool_use":
                tool_id = block.get("id")
                if message_id:
                    if not tool_id:
                        tool_id = f"anonymous-{len(uses_by_id[message_id])}"
                    uses_by_id[message_id][tool_id] = block.get("name")
                if isinstance(tool_id, str) and tool_id:
                    call = {
                        "id": tool_id,
                        "name": block.get("name"),
                        "input": block.get("input"),
                        "use_order": order,
                        "result_order": None,
                        "is_error": None,
                        "result_text": "",
                    }
                    calls.append(call)
                    calls_by_id[tool_id] = call
            elif block.get("type") == "tool_result":
                tool_id = block.get("tool_use_id")
                call = calls_by_id.get(tool_id)
                if call is not None:
                    call["result_order"] = order
                    call["is_error"] = block.get("is_error") is True
                    call["result_text"] = result_text(block.get("content"))
            order += 1
    messages = [
        (message_id, len(uses_by_id[message_id]) == 1
         and next(iter(uses_by_id[message_id].values())) in ALLOWED_TOOLS)
        for message_id in message_order
    ]
    return messages, calls


def assistant_messages_from_lines(lines):
    """Return [(message_id, qualifying)] from already-read transcript lines."""
    return transcript_data(lines)[0]


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


def result_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return " ".join(
            block.get("text", "") for block in value
            if isinstance(block, dict) and isinstance(block.get("text", ""), str)
        )
    return ""


def transcript_calls(lines):
    """Return matched tool calls from already-read transcript lines."""
    return transcript_data(lines)[1]


def extra_tab_state_path(session_id):
    return state_path(session_id)[:-5] + ".extra-tab.json"


def extra_tab_hint(calls, session_id):
    failed_edits = [
        call for call in calls
        if call["name"] == "Edit" and call["is_error"] is True
        and call["result_order"] is not None
    ]
    if not failed_edits:
        return ""
    failed = max(failed_edits, key=lambda call: call["result_order"])
    if "String to replace not found" not in failed["result_text"]:
        return ""
    edit_input = failed["input"]
    if not isinstance(edit_input, dict):
        return ""
    target = edit_input.get("file_path")
    old_string = edit_input.get("old_string")
    if not isinstance(target, str) or not target or not isinstance(old_string, str):
        return ""

    failed_order = failed["result_order"]
    for call in calls:
        tool_input = call["input"]
        if (call["name"] in ("Edit", "Write")
                and call["use_order"] > failed_order
                and call["result_order"] is not None
                and call["is_error"] is not True
                and isinstance(tool_input, dict)
                and tool_input.get("file_path") == target):
            return ""

    state_pathname = extra_tab_state_path(session_id)
    state, readable = load_state(state_pathname)
    if not readable:
        return ""
    hinted = state.get("hinted_edit_ids", [])
    if not isinstance(hinted, list) or failed["id"] in hinted:
        return ""

    normalized_lines = old_string.splitlines(keepends=True)
    normalized = "".join(
        line[1:] if line.startswith("\t") else line
        for line in normalized_lines
    )
    if not normalized or normalized == old_string or not any(
            line.startswith("\t") for line in normalized_lines):
        return ""
    with open(target, "rb") as fh:
        content = fh.read(MAX_BYTES + 1)
    if len(content) > MAX_BYTES:
        return ""
    current = content.decode("utf-8")
    if current.count(normalized) != 1:
        return ""

    hinted = (hinted + [failed["id"]])[-256:]
    save_state(state_pathname, {"hinted_edit_ids": hinted})
    return f"Edit 锚点可能多了一个前导 tab：{target}。{EXTRA_TAB_REMINDER}"


def streak_hint(messages, session_id):
    if len(messages) < 3:
        return ""
    ids = [message_id for message_id, _ in messages]
    recent = messages[-3:]
    if not all(qualifying for _, qualifying in recent):
        return ""
    path = state_path(session_id)
    final_id = ids[-1]
    if not cooldown_allows(path, ids, final_id):
        return ""
    save_state(path, {"last_message_id": final_id})
    return REMINDER


def main():
    if os.environ.get("DRSG_SINGLE_TOOL_STREAK_DISABLED") == "1":
        return
    data = json.load(sys.stdin)
    session_id = data.get("session_id")
    transcript_path = data.get("transcript_path")
    if not session_id or not transcript_path:
        return
    lines = transcript_tail(transcript_path)
    messages, calls = transcript_data(lines)
    hints = []
    try:
        extra_hint = extra_tab_hint(calls, session_id)
    except Exception:
        extra_hint = ""
    if extra_hint:
        hints.append(extra_hint)
    try:
        reminder = streak_hint(messages, session_id)
    except Exception:
        reminder = ""
    if reminder:
        hints.append(reminder)
    if hints:
        print(json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": "\n\n".join(hints),
            }
        }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Hooks are advisory. A transcript, cache, or state failure must never
        # block the tool call that caused this hook to run.
        pass

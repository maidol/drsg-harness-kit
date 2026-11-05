#!/usr/bin/env python3
"""Stop identical deterministic Event mistakes before they are executed again."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import time

PREFIX = "EVENT_POST_ERROR "
TOOLS = {"mcp__drsg-events__event_post", "mcp__drsg-events__event_reply"}
FIELDS = {"recipient", "summary", "kind", "ref", "reply_to", "supersedes", "symbols", "verb", "plane", "event_key", "arguments", "delivery"}
MAX_BYTES = 8192
MAX_ENTRIES = 32
TTL = 86400


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def signature(data, field):
    args = data["tool_input"]
    value = args.get(field)
    if field == "delivery":
        value = args.get("event_key") or args.get("reply_to")
    if field == "arguments":
        value = sorted(set(args) - {"event_key", "summary", "kind", "ref"})
    if data["tool_name"].endswith("__event_reply") and field == "reply_to":
        value = args.get("event_key")
    if field in ("recipient",) and isinstance(value, str):
        value = os.path.realpath(value)
    recipient = args.get("recipient")
    if isinstance(recipient, str):
        recipient = os.path.realpath(recipient)
    return digest([data["tool_name"], recipient, args.get("event_key"), field, value])


def errors(data):
    text = data.get("error")
    if not isinstance(text, str):
        return []
    prefix = PREFIX if PREFIX in text else "EVENT_POST_STATUS "
    start = text.find(prefix)
    if start < 0:
        return []
    try:
        result, _ = json.JSONDecoder().raw_decode(text[start + len(prefix):])
    except ValueError:
        return []
    if not isinstance(result, dict) or result.get("version") != 1:
        return []
    if prefix == "EVENT_POST_STATUS ":
        return [{"field": "delivery", "code": "delivery_outcome"}] if result.get("posted") is True or result.get("posted") == "unknown" else []
    if result.get("posted") is not False:
        return []
    rows = result.get("errors")
    if not isinstance(rows, list):
        return []
    return [row for row in rows if isinstance(row, dict) and row.get("field") in FIELDS
            and row.get("code") in ("invalid_argument", "invalid_reference", "invalid_symbols", "unexpected_field")]


def handle(data, root=None):
    if not isinstance(data, dict) or data.get("tool_name") not in TOOLS:
        return {}
    phase = data.get("hook_event_name")
    if phase not in ("PreToolUse", "PostToolUseFailure") or not isinstance(data.get("tool_input"), dict):
        return {}
    session, prompt = data.get("session_id"), data.get("prompt_id")
    if not isinstance(session, str) or not session or not isinstance(prompt, str) or not prompt:
        return {"systemMessage": "Event retry protection unavailable: missing session/prompt identity."}
    incoming = errors(data) if phase == "PostToolUseFailure" else []
    if phase == "PostToolUseFailure" and not incoming:
        return {}
    directory = Path(root or os.environ.get("DRSG_MEM_DIR") or Path.home() / ".drsg-memory") / "event-retry"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    session_key = digest([session, os.path.realpath(data.get("cwd") or ".")])
    path = directory / (session_key + ".json")
    lock = os.open(directory / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    fd = None
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        entries = list(directory.glob("*.json"))
        if not path.exists() and len(entries) >= 128:
            for entry in entries:
                if len(entry.stem) == 64 and all(c in "0123456789abcdef" for c in entry.stem) and time.time() - entry.lstat().st_mtime > TTL:
                    entry.unlink()
            if len(list(directory.glob("*.json"))) >= 128:
                raise OSError("session state capacity")
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError("state is not a regular file")
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        raw = os.read(fd, MAX_BYTES + 1)
        try:
            state = json.loads(raw) if len(raw) <= MAX_BYTES else {}
        except ValueError:
            state = {}
        identity = digest([session, prompt, data.get("cwd")])
        if not isinstance(state, dict) or state.get("identity") != identity or time.time() - state.get("time", 0) > TTL:
            state = {"identity": identity, "time": time.time(), "blocked": []}
        blocked = state.get("blocked")
        if not isinstance(blocked, list) or any(not isinstance(row, dict) or row.get("field") not in FIELDS or not isinstance(row.get("digest"), str) for row in blocked):
            blocked = []
        if phase == "PreToolUse":
            hit = next((row for row in blocked if signature(data, row["field"]) == row["digest"]), None)
            if hit:
                reason = "Event request stopped: repeated validation error in " + hit["field"] + ". Correct that field or request assistance; nothing was reposted."
                if hit["field"] == "delivery":
                    reason = "Event request stopped: previous delivery is known or uncertain; reconcile with event_list before sending again."
                return {"continue": False, "stopReason": reason, "hookSpecificOutput": {
                    "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}
            return {}
        for row in incoming:
            item = {"field": row["field"], "digest": signature(data, row["field"])}
            if item not in blocked:
                blocked.append(item)
        state["blocked"] = blocked[-MAX_ENTRIES:]
        encoded = json.dumps(state, separators=(",", ":")).encode()
        if len(encoded) > MAX_BYTES:
            raise OSError("state limit")
        os.lseek(fd, 0, os.SEEK_SET)
        os.write(fd, encoded)
        os.ftruncate(fd, len(encoded))
    finally:
        if fd is not None:
            os.close(fd)
        os.close(lock)
    return {}


def main():
    try:
        raw = sys.stdin.read(262145)
        result = handle(json.loads(raw)) if len(raw) <= 262144 else {
            "systemMessage": "Event retry protection unavailable: payload exceeds limit."}
    except Exception:
        result = {"systemMessage": "Event retry protection unavailable: state/input error; do not repeat an unchanged failed request."}
    if result:
        print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()

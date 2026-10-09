#!/usr/bin/env python3
"""PreToolUse hook: block event.py CLI invocations inside agent sessions."""
import json
import re
import sys


CMD = re.compile(
    r"(?:^|[;&|(]|\bthen\b|\bdo\b)\s*(?:\w+=\S*\s+)*(?:\S*/)?(?:python3?\s+)?(?:\S*/)?event\.py\s+(post|list|done)\b"
)
HELP = re.compile(r"(^|\s)(--help|-h)(\s|$)")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    if data.get("tool_name") != "Bash":
        sys.exit(0)

    tool_input = data.get("tool_input") or {}
    cmd = tool_input.get("command") or ""

    deny = bool(CMD.search(cmd)) and not HELP.search(cmd)

    if deny:
        out = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    "Running event.py via Bash inside a session is disabled. "
                    "Use the MCP tools instead: mcp__drsg-events__event_post, "
                    "mcp__drsg-events__event_list (pass project=<dir> for another project), "
                    "mcp__drsg-events__event_done."
                )
            }
        }
        print(json.dumps(out))
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()

#!/usr/bin/env bash
# Regression cases for command-aware Event CLI blocking.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK:-$HERE/../tools/templates/hooks/pre_tool_use.py}"
ONLY="${ONLY:-}"
HOOK="$HOOK" ONLY="$ONLY" python3 - <<'PY'
import json
import os
import subprocess
import sys

hook = os.environ["HOOK"]
only = os.environ.get("ONLY", "")
ran = ok = 0

def call(command, kind="Bash"):
    data = {"tool_name": kind, "tool_input": {"command": command}}
    result = subprocess.run([sys.executable, hook], input=json.dumps(data),
                            text=True, capture_output=True)
    return result.returncode, result.stdout, result.stderr

def check(name, command, want="allow", reason=None, expected_status=0):
    global ran, ok
    if only and only != name:
        return
    ran += 1
    code, out, err = call(command)
    try:
        response = json.loads(out) if out.strip() else {}
    except Exception:
        response = {}
    hso = response.get("hookSpecificOutput", {})
    decision = hso.get("permissionDecision")
    got = "deny" if decision == "deny" else "allow"
    reason_ok = reason is None or reason in hso.get("permissionDecisionReason", "")
    passed = code == expected_status and not err and got == want and reason_ok
    if passed:
        ok += 1
        print("ok   " + name)
    else:
        print("FAIL %s: exit=%d decision=%s reason=%r stderr=%r" % (
            name, code, got, hso.get("permissionDecisionReason", ""), err))

mcp = "mcp__drsg-events__event_post"
take_reason = "Only the user may take the Event-owner lease"

# Plan criteria: bypasses that must now be blocked.
check("help-in-summary", 'python3 ~/.drsg-memory/tools/event.py post /x "fix -h flag"', "deny", mcp)
check("help-in-other-command", "python3 ~/.drsg-memory/tools/event.py done k; echo --help", "deny", mcp)
check("python-unbuffered", "python3 -u ~/.drsg-memory/tools/event.py post /x hi", "deny", mcp)
check("python-versioned", "python3.11 ~/.drsg-memory/tools/event.py post /x hi", "deny", mcp)
check("bash-c", 'bash -c "python3 ~/.drsg-memory/tools/event.py post /x hi"', "deny", mcp)
check("quoted-script", 'python3 "$HOME/.drsg-memory/tools/event.py" post /x hi', "deny", mcp)
check("uv-run", "uv run python ~/.drsg-memory/tools/event.py list", "deny", mcp)
check("take-python-option", "python3 -u ~/.drsg-memory/tools/event-poller.py --take", "deny", take_reason)
check("take-after-lane", "python3 ~/.drsg-memory/tools/event-poller.py --lane x --take", "deny", take_reason)
check("take-wrapper", "env DRSG_RAW=1 command python3 -B ~/.drsg-memory/tools/event-poller.py --take", "deny", take_reason)
check("take-has-priority", "python3 event.py list; python3 event-poller.py --take", "deny", take_reason)
check("help-after-double-dash", "python3 ~/.drsg-memory/tools/event.py post /x -- -h", "deny", mcp)

# Harmless commands that mention the names are not executions.
check("grep-event", "grep -n post tools/event.py")
check("rg-event", "rg event.py")
check("cat-event", "cat ~/.drsg-memory/tools/event.py")
check("sed-poller", "sed -n 1,20p tools/event-poller.py")
check("event-help", "python3 ~/.drsg-memory/tools/event.py --help")
check("event-subcommand-help", "python3 ~/.drsg-memory/tools/event.py post --help")
check("poller-help", "python3 ~/.drsg-memory/tools/event-poller.py --help")
check("git-commit-mention", "git commit -m \"event.py post now uses MCP\"")
check("echo-mention", 'echo "run event.py post later"')

# C1 parse failure is fail-closed only when the original command mentions a target.
check("heredoc-apostrophe", "cat > notes.md <<'EOF'\ndon't forget\nEOF")
check("unclosed-with-event", 'echo "it\'s; python3 ~/.drsg-memory/tools/event.py post /x hi', "deny", mcp)
check("heredoc-target-body", "cat <<'EOF'\npython3 event.py post x\nEOF", "deny", mcp)

# C3 command substitutions execute in double quotes, but not single quotes.
check("double-quoted-substitution", 'echo "$(python3 ~/.drsg-memory/tools/event.py post /x hi)"', "deny", mcp)
check("single-quoted-substitution", "echo '$(python3 ~/.drsg-memory/tools/event.py post /x hi)'")
check("unquoted-substitution", "echo $(python3 event.py list)", "deny", mcp)
check("backtick-substitution", "echo `python3 event.py done k`", "deny", mcp)
check("sh-c", "sh -c 'python3 event.py post /x hi'", "deny", mcp)

# Non-string command values must quietly pass without an exception.
for name, value in (("null-command", None), ("numeric-command", 7), ("list-command", ["python3", "event.py", "list"])):
    if only and only != name:
        continue
    ran += 1
    data = {"tool_name": "Bash", "tool_input": {"command": value}}
    result = subprocess.run([sys.executable, hook], input=json.dumps(data), text=True, capture_output=True)
    if result.returncode == 0 and not result.stdout and not result.stderr:
        ok += 1
        print("ok   " + name)
    else:
        print("FAIL %s: exit=%d stdout=%r stderr=%r" % (name, result.returncode, result.stdout, result.stderr))

if only and ran == 0:
    print("FAIL unknown-only-case")
    sys.exit(2)
print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ok == ran else 1)
PY

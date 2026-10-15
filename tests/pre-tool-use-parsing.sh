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

# v1.12 GRD-1 remainder: five shapes that still slipped through.
check("brace-group", "{ python3 ~/.drsg-memory/tools/event.py post /x hi; }", "deny", mcp)
check("bang-negation", "! python3 ~/.drsg-memory/tools/event.py post /x hi", "deny", mcp)
check("process-substitution", "cat <(python3 ~/.drsg-memory/tools/event.py list)", "deny", mcp)
check("python-optimize", "python3 -O ~/.drsg-memory/tools/event.py post /x hi", "deny", mcp)
check("sudo", "sudo python3 ~/.drsg-memory/tools/event.py post /x hi", "deny", mcp)
check("take-brace-group", "{ python3 ~/.drsg-memory/tools/event-poller.py --take; }", "deny", take_reason)
check("sudo-grep-event", "sudo grep -n post tools/event.py")
check("brace-grep-event", "{ grep -n post tools/event.py; }")
check("diff-process-substitution", "diff <(cat a) <(cat tools/event.py)")
check("python-optimize-help", "python3 -O ~/.drsg-memory/tools/event.py --help")
for opt in ("-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"):
    check("sudo-opt" + opt, "sudo %s x python3 ~/.drsg-memory/tools/event.py post /x hi" % opt, "deny", mcp)
check("sudo-long-user", "sudo --user=x python3 ~/.drsg-memory/tools/event.py post /x hi", "deny", mcp)
check("output-process-substitution", "cat >(python3 ~/.drsg-memory/tools/event.py post /x hi)", "deny", mcp)

# v1.13 GRD-1 leftovers: compound-command keywords and combined sudo flags.
event_post = "python3 ~/.drsg-memory/tools/event.py post /x hi"
check("then-brace-group", "if true; then { %s; }; fi" % event_post, "deny", mcp)
check("then-subshell", "if true; then ( %s ); fi" % event_post, "deny", mcp)
check("then-subshell-glued", "if true; then (%s); fi" % event_post, "deny", mcp)
check("do-brace-group", "while true; do { %s; }; done" % event_post, "deny", mcp)
check("if-condition", "if %s; then :; fi" % event_post, "deny", mcp)
check("while-condition", "while %s; do :; done" % event_post, "deny", mcp)
check("until-condition", "until %s; do :; done" % event_post, "deny", mcp)
check("take-then-brace-group", "if true; then { python3 ~/.drsg-memory/tools/event-poller.py --take; }; fi", "deny", take_reason)
check("sudo-combined-flags", "sudo -nE " + event_post, "deny", mcp)
check("sudo-combined-flags-reversed", "sudo -En " + event_post, "deny", mcp)
check("sudo-combined-value", "sudo -nu root " + event_post, "deny", mcp)
check("if-grep-event", "if grep -q post tools/event.py; then :; fi")
check("sudo-combined-grep-event", "sudo -nE grep -n post tools/event.py")
check("python-c-allowed", "python3 -c 'print(1)'")
check("python-module-allowed", "python3 -m http.server --help")

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

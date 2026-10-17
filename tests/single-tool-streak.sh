#!/usr/bin/env bash
# Synthetic contract tests for tools/single-tool-streak.py.
# No real transcript content is used; every transcript is generated below.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../tools/single-tool-streak.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export XDG_STATE_HOME="$T/state"

RAN=0
OK=0
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
  fi
}

write_case() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, case = sys.argv[1:]
rows = []

def assistant(mid, *tools):
    content = [{"type": "tool_use", "id": f"u-{mid}-{i}",
                "name": name, "input": {}}
               for i, name in enumerate(tools)]
    rows.append({"type": "assistant", "message": {"id": mid, "content": content}})

def text(mid):
    rows.append({"type": "assistant", "message": {
        "id": mid, "content": [{"type": "text", "text": "plain reply"}]}})

if case == "three":
    assistant("a1", "Edit"); assistant("a2", "Write"); assistant("a3", "Read")
elif case == "multi":
    assistant("a1", "Edit"); assistant("a2", "Write", "Read"); assistant("a3", "Read")
elif case == "bash":
    assistant("a1", "Edit"); assistant("a2", "Bash"); assistant("a3", "Read")
elif case == "duplicate":
    assistant("a1", "Edit"); rows.append(json.loads(json.dumps(rows[-1])))
    assistant("a2", "Write"); assistant("a3", "Read")
elif case == "edit-bash-edit":
    assistant("a1", "Edit"); assistant("a2", "Bash"); assistant("a3", "Edit")
elif case == "pure-text":
    assistant("a1", "Edit"); text("a2"); assistant("a3", "Edit"); assistant("a4", "Edit")
elif case == "parallel":
    assistant("a1", "Edit"); assistant("a2", "Write"); assistant("a3", "Read", "Write")
elif case == "cooldown":
    for mid in ("a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8"):
        assistant(mid, "Edit")
elif case == "slid":
    for i in range(12000):
        assistant(f"slide-{i}", "Edit")
else:
    raise SystemExit(f"unknown case: {case}")

with open(path, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
PY
}

run_hook() {
  local transcript="$1" session="$2"
  printf '{"session_id":"%s","transcript_path":"%s"}\n' "$session" "$transcript" \
    | python3 "$HOOK"
}

json_kind() {
  python3 -c 'import json,sys; d=json.load(sys.stdin); print("reminder" if d.get("hookSpecificOutput", {}).get("additionalContext") else "json")'
}

expect_kind() {
  local label="$1" fixture="$2" want="$3"
  local session="${4:-s-$fixture}" transcript="$T/$fixture.jsonl"
  write_case "$transcript" "$fixture"
  local out rc kind
  set +e
  out="$(run_hook "$transcript" "$session" 2>"$T/stderr")"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    kind="exit-$rc"
  elif [ -z "$out" ]; then
    kind="silent"
  else
    kind="$(printf '%s' "$out" | json_kind 2>/dev/null || printf invalid)"
  fi
  check "$label" "$kind" "$want"
}

write_extra_case() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import sys

transcript, target, case = sys.argv[1:]
rows = []
fail_id = f"failed-edit-{case}"
old_string = "\t\treturn 1\n\t\treturn 2\n"
normalized = "\treturn 1\n\treturn 2\n"

if case == "hit-makefile":
    old_string = "\t\tbuild:\n\t\t@printf 'marker-private'\n"
    normalized = "\tbuild:\n\t@printf 'marker-private'\n"

def assistant(mid, tool, tool_id, tool_input):
    rows.append({"type": "assistant", "message": {"id": mid, "content": [{
        "type": "tool_use", "id": tool_id, "name": tool, "input": tool_input
    }]}})

def result(tool_id, text, is_error):
    rows.append({"type": "user", "message": {"content": [{
        "type": "tool_result", "tool_use_id": tool_id,
        "content": [{"type": "text", "text": text}], "is_error": is_error
    }]}})

if case != "independent":
    assistant("before", "Read", "before-read", {"file_path": target})
assistant("edit", "Edit", fail_id, {"file_path": target, "old_string": old_string,
                                      "new_string": normalized + "changed\n"})
error = "String to replace not found in file."
if case == "no-changes":
    error = "No changes to make"
elif case == "found-matches":
    error = "Found 2 matches"
result(fail_id, f"<tool_use_error>{error}</tool_use_error>", True)

if case in ("repaired-edit", "repaired-write"):
    tool = "Edit" if case == "repaired-edit" else "Write"
    assistant("repair", tool, "repair-success", {"file_path": target})
    result("repair-success", "success", False)

next_tool = "Bash" if case == "independent" else "Read"
assistant("next", next_tool, "next-call", {"file_path": target})
result("next-call", "success", False)
if case == "partial":
    rows.append({"type": "assistant", "message": {"id": "partial", "content": [
        {"type": "tool_use", "id": "cut-off", "name": "Read"}
    ]}})

with open(transcript, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row) + "\n")
    if case == "partial":
        fh.write('{"type":"assistant","message":')
PY
}

extra_phrase="每行少一个前导 tab"
expect_extra() {
  local label="$1" case="$2" path="$3" want="$4" session="${5:-extra-$2}"
  local transcript="$T/$session-extra.jsonl" out kind
  write_extra_case "$transcript" "$path" "$case"
  if [ "$case" = "missing" ]; then rm -f "$path"; fi
  if [ "$case" = "multiple" ]; then
    printf '\treturn 1\n\treturn 2\n\treturn 1\n\treturn 2\n' > "$path"
  elif [ "$case" = "absent" ]; then
    printf '\tnot-the-anchor\n' > "$path"
  elif [ "$case" = "hit-makefile" ]; then
    printf "\tbuild:\n\t@printf 'marker-private'\n" > "$path"
  elif [ "$case" != "missing" ]; then
    printf '\treturn 1\n\treturn 2\n' > "$path"
  fi
  if [ "$case" = "unreadable" ]; then rm -f "$path"; mkdir "$path"; fi
  out="$(run_hook "$transcript" "$session" 2>"$T/extra-stderr")"
  kind="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("hookSpecificOutput", {}).get("additionalContext", ""))' 2>/dev/null || true)"
  if [ "$want" = "yes" ]; then
    check "$label" "$(printf '%s' "$kind" | python3 -c 'import sys; print("yes" if sys.argv[1] in sys.stdin.read() else "no")' "$extra_phrase")" yes
    check "$label file path included" "$(printf '%s' "$kind" | python3 -c 'import sys; print("yes" if sys.argv[1] in sys.stdin.read() else "no")' "$path")" yes
    check "$label explains separator tab" "$(printf '%s' "$kind" | python3 -c 'import sys; print("yes" if "行号后的分隔 tab 不是缩进" in sys.stdin.read() else "no")')" yes
    check "$label does not expose anchor" "$(printf '%s' "$kind" | python3 -c 'import sys; print("no" if "marker-private" in sys.stdin.read() else "yes")')" yes
  else
    check "$label" "$(printf '%s' "$kind" | python3 -c 'import sys; print("no" if sys.argv[1] in sys.stdin.read() else "yes")' "$extra_phrase")" yes
  fi
}

run_extra_test() {
  local label="$1" case="$2" path="$3" want="$4" session="${5:-extra-$2}"
  if [ -n "${EXTRA_ONLY:-}" ] && [ "$case" != "$EXTRA_ONLY" ]; then return; fi
  expect_extra "$label" "$case" "$path" "$want" "$session"
}

GO_FILE="$T/x.go"
MAKE_FILE="$T/Makefile"
run_extra_test "extra tab detected for Go file" hit-go "$GO_FILE" yes
run_extra_test "extra tab detected for tab-indented Makefile" hit-makefile "$MAKE_FILE" yes
run_extra_test "detection independent of streak and successful tool name" independent "$T/independent.go" yes
run_extra_test "normalized anchor absent is silent" absent "$T/absent.go" no
run_extra_test "normalized anchor must occur exactly once" multiple "$T/multiple.go" no
run_extra_test "successful Edit supersedes failed Edit" repaired-edit "$T/repaired-edit.go" no
run_extra_test "successful Write supersedes failed Edit" repaired-write "$T/repaired-write.go" no
run_extra_test "No changes to make is not a candidate" no-changes "$T/no-changes.go" no
run_extra_test "Found N matches is not a candidate" found-matches "$T/found-matches.go" no
run_extra_test "missing target file is silent" missing "$T/missing.go" no
run_extra_test "unreadable target file is silent" unreadable "$T/unreadable.go" no
run_extra_test "partial JSONL tail is ignored" partial "$T/partial.go" yes

if [ -z "${EXTRA_ONLY:-}" ] || [ "${EXTRA_ONLY:-}" = "combined" ]; then
  combined_transcript="$T/combined.jsonl"
  printf '\treturn 1\n\treturn 2\n' > "$GO_FILE"
  write_extra_case "$combined_transcript" "$GO_FILE" hit-go
  context="$(run_hook "$combined_transcript" combined-session | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  check "both hints coexist" "$(printf '%s' "$context" | python3 -c 'import sys; s=sys.stdin.read(); print("yes" if "最近几轮" in s and "每行少一个前导 tab" in s else "no")')" yes
  context="$(run_hook "$combined_transcript" combined-session | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hookSpecificOutput", {}).get("additionalContext", ""))' 2>/dev/null || true)"
  check "streak state write does not erase extra-tab dedup" "$(printf '%s' "$context" | python3 -c 'import sys; print("no" if "每行少一个前导 tab" in sys.stdin.read() else "yes")')" yes
fi

if [ -z "${EXTRA_ONLY:-}" ]; then
# Basic classification and deduplication.
expect_kind "three allowed single calls trigger" three reminder
expect_kind "multi-tool message blocks streak" multi silent
expect_kind "Bash is not allowed" bash silent
expect_kind "duplicate message id counts once" duplicate reminder
expect_kind "Edit Bash Edit does not trigger" edit-bash-edit silent
expect_kind "pure text breaks streak" pure-text silent
expect_kind "parallel allowed calls do not trigger" parallel silent

# Cooldown: same final id repeats are suppressed; five later IDs allow a new reminder.
write_case "$T/cooldown.jsonl" cooldown
check "cooldown first reminder" "$(run_hook "$T/cooldown.jsonl" cooldown-session | json_kind)" reminder
check "cooldown same id suppressed" "$(run_hook "$T/cooldown.jsonl" cooldown-session | wc -c)" 0
python3 - "$T/cooldown.jsonl" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "a", encoding="utf-8") as fh:
    for i in range(9, 14):
        fh.write(json.dumps({"type": "assistant", "message": {
            "id": f"a{i}", "content": [{"type": "tool_use", "id": f"u-a{i}",
            "name": "Edit", "input": {}}]}}) + "\n")
PY
check "cooldown five later ids allow" "$(run_hook "$T/cooldown.jsonl" cooldown-session | json_kind)" reminder
check "new session has independent cooldown" "$(run_hook "$T/cooldown.jsonl" cooldown-session-2 | json_kind)" reminder

# A stored id outside the bounded tail is treated as expired.
write_case "$T/slid.jsonl" slid
mkdir -p "$XDG_STATE_HOME/drsg/single-tool-streak"
printf '{"last_message_id":"slide-0"}' > "$XDG_STATE_HOME/drsg/single-tool-streak/slid-session.json"
check "slid window allows reminder" "$(run_hook "$T/slid.jsonl" slid-session | json_kind)" reminder

# Invalid inputs fail open with no stdout and status zero.
for label in "missing transcript" "malformed transcript" "directory transcript" "invalid stdin"; do
  case "$label" in
    "missing transcript") input='{"session_id":"bad","transcript_path":"/no/such/file"}' ;;
    "malformed transcript") printf '{not-json}\n' > "$T/bad.jsonl"; input="{\"session_id\":\"bad2\",\"transcript_path\":\"$T/bad.jsonl\"}" ;;
    "directory transcript") input="{\"session_id\":\"bad3\",\"transcript_path\":\"$T\"}" ;;
    "invalid stdin") input='{not-json}' ;;
  esac
  set +e
  out="$(printf '%s\n' "$input" | python3 "$HOOK" 2>"$T/stderr")"; rc=$?
  set -e
  check "$label silent exit" "$rc:$(printf '%s' "$out" | wc -c)" "0:0"
done

# State path I/O failures and explicit opt-out remain silent.
write_case "$T/state-error.jsonl" three
printf x > "$T/state-root-file"
set +e
out="$(printf '{\"session_id\":\"state-error\",\"transcript_path\":\"%s\"}\n' "$T/state-error.jsonl" \
  | XDG_STATE_HOME="$T/state-root-file" python3 "$HOOK" 2>"$T/stderr")"; rc=$?
set -e
check "state write failure silent exit" "$rc:$(printf '%s' "$out" | wc -c)" "0:0"
set +e
out="$(printf '{\"session_id\":\"disabled\",\"transcript_path\":\"%s\"}\n' "$T/state-error.jsonl" \
  | DRSG_SINGLE_TOOL_STREAK_DISABLED=1 python3 "$HOOK" 2>"$T/stderr")"; rc=$?
set -e
check "environment opt-out silent exit" "$rc:$(printf '%s' "$out" | wc -c)" "0:0"

# setup registers the global hook idempotently and preserves unrelated hooks.
SETUP_HOME="$T/setup-home"
SETUP_TOOLS="$T/setup-tools"
SETUP_CLAUDE="$T/setup-claude"
mkdir -p "$SETUP_CLAUDE"
python3 - "$SETUP_CLAUDE/settings.json" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({"hooks": {"PostToolUse": [{"hooks": [{
        "type": "command", "command": "foreign-tool"
    }]}]}}, fh)
PY
run_setup() {
  HOME="$SETUP_HOME" DRSG_MEM_DIR="$T/setup-mem" CLAUDE_CONFIG_DIR="$SETUP_CLAUDE" \
    bash "$HERE/../setup.sh" --no-skills --no-event-poller --tools-dir "$SETUP_TOOLS" >/dev/null
}
run_setup
run_setup
python3 - "$SETUP_CLAUDE/settings.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    hooks = json.load(fh)["hooks"]
post = hooks.get("PostToolUse", [])
commands = [h.get("command", "") for group in post for h in group.get("hooks", [])]
assert commands.count("foreign-tool") == 1, commands
assert sum("single-tool-streak.py" in command for command in commands) == 1, commands
PY
check "setup idempotently registers hook and keeps foreign hook" "$?" 0
NO_HINT_CLAUDE="$T/no-hint-claude"
mkdir -p "$NO_HINT_CLAUDE"
HOME="$SETUP_HOME" DRSG_MEM_DIR="$T/setup-mem-no-hint" CLAUDE_CONFIG_DIR="$NO_HINT_CLAUDE" \
  bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint \
  --tools-dir "$T/no-hint-tools" >/dev/null
python3 - "$NO_HINT_CLAUDE/settings.json" <<'PY'
import json, os, sys
path = sys.argv[1]
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        hooks = json.load(fh).get("hooks", {})
else:
    hooks = {}
assert not hooks.get("PostToolUse"), hooks.get("PostToolUse")
PY
check "--no-streak-hint skips registration" "$?" 0

# setup.sh rewrites settings.json through a temp file; an existing file's mode
# (0600: it can hold tokens) must survive the rewrite.
MODE_CLAUDE="$T/mode-claude"
mkdir -p "$MODE_CLAUDE"
printf '{}\n' > "$MODE_CLAUDE/settings.json"
chmod 600 "$MODE_CLAUDE/settings.json"
( umask 022
  HOME="$SETUP_HOME" DRSG_MEM_DIR="$T/setup-mem-mode" CLAUDE_CONFIG_DIR="$MODE_CLAUDE" \
    bash "$HERE/../setup.sh" --no-skills --no-event-poller --tools-dir "$T/mode-tools" >/dev/null )
mode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$MODE_CLAUDE/settings.json")"
check "setup keeps settings.json mode 0600" "$mode" 600

# A 20 MiB transcript must still be read from a bounded tail quickly.
write_case "$T/timing.jsonl" three
python3 - "$T/timing.jsonl" <<'PY'
import os, sys
path = sys.argv[1]
with open(path, "ab") as fh:
    block = b'{"type":"assistant","message":{"id":"filler","content":[{"type":"text","text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}]} }\n'
    while os.path.getsize(path) < 20 * 1024 * 1024:
        fh.write(block)
PY
start="$(python3 -c 'import time; print(time.monotonic_ns())')"
run_hook "$T/timing.jsonl" timing-session >/dev/null
end="$(python3 -c 'import time; print(time.monotonic_ns())')"
ms=$(( (end - start) / 1000000 ))
if [ "$ms" -lt 200 ]; then timing=pass; else timing="${ms}ms"; fi
check "20 MiB tail read under 200ms" "$timing" pass
printf '20 MiB invocation: %d ms\n' "$ms"
fi

printf 'PASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

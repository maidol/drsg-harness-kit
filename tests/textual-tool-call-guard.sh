#!/usr/bin/env bash
# Contract and mutation tests for tools/textual-tool-call-guard.py.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GUARD="$REPO/tools/textual-tool-call-guard.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RAN=0
OK=0

check() {
  local desc="$1" got="$2" want="$3"
  RAN=$((RAN + 1))
  if [ "$got" = "$want" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$desc"
  else
    printf 'FAIL %s: got %q, want %q\n' "$desc" "$got" "$want"
    exit 1
  fi
}

run_hook() {
  local input="$1"
  local env_var="${2:-}"
  local out_file="$TMP/out.txt"
  local err_file="$TMP/err.txt"
  local rc=0

  if [ -n "$env_var" ]; then
    env "$env_var" python3 "$GUARD" <<<"$input" >"$out_file" 2>"$err_file" || rc=$?
  else
    python3 "$GUARD" <<<"$input" >"$out_file" 2>"$err_file" || rc=$?
  fi

  printf '%s|%s|%s\n' "$rc" "$(<"$out_file")" "$(<"$err_file")"
}

# --- 1. Scenario Coverage ---

# Case 1: Hit typical textual tool call directly in last_assistant_message
input_hit='{"hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "<mcp__drsg-events__event_list>{\"project\": \"/data/foo\", \"status\": \"all\"}</mcp__drsg-events__event_list>"}'
res=$(run_hook "$input_hit")
rc=$(printf '%s' "$res" | cut -d'|' -f1)
stdout=$(printf '%s' "$res" | cut -d'|' -f2)
stderr=$(printf '%s' "$res" | cut -d'|' -f3)
check "hit textual tool call: rc is 0" "$rc" "0"
check "hit textual tool call: stdout has decision block" "$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('decision'))" "$stdout")" "block"
check "hit textual tool call: stderr is empty" "$stderr" ""

# Case 2: Explanatory text around tool call -> allow
input_surrounded='{"hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "Here is the call:\n<mcp__drsg-events__event_list>{\"status\": \"all\"}</mcp__drsg-events__event_list>\nHope this helps."}'
res=$(run_hook "$input_surrounded")
check "surrounding text allowed: stdout empty" "$(printf '%s' "$res" | cut -d'|' -f2)" ""

# Case 3: Documentation mentioning tag -> allow
input_doc='{"hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "In this project we use <mcp__drsg-events__event_list> to list events."}'
res=$(run_hook "$input_doc")
check "doc mentioning tag allowed: stdout empty" "$(printf '%s' "$res" | cut -d'|' -f2)" ""

# Case 4: Non-dict JSON inside tag -> allow
input_list='{"hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "<mcp__drsg-events__event_list>[\"not\", \"a\", \"dict\"]</mcp__drsg-events__event_list>"}'
res=$(run_hook "$input_list")
check "non-dict JSON allowed: stdout empty" "$(printf '%s' "$res" | cut -d'|' -f2)" ""

# Case 5: Multiple textual calls (C4) -> allow
input_multi='{"hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "<Read>{\"file_path\": \"a\"}</Read>\n<Read>{\"file_path\": \"b\"}</Read>"}'
res=$(run_hook "$input_multi")
check "multiple calls allowed (C4): stdout empty" "$(printf '%s' "$res" | cut -d'|' -f2)" ""

# Case 6: stop_hook_active is true -> allow
input_active='{"hook_event_name": "Stop", "stop_hook_active": true, "last_assistant_message": "<mcp__drsg-events__event_list>{\"status\": \"all\"}</mcp__drsg-events__event_list>"}'
res=$(run_hook "$input_active")
check "stop_hook_active true allowed: stdout empty" "$(printf '%s' "$res" | cut -d'|' -f2)" ""

# Case 7: Bad input (empty / bad json / non-existent transcript) -> allow, stdout and stderr empty (C3)
res_empty=$(run_hook "")
check "empty input rc 0" "$(printf '%s' "$res_empty" | cut -d'|' -f1)" "0"
check "empty input stdout empty" "$(printf '%s' "$res_empty" | cut -d'|' -f2)" ""
check "empty input stderr empty" "$(printf '%s' "$res_empty" | cut -d'|' -f3)" ""

res_badjson=$(run_hook "not a json{{{")
check "bad json rc 0" "$(printf '%s' "$res_badjson" | cut -d'|' -f1)" "0"
check "bad json stdout empty" "$(printf '%s' "$res_badjson" | cut -d'|' -f2)" ""
check "bad json stderr empty" "$(printf '%s' "$res_badjson" | cut -d'|' -f3)" ""

bad_transcript_input="{\"hook_event_name\": \"Stop\", \"stop_hook_active\": false, \"transcript_path\": \"$TMP\"}"
res_badtranscript=$(run_hook "$bad_transcript_input")
check "bad transcript path rc 0 (C3)" "$(printf '%s' "$res_badtranscript" | cut -d'|' -f1)" "0"
check "bad transcript path stdout empty (C3)" "$(printf '%s' "$res_badtranscript" | cut -d'|' -f2)" ""
check "bad transcript path stderr empty (C3)" "$(printf '%s' "$res_badtranscript" | cut -d'|' -f3)" ""

# Case 8: Disabled via env var -> allow
res_disabled=$(run_hook "$input_hit" "DRSG_STOP_TEXTUAL_TOOL_CALL_GUARD_DISABLED=1")
check "disabled via env var allowed: stdout empty" "$(printf '%s' "$res_disabled" | cut -d'|' -f2)" ""

# Case 9: Built-in tool name (e.g. Bash) -> hit and block
input_builtin='{"hook_event_name": "Stop", "stop_hook_active": false, "last_assistant_message": "<Bash>{\"command\": \"ls -la\"}</Bash>"}'
res_builtin=$(run_hook "$input_builtin")
check "builtin tool call blocked: stdout has block" "$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('decision'))" "$(printf '%s' "$res_builtin" | cut -d'|' -f2)")" "block"

# Case 10: Transcript fallback fixture (4 lines: thinking, text, attachment, attachment; no last_assistant_message) (C2)
transcript_file="$TMP/test_transcript.jsonl"
cat > "$transcript_file" <<'JSONL'
{"type": "assistant", "message": {"id": "m1", "role": "assistant", "content": [{"type": "thinking", "thinking": "Let me list events..."}]}}
{"type": "assistant", "message": {"id": "m1", "role": "assistant", "content": [{"type": "text", "text": "<mcp__drsg-events__event_list>{\"status\":\"all\"}</mcp__drsg-events__event_list>"}]}}
{"type": "attachment", "attachment": {"type": "hook_summary", "content": "summary 1"}}
{"type": "attachment", "attachment": {"type": "hook_summary", "content": "summary 2"}}
JSONL

input_fallback="{\"hook_event_name\": \"Stop\", \"stop_hook_active\": false, \"transcript_path\": \"$transcript_file\"}"
res_fallback=$(run_hook "$input_fallback")
check "transcript fallback hit: rc is 0" "$(printf '%s' "$res_fallback" | cut -d'|' -f1)" "0"
check "transcript fallback hit: stdout has block" "$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('decision'))" "$(printf '%s' "$res_fallback" | cut -d'|' -f2)")" "block"


# --- 2. Mutation Verifications (6 Mutants) ---

printf '\n== Running 6 Mutation Verifications ==\n'
KILLED=0
SURVIVED=0

run_mutant() {
  local name="$1"
  local mutant_code="$2"
  local test_input="$3"
  local test_env="${4:-}"
  local expect_killed_when="$5" # "stdout_nonempty" or "stdout_empty" or "error_or_stderr"

  local m_file="$TMP/mutant_${name}.py"
  printf '%s\n' "$mutant_code" > "$m_file"
  local m_out="$TMP/m_${name}.out"
  local m_err="$TMP/m_${name}.err"
  local m_rc=0

  if [ -n "$test_env" ]; then
    env "$test_env" python3 "$m_file" <<<"$test_input" >"$m_out" 2>"$m_err" || m_rc=$?
  else
    python3 "$m_file" <<<"$test_input" >"$m_out" 2>"$m_err" || m_rc=$?
  fi

  local m_stdout
  m_stdout=$(<"$m_out")
  local m_stderr
  m_stderr=$(<"$m_err")

  local killed=0
  if [ "$expect_killed_when" = "stdout_nonempty" ]; then
    # The normal code outputs nothing. If mutant outputs something (e.g. block), mutant is killed.
    if [ -n "$m_stdout" ]; then killed=1; fi
  elif [ "$expect_killed_when" = "stdout_empty" ]; then
    # The normal code outputs block. If mutant outputs nothing, mutant is killed.
    if [ -z "$m_stdout" ]; then killed=1; fi
  elif [ "$expect_killed_when" = "error_or_stderr" ]; then
    # The normal code exits 0 with empty stderr. If mutant fails or prints stderr, mutant is killed.
    if [ "$m_rc" -ne 0 ] || [ -n "$m_stderr" ]; then killed=1; fi
  fi

  if [ "$killed" -eq 1 ]; then
    KILLED=$((KILLED + 1))
    printf 'killed mutant %s\n' "$name"
  else
    SURVIVED=$((SURVIVED + 1))
    printf 'SURVIVED mutant %s\n' "$name"
  fi
}

SRC_TEXT=$(<"$GUARD")

# Mutant 1: Remove stop_hook_active check -> runs Case 6 input (stop_hook_active: true). Expected: normally allowed (empty), mutant blocks (non-empty).
M1_TEXT=$(python3 -c '
import sys
src = sys.stdin.read()
target = "if hook.get(\"stop_hook_active\") is True:\n        return"
assert target in src, "target not found"
print(src.replace(target, "pass"))
' <<<"$SRC_TEXT")
run_mutant "1_stop_hook_active" "$M1_TEXT" "$input_active" "" "stdout_nonempty"

# Mutant 2: Remove JSON dict check -> runs Case 4 input (non-dict JSON). Expected: normally allowed, mutant blocks.
M2_TEXT=$(python3 -c '
import sys
src = sys.stdin.read()
target = "return isinstance(payload, dict)"
assert target in src, "target not found"
print(src.replace(target, "return True"))
' <<<"$SRC_TEXT")
run_mutant "2_json_dict_check" "$M2_TEXT" "$input_list" "" "stdout_nonempty"

# Mutant 3: Relax anchor matching (strip check removed + search instead of match) -> runs Case 2 input (explanatory text around tool call). Expected: normally allowed, mutant blocks.
M3_TEXT=$(python3 -c '
import sys
src = sys.stdin.read()
target = "match = TAG_PATTERN.match(text.strip())"
assert target in src, "target not found"
print(src.replace(target, "match = re.search(r\"<([a-zA-Z0-9_:\-]+)>(.*?)</\\1>\", text, re.DOTALL)"))
' <<<"$SRC_TEXT")
run_mutant "3_anchor_match" "$M3_TEXT" "$input_surrounded" "" "stdout_nonempty"

# Mutant 4: Remove disabled env check -> runs Case 8 input (with disabled env). Expected: normally allowed, mutant blocks.
M4_TEXT=$(python3 -c '
import sys
src = sys.stdin.read()
target = "if os.environ.get(\"DRSG_STOP_TEXTUAL_TOOL_CALL_GUARD_DISABLED\") == \"1\":\n        return"
assert target in src, "target not found"
print(src.replace(target, "pass"))
' <<<"$SRC_TEXT")
run_mutant "4_env_disabled" "$M4_TEXT" "$input_hit" "DRSG_STOP_TEXTUAL_TOOL_CALL_GUARD_DISABLED=1" "stdout_nonempty"

# Mutant 5: Remove transcript fallback -> runs Case 10 input (fallback fixture). Expected: normally blocks, mutant allows (empty).
M5_TEXT=$(python3 -c '
import sys
src = sys.stdin.read()
target = "transcript_path = hook.get(\"transcript_path\")"
assert target in src, "target not found"
print(src.replace(target, "return None\n    transcript_path = None"))
' <<<"$SRC_TEXT")
run_mutant "5_transcript_fallback" "$M5_TEXT" "$input_fallback" "" "stdout_empty"

# Mutant 6: Remove outer try/except -> runs bad transcript path pointing to directory. Expected: normally rc=0 stderr empty, mutant crashes with exception/stderr.
M6_TEXT=$(python3 -c '
import sys
src = sys.stdin.read()
old = """if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass"""
new = """if __name__ == "__main__":
    main()"""
assert old in src, "target not found"
print(src.replace(old, new))
' <<<"$SRC_TEXT")
run_mutant "6_fail_open_crash" "$M6_TEXT" "$bad_transcript_input" "" "error_or_stderr"

# Mutant 7: Read only the last transcript line -> runs Case 10 input (fallback fixture ends with two attachment rows). Expected: normally blocks, mutant allows (empty).
M7_TEXT=$(python3 -c '
import sys
src = sys.stdin.read()
target = "    for line in lines:\n        try:\n            row = json.loads(line)"
assert src.count(target) == 1, "target not found"
print(src.replace(target, "    for line in lines[-1:]:\n        try:\n            row = json.loads(line)"))
' <<<"$SRC_TEXT")
run_mutant "7_transcript_last_line_only" "$M7_TEXT" "$input_fallback" "" "stdout_empty"

printf 'mutants: %d killed, %d survived\n' "$KILLED" "$SURVIVED"
if [ "$KILLED" -ne 7 ] || [ "$SURVIVED" -ne 0 ]; then
  printf 'FAIL mutation gate: %d killed, %d survived (want 7 killed, 0 survived)\n' "$KILLED" "$SURVIVED"
  exit 1
fi

printf 'All textual tool call guard tests passed (%d tests, %d/7 mutants killed).\n' "$RAN" "$KILLED"

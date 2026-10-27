#!/usr/bin/env bash
# Contract tests for tools/sensitive-file-read-guard.py: whole-file reads of
# files that may hold credentials are denied before they run; structure-only
# reads are allowed. ONLY=<case name> runs one case (used by the mutation check).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${SENSITIVE_GUARD:-$HERE/../tools/sensitive-file-read-guard.py}"
ONLY="${ONLY:-}"

RAN=0
OK=0
selected() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
check() {
  local name="$1" want="$2" actual_fn="$3" actual
  shift 3
  selected "$name" || return
  RAN=$((RAN + 1))
  actual="$("$actual_fn" "$@")"
  if [ "$actual" = "$want" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s: got %s want %s\n' "$name" "$actual" "$want"
  fi
}

# decision TOOL JSON-INPUT [ENV=VAL]: prints allow, or deny|<reason>.
decision() {
  local tool="$1" input="$2" envset="${3:-}"
  if [ -n "$envset" ]; then
    python3 -c 'import json,sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": sys.argv[1],
                  "tool_input": json.loads(sys.argv[2])}))' "$tool" "$input" |
      env -u DRSG_SENSITIVE_READ_GUARD_DISABLED "$envset" python3 "$GUARD" |
      python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print("allow")
else:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + "|" + out["permissionDecisionReason"])'
  else
    python3 -c 'import json,sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": sys.argv[1],
                  "tool_input": json.loads(sys.argv[2])}))' "$tool" "$input" |
      env -u DRSG_SENSITIVE_READ_GUARD_DISABLED python3 "$GUARD" |
      python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print("allow")
else:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + "|" + out["permissionDecisionReason"])'
  fi
}
bash_d() {
  decision Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1")" "${2:-}"
}
first() { printf '%s' "${1%%|*}"; }
actual_bash() { bash_d "$@"; }
actual_first_bash() { first "$(bash_d "$1")"; }
actual_decision() { decision "$1" "$2"; }
actual_first_decision() { first "$(decision "$1" "$2")"; }
actual_invalid_json() {
  local rc=0 out
  out="$(printf 'not json' | python3 "$GUARD" 2>&1)" || rc=$?
  printf '%s|%s' "$rc" "$out"
}
actual_missing_input() {
  local rc=0 out
  out="$(printf '{"tool_name": "Bash"}' | python3 "$GUARD" 2>&1)" || rc=$?
  printf '%s|%s' "$rc" "$out"
}
actual_heredoc_write() {
  local command
  command="$(printf 'cat > .env <<%sEOF%s\nA=1\nEOF' "'" "'")"
  bash_d "$command"
}
actual_heredoc_data() {
  local quote="'" command
  command="$(printf 'python3 - <<%sEOF%s\nprint("run `cat .env` and `jq -r %s.x%s ~/.claude/settings.json` first")\nEOF' "$quote" "$quote" "$quote" "$quote")"
  bash_d "$command"
}
actual_heredoc_tab() {
  local command
  command="$(printf 'cat <<-END\n\tcat .mcp.json\n\tEND\necho done')"
  bash_d "$command"
}
actual_heredoc_after() {
  local command
  command="$(printf 'python3 - <<EOF\nprint(1)\nEOF\ncat .env')"
  first "$(bash_d "$command")"
}
actual_reason() {
  local key="$1" output
  output="$(bash_d 'cat /secret-dir-name/.mcp.json')"
  case "$key" in
    category) printf '%s' "$output" | grep -c 'category: mcp-config' ;;
    jq) printf '%s' "$output" | grep -c "jq '.mcpServers | keys'" ;;
    settings) printf '%s' "$output" | grep -c "jq '.hooks | keys'" ;;
    edit) printf '%s' "$output" | grep -c "> <file>.new && mv <file>.new <file>" ;;
    assist) printf '%s' "$output" | grep -c '请求协助：' ;;
    no-assist-content) printf '%s' "$output" | grep -c '不要附上敏感文件内容' ;;
    no-command) printf '%s' "$output" | grep -c 'secret-dir-name' ;;
    separate) printf '%s' "$output" | grep -c 'Run a config read as a command of its own' ;;
    count) printf '%s' "$output" | grep -c 'not cat <file> | grep -c' ;;
    separate-zh) printf '%s' "$output" | grep -c '读配置单独发一条' ;;
  esac
}

# --- denied: the two incident commands first ---
check "incident 10-19: cat .mcp.json || true" deny actual_first_bash 'cat .mcp.json || true'
check "incident 10-18: cat .mcp.json | head -20" deny actual_first_bash 'cat .mcp.json | head -20'
check "reader after a pipe" deny actual_first_bash 'printf x | cat - .env'
check "head ~/.claude.json" deny actual_first_bash 'head -5 ~/.claude.json'
check "less config.env" deny actual_first_bash 'less config.env'
check "grep TOKEN .env" deny actual_first_bash 'grep TOKEN .env'
check "jq . .mcp.json" deny actual_first_bash 'jq . .mcp.json'
check "jq headers .mcp.json" deny actual_first_bash "jq '.mcpServers[] | .headers' .mcp.json"
check "echo \$(cat .mcp.json)" deny actual_first_bash 'echo $(cat .mcp.json)'
check "backtick cat" deny actual_first_bash 'echo `cat .env`'
check "after && in a chain" deny actual_first_bash 'cd /x && cat .claude/settings.local.json'
check "after ; in a chain" deny actual_first_bash 'pwd; tail -n 3 /p/.claude/settings.json'
check "env prefix and sudo" deny actual_first_bash 'FOO=1 sudo cat /root/.netrc'
check "stdin redirect" deny actual_first_bash 'cat < .mcp.json'
check "private key" deny actual_first_bash 'cat ~/.ssh/id_ed25519'
check "unbalanced quote falls back to deny" deny actual_first_bash "cat .mcp.json 'oops"
check "Read .mcp.json" deny actual_first_decision Read '{"file_path": "/x/.mcp.json"}'
check "Grep content on .mcp.json" deny actual_first_decision Grep '{"pattern": "Bearer", "path": ".mcp.json", "output_mode": "content"}'

# --- allowed ---
check "jq keys" allow actual_bash "jq '.mcpServers | keys' .mcp.json"
check "jq type,url" allow actual_bash "jq '.mcpServers[] | {type, url}' .mcp.json"
check "jq hook matcher object" allow actual_bash "jq '.hooks.PreToolUse[] | {matcher}' ~/.claude/settings.json"
check "jq path to hook commands" allow actual_bash "jq -r '.hooks[][] | .hooks[].command' ~/.claude/settings.json"
check "jq path to server url" allow actual_bash "jq -r '.mcpServers[].url' .mcp.json"
check "jq path to a header value" deny actual_first_bash "jq -r '.mcpServers[].headers.Authorization' .mcp.json"
check "jq path to an env value" deny actual_first_bash "jq '.env.ANTHROPIC_API_KEY' .claude/settings.local.json"
check "jq path to args" deny actual_first_bash "jq '.mcpServers[].args[]' .mcp.json"
check "jq string built from fields" deny actual_first_bash "jq '.hooks[][] | .matcher + .env.X' ~/.claude/settings.json"
# Structure-only filters that combine several expressions: the seven
# false denials seen 10-19..10-21 (paths shortened).
check "jq matcher plus command basename" allow actual_bash "jq -r '.hooks.PreToolUse[]? | .matcher + \"  \" + (.hooks[].command | split(\"/\")[-1])' ~/.claude/settings.json"
check "jq hook event names joined" allow actual_bash "jq -r '.hooks | keys | join(\",\")' .claude/settings.local.json"
check "jq hook objects" allow actual_bash "jq -c '.hooks.SessionStart, .hooks.PostCompact' .claude/settings.local.json"
check "jq object of keys, matchers and counts" allow actual_bash "jq '{event_names:(.hooks|keys),session_start_matchers:[.hooks.SessionStart[].matcher],postcompact_count:(.hooks.PostCompact|length)}' .claude/settings.json"
check "jq keys of the file and of env" allow actual_bash "jq 'keys, (.env // {} | keys)' .claude/settings.local.json"
check "jq array of keys" allow actual_bash "jq -c '[keys, (.env // {} | keys)]' .claude/settings.local.json"
check "jq comparison prints only a boolean" allow actual_bash "jq -e '.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW == \"50000\"' settings.local.json"
# ...and combinations that still carry a value out.
check "jq comma with an unsafe side" deny actual_first_bash "jq '.env, .hooks' .claude/settings.local.json"
check "jq array holding headers" deny actual_first_bash "jq '[.mcpServers[].headers]' .mcp.json"
check "jq object holding env" deny actual_first_bash "jq '{a: .env}' .claude/settings.local.json"
check "jq unknown function" deny actual_first_bash "jq '.env | debug' .claude/settings.local.json"
check "jq string interpolation" deny actual_first_bash "jq '\"\\(.env.X)\"' .claude/settings.local.json"
check "jq tostring keeps env unsafe" deny actual_first_bash "jq '.env | tostring' .claude/settings.local.json"
check "jq hooks key below the top level" deny actual_first_bash "jq '.mcpServers[] | .hooks' .mcp.json"
# 10-22 replays: --arg values, $variables, interpolation and to_entries keys,
# and a jq edit whose output goes to a file, not to the transcript.
check "jq --arg index (10-22 02:21)" allow actual_bash "jq -r --arg p /work/x '.projects[\$p].mcpServers | keys' ~/.claude.json"
check "jq interpolation of keys and safe fields (10-22 02:21)" allow actual_bash "jq -r --arg p /x '.projects[\$p].mcpServers | to_entries[] | \"\\(.key) type=\\(.value.type) url=\\(.value.url) headers=\\((.value.headers//{})|keys|join(\",\"))\"' ~/.claude.json"
check "jq edit written to a new file (10-22 08:01)" allow actual_bash "jq --arg c 'bash -c x' '.hooks.SessionStart += [{\"matcher\":\"m\",\"hooks\":[{\"type\":\"command\",\"command\":\$c}]}]' settings.local.json > settings.local.json.new && mv settings.local.json.new settings.local.json"
check "jq --arg still denies a value" deny actual_first_bash "jq --arg p /x '.projects[\$p].mcpServers' ~/.claude.json"
check "jq --rawfile variable" deny actual_first_bash "jq -n --rawfile s .mcp.json '\$s'"
check "jq to_entries value" deny actual_first_bash "jq '.mcpServers | to_entries[] | .value' .mcp.json"
check "jq interpolation with an unsafe part" deny actual_first_bash "jq -r '.mcpServers | to_entries[] | \"\\(.key) \\(.value.headers)\"' .mcp.json"
check "jq output to /dev/stderr" deny actual_first_bash 'jq . .mcp.json > /dev/stderr'
check "jq output to stderr by fd" deny actual_first_bash 'jq . .mcp.json >&2'
check "jq output copied to a plain file" deny actual_first_bash 'jq . .mcp.json > /tmp/x && cat /tmp/x'
check "cat a .new copy" deny actual_first_bash 'cat settings.local.json.new'
check "cat a dated backup" deny actual_first_bash 'cat .claude/settings.local.json.bak-20261022-snapshot'
# 10-27 todo-44: three false denials, and the settings blocks the user allowed
# (permissions, autoMode, statusLine; top level of a claude-config file only).
check "jq // empty after a safe path (10-27 08:39)" allow actual_bash "jq -r '.statusLine.command // empty' ~/.claude/settings.json"
check "jq open slice then length (10-27 07:42)" allow actual_bash "jq -r '.mcpServers[\"x\"].headers.Authorization[7:] | length' .mcp.json"
check "jq slice without a start then length" allow actual_bash "jq -r '.mcpServers.x.headers.Authorization[:3] | length' .mcp.json"
check "jq hook asyncRewake (10-24 05:35)" allow actual_bash "jq -r '.hooks.Stop[].hooks[] | \"\\(.command) timeout=\\(.timeout) async=\\(.asyncRewake // false)\"' ~/.claude/settings.json"
check "jq permissions block" allow actual_bash "jq '.permissions' ~/.claude/settings.json"
check "jq permissions allow list (10-24 12:23)" allow actual_bash "jq -r '.permissions.allow[]?' ~/.claude/settings.json"
check "jq permissions ask list (10-24 14:33)" allow actual_bash "jq -r '.permissions.ask[]?' .claude/settings.local.json"
check "jq permissions additionalDirectories" allow actual_bash "jq '.permissions.additionalDirectories' .claude/settings.local.json"
check "jq permissions defaultMode" allow actual_bash "jq -r '.permissions.defaultMode' ~/.claude/settings.json"
check "jq permissions summary object (10-24 12:23)" allow actual_bash "jq '.permissions // empty | {allow: (.allow|length), additionalDirectories, defaultMode}' ~/.claude/settings.json"
check "jq autoMode block" allow actual_bash "jq '.autoMode' ~/.claude/settings.json"
check "jq autoMode allow list (10-20 17:30)" allow actual_bash "jq -r '.autoMode.allow[]?' ~/.claude/settings.json"
check "jq autoMode environment list" allow actual_bash "jq -r '.autoMode.environment[]?' ~/.claude/settings.json"
check "jq statusLine object (10-27 08:38)" allow actual_bash "jq -r '.statusLine' ~/.claude/settings.json"
check "jq statusLine command" allow actual_bash "jq -r '.statusLine.command' ~/.claude/settings.json"
check "jq permissions in ~/.claude.json" allow actual_bash "jq '.permissions' ~/.claude.json"
check "jq env value after // empty" deny actual_first_bash "jq -r '.env.X // empty' ~/.claude/settings.json"
check "jq open slice prints the value" deny actual_first_bash "jq -r '.mcpServers.x.headers.Authorization[7:]' .mcp.json"
check "jq permissions below the top level" deny actual_first_bash "jq '.projects[\"/p\"].permissions' ~/.claude.json"
check "jq permissions with env" deny actual_first_bash "jq '.permissions, .env' ~/.claude/settings.json"
check "jq object of permissions and env" deny actual_first_bash "jq '{p: .permissions, e: .env}' ~/.claude/settings.json"
check "jq permissions in .mcp.json" deny actual_first_bash "jq '.permissions' .mcp.json"
check "jq mcpServers args in ~/.claude.json" deny actual_first_bash "jq '.mcpServers[].args' ~/.claude.json"
check "jq projects mcpServers env" deny actual_first_bash "jq '.projects[].mcpServers[].env' ~/.claude.json"
check "jq whole settings file" deny actual_first_bash "jq . ~/.claude/settings.json"
check "Read settings file" deny actual_first_decision Read '{"file_path": "/x/.claude/settings.json"}'
check "grep -c" allow actual_bash 'grep -c WDZT_AK config.env'
check "grep -l" allow actual_bash 'grep -l Bearer .mcp.json'
check "grep -q in combined flags" allow actual_bash 'grep -iq token .env && echo yes'
check "example env" allow actual_bash 'cat config.example.env'
check "env.example" allow actual_bash 'cat env.example'
check "README" allow actual_bash 'cat README.md'
check "ls" allow actual_bash 'ls -la .mcp.json'
check "public key" allow actual_bash 'cat id_rsa.pub'
check "grep pattern that looks like a file" allow actual_bash 'grep -n .env README.md'
check "writing an env file with a heredoc" allow actual_heredoc_write
check "heredoc body is data" allow actual_heredoc_data
check "<<- heredoc body is data" allow actual_heredoc_tab
check "command after the heredoc terminator" deny actual_heredoc_after
check "herestring is not a heredoc" deny actual_first_bash 'cat <<< x; cat .env'
check "appending to an env file" allow actual_bash 'cat part.txt >> config.env'
check "sourcing an env file" allow actual_bash 'set -a; . ~/.config/x/ccr.env; set +a'
check "Read README" allow actual_decision Read '{"file_path": "/x/README.md"}'
check "Grep count on .mcp.json" allow actual_decision Grep '{"pattern": "Bearer", "path": ".mcp.json", "output_mode": "count"}'
check "Grep default mode on .mcp.json" allow actual_decision Grep '{"pattern": "Bearer", "path": ".mcp.json"}'
check "disabled switch" allow actual_bash 'cat .mcp.json' DRSG_SENSITIVE_READ_GUARD_DISABLED=1

# --- broken input fails open, silently ---
check "invalid JSON: exit 0, no output" "0|" actual_invalid_json
check "missing tool_input: exit 0, no output" "0|" actual_missing_input

# --- the reason: a category and the alternatives, never the command ---
check "reason names the category" 1 actual_reason category
check "reason gives the jq alternative" 1 actual_reason jq
check "reason gives the settings alternative" 1 actual_reason settings
check "reason gives the edit alternative" 1 actual_reason edit
check "reason offers reviewer assistance route" 1 actual_reason assist
check "assistance route excludes sensitive file contents" 1 actual_reason no-assist-content
check "reason does not echo the command" 0 actual_reason no-command
check "reason says to run a config read alone" 1 actual_reason separate
check "reason gives the grep -c count alternative" 1 actual_reason count
check "reason says to run a config read alone (zh)" 1 actual_reason separate-zh

actual_setup() {
  local mode="$1" result
  local T
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' RETURN
  mkdir -p "$T/claude" "$T/claude-off" "$T/home"
  run_setup() {
    HOME="$T/home" DRSG_MEM_DIR="$T/mem-$1" CLAUDE_CONFIG_DIR="$T/$1" \
      bash "$HERE/../setup.sh" --no-skills --tools-dir "$T/tools-$1" "${@:2}" >/dev/null 2>&1
  }
  hooks_summary() {
    python3 - "$1" <<'PY'
import json, sys
hooks = json.load(open(sys.argv[1])).get("hooks", {})
guard = [g.get("matcher") for ev, gs in hooks.items() for g in gs
         for h in g.get("hooks", []) if "sensitive-file-read-guard.py" in h.get("command", "")]
others = sorted({g.get("matcher") for ev, gs in hooks.items() for g in gs
                 if not any("sensitive-file-read-guard.py" in h.get("command", "") for h in g.get("hooks", []))})
print("guard=" + ",".join(guard))
print("others=" + ",".join(others))
PY
  }
  case "$mode" in
    guard-on)
      run_setup claude
      result="$(hooks_summary "$T/claude/settings.json" | sed -n 's/^guard=//p')"
      printf '%s' "$result"
      ;;
    other-matchers)
      run_setup claude
      result="$(hooks_summary "$T/claude/settings.json" | sed -n 's/^others=//p')"
      printf '%s' "$result"
      ;;
    guard-off)
      run_setup claude-off --no-sensitive-read-guard
      result="$(hooks_summary "$T/claude-off/settings.json" | sed -n 's/^guard=//p')"
      printf '%s' "$result"
      ;;
  esac
}
check "setup registers Bash|Read|Grep once" "Bash|Read|Grep" actual_setup guard-on
check "setup leaves other matchers on *" "*" actual_setup other-matchers
check "--no-sensitive-read-guard skips registration" "" actual_setup guard-off

if [ -n "$ONLY" ] && [ "$RAN" -eq 0 ]; then
  printf 'FAIL unknown-only-case: %s\n' "$ONLY"
  RAN=1
fi
printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

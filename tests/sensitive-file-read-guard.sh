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
check() {
  if [ -n "$ONLY" ] && [ "$ONLY" != "$1" ]; then
    return
  fi
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
  fi
}

# decision TOOL JSON-INPUT [ENV=VAL]: prints allow, or deny|<reason>.
decision() {
  local tool="$1" input="$2" envset="${3:-}"
  python3 -c 'import json,sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": sys.argv[1],
                  "tool_input": json.loads(sys.argv[2])}))' "$tool" "$input" |
    env -u DRSG_SENSITIVE_READ_GUARD_DISABLED $envset python3 "$GUARD" |
    python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print("allow")
else:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + "|" + out["permissionDecisionReason"])'
}
bash_d() {
  decision Bash "$(python3 -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1")" "${2:-}"
}
first() { printf '%s' "${1%%|*}"; }

# --- denied: the two incident commands first ---
check "incident 10-19: cat .mcp.json || true" "$(first "$(bash_d 'cat .mcp.json || true')")" deny
check "incident 10-18: cat .mcp.json | head -20" "$(first "$(bash_d 'cat .mcp.json | head -20')")" deny
check "reader after a pipe" "$(first "$(bash_d 'printf x | cat - .env')")" deny
check "head ~/.claude.json" "$(first "$(bash_d 'head -5 ~/.claude.json')")" deny
check "less config.env" "$(first "$(bash_d 'less config.env')")" deny
check "grep TOKEN .env" "$(first "$(bash_d 'grep TOKEN .env')")" deny
check "jq . .mcp.json" "$(first "$(bash_d 'jq . .mcp.json')")" deny
check "jq headers .mcp.json" "$(first "$(bash_d "jq '.mcpServers[] | .headers' .mcp.json")")" deny
check "echo \$(cat .mcp.json)" "$(first "$(bash_d 'echo $(cat .mcp.json)')")" deny
check "backtick cat" "$(first "$(bash_d 'echo `cat .env`')")" deny
check "after && in a chain" "$(first "$(bash_d 'cd /x && cat .claude/settings.local.json')")" deny
check "after ; in a chain" "$(first "$(bash_d 'pwd; tail -n 3 /p/.claude/settings.json')")" deny
check "env prefix and sudo" "$(first "$(bash_d 'FOO=1 sudo cat /root/.netrc')")" deny
check "stdin redirect" "$(first "$(bash_d 'cat < .mcp.json')")" deny
check "private key" "$(first "$(bash_d 'cat ~/.ssh/id_ed25519')")" deny
check "unbalanced quote falls back to deny" "$(first "$(bash_d "cat .mcp.json 'oops")")" deny
check "Read .mcp.json" "$(first "$(decision Read '{"file_path": "/x/.mcp.json"}')")" deny
check "Grep content on .mcp.json" "$(first "$(decision Grep '{"pattern": "Bearer", "path": ".mcp.json", "output_mode": "content"}')")" deny

# --- allowed ---
check "jq keys" "$(bash_d "jq '.mcpServers | keys' .mcp.json")" allow
check "jq type,url" "$(bash_d "jq '.mcpServers[] | {type, url}' .mcp.json")" allow
check "jq hook matcher object" "$(bash_d "jq '.hooks.PreToolUse[] | {matcher}' ~/.claude/settings.json")" allow
check "jq path to hook commands" "$(bash_d "jq -r '.hooks[][] | .hooks[].command' ~/.claude/settings.json")" allow
check "jq path to server url" "$(bash_d "jq -r '.mcpServers[].url' .mcp.json")" allow
check "jq path to a header value" "$(first "$(bash_d "jq -r '.mcpServers[].headers.Authorization' .mcp.json")")" deny
check "jq path to an env value" "$(first "$(bash_d "jq '.env.ANTHROPIC_API_KEY' .claude/settings.local.json")")" deny
check "jq path to args" "$(first "$(bash_d "jq '.mcpServers[].args[]' .mcp.json")")" deny
check "jq string built from fields" "$(first "$(bash_d "jq '.hooks[][] | .matcher + .env.X' ~/.claude/settings.json")")" deny
check "grep -c" "$(bash_d 'grep -c WDZT_AK config.env')" allow
check "grep -l" "$(bash_d 'grep -l Bearer .mcp.json')" allow
check "grep -q in combined flags" "$(bash_d 'grep -iq token .env && echo yes')" allow
check "example env" "$(bash_d 'cat config.example.env')" allow
check "env.example" "$(bash_d 'cat env.example')" allow
check "README" "$(bash_d 'cat README.md')" allow
check "ls" "$(bash_d 'ls -la .mcp.json')" allow
check "public key" "$(bash_d 'cat id_rsa.pub')" allow
check "grep pattern that looks like a file" "$(bash_d 'grep -n .env README.md')" allow
HEREDOC_CMD="$(printf 'cat > .env <<%sEOF%s\nA=1\nEOF' "'" "'")"
check "writing an env file with a heredoc" "$(bash_d "$HEREDOC_CMD")" allow
Q="'"
HD_DATA="$(printf 'python3 - <<%sEOF%s\nprint("run `cat .env` and `jq -r %s.x%s ~/.claude/settings.json` first")\nEOF' "$Q" "$Q" "$Q" "$Q")"
check "heredoc body is data" "$(bash_d "$HD_DATA")" allow
HD_TAB="$(printf 'cat <<-END\n\tcat .mcp.json\n\tEND\necho done')"
check "<<- heredoc body is data" "$(bash_d "$HD_TAB")" allow
HD_AFTER="$(printf 'python3 - <<EOF\nprint(1)\nEOF\ncat .env')"
check "command after the heredoc terminator" "$(first "$(bash_d "$HD_AFTER")")" deny
check "herestring is not a heredoc" "$(first "$(bash_d 'cat <<< x; cat .env')")" deny
check "appending to an env file" "$(bash_d 'cat part.txt >> config.env')" allow
check "sourcing an env file" "$(bash_d 'set -a; . ~/.config/x/ccr.env; set +a')" allow
check "Read README" "$(decision Read '{"file_path": "/x/README.md"}')" allow
check "Grep count on .mcp.json" "$(decision Grep '{"pattern": "Bearer", "path": ".mcp.json", "output_mode": "count"}')" allow
check "Grep default mode on .mcp.json" "$(decision Grep '{"pattern": "Bearer", "path": ".mcp.json"}')" allow
check "disabled switch" "$(bash_d 'cat .mcp.json' DRSG_SENSITIVE_READ_GUARD_DISABLED=1)" allow

# --- the reason: a category and the alternatives, never the command ---
OUT="$(bash_d 'cat /secret-dir-name/.mcp.json')"
check "reason names the category" "$(printf '%s' "$OUT" | grep -c 'category: mcp-config')" 1
check "reason gives the jq alternative" "$(printf '%s' "$OUT" | grep -c "jq '.mcpServers | keys'")" 1
check "reason does not echo the command" "$(printf '%s' "$OUT" | grep -c 'secret-dir-name')" 0

# --- broken input fails open, silently ---
rc=0; out="$(printf 'not json' | python3 "$GUARD" 2>&1)" || rc=$?
check "invalid JSON: exit 0, no output" "$rc|$out" "0|"
rc=0; out="$(printf '{"tool_name": "Bash"}' | python3 "$GUARD" 2>&1)" || rc=$?
check "missing tool_input: exit 0, no output" "$rc|$out" "0|"

# --- setup.sh registers it with its own matcher and leaves the others on "*" ---
SETUP_CASES="setup registers Bash|Read|Grep once
setup leaves other matchers on *
--no-sensitive-read-guard skips registration"
if [ -z "$ONLY" ] || printf '%s\n' "$SETUP_CASES" | grep -qxF -- "$ONLY"; then
  T="$(mktemp -d)"
  trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/claude" "$T/claude-off" "$T/home"
  run_setup() {
    HOME="$T/home" DRSG_MEM_DIR="$T/mem-$1" CLAUDE_CONFIG_DIR="$T/$1" \
      bash "$HERE/../setup.sh" --no-skills --tools-dir "$T/tools-$1" "${@:2}" >/dev/null 2>&1
  }
  run_setup claude
  run_setup claude
  run_setup claude-off --no-sensitive-read-guard
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
  ON="$(hooks_summary "$T/claude/settings.json")"
  OFF="$(hooks_summary "$T/claude-off/settings.json")"
  check "setup registers Bash|Read|Grep once" "$(printf '%s\n' "$ON" | sed -n 's/^guard=//p')" "Bash|Read|Grep"
  check "setup leaves other matchers on *" "$(printf '%s\n' "$ON" | sed -n 's/^others=//p')" "*"
  check "--no-sensitive-read-guard skips registration" "$(printf '%s\n' "$OFF" | sed -n 's/^guard=//p')" ""
fi

if [ -n "$ONLY" ] && [ "$RAN" -eq 0 ]; then
  printf 'FAIL unknown-only-case: %s\n' "$ONLY"
  RAN=1
fi
printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

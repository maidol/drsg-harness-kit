#!/usr/bin/env bash
# Checks for tools/claude-model-picker.sh with a fake `claude` and local gateway.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICKER="${PICKER:-$HERE/../tools/claude-model-picker.sh}"
T="$(mktemp -d)"
mkdir -p "$T/bin" "$T/home" "$T/proj"
cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "ARGS:$*"
exit "${FAKE_RC:-0}"
SH
chmod +x "$T/bin/claude"
cat > "$T/server.py" <<'PY'
import http.server
import json
import os
import sys
import time

root = sys.argv[1]
models = {"data": [
    {"id": "gateway/model-a[1m]"},
    {"id": "gateway/model-a[1m]"},
    {"id": "\u001b[31mx"},
    {"id": "a b"},
    {"id": "gateway/model-b"},
    {"id": "gateway/gpt6", "max_input_tokens": 1000000},
    {"id": "gateway/gpt6-already[1m]", "max_input_tokens": 1000000},
    {"id": "gateway/codex-auto-review", "max_input_tokens": 0},
    {"id": "gateway/qwen256k", "max_input_tokens": 256000},
    {"id": "gateway/no-window"},
    {"id": "gateway/string-window", "max_input_tokens": "1000000"},
    {"id": "gateway/model-1m-no-window"},
    {"id": "gateway/" + "x" * 121},
    {"id": "gateway/" + "y" * 249},
]}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with open(os.path.join(root, "gateway.requests"), "a") as f:
            f.write("%s\t%s\t%s\t%s\n" % (self.path, self.headers.get("anthropic-version", ""), self.headers.get("Authorization", ""), self.headers.get("x-api-key", "")))
        if self.path == "/fail/v1/models":
            self.send_response(503)
            self.end_headers()
            return
        if self.path == "/bad-json/v1/models":
            body = b"not json"
        elif self.path == "/slow/v1/models":
            body = b'{"data":[]}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            for byte in body:
                try:
                    self.wfile.write(bytes([byte]))
                    self.wfile.flush()
                    time.sleep(0.15)
                except (BrokenPipeError, ConnectionResetError):
                    break
            return
        elif self.path == "/empty/v1/models":
            body = b'{"data":[]}'
        else:
            body = json.dumps(models).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
with open(os.path.join(root, "gateway.port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$T/server.py" "$T" >/dev/null 2>&1 &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
for _ in {1..100}; do [ -s "$T/gateway.port" ] && break; sleep 0.02; done
PORT="$(<"$T/gateway.port")"
ORIGIN="http://127.0.0.1:$PORT"
: > "$T/gateway.requests"
RAN=0; OK=0
check() { RAN=$((RAN+1)); if [ "$2" = "$3" ]; then OK=$((OK+1)); echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fi; }
# $1 is menu input; remaining args are passed to claude. PICK_* vars configure a case.
pick() {
  local input="$1"; shift
  local out rc cwd="${PICK_CWD:-$T/proj}" home="${PICK_HOME:-$T/home}"
  out="$(printf "$input" | (
    cd "$cwd" || exit
    env -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
      -u CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY \
      HOME="$home" PATH="$T/bin:$PATH" CLAUDE_PICK_FORCE_TTY="${TTY:-1}" \
      ${PICK_BASE_URL:+ANTHROPIC_BASE_URL="$PICK_BASE_URL"} \
      ${PICK_API_KEY:+ANTHROPIC_API_KEY="$PICK_API_KEY"} \
      ${PICK_AUTH_TOKEN:+ANTHROPIC_AUTH_TOKEN="$PICK_AUTH_TOKEN"} \
      ${PICK_GATEWAY_DISCOVERY:+CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="$PICK_GATEWAY_DISCOVERY"} \
      bash -c '. "$1"; shift; claude "$@"' _ "$PICKER" "$@"
  ) 2>"$T/stderr")"
  rc=$?
  echo "${out:-none} rc=$rc"
}

# Existing picker behavior remains deterministic and isolated from repo settings.
check "number picks a model" "$(pick '2\n')" "ARGS:--model sonnet rc=0"
check "own arguments kept, after --model" "$(pick '1\n' --resume abc)" "ARGS:--model opus --resume abc rc=0"
check "a prompt argument still gets the menu" "$(pick '3\n' 'fix the bug')" "ARGS:--model haiku fix the bug rc=0"
check "Enter alone: settings default, no --model" "$(pick '\n' -c)" "ARGS:-c rc=0"
check "a typed name goes through as is" "$(pick 'claude-opus-5-5\n')" "ARGS:--model claude-opus-5-5 rc=0"
check "Ctrl+D starts nothing" "$(pick '')" "none rc=130"
check "CLAUDE_PICK_MODELS replaces the menu" "$(CLAUDE_PICK_MODELS='fable haiku' pick '1\n')" "ARGS:--model fable rc=0"
check "claude's exit code comes back" "$(FAKE_RC=3 pick '1\n')" "ARGS:--model opus rc=3"
# A settings file outside the test cwd must not affect the old static assertions.
mkdir -p "$T/.claude"
printf '{"env":{"ANTHROPIC_BASE_URL":"%s/count"}}\n' "$ORIGIN" > "$T/.claude/settings.local.json"
PICK_CWD="$T/proj" check "parent-directory settings do not change static menu" "$(pick '2\n')" "ARGS:--model sonnet rc=0"
check "parent-directory settings do not trigger discovery" "$(wc -l < "$T/gateway.requests" 2>/dev/null || echo 0)" "0"

# Gateway discovery from project settings, precedence, and safe model IDs.
mkdir -p "$T/proj/.claude"
printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
check "settings.local.json supplies gateway URL" "$(pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
check "1M live metadata adds suffix" "$(grep -cE '^[[:space:]]+[0-9]+\) gateway/gpt6\[1m\]$' "$T/stderr")" "1"
check "unsafe IDs and ESC labels are absent" "$(if grep -Eq $'\\033|a b' "$T/stderr"; then echo found; else echo absent; fi)" absent
check "settings override shell URL" "$(PICK_BASE_URL="$ORIGIN/count" pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
check "anthropic version header sent" "$(grep -c $'\t2023-06-01\t' "$T/gateway.requests")" "2"
# A trailing slash in base URL resolves to the same /v1/models endpoint.
printf '{"env":{"ANTHROPIC_BASE_URL":"%s/"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
check "trailing slash base URL is normalized" "$(pick '2\n')" "ARGS:--model gateway/model-b rc=0"
# Empty API key must not hide a non-empty Bearer token.
printf '{"env":{"ANTHROPIC_BASE_URL":"%s","ANTHROPIC_API_KEY":"","ANTHROPIC_AUTH_TOKEN":"fixture-token"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
check "empty API key falls back to auth token" "$(pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
check "auth token is sent as Bearer" "$(grep -c $'\tBearer fixture-token\t$' "$T/gateway.requests")" "1"
printf '{"env":{"ANTHROPIC_BASE_URL":"%s","ANTHROPIC_API_KEY":"fixture-key"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
check "API key is sent as x-api-key" "$(PICK_BASE_URL= PICK_API_KEY= PICK_AUTH_TOKEN= pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
check "API key header value" "$(grep -c $'\tfixture-key$' "$T/gateway.requests")" "1"

# A matching CLI cache is preferred, but each cache test gets a private HOME.
printf '{"env":{"ANTHROPIC_BASE_URL":"%s","CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY":"1"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
mkdir -p "$T/home-cache-match/.claude/cache"
cat > "$T/home-cache-match/.claude/cache/gateway-models.json" <<'JSON'
{"baseUrl":"ORIGIN_PLACEHOLDER/","fetchedAt":1,"models":[{"id":"anthropic/claude-ccr-h737562326170692d6f70656e61692f6770742d362d6c756e61[1m]","display_name":"gpt-6-luna (1M context)"},{"id":"anthropic/claude-ccr-h65736361706564","display_name":"\u001b[31mred"}]}
JSON
python3 - "$T/home-cache-match/.claude/cache/gateway-models.json" "$ORIGIN" <<'PY'
import json, sys
path, origin = sys.argv[1:]
with open(path, encoding="utf-8") as f: cache = json.load(f)
cache["baseUrl"] = origin + "/"
with open(path, "w", encoding="utf-8") as f: json.dump(cache, f)
PY
before="$(wc -l < "$T/gateway.requests")"
check "matching CLI cache passes the encoded model ID" "$(PICK_HOME="$T/home-cache-match" pick '1\n')" "ARGS:--model anthropic/claude-ccr-h737562326170692d6f70656e61692f6770742d362d6c756e61[1m] rc=0"
check "matching cache renders friendly display name" "$(grep -c 'gpt-6-luna (1M context)' "$T/stderr")" "1"
check "unsafe cached display name falls back to ID" "$(PICK_HOME="$T/home-cache-match" pick '2\n')" "ARGS:--model anthropic/claude-ccr-h65736361706564 rc=0"
check "ESC and unsafe display text are absent" "$(if grep -Eq $'\\033|red' "$T/stderr"; then echo unsafe; else echo safe; fi)" safe
check "matching cache avoids live request" "$(wc -l < "$T/gateway.requests")" "$before"
# Cache use is gated by the same discovery flag Claude Code uses.
mkdir -p "$T/home-cache-disabled/.claude/cache"
cp "$T/home-cache-match/.claude/cache/gateway-models.json" "$T/home-cache-disabled/.claude/cache/"
printf '{"env":{"ANTHROPIC_BASE_URL":"%s","CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY":"0"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
before="$(wc -l < "$T/gateway.requests")"
check "discovery disabled skips matching CLI cache" "$(PICK_HOME="$T/home-cache-disabled" pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
check "disabled cache falls back online" "$(( $(wc -l < "$T/gateway.requests") - before ))" "1"
# Cache mismatch, malformed JSON, and empty cache each fall back to live discovery.
for case in mismatch malformed empty missing; do
  home="$T/home-cache-$case"
  mkdir -p "$home/.claude/cache"
  case "$case" in
    mismatch) printf '{"baseUrl":"http://other.invalid","fetchedAt":1,"models":[{"id":"cached/model"}]}\n' > "$home/.claude/cache/gateway-models.json" ;;
    malformed) printf '{broken' > "$home/.claude/cache/gateway-models.json" ;;
    empty) printf '{"baseUrl":"%s","fetchedAt":1,"models":[]}\n' "$ORIGIN" > "$home/.claude/cache/gateway-models.json" ;;
  esac
  printf '{"env":{"ANTHROPIC_BASE_URL":"%s","CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY":"1"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
  before="$(wc -l < "$T/gateway.requests")"
  check "$case cache falls back to online IDs" "$(PICK_HOME="$home" pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
  check "$case cache issues one online request" "$(( $(wc -l < "$T/gateway.requests") - before ))" "1"
done
# The live response annotates only rows with numeric one-million input capacity.
check "live gpt6 row gets 1M model suffix" "$(pick '3\n')" "ARGS:--model gateway/gpt6[1m] rc=0"
check "already-suffixed ID is not duplicated" "$(pick '4\n')" "ARGS:--model gateway/gpt6-already[1m] rc=0"
check "zero-capacity metadata stays unsuffixed" "$(pick '5\n')" "ARGS:--model gateway/codex-auto-review rc=0"
check "small-capacity metadata stays unsuffixed" "$(pick '6\n')" "ARGS:--model gateway/qwen256k rc=0"
check "missing and string metadata stay unsuffixed" "$(grep -cE 'gateway/(no-window|string-window|model-1m-no-window)$' "$T/stderr")" "3"
long129="gateway/$(printf 'x%.0s' {1..121})"
check "129-character model ID remains selectable" "$(pick '10\n')" "ARGS:--model $long129 rc=0"
check "257-character model ID is filtered" "$(grep -c "gateway/$(printf 'y%.0s' {1..249})" "$T/stderr" || true)" "0"
# A configured default suffix must not be copied to a model with no capacity metadata.
printf '{"env":{"ANTHROPIC_BASE_URL":"%s","ANTHROPIC_MODEL":"gateway/no-window[1m]"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
check "default model context is not inferred for another ID" "$(pick '7\n')" "ARGS:--model gateway/no-window rc=0"

# Invalid settings layers are skipped, and lookup failures fall back to static choices.
printf '{invalid' > "$T/proj/.claude/settings.local.json"
check "malformed settings layer is skipped" "$(PICK_BASE_URL="$ORIGIN" pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
check "HTTP error falls back to static list" "$(PICK_BASE_URL="$ORIGIN/fail" pick '1\n')" "ARGS:--model opus rc=0"
check "invalid JSON falls back to static list" "$(PICK_BASE_URL="$ORIGIN/bad-json" pick '1\n')" "ARGS:--model opus rc=0"
check "empty list falls back to static list" "$(PICK_BASE_URL="$ORIGIN/empty" pick '1\n')" "ARGS:--model opus rc=0"
check "unsupported URL scheme falls back" "$(PICK_BASE_URL="file:///tmp" pick '1\n')" "ARGS:--model opus rc=0"
start="$(date +%s)"
check "slow response falls back" "$(PICK_BASE_URL="$ORIGIN/slow" pick '1\n')" "ARGS:--model opus rc=0"
elapsed=$(( $(date +%s) - start ))
check "slow response bounded by wall-clock deadline" "$([ "$elapsed" -le 3 ] && echo bounded || echo slow)" bounded
# Loopback must bypass dead proxy settings even when no_proxy is unset.
printf '{"env":{"ANTHROPIC_BASE_URL":"%s"}}\n' "$ORIGIN" > "$T/proj/.claude/settings.local.json"
check "loopback discovery bypasses dead proxy" "$(http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 no_proxy= NO_PROXY= pick '1\n')" "ARGS:--model gateway/model-a[1m] rc=0"
# Explicit menu and all pre-existing bypasses must not make a request.
before="$(wc -l < "$T/gateway.requests")"
check "manual list takes precedence" "$(CLAUDE_PICK_MODELS='manual-one manual-two' pick '2\n')" "ARGS:--model manual-two rc=0"
check "manual list avoids gateway request" "$(wc -l < "$T/gateway.requests")" "$before"
check "not a terminal" "$(TTY=0 pick '9\n' --resume abc)" "ARGS:--resume abc rc=0"
check "CLAUDE_PICK_MODEL=0" "$(CLAUDE_PICK_MODEL=0 pick '9\n')" "ARGS: rc=0"
check "--model already given" "$(pick '9\n' --model haiku)" "ARGS:--model haiku rc=0"
check "--model=... already given" "$(pick '9\n' --model=haiku -c)" "ARGS:--model=haiku -c rc=0"
check "-p (print mode)" "$(pick '9\n' -p hi)" "ARGS:-p hi rc=0"
check "--version" "$(pick '9\n' --version)" "ARGS:--version rc=0"
check "a subcommand (mcp)" "$(pick '9\n' mcp list)" "ARGS:mcp list rc=0"
check "a subcommand (attach)" "$(pick '9\n' attach 1a2b)" "ARGS:attach 1a2b rc=0"

# setup.sh keeps picker opt-in and deploys a standalone configuration command.
mkdir -p "$T/setup-default-home"
HOME="$T/setup-default-home" DRSG_MEM_DIR="$T/setup-default-tools" CLAUDE_CONFIG_DIR="$T/setup-default-claude" \
  bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint >/dev/null 2>&1
check "fresh setup without flag leaves bashrc absent" "$([ -e "$T/setup-default-home/.bashrc" ] && echo touched || echo untouched)" untouched
check "fresh setup deploys the toggle command" "$([ -x "$T/setup-default-tools/tools/claude-model-picker-config.sh" ] && echo present || echo missing)" present

# Explicit setup enable is idempotent and preserves an existing user choice on updates.
mkdir -p "$T/setup-enable-home"
for _ in 1 2; do
  HOME="$T/setup-enable-home" DRSG_MEM_DIR="$T/setup-enable-tools" CLAUDE_CONFIG_DIR="$T/setup-enable-claude" \
    bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint --model-picker >/dev/null 2>&1
done
check "setup --model-picker adds one line" "$(grep -cF 'claude-model-picker.sh' "$T/setup-enable-home/.bashrc")" 1
check "setup source line uses selected tools dir" "$(grep -Fxc "[ -f \"$T/setup-enable-tools/tools/claude-model-picker.sh\" ] && . \"$T/setup-enable-tools/tools/claude-model-picker.sh\"" "$T/setup-enable-home/.bashrc")" 1
before_contents="$(<"$T/setup-enable-home/.bashrc")"
HOME="$T/setup-enable-home" DRSG_MEM_DIR="$T/setup-enable-tools" CLAUDE_CONFIG_DIR="$T/setup-enable-claude" \
  bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint >/dev/null 2>&1
check "ordinary setup preserves enabled state" "$(<"$T/setup-enable-home/.bashrc")" "$before_contents"
check "source line makes picker available in new shell" "$(HOME="$T/setup-enable-home" PATH="$T/bin:$PATH" bash -c '. "$HOME/.bashrc"; type -t claude' 2>/dev/null)" function

# The standalone command is tested against a real tools directory and a logical symlink.
TOGGLE="$T/setup-default-tools/tools/claude-model-picker-config.sh"
TOGGLE_TOOLS="$(dirname "$TOGGLE")"
run_toggle() {
  local home="$1" command_path="$2" rc; shift 2
  HOME="$home" "$command_path" "$@" >"$T/toggle.stdout" 2>"$T/toggle.stderr"
  rc=$?
  echo "rc=$rc"
}
mkdir -p "$T/toggle-home"
check "standalone enable succeeds" "$(run_toggle "$T/toggle-home" "$TOGGLE" enable)" "rc=0"
check "standalone enable reports active" "$(grep -c 'enabled in' "$T/toggle.stdout")" 1
check "standalone enable writes exact line" "$(grep -Fxc "[ -f \"$TOGGLE_TOOLS/claude-model-picker.sh\" ] && . \"$TOGGLE_TOOLS/claude-model-picker.sh\"" "$T/toggle-home/.bashrc")" 1
toggle_before="$(<"$T/toggle-home/.bashrc")"
check "repeated enable is idempotent" "$(run_toggle "$T/toggle-home" "$TOGGLE" enable)" "rc=0"
check "repeated enable leaves content unchanged" "$(<"$T/toggle-home/.bashrc")" "$toggle_before"
check "standalone disable succeeds" "$(run_toggle "$T/toggle-home" "$TOGGLE" disable)" "rc=0"
check "disable of sole source line leaves empty file" "$([ -f "$T/toggle-home/.bashrc" ] && [ ! -s "$T/toggle-home/.bashrc" ] && echo empty || echo not-empty)" empty
# Disable removes only the exact line, preserving similar and unrelated lines.
printf 'keep this\n[ -f "%s/claude-model-picker.sh" ] && . "%s/claude-model-picker.sh"\n[ -f "%s/claude-model-picker.sh" ] && echo keep\n' \
  "$TOGGLE_TOOLS" "$TOGGLE_TOOLS" "$TOGGLE_TOOLS" > "$T/toggle-home/.bashrc"
run_toggle "$T/toggle-home" "$TOGGLE" disable
check "disable preserves similar and unrelated lines" "$(<"$T/toggle-home/.bashrc")" "keep this
[ -f \"$TOGGLE_TOOLS/claude-model-picker.sh\" ] && echo keep"
toggle_before="$(<"$T/toggle-home/.bashrc")"
check "repeated disable is idempotent" "$(run_toggle "$T/toggle-home" "$TOGGLE" disable)" "rc=0"
check "repeated disable leaves content unchanged" "$(<"$T/toggle-home/.bashrc")" "$toggle_before"
mkdir -p "$T/toggle-missing-home"
check "disable leaves missing bashrc absent" "$(run_toggle "$T/toggle-missing-home" "$TOGGLE" disable; [ -e "$T/toggle-missing-home/.bashrc" ] && echo exists || echo absent)" "rc=0
absent"
toggle_before="$(<"$T/toggle-home/.bashrc")"
check "missing subcommand fails without modification" "$(run_toggle "$T/toggle-home" "$TOGGLE")" "rc=2"
check "unknown subcommand fails without modification" "$(run_toggle "$T/toggle-home" "$TOGGLE" nope)" "rc=2"
check "invalid commands preserve bashrc" "$(<"$T/toggle-home/.bashrc")" "$toggle_before"
check "invalid command prints usage" "$(grep -c '^Usage:' "$T/toggle.stderr")" 1

# A symlinked tools directory must recognize both logical and physical source-line forms.
mkdir -p "$T/real-tools" "$T/toggle-symlink-home"
cp "$TOGGLE" "$T/real-tools/claude-model-picker-config.sh"
cp "$T/setup-default-tools/tools/claude-model-picker.sh" "$T/real-tools/claude-model-picker.sh"
ln -s "$T/real-tools" "$T/link-tools"
real_line="[ -f \"$T/real-tools/claude-model-picker.sh\" ] && . \"$T/real-tools/claude-model-picker.sh\""
logical_line="[ -f \"$T/link-tools/claude-model-picker.sh\" ] && . \"$T/link-tools/claude-model-picker.sh\""
printf '%s\n' "$real_line" > "$T/toggle-symlink-home/.bashrc"
check "symlink enable recognizes physical equivalent" "$(run_toggle "$T/toggle-symlink-home" "$T/link-tools/claude-model-picker-config.sh" enable >/dev/null; grep -cF 'claude-model-picker.sh' "$T/toggle-symlink-home/.bashrc")" 1
check "symlink enable avoids duplicate source line" "$(grep -cF 'claude-model-picker.sh' "$T/toggle-symlink-home/.bashrc")" 1
check "symlink disable removes logical and physical forms" "$(run_toggle "$T/toggle-symlink-home" "$T/link-tools/claude-model-picker-config.sh" disable >/dev/null; [ ! -s "$T/toggle-symlink-home/.bashrc" ] && echo empty || echo not-empty)" empty
run_toggle "$T/toggle-symlink-home" "$T/link-tools/claude-model-picker-config.sh" enable
run_toggle "$T/toggle-symlink-home" "$T/link-tools/claude-model-picker-config.sh" enable
check "symlink enable writes canonical logical path once" "$(grep -Fxc "$logical_line" "$T/toggle-symlink-home/.bashrc")" 1

# A .bashrc symlink stays a symlink while its target is updated.
mkdir -p "$T/bashrc-link-home"
printf 'unrelated\n%s\n' "$logical_line" > "$T/bashrc-link-target"
ln -s "$T/bashrc-link-target" "$T/bashrc-link-home/.bashrc"
run_toggle "$T/bashrc-link-home" "$T/link-tools/claude-model-picker-config.sh" disable
check "disable preserves bashrc symlink" "$([ -L "$T/bashrc-link-home/.bashrc" ] && echo symlink || echo replaced)" symlink
check "disable edits bashrc symlink target" "$(<"$T/bashrc-link-target")" unrelated

echo "PASS $OK/$RAN"
[ "$RAN" -eq "$OK" ]

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
      HOME="$home" PATH="$T/bin:$PATH" CLAUDE_PICK_FORCE_TTY="${TTY:-1}" \
      ${PICK_BASE_URL:+ANTHROPIC_BASE_URL="$PICK_BASE_URL"} \
      ${PICK_API_KEY:+ANTHROPIC_API_KEY="$PICK_API_KEY"} \
      ${PICK_AUTH_TOKEN:+ANTHROPIC_AUTH_TOKEN="$PICK_AUTH_TOKEN"} \
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
check "only safe model IDs appear in menu" "$(grep -cE '^[[:space:]]+[0-9]+\) (gateway/model-a\[1m\]|gateway/model-b)$' "$T/stderr")" "2"
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

# setup.sh --model-picker adds the source line to ~/.bashrc exactly once.
for _ in 1 2; do
  HOME="$T/home" DRSG_MEM_DIR="$T/mem" CLAUDE_CONFIG_DIR="$T/claude" \
    bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint --model-picker >/dev/null 2>&1
done
check "setup adds the source line once" "$(grep -c 'claude-model-picker.sh' "$T/home/.bashrc" 2>/dev/null)" 1
check "the line sources the runtime copy" "$(HOME="$T/home" PATH="$T/bin:$PATH" bash -c '. "$HOME/.bashrc"; type -t claude' 2>/dev/null)" function
mkdir -p "$T/home2"
HOME="$T/home2" DRSG_MEM_DIR="$T/mem2" CLAUDE_CONFIG_DIR="$T/claude2" \
  bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint >/dev/null 2>&1
check "without the flag ~/.bashrc is left alone" "$([ -e "$T/home2/.bashrc" ] && echo touched || echo untouched)" untouched

echo "PASS $OK/$RAN"
[ "$RAN" -eq "$OK" ]

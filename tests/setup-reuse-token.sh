#!/usr/bin/env bash
# Existing project credentials must let setup refresh hooks without a token flag,
# and a new project must join the running daemon without one. In both cases the
# drsg MCP entry is written straight into .claude.json, never through argv.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
DAEMON_PID=""
cleanup() {
  if [ -n "$DAEMON_PID" ]; then kill "$DAEMON_PID" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
PROJECT="$T/project"
HOME_DIR="$T/home"
MEM_DIR="$T/mem"
CLAUDE_DIR="$T/claude"
BIN_DIR="$T/bin"
SENTINEL="fixture-token-not-for-output"
mkdir -p "$PROJECT/.drsg" "$HOME_DIR" "$MEM_DIR" "$CLAUDE_DIR" "$BIN_DIR"

cat > "$T/server.py" <<'PY'
import http.server
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = os.environ["FIXTURE_TOKEN"]
project = os.environ["FIXTURE_PROJECT"]


class Server(http.server.HTTPServer):
    last_key = ""


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body, status=200, content_type="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/health":
            self.reply(b"ok", content_type="text/plain")
        else:
            self.reply(b"not found", 404, "text/plain")

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        rid = req.get("id")
        if self.headers.get("Authorization") != "Bearer " + expected:
            (root / "auth-failed").write_text("yes", encoding="utf-8")
            self.reply({"jsonrpc": "2.0", "id": rid,
                        "error": {"message": "fixture auth failed"}})
            return
        (root / "auth-ok").write_text("yes", encoding="utf-8")
        method = req.get("method")
        params = req.get("params") or {}
        if method == "plane.list":
            result = [{"name": "memory"}]
        elif method == "node.create":
            Server.last_key = params.get("key", "")
            result = {"id": 1}
        elif method == "node.get":
            result = {"id": 1, "labels": ["Project"],
                      "properties": {"path": project}}
        elif method == "plane.cypher":
            result = {"nodes": [{"external_key": Server.last_key}]}
        else:
            result = {}
        self.reply({"jsonrpc": "2.0", "id": rid, "result": result})


server = Server(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
PY

FAKE_TOKEN="$SENTINEL" FIXTURE_TOKEN="$SENTINEL" FIXTURE_PROJECT="$PROJECT" \
  python3 "$T/server.py" "$T" >"$T/server.out" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do
  [ -s "$T/port" ] && break
  sleep 0.1
done
if [ ! -s "$T/port" ]; then
  echo "FAIL fixture daemon did not start"
  exit 1
fi
PORT="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text())' "$T/port")"
printf 'DRSG_TOKEN=%s\nDRSG_API=http://127.0.0.1:%s/rpc\nDRSG_PLANE=memory\n' \
  "$SENTINEL" "$PORT" > "$PROJECT/.drsg/env"

cat > "$BIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_CALLS"
SH
chmod +x "$BIN_DIR/claude"
export CLAUDE_CALLS="$T/claude.calls"

cat > "$CLAUDE_DIR/.claude.json" <<JSON
{"projects":{"$PROJECT":{"mcpServers":{"drsg":{"type":"http"}}}}}
JSON

# run_setup <output file> [project dir] [extra setup arguments...]
run_setup() {
  local out="$1" project="${2:-$PROJECT}"
  shift
  [ "$#" -gt 0 ] && shift
  HOME="$HOME_DIR" DRSG_MEM_DIR="$MEM_DIR" DRSG_MEM_ADDR= DRSG_MEM_TOKEN= \
    CLAUDE_CONFIG_DIR="$CLAUDE_DIR" PATH="$BIN_DIR:$PATH" \
    bash "$REPO/setup.sh" --project "$project" --bin /bin/true \
      --no-skills --no-event-poller --no-streak-hint "$@" >"$out" 2>&1
}
# Prints "<type> <url> <yes|no: header carries the fixture token>" for the
# project's local-scope drsg entry, or "absent". Never prints the header.
drsg_entry() {
  python3 - "$CLAUDE_DIR/.claude.json" "$1" "$SENTINEL" <<'PY'
import json, sys
path, project, want = sys.argv[1:]
try:
    entry = json.load(open(path))["projects"][project]["mcpServers"]["drsg"]
except Exception:
    print("absent")
    sys.exit()
auth = (entry.get("headers") or {}).get("Authorization")
print(entry.get("type"), entry.get("url"), "yes" if auth == "Bearer " + want else "no")
PY
}
mode_of() {
  python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"
}

RAN=0; OK=0
check() {
  RAN=$((RAN+1))
  if [ "$2" = "$3" ]; then OK=$((OK+1)); echo "ok   $1"
  else echo "FAIL $1: got '$2' want '$3'"
  fi
}
if run_setup "$T/setup.out"; then SETUP_RC=0; else SETUP_RC=$?; fi
check "existing project's setup succeeds without --token" "$SETUP_RC" 0
check "existing project token authenticates silently" \
  "$( [ -f "$T/auth-ok" ] && [ ! -f "$T/auth-failed" ] && echo yes || echo no )" yes
check "registered drsg is untouched while drsg-events is added" \
  "$(grep -c '^mcp add --scope local drsg-events ' "$CLAUDE_CALLS")/$(grep -Ec '^mcp (add|remove) .* drsg([[:space:]]|$)' "$CLAUDE_CALLS")" 1/0
check "drsg-events registration arguments contain no token" \
  "$(grep -Fq "$SENTINEL" "$CLAUDE_CALLS" && echo leaked || echo hidden)" hidden
check "token is absent from setup output" \
  "$(grep -Fq "$SENTINEL" "$T/setup.out" && echo leaked || echo hidden)" hidden
check "refreshed project env retains its credential" \
  "$(python3 - "$PROJECT/.drsg/env" "$SENTINEL" <<'PY'
import sys
found = ""
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("DRSG_TOKEN="):
        found = line.rstrip("\n").split("=", 1)[1]
print("yes" if found == sys.argv[2] else "no")
PY
)" yes

# The hooks setup registered come from tools/templates/settings-hooks.json.
# The expected set is written out here, not read from the template, so a
# registration dropped from the template turns this red.
check "setup registers all six kit hooks in settings.local.json" \
  "$(python3 - "$PROJECT/.claude/settings.local.json" <<'PY'
import json, sys
want = {
    "PreToolUse": "pre_tool_use.py",
    "SessionStart": "session_start.py",
    "UserPromptSubmit": "user_prompt.py",
    "PreCompact": "compact_handoff.py",
    "PostCompact": "compact_handoff.py",
    "SessionEnd": "session_end.py",
}
try:
    hooks = json.load(open(sys.argv[1], encoding="utf-8")).get("hooks") or {}
except Exception:
    print("unreadable")
    sys.exit()
missing = []
for event, script in want.items():
    commands = [h.get("command", "")
                for group in hooks.get(event) or []
                for h in group.get("hooks") or []]
    if not any(c.split()[0].split("/")[-1] == script for c in commands if c.split()):
        missing.append(event)
if not any("clear" in str(group.get("matcher", "")).split("|")
           for group in hooks.get("SessionStart") or []):
    missing.append("SessionStart-clear")
print("complete" if not missing else "missing " + ",".join(missing))
PY
)" complete

: > "$CLAUDE_CALLS"
printf '{}\n' > "$CLAUDE_DIR/.claude.json"
chmod 640 "$CLAUDE_DIR/.claude.json"
if run_setup "$T/setup-missing.out"; then SETUP_MISSING_RC=0; else SETUP_MISSING_RC=$?; fi
check "missing drsg MCP is written into .claude.json, not warned" \
  "$(grep -c 'drsg MCP registered for this project' "$T/setup-missing.out")/$(grep -c 'WARN: drsg MCP' "$T/setup-missing.out")" 1/0
check "written drsg entry has the daemon url and the reused token" \
  "$(drsg_entry "$PROJECT")" "http http://127.0.0.1:$PORT/mcp yes"
check "drsg is written without claude mcp add/remove (token stays out of argv)" \
  "$(grep -Ec '^mcp (add|remove) .* drsg([[:space:]]|$)' "$CLAUDE_CALLS")" 0
check "writing drsg keeps the config file's mode" "$(mode_of "$CLAUDE_DIR/.claude.json")" 0o640
check "missing-drsg setup does not expose the token" \
  "$(grep -Fq "$SENTINEL" "$T/setup-missing.out" && echo leaked || echo hidden)" hidden
check "missing-drsg setup still adds drsg-events" \
  "$(grep -c '^mcp add --scope local drsg-events ' "$CLAUDE_CALLS")" 1
check "missing-drsg setup succeeds" "$SETUP_MISSING_RC" 0

# An existing entry is preserved as before, even one that is not ours.
python3 - "$CLAUDE_DIR/.claude.json" "$PROJECT" <<'PY'
import json, sys
path, project = sys.argv[1:]
cfg = json.load(open(path))
cfg["projects"][project]["mcpServers"]["drsg"] = {"type": "http", "url": "http://other/mcp"}
json.dump(cfg, open(path, "w"))
PY
run_setup "$T/setup-again.out"
check "existing drsg entry is preserved, not rewritten" \
  "$(grep -c 'preserving existing drsg MCP registration' "$T/setup-again.out")/$(drsg_entry "$PROJECT")" \
  "1/http http://other/mcp no"

# A config file that is not JSON is left byte for byte.
printf '{"projects": \n' > "$CLAUDE_DIR/.claude.json"
cp "$CLAUDE_DIR/.claude.json" "$T/corrupt.before"
if run_setup "$T/setup-corrupt.out"; then SETUP_CORRUPT_RC=0; else SETUP_CORRUPT_RC=$?; fi
check "corrupt .claude.json: warned, untouched, setup still succeeds" \
  "$(grep -c 'WARN: could not write the drsg MCP registration' "$T/setup-corrupt.out")/$(cmp -s "$T/corrupt.before" "$CLAUDE_DIR/.claude.json" && echo same || echo changed)/$SETUP_CORRUPT_RC" \
  1/same/0
check "corrupt-config setup does not expose the token" \
  "$(grep -Fq "$SENTINEL" "$T/setup-corrupt.out" && echo leaked || echo hidden)" hidden

# A config file that does not exist yet is created private.
rm -f "$CLAUDE_DIR/.claude.json"
run_setup "$T/setup-create.out"
check "absent .claude.json is created 0600 with the drsg entry" \
  "$(mode_of "$CLAUDE_DIR/.claude.json") $(drsg_entry "$PROJECT")" \
  "0o600 http http://127.0.0.1:$PORT/mcp yes"

# A new project (no .drsg/env) joins the running daemon with the token the
# daemon persisted, without --token.
NEW="$T/newproject"
mkdir -p "$NEW"
printf 'DRSG_TOKEN=%s\n' "$SENTINEL" > "$MEM_DIR/env"
printf '{}\n' > "$CLAUDE_DIR/.claude.json"
: > "$CLAUDE_CALLS"
rm -f "$T/auth-ok" "$T/auth-failed"
if run_setup "$T/setup-join.out" "$NEW" --addr "127.0.0.1:$PORT"; then JOIN_RC=0; else JOIN_RC=$?; fi
check "new project joins a running daemon without --token" "$JOIN_RC" 0
check "joined project's env carries the daemon token" \
  "$(grep -Fxc "DRSG_TOKEN=$SENTINEL" "$NEW/.drsg/env" 2>/dev/null || true)" 1
check "joined project gets its drsg entry written" \
  "$(drsg_entry "$NEW")" "http http://127.0.0.1:$PORT/mcp yes"
check "join keeps the token out of output and claude arguments" \
  "$(cat "$T/setup-join.out" "$CLAUDE_CALLS" | grep -Fq "$SENTINEL" && echo leaked || echo hidden)" hidden

# The daemon env token is checked against the daemon before it is used.
NEW2="$T/newproject2"
mkdir -p "$NEW2"
printf 'DRSG_TOKEN=stale-%s\n' "$SENTINEL" > "$MEM_DIR/env"
if run_setup "$T/setup-stale.out" "$NEW2" --addr "127.0.0.1:$PORT"; then STALE_RC=0; else STALE_RC=$?; fi
check "stale daemon env token is refused before anything is written" \
  "$STALE_RC/$(grep -c 'rejected the token in' "$T/setup-stale.out")/$([ -e "$NEW2/.drsg/env" ] && echo written || echo none)" \
  1/1/none
check "stale-token refusal does not print the token" \
  "$(grep -Fq "$SENTINEL" "$T/setup-stale.out" && echo leaked || echo hidden)" hidden

rm -f "$MEM_DIR/env"
if run_setup "$T/setup-noenv.out" "$NEW2" --addr "127.0.0.1:$PORT"; then NOENV_RC=0; else NOENV_RC=$?; fi
check "no daemon env and no --token still stops the join" \
  "$NOENV_RC/$(grep -c 'joining a running daemon requires --token' "$T/setup-noenv.out")" 1/1

echo "PASS $OK/$RAN"
[ "$RAN" -eq 25 ] && [ "$OK" -eq "$RAN" ]

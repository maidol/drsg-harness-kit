#!/usr/bin/env bash
# Existing project credentials must let setup refresh hooks without a token flag.
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

run_setup() {
  HOME="$HOME_DIR" DRSG_MEM_DIR="$MEM_DIR" DRSG_MEM_ADDR= DRSG_MEM_TOKEN= \
    CLAUDE_CONFIG_DIR="$CLAUDE_DIR" PATH="$BIN_DIR:$PATH" \
    bash "$REPO/setup.sh" --project "$PROJECT" --bin /bin/true \
      --no-skills --no-event-poller --no-streak-hint >"$1" 2>&1
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

: > "$CLAUDE_CALLS"
printf '{}\n' > "$CLAUDE_DIR/.claude.json"
if run_setup "$T/setup-missing.out"; then SETUP_MISSING_RC=0; else SETUP_MISSING_RC=$?; fi
check "missing drsg MCP is warned, not called preserved" \
  "$(grep -c 'WARN: drsg MCP is not registered' "$T/setup-missing.out")/$(grep -c 'preserving existing drsg MCP registration' "$T/setup-missing.out")" 1/0
check "missing-drsg setup does not expose the token" \
  "$(grep -Fq "$SENTINEL" "$T/setup-missing.out" && echo leaked || echo hidden)" hidden
check "missing-drsg setup still adds drsg-events" \
  "$(grep -c '^mcp add --scope local drsg-events ' "$CLAUDE_CALLS")" 1
check "missing-drsg setup completes without registering drsg" "$SETUP_MISSING_RC" 0

echo "PASS $OK/$RAN"
[ "$RAN" -eq 10 ] && [ "$OK" -eq "$RAN" ]

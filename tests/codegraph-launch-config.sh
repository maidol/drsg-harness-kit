#!/usr/bin/env bash
# Which drsg config a code-graph daemon reads must not depend on who started it:
# codegraph.sh hands it $DRSG_CODE_CONFIG (default ~/.drsg-memory/codegraph.toml)
# when that file exists and nothing otherwise — never a DRSG_CONFIG inherited
# from the caller, never a ./drsg.toml from the caller's directory. drsg init,
# which starts its own daemon, gets the same environment.
set -u
unset DRSG_EVENT_LANES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CODEGRAPH_SCRIPT:-$HERE/../tools/codegraph.sh}"
TMP="$(mktemp -d)"
cleanup() {
  local f p
  for f in "$TMP"/record-*; do
    [ -f "$f" ] || continue
    p="$(sed -n 's/^pid=//p' "$f")"
    [ -n "$p" ] && kill "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
pass=0; fail=0
check() {
  if [ "$1" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $2"; fi
}

# A stand-in for drsg: writes down how it was started, then — for `serve` —
# plays a daemon that has come up: holds the database lock and answers /health.
fake="$TMP/fake-drsg"
cat > "$fake" <<'FAKE'
#!/usr/bin/env bash
{
  printf 'pid=%s\n' "$$"
  printf 'cwd=%s\n' "$PWD"
  printf 'config=%s\n' "${DRSG_CONFIG-<unset>}"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$FAKE_RECORD"
db=""; addr=""; prev=""
for a in "$@"; do
  [ "$prev" = --db ] && db="$a"
  [ "$prev" = --addr ] && addr="$a"
  prev="$a"
done
case " $* " in *" serve "*) ;; *) exit 1 ;; esac
exec 3<"$db/LOCK"
exec python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers()
    def log_message(self, *a):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "${addr##*:}"
FAKE
chmod +x "$fake"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

# A repository with a .mcp.json on a free port and a database holding a LOCK.
repo() {
  local dir="$TMP/$1" port
  port="$(free_port)"
  mkdir -p "$dir/graph.drsg"
  git -C "$dir" init -q
  : > "$dir/graph.drsg/LOCK"
  printf '{"mcpServers":{"drsg-watch":{"url":"http://127.0.0.1:%s/mcp","headers":{"Authorization":"Bearer abc123"}}}}\n' "$port" > "$dir/.mcp.json"
  printf '%s' "$dir"
}

state_of() {
  printf '%s/state/drsg/codegraph/%s-%s' "$TMP" "$(basename "$1")" "$(printf %s "$1" | sha256sum | cut -c1-8)"
}

# The caller stands in a directory with its own drsg.toml and exports a
# DRSG_CONFIG of its own: both are what a daemon must not pick up.
caller="$TMP/caller"
mkdir -p "$caller"
printf '[digest]\nembed_provider = "openai"\n' > "$caller/drsg.toml"
printf '[plugins]\nhostcall_mb = 1\n' > "$TMP/caller-config.toml"
shared="$TMP/codegraph.toml"
printf '[plugins]\nhostcall_mb = 2048\n' > "$shared"

# 1. The shared file exists: the daemon is started from its state directory
#    with DRSG_CONFIG naming that file.
dir="$(repo one)"
rec="$TMP/record-one"
out="$(cd "$caller" && FAKE_RECORD="$rec" DRSG_CONFIG="$TMP/caller-config.toml" \
  DRSG_CODE_CONFIG="$shared" XDG_STATE_HOME="$TMP/state" DRSG_CODE_BIN="$fake" \
  bash "$SCRIPT" start --dir "$dir" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check ok "" || check bad "start rc=$rc: $out"
grep -qx "cwd=$(state_of "$dir")" "$rec" 2>/dev/null && check ok "" || check bad "daemon cwd is not its state dir: $(tr "\n" " " < "$rec" 2>/dev/null)"
grep -qx "config=$shared" "$rec" 2>/dev/null && check ok "" || check bad "daemon DRSG_CONFIG is not the shared file: $(tr "\n" " " < "$rec" 2>/dev/null)"

# 2. No shared file: the caller's DRSG_CONFIG is removed, not passed on.
dir="$(repo two)"
rec="$TMP/record-two"
out="$(cd "$caller" && FAKE_RECORD="$rec" DRSG_CONFIG="$TMP/caller-config.toml" \
  DRSG_CODE_CONFIG="$TMP/absent.toml" XDG_STATE_HOME="$TMP/state" DRSG_CODE_BIN="$fake" \
  bash "$SCRIPT" start --dir "$dir" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check ok "" || check bad "start without shared file rc=$rc: $out"
grep -qx "config=<unset>" "$rec" 2>/dev/null && check ok "" || check bad "caller DRSG_CONFIG reached the daemon: $(tr "\n" " " < "$rec" 2>/dev/null)"
grep -qx "cwd=$caller" "$rec" 2>/dev/null && check bad "daemon started in the caller's directory" || check ok ""

# 3. Relative DRSG_CODE_DB and DRSG_CODE_BIN still mean the caller's directory.
dir="$(repo three)"
rec="$TMP/record-three"
out="$(cd "$TMP" && FAKE_RECORD="$rec" DRSG_CODE_CONFIG="$shared" XDG_STATE_HOME="$TMP/state" \
  DRSG_CODE_DB="three/graph.drsg" DRSG_CODE_BIN="./fake-drsg" \
  bash "$SCRIPT" start --dir "$dir" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check ok "" || check bad "start with relative paths rc=$rc: $out"
grep -qx "arg=$TMP/three/graph.drsg" "$rec" 2>/dev/null && check ok "" || check bad "--db is not absolute: $(tr "\n" " " < "$rec" 2>/dev/null)"

# 4. install's drsg init gets the shared file too (the fake refuses init, so
#    install stops there; the record is what this checks).
dir="$TMP/four"
mkdir -p "$dir"; git -C "$dir" init -q
rec="$TMP/record-four"
out="$(cd "$caller" && FAKE_RECORD="$rec" DRSG_CONFIG="$TMP/caller-config.toml" \
  DRSG_CODE_CONFIG="$shared" XDG_STATE_HOME="$TMP/state" DRSG_CODE_BIN="$fake" \
  bash "$SCRIPT" install --dir "$dir" 2>&1)"
grep -qx "arg=init" "$rec" 2>/dev/null && check ok "" || check bad "install did not run drsg init: $out"
grep -qx "config=$shared" "$rec" 2>/dev/null && check ok "" || check bad "drsg init DRSG_CONFIG is not the shared file: $(tr "\n" " " < "$rec" 2>/dev/null)"

echo "PASS $pass/$((pass + fail))"
[ "$fail" -eq 0 ]

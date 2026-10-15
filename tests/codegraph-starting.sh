#!/usr/bin/env bash
# A daemon that holds the code-graph database but is not listening yet (the
# first seconds of a cold start) is reported as starting, not as listening on
# an empty address with a false port-mismatch warning.
set -u
unset DRSG_EVENT_LANES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CODEGRAPH_SCRIPT:-$HERE/../tools/codegraph.sh}"
TMP="$(mktemp -d)"
holder=""
cleanup() {
  [ -n "$holder" ] && kill "$holder" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
pass=0; fail=0
check() {
  if [ "$1" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $2"; fi
}

dir="$TMP/repo"
mkdir -p "$dir/graph.drsg"
git -C "$dir" init -q
printf '%s\n' '{"mcpServers":{"drsg-watch":{"url":"http://127.0.0.1:7999/mcp","headers":{"Authorization":"Bearer abc123"}}}}' > "$dir/.mcp.json"
: > "$dir/graph.drsg/LOCK"
# Holds the database lock open and listens on nothing: what a daemon looks
# like between taking the lock and binding its port.
sleep 300 3<"$dir/graph.drsg/LOCK" &
holder=$!

run() {
  XDG_STATE_HOME="$TMP/state" DRSG_CODE_BIN=/bin/false bash "$SCRIPT" "$1" --dir "$dir" 2>&1
}

out="$(run status)"; rc=$?
[ "$rc" -eq 0 ] && check ok "" || check bad "status rc=$rc: $out"
case "$out" in *"starting (pid $holder"*"not listening yet"*) check ok "" ;; *) check bad "status does not say starting: $out" ;; esac
case "$out" in *WARNING*|*"http:///mcp"*) check bad "status still reports an empty address: $out" ;; *) check ok "" ;; esac

out="$(run doctor)"; rc=$?
[ "$rc" -ne 0 ] && check ok "" || check bad "doctor rc=0 for a daemon that is not listening: $out"
case "$out" in *"pid $holder holds"*"not listening"*) check ok "" ;; *) check bad "doctor does not say not listening: $out" ;; esac
case "$out" in *".mcp.json says"*) check bad "doctor still reports a port mismatch: $out" ;; *) check ok "" ;; esac

echo "PASS $pass/$((pass + fail))"
[ "$fail" -eq 0 ]

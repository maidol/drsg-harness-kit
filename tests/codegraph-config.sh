#!/usr/bin/env bash
# codegraph.sh reads .mcp.json as data: a token or URL in a repository's
# .mcp.json must never be executed by the shell.
set -u
unset DRSG_EVENT_LANES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../tools/codegraph.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
check() {
  if [ "$1" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $2"; fi
}

repo() {
  local dir="$TMP/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '%s\n' "$2" > "$dir/.mcp.json"
  printf '%s' "$dir"
}

status_of() {
  XDG_STATE_HOME="$TMP/state" DRSG_CODE_BIN=/bin/false bash "$SCRIPT" status --dir "$1" 2>&1
}

# 1. A well-formed config is read as before.
dir="$(repo good '{"mcpServers":{"drsg-watch":{"url":"http://127.0.0.1:7999/mcp","headers":{"Authorization":"Bearer abc123DEF.4_5-6"}}}}')"
out="$(status_of "$dir")"
case "$out" in *"not running"*".mcp.json says 127.0.0.1:7999"*) check ok "" ;; *) check bad "good config: $out" ;; esac

# 2. Shell syntax in the token is refused, not executed.
marker="$TMP/token-ran"
dir="$(repo token "{\"mcpServers\":{\"drsg-watch\":{\"url\":\"http://127.0.0.1:7999/mcp\",\"headers\":{\"Authorization\":\"Bearer abc;touch\${IFS}$marker\"}}}}")"
out="$(status_of "$dir")"; rc=$?
[ ! -e "$marker" ] && check ok "" || check bad "token payload was executed"
[ "$rc" -ne 0 ] && check ok "" || check bad "malicious token: exit 0"
case "$out" in *"token has unexpected characters"*) check ok "" ;; *) check bad "malicious token reason: $out" ;; esac

# 3. Shell syntax in the URL host is refused, not evaluated (a host cannot
# carry a path, so the reason is the evidence here, not a marker file).
dir="$(repo host '{"mcpServers":{"drsg-watch":{"url":"http://x;true:7999/mcp","headers":{"Authorization":"Bearer abc"}}}}')"
out="$(status_of "$dir")"; rc=$?
[ "$rc" -ne 0 ] && check ok "" || check bad "malicious host: exit 0"
case "$out" in *"host has unexpected characters"*) check ok "" ;; *) check bad "malicious host reason: $out" ;; esac

# 4. A missing entry still names the fix.
dir="$(repo missing '{"mcpServers":{}}')"
out="$(status_of "$dir")"; rc=$?
[ "$rc" -ne 0 ] && check ok "" || check bad "missing entry: exit 0"
case "$out" in *"no usable 'drsg-watch' entry"*) check ok "" ;; *) check bad "missing entry reason: $out" ;; esac

echo "PASS $pass/$((pass + fail))"
[ "$fail" -eq 0 ]

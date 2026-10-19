#!/usr/bin/env bash
# PreToolUse denies Bash commands that carry a plaintext secret, and
# SessionStart warns (terminal only) when this project's settings hold one.
# Fake values are built at run time so no secret-shaped literal sits in the repo.
set -u
unset DRSG_EVENT_LANES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="${SECRET_GUARD_HOOKS:-$HERE/../tools/templates/hooks}"
ONLY="${ONLY:-}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAKE_BEARER="$(python3 -c 'print("Fk" + "x9" * 12)')"
FAKE_SIG="$(python3 -c 'print("S1g" * 8)')"
FAKE_AK="$(python3 -c 'print("AK" + "F4" * 7)')"
FAKE_API="$(python3 -c 'print("sk-" + "Zq7" * 8)')"
export FAKE_BEARER FAKE_SIG FAKE_AK FAKE_API

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

decision() {
  python3 -c 'import json,sys
cmd = sys.argv[2]
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}))' x "$1" |
    python3 "$HOOKS/pre_tool_use.py" |
    python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if not raw:
    print("allow")
else:
    out = json.loads(raw)["hookSpecificOutput"]
    print(out["permissionDecision"] + "|" + out["permissionDecisionReason"])'
}

OUT="$(decision "curl -H \"Authorization: Bearer $FAKE_BEARER\" http://127.0.0.1:3456/v1/models")"
check "inline bearer is denied" "${OUT%%|*}" "deny"
check "denial names the kind, not the value" \
  "$(printf '%s' "$OUT" | grep -c 'kinds: bearer')/$(printf '%s' "$OUT" | grep -cF "$FAKE_BEARER")" "1/0"

OUT="$(decision "curl 'http://h.test:9000/b/o?X-Amz-Signature=$FAKE_SIG&Expires=1'")"
check "url signature is denied" "${OUT%%|*}" "deny"

OUT="$(decision "curl 'http://h.test:9000/b/o?AWSAccessKeyId=$FAKE_AK&Expires=1'")"
check "url access key is denied" "${OUT%%|*}" "deny"

OUT="$(decision "curl -H 'Authorization: Basic $FAKE_SIG' http://h.test/")"
check "basic authorization header is denied" "${OUT%%|*}" "deny"

OUT="$(decision 'curl -H "Authorization: Bearer $CCR_KEY" http://127.0.0.1:3456/v1/models')"
check "bearer from an env variable is allowed" "$OUT" "allow"

OUT="$(decision 'set -a; . ~/.config/claude-secrets/ccr.env; set +a')"
check "loading a secrets file is allowed" "$OUT" "allow"

OUT="$(decision 'git status')"
check "ordinary command is allowed" "$OUT" "allow"

# SessionStart: the warning text, then that main() actually shows it.
mkdir -p "$T/clean/.claude" "$T/dirty/.claude" "$T/varonly/.claude" "$T/bare" "$T/mem"
python3 - "$T" <<'PY'
import json, os, sys
t = sys.argv[1]
b, a = os.environ["FAKE_BEARER"], os.environ["FAKE_API"]
def w(p, d):
    with open(p, "w") as fh:
        json.dump(d, fh)
w(t + "/clean/.claude/settings.local.json",
  {"env": {"DISABLE_AUTOUPDATER": "1"}, "permissions": {"allow": ["Bash(git status)"]}})
w(t + "/dirty/.claude/settings.local.json",
  {"env": {"ANTHROPIC_API_KEY": a, "ANTHROPIC_BASE_URL": "http://127.0.0.1:3456"},
   "permissions": {"allow": ["Bash(git status)",
                             'Bash(curl -H "Authorization: Bearer %s" http://127.0.0.1:3456/v1/models)' % b]}})
w(t + "/varonly/.claude/settings.local.json",
  {"env": {"ANTHROPIC_API_KEY": "$ANTHROPIC_API_KEY_FROM_SHELL"},
   "permissions": {"allow": ['Bash(curl -H "Authorization: Bearer $CCR_KEY" http://x/)']}})
w(t + "/dirty/.mcp.json",
  {"mcpServers": {"drsg-watch": {"type": "http", "url": "http://127.0.0.1:7708/mcp",
                                 "headers": {"Authorization": "Bearer " + b}},
                  "remote": {"type": "http", "url": "http://h.test/mcp",
                             "headers": {"Authorization": "Bearer ${REMOTE_TOKEN}"}}}})
w(t + "/varonly/.mcp.json",
  {"mcpServers": {"remote": {"type": "http", "url": "http://h.test/mcp",
                             "headers": {"Authorization": "Bearer ${REMOTE_TOKEN}"}}}})
PY
cp "$HOOKS/session_start.py" "$T/bare/session_start.py"

SS_OUT="$(env -u PYTHONPATH -u DRSG_TOKEN -u DRSG_API DRSG_MEM_DIR="$T/mem" \
  python3 - "$HOOKS" "$T" <<'PY'
import importlib.util, io, json, os, sys
hooks, t = sys.argv[1:]
def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
ss = load(os.path.join(hooks, "session_start.py"), "ss_under_test")
msg = getattr(ss, "settings_secret_message", lambda _p: "")
dirty = msg(t + "/dirty")
print("clean=" + repr(msg(t + "/clean")))
print("varonly=" + repr(msg(t + "/varonly")))
print("dirty_rules=%d" % ("1 permission rule(s)" in dirty))
print("dirty_env=%d" % ("env ANTHROPIC_API_KEY" in dirty))
print("dirty_novalue=%d" % (os.environ["FAKE_BEARER"] not in dirty and os.environ["FAKE_API"] not in dirty))
mcp = getattr(ss, "mcp_bearer_message", lambda _p: "")
mcp_dirty = mcp(t + "/dirty")
print("mcp_clean=" + repr(mcp(t + "/clean")))
print("mcp_varonly=" + repr(mcp(t + "/varonly")))
print("mcp_names=%d" % ("drsg-watch" in mcp_dirty and "remote" not in mcp_dirty))
print("mcp_novalue=%d" % (bool(mcp_dirty) and os.environ["FAKE_BEARER"] not in mcp_dirty))
# The first load put the hooks dir on sys.path and cached secret_redact.
sys.modules.pop("secret_redact", None)
sys.path[:] = [p for p in sys.path if os.path.abspath(p) != os.path.abspath(hooks)]
bare = load(t + "/bare/session_start.py", "ss_bare")
print("bare=" + repr(getattr(bare, "settings_secret_message", lambda _p: "x")(t + "/dirty")))
sys.path.insert(0, hooks)
# Wiring: the tokenless return path must carry the warning in systemMessage.
os.environ["CLAUDE_PROJECT_DIR"] = t + "/dirty"
sys.stdin = io.StringIO(json.dumps({"session_id": "s", "source": "startup", "cwd": t + "/dirty"}))
buf = io.StringIO()
real = sys.stdout
sys.stdout = buf
try:
    ss.main()
finally:
    sys.stdout = real
out = json.loads(buf.getvalue().strip().splitlines()[-1])
print("wired=%d" % ("1 permission rule(s)" in (out.get("systemMessage") or "")))
print("mcp_wired=%d" % (".mcp.json Authorization for drsg-watch" in (out.get("systemMessage") or "")))
print("wired_novalue=%d" % (os.environ["FAKE_BEARER"] not in buf.getvalue() and os.environ["FAKE_API"] not in buf.getvalue()))
PY
)"
val() { printf '%s\n' "$SS_OUT" | sed -n "s/^$1=//p"; }
check "clean settings give no warning" "$(val clean)" "''"
check "variable references give no warning" "$(val varonly)" "''"
check "warning counts secret rules" "$(val dirty_rules)" "1"
check "warning names secret env vars" "$(val dirty_env)" "1"
check "warning never shows a value" "$(val dirty_novalue)" "1"
check "missing secret_redact degrades to no warning" "$(val bare)" "''"
check "session start shows the warning" "$(val wired)" "1"
check "session start output has no value" "$(val wired_novalue)" "1"
check "no .mcp.json gives no mcp warning" "$(val mcp_clean)" "''"
check "\${VAR} Authorization gives no mcp warning" "$(val mcp_varonly)" "''"
check "mcp warning names the plaintext server only" "$(val mcp_names)" "1"
check "mcp warning never shows a value" "$(val mcp_novalue)" "1"
check "session start shows the mcp warning" "$(val mcp_wired)" "1"

if [ -n "$ONLY" ] && [ "$RAN" -eq 0 ]; then
  printf 'FAIL unknown-only-case: %s\n' "$ONLY"
  RAN=1
fi
printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

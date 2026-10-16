#!/usr/bin/env bash
# Exercise setup.sh --all-projects against a real temporary memory daemon.
set -u
unset DRSG_EVENT_LANES

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CASE="${1:-all}"
MEM_BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
if [ ! -x "$MEM_BIN" ]; then MEM_BIN="$(command -v drsg || true)"; fi
if [ -z "$MEM_BIN" ] || [ ! -x "$MEM_BIN" ]; then
  echo "SKIP setup-all-projects: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi
for tool in curl python3 realpath; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP setup-all-projects: missing $tool"
    exit 0
  fi
done

T="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
TOKEN="fake-token"
API="http://127.0.0.1:$PORT/rpc"
MEM_DIR="$T/mem"
HOME_DIR="$T/home"
CLAUDE_DIR="$T/claude-config"
BUNDLE="$T/bundle"
PROJECTS="$T/projects"
ALPHA="$PROJECTS/alpha"
BETA="$PROJECTS/beta"
NO_ENV="$PROJECTS/no-env"
MISSING="$PROJECTS/missing"
ALIAS="$PROJECTS/alpha-alias"
FAKE_INSTALL_LOG="$T/install.calls"
MAIN_BRANCH_CALLS="$T/main-branch.calls"
mkdir -p "$MEM_DIR" "$HOME_DIR" "$CLAUDE_DIR" "$PROJECTS" "$BUNDLE/tools" \
  "$BUNDLE/claude" "$BUNDLE/skills/test-skill" "$ALPHA/.drsg" "$BETA/.drsg" "$NO_ENV"

DRSG_TOKEN="$TOKEN" "$MEM_BIN" --db "$T/memory.drsg" serve --addr "127.0.0.1:$PORT" >"$T/daemon.log" 2>&1 &
DAEMON=$!
cleanup() {
  kill "$DAEMON" 2>/dev/null || true
  wait "$DAEMON" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
for _ in $(seq 1 50); do
  curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done
if ! curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "FAIL setup-all-projects: temporary drsg daemon did not start"
  exit 1
fi

cat > "$MEM_DIR/env" <<EOF
DRSG_TOKEN=$TOKEN
DRSG_API=$API
DRSG_PLANE=memory
EOF
for project in "$ALPHA" "$BETA" "$NO_ENV"; do
  mkdir -p "$project"
done
for project in "$ALPHA" "$BETA"; do
  cat > "$project/.drsg/env" <<EOF
DRSG_TOKEN=$TOKEN
DRSG_API=$API
DRSG_PLANE=memory
EOF
done

# Minimal bundle: real setup.sh and project registry, with instrumented installers.
cp "$REPO/setup.sh" "$BUNDLE/setup.sh"
cp "$REPO/claude/MAIN-BRANCH-WORKFLOW.md" "$BUNDLE/claude/MAIN-BRANCH-WORKFLOW.md"
cp "$REPO/claude/AGENT-EFFICIENCY.md" "$BUNDLE/claude/AGENT-EFFICIENCY.md"
if [ -f "$REPO/claude/CROSS-PROJECT-REVIEW.md" ]; then
  cp "$REPO/claude/CROSS-PROJECT-REVIEW.md" "$BUNDLE/claude/CROSS-PROJECT-REVIEW.md"
fi
printf 'fixture skill\n' > "$BUNDLE/skills/test-skill/SKILL.md"
SETUP_SOURCE="${SETUP_SOURCE:-$REPO/setup.sh}"
cp "$SETUP_SOURCE" "$BUNDLE/setup.sh"
REGISTRY_SOURCE="${REGISTRY_SOURCE:-$REPO/tools/project_registry.py}"
if [ -f "$REGISTRY_SOURCE" ]; then cp "$REGISTRY_SOURCE" "$BUNDLE/tools/project_registry.py"; fi
cp "$REPO/tools/drsg_rpc.py" "$BUNDLE/tools/drsg_rpc.py"
cat > "$BUNDLE/tools/install.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\0' "$@" >> "$FAKE_INSTALL_LOG"
printf '\n' >> "$FAKE_INSTALL_LOG"
count="$(wc -l < "$FAKE_INSTALL_LOG" | tr -d ' ')"
echo "fake-install-output $count"
if [ "${FAIL_FIRST:-0}" = 1 ] && [ "$count" -eq 1 ]; then
  exit 7
fi
exit 0
SH
cat > "$BUNDLE/tools/main-branch-workflow-config.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MAIN_BRANCH_CALLS"
SH
chmod +x "$BUNDLE/tools/install.sh" "$BUNDLE/tools/main-branch-workflow-config.sh"

# Create Project nodes through the real daemon's JSON-RPC surface.
NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
DRSG_API="$API" DRSG_TOKEN="$TOKEN" EMPTY_PROJECTS="$([ "$CASE" = empty-project-list ] && echo 1 || echo 0)" \
python3 - "$ALPHA" "$BETA" "$NO_ENV" "$MISSING" <<'PY'
import json, os, sys, urllib.request
api, token = os.environ["DRSG_API"], os.environ["DRSG_TOKEN"]
def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=5) as response:
        result = json.load(response)
    if "error" in result:
        raise RuntimeError("fixture RPC failed: " + str(result["error"].get("code")))
    return result.get("result")
rpc("plane.create", {"name": "memory"})
rpc("plane.create", {"name": "empty"})
if os.environ.get("EMPTY_PROJECTS") != "1":
    for index, path in enumerate(sys.argv[1:]):
        rpc("node.create", {"plane": "memory", "key": "n5-project-%d" % index,
                             "labels": ["Project"], "properties": {"path": path}})
PY
if [ "$?" -ne 0 ]; then
  echo "FAIL setup-all-projects: could not create fixture Project nodes"
  exit 1
fi

RAN=0
OK=0
check() {
  local name="$1" actual="$2" expected="$3"
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then return; fi
  RAN=$((RAN + 1))
  if [ "$actual" = "$expected" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s: got <%s> want <%s>\n' "$name" "$actual" "$expected"
  fi
}
run_setup() {
  local out="$1" fail_first="$2"
  : > "$FAKE_INSTALL_LOG"
  FAIL_FIRST="$fail_first" HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" \
    DRSG_MEM_DIR="$MEM_DIR" DRSG_API="$API" DRSG_TOKEN="$TOKEN" DRSG_PLANE=memory \
    FAKE_INSTALL_LOG="$FAKE_INSTALL_LOG" MAIN_BRANCH_CALLS="$MAIN_BRANCH_CALLS" \
    PATH="$T/bin:$PATH" bash "$BUNDLE/setup.sh" --all-projects --bin /bin/true \
      --addr "127.0.0.1:$PORT" >"$out" 2>&1
}

case "$CASE" in
  all|skip-no-env|failure-continues|mutual-exclusion|query-failure|empty-project-list|registry-from-env) ;;
  *) echo "FAIL setup-all-projects: unknown case '$CASE'"; exit 2 ;;
esac

if [ "$CASE" = all ] || [ "$CASE" = mutual-exclusion ]; then
  : > "$FAKE_INSTALL_LOG"
  : > "$MAIN_BRANCH_CALLS"
  for option in project repo hub router usage-report; do
    args=(--all-projects)
    case "$option" in
      project) args+=(--project "$ALPHA") ;;
      repo) args+=(--repo "$T/repo") ;;
      hub) args+=(--hub "$ALPHA") ;;
      router) args+=(--router "$ALPHA") ;;
      usage-report) args+=(--usage-report "$ALPHA") ;;
    esac
    HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" DRSG_MEM_DIR="$MEM_DIR" \
      FAKE_INSTALL_LOG="$FAKE_INSTALL_LOG" MAIN_BRANCH_CALLS="$MAIN_BRANCH_CALLS" \
      PATH="$T/bin:$PATH" bash "$BUNDLE/setup.sh" "${args[@]}" >"$T/mutual-$option.out" 2>&1
    rc=$?
    check "mutual-exclusion-$option" \
      "$( [ "$rc" -ne 0 ] && grep -c -- "--all-projects cannot be combined with --$option" "$T/mutual-$option.out" || true )" 1
  done
  check "mutual-exclusion-happens-before-global-write" \
    "$(wc -l < "$MAIN_BRANCH_CALLS" | tr -d ' ')" 0
  check "mutual-exclusion-does-not-call-installer" \
    "$(wc -l < "$FAKE_INSTALL_LOG" | tr -d ' ')" 0
fi

if [ "$CASE" = empty-project-list ]; then
  : > "$FAKE_INSTALL_LOG"
  : > "$MAIN_BRANCH_CALLS"
  HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" DRSG_MEM_DIR="$MEM_DIR" \
    FAKE_INSTALL_LOG="$FAKE_INSTALL_LOG" MAIN_BRANCH_CALLS="$MAIN_BRANCH_CALLS" \
    PATH="$T/bin:$PATH" bash "$BUNDLE/setup.sh" --all-projects --bin /bin/true \
      --addr "127.0.0.1:$PORT" > "$T/empty-project-list.out" 2>&1
  rc=$?
  check "empty-project-list-is-success" "$rc" 0
  check "empty-project-list-reports-no-projects-and-zero-summary" \
    "$(grep -c '^no projects found$' "$T/empty-project-list.out" || true)/$(tail -1 "$T/empty-project-list.out")" \
    "1/summary: 0 ok, 0 failed, 0 skipped"
  check "empty-project-list-does-not-call-installer" \
    "$(wc -l < "$FAKE_INSTALL_LOG" | tr -d ' ')" 0
fi

if [ "$CASE" = query-failure ]; then
  : > "$FAKE_INSTALL_LOG"
  HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" DRSG_MEM_DIR="$MEM_DIR" \
    FAKE_INSTALL_LOG="$FAKE_INSTALL_LOG" MAIN_BRANCH_CALLS="$MAIN_BRANCH_CALLS" \
    PATH="$T/bin:$PATH" bash "$BUNDLE/setup.sh" --all-projects --bin /bin/true \
      --addr 127.0.0.1:1 > "$T/query-failure.out" 2>&1
  rc=$?
  check "query-failure-is-nonzero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" yes
  check "query-failure-does-not-call-installer" \
    "$(wc -l < "$FAKE_INSTALL_LOG" | tr -d ' ')" 0
  check "query-failure-is-reported" \
    "$(grep -c 'could not list projects' "$T/query-failure.out" || true)" 1
fi

if [ "$CASE" = all ]; then
  API_ARGS=(--env "$MEM_DIR/env" --api "$API" --plane memory --nul)
  python3 "$REPO/tools/project_registry.py" "${API_ARGS[@]}" > "$T/projects.nul" 2>"$T/registry.err"
  registry_rc=$?
  check "registry-nul-returns-success" "$registry_rc" 0
  check "registry-nul-returns-four-known-projects" \
    "$(python3 - "$T/projects.nul" "$ALPHA" "$BETA" "$NO_ENV" "$MISSING" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
items = raw.split(b"\0")
if items and items[-1] == b"": items.pop()
want = {p.encode() for p in sys.argv[2:]}
print("yes" if set(items) == want and len(items) == len(want) else "no")
PY
)" yes
  python3 "$REPO/tools/project_registry.py" --env "$MEM_DIR/env" --api "$API" \
    --plane empty --nul > "$T/empty.nul" 2>"$T/empty.err"
  empty_rc=$?
  check "empty-project-list-is-success" "$empty_rc/$(wc -c < "$T/empty.nul" | tr -d ' ')" 0/0
  DRSG_MEM_DIR="$MEM_DIR" DRSG_API="$API" DRSG_PLANE=memory \
    HOME="$HOME_DIR" "$REPO/tools/install.sh" --check --addr "127.0.0.1:$PORT" \
    > "$T/install-check.out" 2>&1
  check_rc=$?
  check "install-check-keeps-success-exit" "$check_rc" 0
  check "install-check-keeps-no-hooks-output" \
    "$(grep -c '(no hooks installed)' "$T/install-check.out" || true)" 4
fi

if [ "$CASE" = all ] || [ "$CASE" = skip-no-env ]; then
  if run_setup "$T/setup-first.out" 1; then rc=0; else rc=$?; fi
  check "skills-land-under-temporary-HOME" "$( [ -d "$HOME_DIR/.claude/skills" ] && echo yes || echo no )" yes
  check "cross-review-installed-not-imported" \
    "$( [ -f "$CLAUDE_DIR/CROSS-PROJECT-REVIEW.md" ] && echo yes || echo no )/$(grep -c '^@CROSS-PROJECT-REVIEW.md' "$CLAUDE_DIR/CLAUDE.md" || true)" yes/0
  check "missing-dir-and-no-env-are-skipped" \
    "$(grep -Ec '^skipped .*(directory missing|no .drsg/env)' "$T/setup-first.out" || true)" 2
  check "no-env-case-does-not-call-installer" \
    "$(python3 - "$FAKE_INSTALL_LOG" "$NO_ENV" <<'PY'
import sys
print("no" if sys.argv[2].encode() in open(sys.argv[1], "rb").read() else "yes")
PY
)" yes
  if [ "$CASE" = skip-no-env ]; then
    check "skip-no-env-is-not-installed" \
      "$(grep -F "$NO_ENV" "$FAKE_INSTALL_LOG" >/dev/null 2>&1 && echo installed || echo skipped)" skipped
  else
    check "first-failure-does-not-stop-later-project" "$(grep -c '^FAILED ' "$T/setup-first.out" || true)/$(grep -c '^ok ' "$T/setup-first.out" || true)" 1/1
    check "first-run-summary-and-failure-exit" \
      "$(tail -1 "$T/setup-first.out")/$rc" "summary: 1 ok, 1 failed, 2 skipped/1"
    check "failed-project-log-is-private" \
      "$(python3 - "$T/setup-first.out" <<'PY'
import os, re, stat, sys
for line in open(sys.argv[1], encoding="utf-8"):
    match = re.search(r"\(log: (.+)\)$", line.rstrip())
    if match and os.path.isfile(match.group(1)):
        print("yes" if stat.S_IMODE(os.stat(match.group(1)).st_mode) == 0o600 else "no")
        break
else:
    print("no")
PY
)" yes
    check "project-log-is-readable-without-token" \
      "$(python3 - "$T/setup-first.out" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8"):
    match = re.search(r"\(log: (.+)\)$", line.rstrip())
    if match:
        print(open(match.group(1), encoding="utf-8").read().strip())
        break
else:
    print("no-log")
PY
)" "fake-install-output 1"
    check "installer-gets-same-bin-and-address-for-each-project" \
      "$(python3 - "$FAKE_INSTALL_LOG" "$PORT" <<'PY'
import sys
records = [row.split(b"\0")[:-1] for row in open(sys.argv[1], "rb").read().splitlines()]
want_addr = ("127.0.0.1:" + sys.argv[2]).encode()
valid = len(records) == 2 and all(
    b"--bin" in args and b"/bin/true" in args and
    b"--addr" in args and want_addr in args for args in records)
print("yes" if valid else "no")
PY
)" yes
    check "global-main-branch-step-runs-once" \
      "$(wc -l < "$MAIN_BRANCH_CALLS" | tr -d ' ')" 1
    check "setup-output-does-not-expose-fixture-token" \
      "$(grep -Fq "$TOKEN" "$T/setup-first.out" && echo leaked || echo hidden)" hidden
  fi
fi

if [ "$CASE" = all ] || [ "$CASE" = failure-continues ]; then
  if [ "$CASE" = failure-continues ]; then : > "$MAIN_BRANCH_CALLS"; fi
  if run_setup "$T/setup-failure.out" 1; then rc=0; else rc=$?; fi
  calls="$(wc -l < "$FAKE_INSTALL_LOG" | tr -d ' ')"
  check "failure-continues-attempts-both-valid-projects" "$calls" 2
  check "failure-continues-has-failed-and-success-status" \
    "$(grep -c '^FAILED ' "$T/setup-failure.out" || true)/$(grep -c '^ok ' "$T/setup-failure.out" || true)" 1/1
  check "failure-continues-summary-and-nonzero" \
    "$(tail -1 "$T/setup-failure.out")/$rc" "summary: 1 ok, 1 failed, 2 skipped/1"
fi

if [ "$CASE" = all ]; then
  ln -s "$ALPHA" "$ALIAS"
  DRSG_API="$API" DRSG_TOKEN="$TOKEN" python3 - "$ALIAS" <<'PY'
import json, os, sys, urllib.request
req = urllib.request.Request(os.environ["DRSG_API"], data=json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "node.create",
    "params": {"plane": "memory", "key": "n5-project-alias", "labels": ["Project"],
               "properties": {"path": sys.argv[1]}}}).encode(), headers={
    "Content-Type": "application/json", "Authorization": "Bearer " + os.environ["DRSG_TOKEN"]})
with urllib.request.urlopen(req, timeout=5) as response:
    result = json.load(response)
if "error" in result: raise SystemExit(1)
PY
  if run_setup "$T/setup-alias.out" 0; then alias_rc=0; else alias_rc=$?; fi
  check "realpath-alias-is-skipped" \
    "$(grep -c '^skipped .*duplicate realpath:' "$T/setup-alias.out" || true)" 1
  check "alias-run-summary-is-success" \
    "$(tail -1 "$T/setup-alias.out")/$alias_rc" "summary: 2 ok, 0 failed, 3 skipped/0"
  check "global-main-branch-step-once-per-run" \
    "$(wc -l < "$MAIN_BRANCH_CALLS" | tr -d ' ')" 3
fi

# Without --addr, the project list comes from the daemon that DRSG_API in the
# memory dir's env file names, never from whatever answers on 127.0.0.1:7700.
if [ "$CASE" = all ] || [ "$CASE" = registry-from-env ]; then
  : > "$FAKE_INSTALL_LOG"
  env -u DRSG_MEM_ADDR HOME="$HOME_DIR" CLAUDE_CONFIG_DIR="$CLAUDE_DIR" DRSG_MEM_DIR="$MEM_DIR" \
    FAKE_INSTALL_LOG="$FAKE_INSTALL_LOG" MAIN_BRANCH_CALLS="$MAIN_BRANCH_CALLS" \
    PATH="$T/bin:$PATH" bash "$BUNDLE/setup.sh" --all-projects --bin /bin/true \
    > "$T/registry-from-env.out" 2>&1
  rc=$?
  check "registry-from-env-lists-projects-from-env-api" \
    "$rc/$(grep -c '^ok ' "$T/registry-from-env.out" || true)" 0/2
fi

if [ -n "${ONLY:-}" ] && [ "$RAN" -eq 0 ]; then
  echo "FAIL setup-all-projects: unknown-only-case '$ONLY'"
  exit 2
fi
printf 'PASS %d/%d\n' "$OK" "$RAN"
[ "$RAN" -gt 0 ] && [ "$OK" -eq "$RAN" ]

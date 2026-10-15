#!/usr/bin/env bash
# Live-process tests for Claude Code owner detection.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ONLY="${ONLY:-}"

if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP owner-process-detection: node executable not found\n'
  exit 0
fi
for tool in bash python3 env; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'SKIP owner-process-detection: %s executable not found\n' "$tool"
    exit 0
  fi
done

case "$ONLY" in
  ""|npm-poller|npm-session-start|npm-user-prompt|npm-event|npm-nodejs-poller|ccr-poller) ;;
  *)
    printf 'FAIL owner-process-detection: unknown ONLY case %s\n' "$ONLY"
    exit 2
    ;;
esac

SOURCE_POLLER="${SOURCE_POLLER:-$REPO/tools/event-poller.py}"
SOURCE_SESSION_START="${SOURCE_SESSION_START:-$REPO/tools/templates/hooks/session_start.py}"
SOURCE_USER_PROMPT="${SOURCE_USER_PROMPT:-$REPO/tools/templates/hooks/user_prompt.py}"
SOURCE_EVENT="${SOURCE_EVENT:-$REPO/tools/event.py}"
NODE_BIN="$(command -v node)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/lib/node_modules/@anthropic-ai/claude-code" \
  "$T/lib/node_modules/@musistudio/claude-code-router/dist"

cat >"$T/lib/node_modules/@anthropic-ai/claude-code/cli.js" <<'JS'
const { spawnSync } = require("child_process");
const sources = [
  process.env.SOURCE_POLLER,
  process.env.SOURCE_SESSION_START,
  process.env.SOURCE_USER_PROMPT,
  process.env.SOURCE_EVENT,
];
const result = spawnSync("python3", [
  process.env.PROBE, process.env.EXPECT_OWNER, process.env.TARGET,
  ...sources,
], {
  env: { ...process.env, WANT_PID: String(process.pid) },
  stdio: "inherit",
});
if (result.error || result.status === null) process.exit(2);
process.exit(result.status);
JS
cp "$T/lib/node_modules/@anthropic-ai/claude-code/cli.js" \
  "$T/lib/node_modules/@musistudio/claude-code-router/dist/cli.js"

cat >"$T/probe.py" <<'PY'
import importlib.util
import os
import sys

names = ("poller", "session_start", "user_prompt", "event")
functions = ("owner_process", "_claude_pid", "_claude_pid", "_claude_process")
try:
    expected, target, *paths = sys.argv[1:]
    if len(paths) != 4 or target not in names or expected not in ("same", "different"):
        raise ValueError("invalid probe arguments")
    index = names.index(target)
    module_name = "owner_probe_" + target
    spec = importlib.util.spec_from_file_location(module_name, paths[index])
    if spec is None or spec.loader is None:
        raise ImportError("could not load detector")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    result = getattr(module, functions[index])()
    actual = result[0] if isinstance(result, tuple) else result
    want_pid = int(os.environ["WANT_PID"])
    passed = actual == want_pid if expected == "same" else actual != want_pid
except Exception as exc:
    print("probe error: " + type(exc).__name__)
    sys.exit(2)
sys.exit(0 if passed else 1)
PY

passed=0
ran=0
run_node_case() {
  local label="$1" target="$2" expected="$3" cli
  if [ "$expected" = different ]; then
    cli="$T/lib/node_modules/@musistudio/claude-code-router/dist/cli.js"
  else
    cli="$T/lib/node_modules/@anthropic-ai/claude-code/cli.js"
  fi
  ran=$((ran + 1))
  if [ "$label" = npm-nodejs-poller ]; then
    if env -u EVENT_POLL_OWNER_PID \
      PROBE="$T/probe.py" EXPECT_OWNER="$expected" TARGET="$target" \
      SOURCE_POLLER="$SOURCE_POLLER" SOURCE_SESSION_START="$SOURCE_SESSION_START" \
      SOURCE_USER_PROMPT="$SOURCE_USER_PROMPT" SOURCE_EVENT="$SOURCE_EVENT" \
      bash -c 'exec -a nodejs "$1" "$2"' _ "$NODE_BIN" "$cli"; then
      printf 'ok   %s\n' "$label"
      passed=$((passed + 1))
    else
      printf 'FAIL %s\n' "$label"
    fi
  else
    if env -u EVENT_POLL_OWNER_PID \
      PROBE="$T/probe.py" EXPECT_OWNER="$expected" TARGET="$target" \
      SOURCE_POLLER="$SOURCE_POLLER" SOURCE_SESSION_START="$SOURCE_SESSION_START" \
      SOURCE_USER_PROMPT="$SOURCE_USER_PROMPT" SOURCE_EVENT="$SOURCE_EVENT" \
      "$NODE_BIN" "$cli"; then
      printf 'ok   %s\n' "$label"
      passed=$((passed + 1))
    else
      printf 'FAIL %s\n' "$label"
    fi
  fi
}
run_native_case() {
  local label="$1" target="$2"
  ran=$((ran + 1))
  if env -u EVENT_POLL_OWNER_PID \
    PROBE="$T/probe.py" TARGET="$target" \
    SOURCE_POLLER="$SOURCE_POLLER" SOURCE_SESSION_START="$SOURCE_SESSION_START" \
    SOURCE_USER_PROMPT="$SOURCE_USER_PROMPT" SOURCE_EVENT="$SOURCE_EVENT" \
    bash -c 'exec -a claude bash -c "WANT_PID=\$\$ python3 \"\$PROBE\" same \"\$TARGET\" \"\$SOURCE_POLLER\" \"\$SOURCE_SESSION_START\" \"\$SOURCE_USER_PROMPT\" \"\$SOURCE_EVENT\"; exit \$?"'; then
    printf 'ok   %s\n' "$label"
    passed=$((passed + 1))
  else
    printf 'FAIL %s\n' "$label"
  fi
}
selected() {
  [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]
}

selected npm-poller && run_node_case npm-poller poller same
selected npm-session-start && run_node_case npm-session-start session_start same
selected npm-user-prompt && run_node_case npm-user-prompt user_prompt same
selected npm-event && run_node_case npm-event event same
selected npm-nodejs-poller && run_node_case npm-nodejs-poller poller same
selected ccr-poller && run_node_case ccr-poller poller different
if [ -z "$ONLY" ]; then
  run_node_case ccr-session-start session_start different
  run_node_case ccr-user-prompt user_prompt different
  run_node_case ccr-event event different
  run_native_case native-poller poller
  run_native_case native-session-start session_start
  run_native_case native-user-prompt user_prompt
  run_native_case native-event event
fi

printf 'PASS %d/%d\n' "$passed" "$ran"
[ "$passed" -eq "$ran" ]

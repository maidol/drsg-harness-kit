#!/usr/bin/env bash
# Contract tests for the interactive Claude Event-lane picker.
set -u
unset DRSG_EVENT_LANES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICKER="${PICKER:-$HERE/../tools/claude-model-picker.sh}"
T="$(mktemp -d)"
HOLDER=
cleanup() {
  [ -n "$HOLDER" ] && kill "$HOLDER" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/bin" "$T/home" "$T/project/.drsg"
cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'ARGS:'
printf ' <%s>' "$@"
printf '\nLANES:'
if [ "${DRSG_EVENT_LANES+x}" = x ]; then
  printf 'set:%s\n' "$DRSG_EVENT_LANES"
else
  printf 'unset\n'
fi
SH
chmod +x "$T/bin/claude"
printf 'alpha\n' > "$T/project/.drsg/lanes"

RAN=0
OK=0
INVOKE_RC=0
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got <%s> want <%s>\n' "$1" "$2" "$3"
  fi
}
# invoke INPUT [ENV=VALUE ...] -- CLAUDE-ARGS...
invoke() {
  local input="$1" picker_path="$PICKER"
  shift
  local -a envs=() args=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    case "$1" in
      PICKER_PATH=*) picker_path="${1#PICKER_PATH=}" ;;
      *) envs+=("$1") ;;
    esac
    shift
  done
  [ "$#" -gt 0 ] && shift
  args=("$@")
  set +e
  printf '%b' "$input" | (
    cd "$T/project" || exit
    env -u DRSG_EVENT_LANES -u CLAUDE_PICK_MODEL -u CLAUDE_PICK_LANES \
      -u CLAUDE_PICK_MODELS PATH="$T/bin:$PATH" HOME="$T/home" \
      DRSG_MEM_DIR="$T/memory" CLAUDE_CONFIG_DIR="$T/config" \
      CLAUDE_PICK_FORCE_TTY=1 CLAUDE_PICK_MODELS='opus sonnet' "${envs[@]}" \
      bash -c '. "$1"; shift; claude "$@"; rc=$?; printf "FUNCTION_RC:%s\\n" "$rc"' \
      _ "$picker_path" "${args[@]}"
  ) >"$T/stdout" 2>"$T/stderr"
  INVOKE_RC=$?
  set -e
}

if [ -n "${ONLY:-}" ]; then
  case "$ONLY" in
    invalid-name)
      invoke 'a b\n1\n' CLAUDE_PICK_MODEL=0 -- --resume mutant-invalid
      check "invalid lane is rejected before invoking claude" "$(grep -c 'lane names must match' "$T/stderr" || true) $(grep -c '^LANES:set:alpha$' "$T/stdout" || true)" '1 1'
      ;;
    inherited-empty-lanes)
      invoke '\n' DRSG_EVENT_LANES= CLAUDE_PICK_MODEL=0 -- --resume mutant-inherited
      check "empty inherited lanes bypasses menu and stays empty" "$(grep -c 'Event lane' "$T/stderr" || true) $(grep -c '^LANES:set:$' "$T/stdout" || true)" '0 1'
      ;;
    child-only-lanes)
      set +e
      printf '1\n' | (
        cd "$T/project" || exit
        env -u DRSG_EVENT_LANES PATH="$T/bin:$PATH" HOME="$T/home" \
          DRSG_MEM_DIR="$T/memory" CLAUDE_CONFIG_DIR="$T/config" \
          CLAUDE_PICK_FORCE_TTY=1 CLAUDE_PICK_MODEL=0 \
          bash -c '. "$1"; unset DRSG_EVENT_LANES; claude --resume mutant-child; rc=$?; if [ "${DRSG_EVENT_LANES+x}" = x ]; then printf "PARENT:set:%s\\n" "$DRSG_EVENT_LANES"; else printf "PARENT:unset\\n"; fi; printf "FUNCTION_RC:%s\\n" "$rc"' _ "$PICKER"
      ) >"$T/stdout" 2>"$T/stderr"
      set -e
      check "selected lane remains child-only" "$(<"$T/stdout")" $'ARGS: <--resume> <mutant-child>\nLANES:set:alpha\nPARENT:unset\nFUNCTION_RC:0'
      ;;
    *)
      printf 'unknown ONLY case: %s\\n' "$ONLY" >&2
      exit 2
      ;;
  esac
  printf 'PASS %s/%s\n' "$OK" "$RAN"
  [ "$RAN" -eq "$OK" ]
  exit $?
fi

# The two pickers run in order; the selected lane is scoped to the child.
invoke '1\n1\n' -- --resume session-1
check "model then lane selection starts claude" "$INVOKE_RC" 0
check "model and lane argv plus lane env" "$(<"$T/stdout")" $'ARGS: <--model> <opus> <--resume> <session-1>\nLANES:set:alpha\nFUNCTION_RC:0'
check "both menu prompts use stderr" "$(grep -c 'Model for this session' "$T/stderr") $(grep -c 'Event lane' "$T/stderr")" "1 1"

# The model and lane menus are independent; explicit --model only skips model selection.
invoke '1\n' CLAUDE_PICK_MODEL=0 -- --resume session-2
check "model menu disabled still offers lane menu" "$(<"$T/stdout")" $'ARGS: <--resume> <session-2>\nLANES:set:alpha\nFUNCTION_RC:0'
check "model menu disabled shows no model prompt" "$(grep -c 'Model for this session' "$T/stderr" || true)" 0
invoke '1\n' -- --model haiku -c
check "explicit --model still allows lane selection" "$(<"$T/stdout")" $'ARGS: <--model> <haiku> <-c>\nLANES:set:alpha\nFUNCTION_RC:0'

# Default selection does not add DRSG_EVENT_LANES to the child environment.
invoke '\n\n' -- --resume session-3
check "Enter in both menus keeps defaults" "$(<"$T/stdout")" $'ARGS: <--resume> <session-3>\nLANES:unset\nFUNCTION_RC:0'
check "default lane selection is an empty stdout result" "$(cat "$T/stdout" | grep -c '^LANES:unset$')" 1

# An inherited empty lane value suppresses the picker and remains present.
invoke '\n' DRSG_EVENT_LANES= CLAUDE_PICK_MODEL=0 -- --resume session-4
check "inherited empty lanes bypasses menu and is preserved" "$(<"$T/stdout")" $'ARGS: <--resume> <session-4>\nLANES:set:\nFUNCTION_RC:0'
check "inherited empty lanes shows no lane menu" "$(grep -c 'Event lane' "$T/stderr" || true)" 0
invoke '\n' DRSG_EVENT_LANES=preconfigured CLAUDE_PICK_MODEL=0 -- --resume session-4b
check "inherited nonempty lanes bypasses menu and is preserved" "$(<"$T/stdout")" $'ARGS: <--resume> <session-4b>\nLANES:set:preconfigured\nFUNCTION_RC:0'

# Projects without the opt-in marker and non-session commands never show a lane menu.
rm "$T/project/.drsg/lanes"
invoke '' CLAUDE_PICK_MODEL=0 -- --resume session-5
check "project without lane marker skips lane menu" "$(<"$T/stdout")" $'ARGS: <--resume> <session-5>\nLANES:unset\nFUNCTION_RC:0'
check "project without marker shows no lane prompt" "$(grep -c 'Event lane' "$T/stderr" || true)" 0
: > "$T/project/.drsg/lanes"
invoke '' CLAUDE_PICK_MODEL=0 -- mcp list
check "subcommand bypasses both menus" "$(<"$T/stdout")" $'ARGS: <mcp> <list>\nLANES:unset\nFUNCTION_RC:0'
check "subcommand bypass shows no picker prompt" "$(wc -l < "$T/stderr")" 0
invoke '\n' CLAUDE_PICK_MODEL=0 -- --resume empty-config
check "empty opt-in file allows choosing the default lane" "$(<"$T/stdout")" $'ARGS: <--resume> <empty-config>\nLANES:unset\nFUNCTION_RC:0'
printf 'bad lane\n' > "$T/project/.drsg/lanes"
invoke '\n' CLAUDE_PICK_MODEL=0 -- --resume invalid-config
check "invalid configured lane blocks startup" "$(<"$T/stdout")" 'FUNCTION_RC:1'
check "invalid config error includes cause and bypass" "$(grep -c 'lane picker: invalid lane name' "$T/stderr") $(grep -c 'CLAUDE_PICK_LANES=0 to bypass' "$T/stderr")" '1 1'
printf 'alpha\n' > "$T/project/.drsg/lanes"

# Lane-menu opt-out, cancellation, selection validation, and multiple selection.
invoke '\n' CLAUDE_PICK_MODEL=0 CLAUDE_PICK_LANES=0 -- --resume session-6
check "lane menu can be disabled independently" "$(<"$T/stdout")" $'ARGS: <--resume> <session-6>\nLANES:unset\nFUNCTION_RC:0'
check "disabled lane menu shows no prompt" "$(grep -c 'Event lane' "$T/stderr" || true)" 0
invoke '' -- --resume session-7
check "model menu EOF cancels before lane prompt" "$(<"$T/stdout")" 'FUNCTION_RC:130'
check "model menu EOF does not show lane prompt" "$(grep -c 'Event lane' "$T/stderr" || true)" 0
invoke '' CLAUDE_PICK_MODEL=0 -- --resume session-8
check "lane menu EOF cancels without starting claude" "$(<"$T/stdout")" 'FUNCTION_RC:130'
check "lane menu EOF emits no helper error" "$(grep 'lane picker:' "$T/stderr" || true)" ''
invoke 'a b\n1\n' CLAUDE_PICK_MODEL=0 -- --resume session-9
check "invalid direct lane name reprompts" "$(grep -c 'lane names must match' "$T/stderr" || true)" 1
check "invalid direct lane name emits no helper error" "$(grep 'lane picker:' "$T/stderr" || true)" ''
check "invalid direct lane name is not passed through" "$(<"$T/stdout")" $'ARGS: <--resume> <session-9>\nLANES:set:alpha\nFUNCTION_RC:0'
printf 'alpha\nbeta\n' > "$T/project/.drsg/lanes"
invoke '1,2\n' CLAUDE_PICK_MODEL=0 -- --resume session-10
check "comma-separated lane selections reach child" "$(<"$T/stdout")" $'ARGS: <--resume> <session-10>\nLANES:set:alpha,beta\nFUNCTION_RC:0'
invoke 'alpha,beta\n' CLAUDE_PICK_MODEL=0 -- --resume direct-lanes
check "direct comma-separated names reach child" "$(<"$T/stdout")" $'ARGS: <--resume> <direct-lanes>\nLANES:set:alpha,beta\nFUNCTION_RC:0'
printf 'alpha\n' > "$T/project/.drsg/lanes"
invoke 'alpha\n' CLAUDE_PICK_MODEL=0 -- --resume direct-name
check "direct lane name is accepted" "$(<"$T/stdout")" $'ARGS: <--resume> <direct-name>\nLANES:set:alpha\nFUNCTION_RC:0'
printf '10\n' > "$T/project/.drsg/lanes"
invoke '10\n' CLAUDE_PICK_MODEL=0 -- --resume numeric-lane
check "numeric lane name can be typed directly" "$(<"$T/stdout")" $'ARGS: <--resume> <numeric-lane>\nLANES:set:10\nFUNCTION_RC:0'
printf 'alpha\n' > "$T/project/.drsg/lanes"
invoke '1\n' CLAUDE_PICK_MODEL=0 -- --model haiku
check "explicit lane opt-in prompts with model disabled" "$(grep -c 'Event lane' "$T/stderr")" 1

# A lease file contributes a candidate lane even without a config entry.
python3 - "$HERE/../tools/event.py" "$T/project" "$T/memory" <<'PY'
import importlib.util, json, os, sys
path, project, mem = sys.argv[1:]
spec = importlib.util.spec_from_file_location("event_lane_candidate", path)
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
os.environ["DRSG_MEM_DIR"] = mem
state = ev.poller_state(project)
os.makedirs(state, exist_ok=True)
with open(os.path.join(state, "lease.beta.json"), "w", encoding="utf-8") as f:
    json.dump({"session_id": "gone", "pid": 99999999, "start": 1}, f)
PY
invoke '2\n' CLAUDE_PICK_MODEL=0 -- --resume discovered-lane
check "existing lease lane is a candidate" "$(<"$T/stdout")" $'ARGS: <--resume> <discovered-lane>\nLANES:set:beta\nFUNCTION_RC:0'
check "lease-derived candidate is displayed" "$(grep -c '2) beta（空闲可用）' "$T/stderr")" 1
: > "$T/project/.drsg/lanes"
python3 - "$HERE/../tools/event.py" "$T/project" "$T/memory" <<'PY'
import importlib.util, os, sys
path, project, mem = sys.argv[1:]
spec = importlib.util.spec_from_file_location("event_lane_corrupt", path)
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
os.environ["DRSG_MEM_DIR"] = mem
with open(os.path.join(ev.poller_state(project), "lease.beta.json"), "w", encoding="utf-8") as f:
    f.write("{")
PY
invoke '1\n' CLAUDE_PICK_MODEL=0 -- --resume corrupt-lease
check "unreadable lease file follows documented non-fail-closed behavior" "$(<"$T/stdout")" $'ARGS: <--resume> <corrupt-lease>\nLANES:set:beta\nFUNCTION_RC:0'
check "corrupt lease is displayed as available" "$(grep -c '1) beta（空闲可用）' "$T/stderr")" 1
printf 'alpha\n' > "$T/project/.drsg/lanes"

# A live lease is shown using the shared pid/state and transcript-age logic.
sleep 60 &
HOLDER=$!
python3 - "$HERE/../tools/event.py" "$T/project" "$T/memory" "$HOLDER" "$T/config" <<'PY'
import importlib.util, json, os, re, sys, time
path, project, mem, pid, config = sys.argv[1:]
spec = importlib.util.spec_from_file_location("event_lane_fixture", path)
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
os.environ["DRSG_MEM_DIR"] = mem
state = ev.poller_state(project)
os.makedirs(state, exist_ok=True)
proc = ev._proc(int(pid))
with open(os.path.join(state, "lease.alpha.json"), "w", encoding="utf-8") as f:
    json.dump({"session_id": "owner-session", "pid": int(pid), "start": proc[0]}, f)
slug = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(project))
transcripts = os.path.join(config, "projects", slug)
os.makedirs(transcripts, exist_ok=True)
transcript = os.path.join(transcripts, "owner-session.jsonl")
with open(transcript, "w", encoding="utf-8") as f:
    f.write("owner")
os.utime(transcript, (time.time() - 7200, time.time() - 7200))
PY
invoke '1\ny\n' CLAUDE_PICK_MODEL=0 DRSG_MEM_DIR="$T/memory" CLAUDE_CONFIG_DIR="$T/config" -- --resume owner-ok
check "busy lane confirmation permits selected owner lane" "$(<"$T/stdout")" $'ARGS: <--resume> <owner-ok>\nLANES:set:alpha\nFUNCTION_RC:0'
check "busy lane shows session pid and idle hours" "$(grep -c 'alpha（会话 owner-se，pid .*，空闲 2 小时）' "$T/stderr")" 1
check "busy lane prompt says readonly queue and asks confirmation" "$(grep -c '车道 alpha 由会话 owner-se 持有（空闲 2 小时），本会话将只读排队。继续？\[y/N\]' "$T/stderr")" 1
invoke '1\nn\n\n' CLAUDE_PICK_MODEL=0 DRSG_MEM_DIR="$T/memory" CLAUDE_CONFIG_DIR="$T/config" -- --resume owner-decline
check "declining busy lane returns to menu and default" "$(<"$T/stdout")" $'ARGS: <--resume> <owner-decline>\nLANES:unset\nFUNCTION_RC:0'
invoke '1\n' CLAUDE_PICK_MODEL=0 DRSG_MEM_DIR="$T/memory" CLAUDE_CONFIG_DIR="$T/config" -- --resume owner-eof
check "EOF at busy-lane confirmation cancels" "$(<"$T/stdout")" 'FUNCTION_RC:130'
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
HOLDER=

# Every non-session mode bypasses both menus and forwards argv unchanged.
for arg in -p --print -h --help -v --version; do
  invoke '' CLAUDE_PICK_MODEL=0 -- "$arg" sample
  check "$arg bypasses lane menu" "$(grep -c 'Event lane' "$T/stderr" || true) $(grep -c '^FUNCTION_RC:0$' "$T/stdout")" '0 1'
done
invoke '' CLAUDE_PICK_MODEL=0 CLAUDE_PICK_FORCE_TTY=0 -- --resume non-tty
check "non-TTY launch bypasses lane menu" "$(grep -c 'Event lane' "$T/stderr" || true) $(grep -c '^ARGS: <--resume> <non-tty>$' "$T/stdout")" '0 1'

# A missing shared hook template is an error, not an empty/default selection.
mkdir -p "$T/broken-tools"
cp "$PICKER" "$T/broken-tools/claude-model-picker.sh"
cp "$HERE/../tools/claude-lane-picker.py" "$T/broken-tools/claude-lane-picker.py"
cp "$HERE/../tools/claude-model-discovery.py" "$T/broken-tools/claude-model-discovery.py"
cp "$HERE/../tools/event.py" "$T/broken-tools/event.py"
invoke '' PICKER_PATH="$T/broken-tools/claude-model-picker.sh" CLAUDE_PICK_MODEL=0 -- --resume helper-error
check "helper failure does not start claude" "$(<"$T/stdout")" 'FUNCTION_RC:1'
check "helper failure explains cause and explicit bypass" "$(grep -c 'lane picker:.*session_start.py' "$T/stderr") $(grep -c 'CLAUDE_PICK_LANES=0 to bypass' "$T/stderr")" '1 1'

# The shared idle-hour helper keeps the SessionStart text byte-for-byte stable.
set +e
python3 - "$HERE/../tools/templates/hooks/session_start.py" "$T" <<'PY'
import importlib.util, os, sys
from unittest.mock import patch
path, root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("session_start_test", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert hasattr(mod, "_hook_idle_hours"), "_hook_idle_hours is not defined"
project = os.path.join(root, "idle-project")
sid = "session-123"
import re
slug = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(project))
transcripts = os.path.join(root, "claude", "projects", slug)
os.makedirs(transcripts, exist_ok=True)
transcript = os.path.join(transcripts, sid + ".jsonl")
os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(root, "claude")
with open(transcript, "w", encoding="utf-8") as f:
    f.write("test")
lease = {"session_id": sid}
with patch.object(mod.time, "time", return_value=10000):
    os.utime(transcript, (9999, 9999))
    assert mod._hook_idle_hours(project, lease) == 0
    assert mod._hook_idle(project, lease) == ""
    os.utime(transcript, (2799, 2799))
    assert mod._hook_idle_hours(project, lease) == 2
    assert mod._hook_idle(project, lease) == "，已空闲 2 小时"
    os.unlink(transcript)
    assert mod._hook_idle_hours(project, lease) is None
    assert mod._hook_idle(project, lease) == ""
    assert mod._hook_idle_hours(project, {"session_id": "bad/id"}) is None
    assert mod._hook_idle(project, {"session_id": "bad/id"}) == ""
PY
idle_rc=$?
check "shared idle helper returns zero for a recent transcript" "$idle_rc" 0

printf 'PASS %s/%s\n' "$OK" "$RAN"
[ "$RAN" -eq "$OK" ]

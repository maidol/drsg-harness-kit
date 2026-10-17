#!/usr/bin/env bash
# Run one contract case for each lane-picker mutation.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$HERE/../tools"
SCRIPT="$HERE/lane-picker.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  printf 'SURVIVED deliberate self-test\n'
  printf 'MUTATION SURVIVORS: 1/1\n'
  exit 1
fi

ran=0
survivors=0
failures=0
run_mutation() {
  local name="$1" case_name="$2" file="$3" needle="$4" replacement="$5"
  local target="$T/tools/$file"
  rm -rf "$T/tools"
  mkdir -p "$T/tools"
  cp "$TOOLS/claude-model-picker.sh" "$TOOLS/claude-lane-picker.py" "$TOOLS/event.py" \
    "$TOOLS/claude-model-discovery.py" "$TOOLS/drsg_rpc.py" "$T/tools/"
  mkdir -p "$T/tools/templates/hooks"
  cp "$TOOLS/templates/hooks/session_start.py" "$TOOLS/templates/hooks/drsg_hook_common.py" \
    "$T/tools/templates/hooks/"
  local control="$T/$name.control.out" control_rc=0
  if PICKER="$T/tools/claude-model-picker.sh" ONLY="$case_name" bash "$SCRIPT" >"$control" 2>&1; then
    control_rc=0
  else
    control_rc=$?
  fi
  if [ "$control_rc" -ne 0 ] ||
     grep -Eq '^(SKIP|FAIL )|No module named|Traceback' "$control"; then
    failures=$((failures + 1))
    printf 'NOT RUN %s: unmutated paired case did not pass (exit %s)\n' "$name" "$control_rc"
    return
  fi
  if ! python3 - "$target" "$needle" "$replacement" <<'PY'
import sys
path, old, new = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    text = f.read()
count = text.count(old)
if count != 1:
    print("mutation setup failed: expected one target, found %d" % count, file=sys.stderr)
    sys.exit(2)
with open(path, "w", encoding="utf-8") as f:
    f.write(text.replace(old, new, 1))
PY
  then
    failures=$((failures + 1))
    printf 'NOT RUN %s: mutation target unavailable\n' "$name"
    return
  fi
  ran=$((ran + 1))
  if PICKER="$T/tools/claude-model-picker.sh" ONLY="$case_name" bash "$SCRIPT" >"$T/$name.out" 2>&1; then
    survivors=$((survivors + 1))
    printf 'SURVIVED %s\n' "$name"
    python3 - "$T/$name.out" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read(), end="")
PY
  else
    printf 'KILLED %s\n' "$name"
  fi
}

run_mutation invalid-name invalid-name claude-lane-picker.py \
  'if any(not LANE_RE.fullmatch(token) for token in tokens):' \
  'if False:'
run_mutation inherited-empty-lanes inherited-empty-lanes claude-model-picker.sh \
  '[ "${DRSG_EVENT_LANES+x}" = x ] && show_lanes=0' \
  ': # mutation: inherited lane guard removed'
run_mutation child-only-lanes child-only-lanes claude-model-picker.sh \
  'DRSG_EVENT_LANES="$lane_selection" command claude "$@"' \
  'export DRSG_EVENT_LANES="$lane_selection"; command claude "$@"'

if [ "$failures" -gt 0 ] || [ "$ran" -ne 3 ]; then
  printf 'MUTATION RESULT: NOT RUN (%s setup/control failure(s); ran %s/3)\n' "$failures" "$ran"
  exit 2
fi
if [ "$survivors" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED (%s/%s)\n' "$survivors" "$ran"
  exit 1
fi
if MUTATION_SELF_TEST=1 bash "$0" >"$T/self-test.out" 2>&1; then
  printf 'MUTATION SELF-CHECK DID NOT RUN (survivor-path self-test unexpectedly passed)\n'
  exit 2
fi
if ! grep -qx 'SURVIVED deliberate self-test' "$T/self-test.out" || \
   ! grep -qx 'MUTATION SURVIVORS: 1/1' "$T/self-test.out"; then
  printf 'MUTATION SELF-CHECK DID NOT RUN (survivor-path self-test output mismatch)\n'
  exit 2
fi
printf 'SELF-CHECK VERIFIED: a surviving mutant exits nonzero\n'
printf 'ALL KILLED: %s/%s\n' "$ran" "$ran"

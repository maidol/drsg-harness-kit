#!/usr/bin/env bash
# Kill each N5 behavior mutation with only its dedicated integration assertion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SETUP_SOURCE="$REPO/setup.sh"
HOOK_SOURCE="$REPO/tools/templates/hooks/session_start.py"
SETUP_TEST="$HERE/setup-all-projects.sh"
HOOK_TEST="$HERE/session-start-hook-drift.sh"
T="$(mktemp -d)"
LOG_DIR="${N5_MUTATION_LOG_DIR:-$T}"
mkdir -p "$LOG_DIR"
trap 'rm -rf "$T"' EXIT
# Mutants are written into $T; the shared module the hook imports goes with them.
cp "$REPO/tools/templates/hooks/drsg_hook_common.py" "$T/"
KILLED=0
SURVIVED=0
NOT_RUN=0

mutate() {
  local source="$1" target="$2" old="$3" new="$4"
  python3 - "$source" "$target" "$old" "$new" <<'PY'
import sys
source, target, old, new = sys.argv[1:]
text = open(source, encoding="utf-8").read()
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
count = text.count(old)
if count != 1:
    print("mutation setup failed: expected one target, found %d" % count, file=sys.stderr)
    raise SystemExit(2)
with open(target, "w", encoding="utf-8") as out:
    out.write(text.replace(old, new, 1))
PY
}

# Return 0 only when the targeted assertion kills the mutant; survivors return 1,
# and setup/test failures return 2. Each target test's complete output is retained.
run_one() {
  local name="$1" type="$2" case_name="$3" only="$4" source="$5" assertion="$6"
  local out="$LOG_DIR/$name.log" rc=0
  if [ "$type" = setup ]; then
    if CASE="$case_name" ONLY="$only" SETUP_SOURCE="$source" \
        bash "$SETUP_TEST" "$case_name" >"$out" 2>&1; then rc=0; else rc=$?; fi
  else
    if ONLY="$only" SESSION_START_SOURCE="$source" bash "$HOOK_TEST" >"$out" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'MUTATION SURVIVED: %s\n' "$name"
    return 1
  fi
  if grep -Fq "FAIL $assertion" "$out"; then
    printf 'KILLED: %s\n' "$name"
    KILLED=$((KILLED + 1))
    return 0
  fi
  printf 'NOT RUN: %s (target assertion absent)\n' "$name"
  NOT_RUN=$((NOT_RUN + 1))
  return 2
}

run_required() {
  local name="$1" type="$2" case_name="$3" only="$4" source="$5" assertion="$6"
  local rc=0
  if run_one "$name" "$type" "$case_name" "$only" "$source" "$assertion"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ]; then SURVIVED=$((SURVIVED + 1)); fi
}

# The no-.drsg/env skip must be the sole gate preventing a project install.
MUT="$T/setup-no-env.py"
if mutate "$SETUP_SOURCE" "$MUT" \
    'if [ ! -f "$target/.drsg/env" ]; then' \
    'if [ "$target/.drsg/env" = "" ]; then'; then
  run_required skip-no-env-not-installed setup skip-no-env \
    skip-no-env-is-not-installed "$MUT" skip-no-env-is-not-installed
else
  NOT_RUN=$((NOT_RUN + 1)); printf 'NOT RUN: skip-no-env-not-installed (mutation setup failed)\n'
fi

# One install failure must not prevent the next registered project from running.
MUT="$T/failure-continues.py"
if mutate "$SETUP_SOURCE" "$MUT" \
    'FAILED_COUNT=$((FAILED_COUNT + 1))' \
    'FAILED_COUNT=$((FAILED_COUNT + 1))\n      exit 1'; then
  run_required failure-continues setup failure-continues \
    failure-continues-attempts-both-valid-projects "$MUT" \
    failure-continues-attempts-both-valid-projects
else
  NOT_RUN=$((NOT_RUN + 1)); printf 'NOT RUN: failure-continues (mutation setup failed)\n'
fi

# Batch mode must reject a single-project option before any global write.
MUT="$T/mutual-exclusion.py"
if mutate "$SETUP_SOURCE" "$MUT" \
    'if [ "$ALL_PROJECTS" -eq 1 ]; then\n  for option in PROJECT REPO HUB ROUTER USAGE_REPORT; do' \
    'if false; then\n  for option in PROJECT REPO HUB ROUTER USAGE_REPORT; do'; then
  run_required mutual-exclusion setup mutual-exclusion \
    mutual-exclusion-project "$MUT" mutual-exclusion-project
else
  NOT_RUN=$((NOT_RUN + 1)); printf 'NOT RUN: mutual-exclusion (mutation setup failed)\n'
fi

# Identical deployed hooks must not trigger the human-visible refresh prompt.
MUT="$T/hooks-always-alert.py"
if mutate "$HOOK_SOURCE" "$MUT" \
    'if not drifted:\n            return ""' \
    'if False:\n            return ""'; then
  run_required identical-hooks-silent hooks unused \
    identical-hooks-are-silent "$MUT" identical-hooks-are-silent
else
  NOT_RUN=$((NOT_RUN + 1)); printf 'NOT RUN: identical-hooks-silent (mutation setup failed)\n'
fi

# Control mutant: comment-only change survives; verify run_one detects and returns 1.
MUT="$T/control-noop.py"
if mutate "$HOOK_SOURCE" "$MUT" \
    '"""Human-visible refresh command when installed project hooks differ."""' \
    '"""Human-visible refresh command when installed project hooks differ. """'; then
  BEFORE="$KILLED"
  if run_one control-survivor hooks unused identical-hooks-are-silent "$MUT" \
      identical-hooks-are-silent; then
    printf 'NOT RUN: mutation runner failed to detect control survivor\n'
    NOT_RUN=$((NOT_RUN + 1))
  else
    rc=$?
    if [ "$rc" -eq 1 ] && [ "$KILLED" -eq "$BEFORE" ]; then
      printf 'SELF-CHECK VERIFIED: control mutant is reported as surviving\n'
    else
      printf 'NOT RUN: mutation runner control self-check failed\n'
      NOT_RUN=$((NOT_RUN + 1))
    fi
  fi
else
  printf 'NOT RUN: control-survivor (mutation setup failed)\n'
  NOT_RUN=$((NOT_RUN + 1))
fi

if [ "$NOT_RUN" -gt 0 ]; then
  printf 'MUTATION RESULT: NOT RUN\n'
  exit 2
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVOR\n'
  exit 1
fi
if [ "$KILLED" -ne 4 ]; then
  printf 'MUTATION RESULT: NOT RUN\n'
  exit 2
fi
printf 'MUTATION RESULT: ALL KILLED\n'

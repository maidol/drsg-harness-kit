#!/usr/bin/env bash
# Kill each compact-context mutation with only its dedicated assertion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK_SOURCE="$REPO/tools/templates/hooks/session_start.py"
HOOK_TEST="$HERE/session-start-compact-context.sh"
MEM_BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
if [ ! -x "$MEM_BIN" ]; then MEM_BIN="$(command -v drsg || true)"; fi
if [ -z "$MEM_BIN" ] || [ ! -x "$MEM_BIN" ]; then
  echo "SKIP compact-guard-mutations: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi
T="$(mktemp -d)"
LOG_DIR="${COMPACT_GUARD_MUTATION_LOG_DIR:-$T}"
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
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
text = open(source, encoding="utf-8").read()
count = text.count(old)
if count != 1:
    print("mutation setup failed: expected one target, found %d" % count,
          file=sys.stderr)
    raise SystemExit(2)
with open(target, "w", encoding="utf-8") as out:
    out.write(text.replace(old, new, 1))
PY
}

run_one() {
  local name="$1" source="$2" assertion="$3"
  local out="$LOG_DIR/$name.log" rc=0
  if ONLY="$assertion" SESSION_START_SOURCE="$source" \
      DRSG_MEM_BIN="$MEM_BIN" bash "$HOOK_TEST" >"$out" 2>&1; then
    rc=0
  else
    rc=$?
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
  local name="$1" source="$2" assertion="$3" rc=0
  if run_one "$name" "$source" "$assertion"; then
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ]; then SURVIVED=$((SURVIVED + 1)); fi
}

MUT="$T/no-token-injection-removed.py"
if mutate "$HOOK_SOURCE" "$MUT" \
    '    if not token:\n        hook_out(system_message=drift_message or None,\n                 **compact_context_kwargs(source))\n        return' \
    '    if not token:\n        hook_out(system_message=drift_message or None)\n        return'; then
  run_required no-token-injection-removed "$MUT" compact-no-token-context
else
  NOT_RUN=$((NOT_RUN + 1)); printf 'NOT RUN: no-token-injection-removed (mutation setup failed)\n'
fi

MUT="$T/unconditional-injection.py"
if mutate "$HOOK_SOURCE" "$MUT" \
    '    if source != "compact":\n        return existing' \
    '    if False:\n        return existing'; then
  run_required unconditional-injection "$MUT" startup-no-compact-context
else
  NOT_RUN=$((NOT_RUN + 1)); printf 'NOT RUN: unconditional-injection (mutation setup failed)\n'
fi

# A comment-only control mutant must pass its case and be reported as surviving.
MUT="$T/control-noop.py"
if mutate "$HOOK_SOURCE" "$MUT" \
    'def compact_context(source, existing=None):' \
    'def compact_context(source, existing=None):  # control'; then
  BEFORE="$KILLED"
  if run_one control-survivor "$MUT" compact-no-token-context; then
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
if [ "$KILLED" -ne 2 ]; then
  printf 'MUTATION RESULT: NOT RUN\n'
  exit 2
fi
printf 'MUTATION RESULT: ALL KILLED\n'

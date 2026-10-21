#!/usr/bin/env bash
# Each compact-handoff mutation is checked by only its paired assertion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK_SOURCE="$REPO/tools/templates/hooks/compact_handoff.py"
AUDIT_SOURCE="$REPO/tools/audit_deployment.py"
INSTALL_SOURCE="$REPO/tools/install.sh"
T="$(mktemp -d)"
LOG_DIR="${COMPACT_HANDOFF_MUTATION_LOG_DIR:-$T}"
mkdir -p "$LOG_DIR" "$T/install/templates"
trap 'rm -rf "$T"' EXIT
cp "$REPO/tools/templates/compact-instructions.md" "$T/install/templates/compact-instructions.md"
cp "$INSTALL_SOURCE" "$T/install/install.sh"
chmod +x "$T/install/install.sh"

KILLED=0
SURVIVED=0
NOT_RUN=0

mutate() {
  local source="$1" target="$2" old="$3" new="$4"
  python3 - "$source" "$target" "$old" "$new" <<'PY'
import sys
source, target, old, new = sys.argv[1:]
old = old.replace("\\\\n", "\n").replace("\\n", "\n")
new = new.replace("\\\\n", "\n").replace("\\n", "\n")
text = open(source, encoding="utf-8").read()
count = text.count(old)
if count != 1:
    print("mutation setup failed: expected one target, found %d" % count, file=sys.stderr)
    raise SystemExit(2)
with open(target, "w", encoding="utf-8") as stream:
    stream.write(text.replace(old, new, 1))
PY
}

run_case() {
  local suite="$1" assertion="$2" source="$3" log="$4" rc=0
  case "$suite" in
    handoff)
      COMPACT_HANDOFF_SOURCE="$source" ONLY="$assertion" \
        bash "$HERE/compact-handoff.sh" > "$log" 2>&1 || rc=$?
      ;;
    expiry)
      COMPACT_HANDOFF_SOURCE="$source" bash "$HERE/compact-handoff-expiry.sh" > "$log" 2>&1 || rc=$?
      ;;
    audit)
      AUDIT_SOURCE="$source" ONLY="$assertion" \
        bash "$HERE/audit-deployment.sh" > "$log" 2>&1 || rc=$?
      ;;
    install)
      COMPACT_INSTALL_SOURCE="$source" ONLY="$assertion" \
        bash "$HERE/compact-instructions.sh" > "$log" 2>&1 || rc=$?
      ;;
  esac
  return "$rc"
}

run_mutation() {
  local name="$1" suite="$2" assertion="$3" source="$4" old="$5" new="$6"
  local target="$T/$name.py" base_log="$LOG_DIR/$name.baseline.log"
  local mutant_log="$LOG_DIR/$name.mutant.log" base_rc=0 mutant_rc=0
  if [ "$suite" = handoff ]; then
    target="$(dirname "$source")/$name-mutant.py"
  elif [ "$suite" = install ]; then
    target="$T/install/$name-mutant.sh"
  fi
  baseline_source="$source"
  if [ "$suite" = handoff ]; then baseline_source="$HOOK_SOURCE"; fi
  if run_case "$suite" "$assertion" "$baseline_source" "$base_log"; then
    base_rc=0
  else
    base_rc=$?
  fi
  if [ "$base_rc" -ne 0 ] || ! grep -Fq "ok   $assertion" "$base_log"; then
    printf 'NOT RUN: %s (paired assertion did not pass before mutation)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! mutate "$source" "$target" "$old" "$new"; then
    printf 'NOT RUN: %s (mutation target not unique)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if run_case "$suite" "$assertion" "$target" "$mutant_log"; then
    mutant_rc=0
  else
    mutant_rc=$?
  fi
  if [ "$mutant_rc" -eq 0 ]; then
    printf 'SURVIVED: %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  elif grep -Fq "FAIL $assertion" "$mutant_log"; then
    printf 'KILLED: %s\n' "$name"
    KILLED=$((KILLED + 1))
  else
    printf 'NOT RUN: %s (paired assertion was not the failure)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
  fi
}

copy_hook_tree() {
  local name="$1" dir="$T/hooks-$1"
  mkdir -p "$dir"
  cp "$REPO/tools/templates/hooks/"*.py "$dir/"
  printf '%s\n' "$dir/compact_handoff.py"
}

MUT="$(copy_hook_tree consumed)"
run_mutation consumed handoff "successful output consumes record once" "$MUT" \
  'current["consumed"] = True' 'current["consumed"] = False'

MUT="$(copy_hook_tree expiry)"
run_mutation expiry expiry "expired record cleanup prunes file" "$MUT" \
  '            if now - float(record.get("created_at_epoch", 0)) > ttl_seconds():' \
  '            if now - float(record.get("created_at_epoch", 0)) < ttl_seconds():'

MUT="$(copy_hook_tree source-filter)"
run_mutation source-filter handoff "resume does not read or consume handoff" "$MUT" \
  'if source not in ("startup", "clear") or os.environ.get("DRSG_COMPACT_HANDOFF", "1") != "1":' \
  'if source not in ("startup", "clear", "resume") or os.environ.get("DRSG_COMPACT_HANDOFF", "1") != "1":'

MUT="$(copy_hook_tree redaction)"
run_mutation redaction handoff "safe_summary redacts before persistence" "$MUT" \
  '    if redact is None:\\n        raise RuntimeError("secret redactor unavailable")\\n    return redact(value)[0]' \
  '    if redact is None:\\n        raise RuntimeError("secret redactor unavailable")\\n    return value'

MUT="$(copy_hook_tree output-cap)"
run_mutation output-cap handoff "rendered handoff is capped at 8,000 with truncation marker" "$MUT" \
  '    if len(selected) > available:' '    if len(selected) > available and False:'

MUT="$(copy_hook_tree daemon-project-dependency)"
run_mutation daemon-project-dependency handoff "tokenless SessionStart injects handoff" "$MUT" \
  '    if source not in ("startup", "clear") or os.environ.get("DRSG_COMPACT_HANDOFF", "1") != "1":' \
  '    if source not in ("startup", "clear") or not os.environ.get("DRSG_TOKEN") or os.environ.get("DRSG_COMPACT_HANDOFF", "1") != "1":'

MUT="$(copy_hook_tree mtime-threshold)"
run_mutation mtime-threshold handoff "late transcript mtime adds D2 notice without reading content" "$MUT" \
  '        if age > 600:' '        if age > 6000:'

MUT="$T/audit-clear-matcher.py"
run_mutation clear-matcher audit "old SessionStart matcher is audit drift" "$AUDIT_SOURCE" \
  '            session_start = hooks.get("SessionStart") or []\\n            if not any("clear" in str(group.get("matcher", "")).split("|")\\n                       for group in session_start):' \
  '            session_start = hooks.get("SessionStart") or []\\n            if False:'

MUT="$T/install-tracked-warning.py"
run_mutation tracked-setup-warning install "tracked CLAUDE.md setup warns and still succeeds" "$INSTALL_SOURCE" \
  '    print("   NOTE: 这一段会出现在 git diff 里，需要你自己决定要不要提交。")' '    pass'

MUT="$T/audit-tracked-warning.py"
run_mutation tracked-audit-warning audit "tracked CLAUDE.md advisory does not fail audit" "$AUDIT_SOURCE" \
  'Advisory: CLAUDE.md is tracked; 这一段会出现在 git diff 里，需要你自己决定要不要提交。' \
  'Advisory: CLAUDE.md is tracked; warning omitted.'

# A no-op mutant must pass its paired test and be explicitly reported as surviving.
MUT="$(copy_hook_tree control-survivor)"
BASE="$LOG_DIR/control-survivor.baseline.log"
OUT="$LOG_DIR/control-survivor.mutant.log"
if run_case handoff "successful output consumes record once" "$MUT" "$BASE" &&
   grep -Fq 'ok   successful output consumes record once' "$BASE" &&
   mutate "$MUT" "$(dirname "$MUT")/control-survivor.py" 'def safe_summary(value):' \
     'def safe_summary(value):  # control'; then
  if run_case handoff "successful output consumes record once" "$(dirname "$MUT")/control-survivor.py" "$OUT"; then
    printf 'SELF-CHECK VERIFIED: control mutant survived its paired assertion\n'
  else
    rc=$?
    if grep -Fq 'FAIL successful output consumes record once' "$OUT"; then
      printf 'NOT RUN: control mutant was killed instead of surviving\n'
      NOT_RUN=$((NOT_RUN + 1))
    else
      printf 'NOT RUN: control mutant test did not reach its paired assertion (exit %s)\n' "$rc"
      NOT_RUN=$((NOT_RUN + 1))
    fi
  fi
else
  printf 'NOT RUN: control mutant baseline or mutation setup failed\n'
  NOT_RUN=$((NOT_RUN + 1))
fi

if [ "$NOT_RUN" -gt 0 ]; then
  printf 'MUTATION RESULT: NOT RUN (%d)\n' "$NOT_RUN"
  exit 2
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
if [ "$KILLED" -ne 10 ]; then
  printf 'MUTATION RESULT: NOT RUN (killed %d/10)\n' "$KILLED"
  exit 2
fi
printf 'MUTATION RESULT: ALL KILLED (%d)\n' "$KILLED"

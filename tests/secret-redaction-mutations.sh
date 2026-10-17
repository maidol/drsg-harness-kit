#!/usr/bin/env bash
# Targeted mutations for the assignment-name and mixed-value false-positive gates.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SOURCE="$REPO/tools/templates/hooks/secret_redact.py"
TEST="$HERE/secret-redaction-shapes.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0

run_mutation() {
  local name="$1" only="$2" variant="$3" copy="$T/$1.py"
  if ! cp "$SOURCE" "$copy"; then
    printf 'NOT RUN %s (source copy failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  local control="$T/$name.control.out" control_rc=0
  ONLY="$only" REDACTOR="$copy" bash "$TEST" >"$control" 2>&1 || control_rc=$?
  if [ "$control_rc" -ne 0 ] ||
     grep -Eq '^(SKIP|FAIL )|No module named|Traceback' "$control"; then
    printf 'NOT RUN %s (unmutated paired case did not pass; exit %s)\n' "$name" "$control_rc"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! cp "$SOURCE" "$copy"; then
    printf 'NOT RUN %s (source copy failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! python3 - "$SOURCE" "$copy" "$variant" <<'PY'
import sys
source_path, output_path, variant = sys.argv[1:]
text = open(source_path, encoding="utf-8").read()
if variant == "drop-name-segments":
    old, new = "(?:_[A-Za-z0-9]+)*", ""
elif variant == "drop-mixed-value-gate":
    old = r'''(?=[^\s\"',;]*\d)(?=[^\s\"',;]*[A-Za-z])'''
    new = ""
elif variant == "no-op":
    old, new = "# A value must mix letters and digits:", "# A value must mix letters and digits: "
else:
    raise SystemExit("unknown mutation")
if text.count(old) != 1:
    raise SystemExit("mutation target not unique")
with open(output_path, "w", encoding="utf-8") as out:
    out.write(text.replace(old, new))
PY
  then
    printf 'NOT RUN %s (mutation setup failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi

  printf '\n== %s: ONLY=%s ==\n' "$name" "$only"
  if ONLY="$only" REDACTOR="$copy" bash "$TEST"; then
    printf 'SURVIVED %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  else
    printf 'killed %s\n' "$name"
    KILLED=$((KILLED + 1))
  fi
}

run_mutation assignment-name-segments aws-assignment drop-name-segments
run_mutation assignment-mixed-value keep-01 drop-mixed-value-gate
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop aws-assignment no-op
fi

if [ "$NOT_RUN" -gt 0 ] || [ "$KILLED" -ne 2 ]; then
  printf 'MUTATION RESULT: NOT RUN (%d; killed %d/2)\n' "$NOT_RUN" "$KILLED"
  exit 2
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
printf 'MUTATION RESULT: ALL KILLED (%d)\n' "$KILLED"

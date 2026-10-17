#!/usr/bin/env bash
# Isolated mutation checks for the extra-tab hint in single-tool-streak.py.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tests" "$T/tools"
cp "$HERE/single-tool-streak.sh" "$T/tests/single-tool-streak.sh"
cp "$HERE/../tools/single-tool-streak.py" "$T/tools/single-tool-streak.py"

run_case() {
  local case="$1" hook="$2" out="$3"
  if [ "$hook" != "$T/tools/single-tool-streak.py" ]; then
    cp "$hook" "$T/tools/single-tool-streak.py"
  fi
  EXTRA_ONLY="$case" bash "$T/tests/single-tool-streak.sh" >"$out" 2>&1
}

if [ "${MUTATION_SENTINEL:-}" = "1" ]; then
  if run_case hit-go "$HERE/../tools/single-tool-streak.py" "$T/sentinel.out"; then
    printf 'MUTATION RESULT: SURVIVED\n'
    exit 1
  fi
  printf 'MUTATION RESULT: ALL KILLED\n'
  exit 0
fi

cases=(multiple repaired-edit combined hit-makefile found-matches independent)
for case in "${cases[@]}"; do
  if ! run_case "$case" "$HERE/../tools/single-tool-streak.py" "$T/control.out"; then
    printf 'unmutated paired case failed: %s\n' "$case"
    printf 'MUTATION RESULT: NOT RUN\n'
    exit 2
  fi
  printf 'PASS unmutated control: %s\n' "$case"
done

apply_mutation() {
  local mutant="$1" source="$T/tools/single-tool-streak.py"
  cp "$HERE/../tools/single-tool-streak.py" "$source"
  MUTANT="$mutant" python3 - "$source" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
mutants = {
    "exactly-one": (
        '    if current.count(normalized) != 1:\n',
        '    if current.count(normalized) == 0:\n',
    ),
    "superseded": (
        '    failed_order = failed["result_order"]\n'
        '    for call in calls:\n'
        '        tool_input = call["input"]\n'
        '        if (call["name"] in ("Edit", "Write")\n'
        '                and call["use_order"] > failed_order\n'
        '                and call["result_order"] is not None\n'
        '                and call["is_error"] is not True\n'
        '                and isinstance(tool_input, dict)\n'
        '                and tool_input.get("file_path") == target):\n'
        '            return ""\n',
        '    failed_order = failed["result_order"]\n',
    ),
    "dedup": (
        '    if not isinstance(hinted, list) or failed["id"] in hinted:\n',
        '    if not isinstance(hinted, list):\n',
    ),
    "go-only": (
        '    with open(target, "rb") as fh:\n',
        '    if not target.endswith(".go"):\n'
        '        return ""\n'
        '    with open(target, "rb") as fh:\n',
    ),
    "error-text": (
        '    if "String to replace not found" not in failed["result_text"]:\n'
        '        return ""\n',
        '',
    ),
    "streak-order": (
        '    try:\n'
        '        extra_hint = extra_tab_hint(calls, session_id)\n'
        '    except Exception:\n'
        '        extra_hint = ""\n',
        '    try:\n'
        '        extra_hint = (\n'
        '            extra_tab_hint(calls, session_id) if len(messages) >= 3 else ""\n'
        '        )\n'
        '    except Exception:\n'
        '        extra_hint = ""\n',
    ),
}
old, new = mutants[os.environ["MUTANT"]]
if source.count(old) != 1:
    raise SystemExit(f"mutation anchor count {source.count(old)} for {os.environ['MUTANT']}")
path.write_text(source.replace(old, new, 1), encoding="utf-8")
PY
}

mutants=(exactly-one superseded dedup go-only error-text streak-order)
pairs=(multiple repaired-edit combined hit-makefile found-matches independent)
killed=0
survived=0
for i in "${!mutants[@]}"; do
  mutant="${mutants[$i]}"
  case="${pairs[$i]}"
  if ! apply_mutation "$mutant" || ! python3 -m py_compile "$T/tools/single-tool-streak.py"; then
    printf 'mutation setup failed: %s\n' "$mutant"
    printf 'MUTATION RESULT: NOT RUN\n'
    exit 2
  fi
  if run_case "$case" "$T/tools/single-tool-streak.py" "$T/mutant.out"; then
    printf 'SURVIVED mutant: %s (paired case %s)\n' "$mutant" "$case"
    survived=$((survived + 1))
  else
    printf 'KILLED mutant: %s (paired case %s)\n' "$mutant" "$case"
    killed=$((killed + 1))
  fi
done

set +e
MUTATION_SENTINEL=1 bash "$0" >"$T/sentinel.out" 2>&1
sentinel_rc=$?
set -e
sentinel_result="$(python3 - "$T/sentinel.out" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
print(lines[-1] if lines else "")
PY
)"
if [ "$sentinel_rc" -ne 1 ] || [ "$sentinel_result" != "MUTATION RESULT: SURVIVED" ]; then
  printf 'survivor sentinel self-check failed (exit %s, result %s)\n' "$sentinel_rc" "$sentinel_result"
  printf 'MUTATION RESULT: NOT RUN\n'
  exit 2
fi
printf 'PASS survivor sentinel reports SURVIVED and exits 1\n'

if [ "$survived" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED\n'
  exit 1
fi
if [ "$killed" -ne "${#mutants[@]}" ]; then
  printf 'MUTATION RESULT: NOT RUN\n'
  exit 2
fi
printf 'MUTATION RESULT: ALL KILLED\n'

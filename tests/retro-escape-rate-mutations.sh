#!/usr/bin/env bash
# Verify the escape-rate contract tests kill focused implementation mutants.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SOURCE="$REPO/skills/agent-efficiency-retro/retro.py"
TEST="$HERE/retro-escape-rate.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

replace_once() {
  python3 - "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys

path, old, new = sys.argv[1:]
old = old.replace(r"\n", "\n")
new = new.replace(r"\n", "\n")
source = Path(path).read_text(encoding="utf-8")
if source.count(old) != 1:
    raise SystemExit(f"expected one mutation anchor, found {source.count(old)}: {old!r}")
Path(path).write_text(source.replace(old, new), encoding="utf-8")
PY
}

run_case() {
  local name="$1" case_id="$2"
  local output="$T/$name.out" rc
  set +e
  RETRO_SCRIPT="$T/retro.py" ONLY_CASE="$case_id" bash "$TEST" >"$output" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'SURVIVED %s (case %s)\n' "$name" "$case_id"
    return 1
  fi
  if ! grep -q "^FAIL case $case_id:" "$output" || grep -q 'Traceback' "$output"; then
    printf 'NOT KILLED AS EXPECTED %s (case %s)\n' "$name" "$case_id"
    cat "$output"
    return 2
  fi
  printf 'killed %s by case %s\n' "$name" "$case_id"
}

survived=0
failed=0

make_mutant() {
  cp "$SOURCE" "$T/retro.py"
}

make_mutant
replace_once "$T/retro.py" "ESCAPE_RE = re.compile(r'^验收逃逸：')" "ESCAPE_RE = re.compile(r'验收逃逸：')"
replace_once "$T/retro.py" "ESCAPE_RE.match(summary)" "ESCAPE_RE.search(summary)"
run_case M1-prime 5 || { rc=$?; [ "$rc" -eq 1 ] && survived=1 || failed=1; }

make_mutant
old='m = len(origin_ids) + unknown_count'
new='m = n'
if [ "${M2_NOOP:-0}" = 1 ]; then
  new="$old"
fi
replace_once "$T/retro.py" "$old" "$new"
run_case M2 4 || { rc=$?; [ "$rc" -eq 1 ] && survived=1 || failed=1; }

make_mutant
replace_once "$T/retro.py" "    if not escapes:\n        print('验收逃逸：0（只认「验收逃逸：」前缀；窗口内没有标注）')\n        return\n" ""
run_case M3 2 || { rc=$?; [ "$rc" -eq 1 ] && survived=1 || failed=1; }

if [ "$failed" -ne 0 ]; then
  printf '没跑起来\n'
  exit 2
fi
if [ "$survived" -ne 0 ]; then
  printf '有存活\n'
  exit 1
fi
printf '全部杀死\n'

#!/usr/bin/env bash
# Paired mutations for the cross-project document gates.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../tools/check-docs.py"
CONTRACT="$HERE/check-docs-coverage.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mutate() {
  local name="$1" old="$2" new="$3"
  local output="$T/$name/check-docs.py"
  mkdir -p "$(dirname "$output")"
  python3 - "$SOURCE" "$output" "$old" "$new" <<'PY' || return $?
import pathlib, sys
source, target, old, new = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
if text.count(old) != 1:
    raise SystemExit("mutation anchor must occur exactly once")
pathlib.Path(target).write_text(text.replace(old, new), encoding="utf-8")
PY
  printf '%s\n' "$output"
}

assert_killed() {
  local name="$1" anchor="$2" checker="$3" rc=0
  local out="$T/$name.out"
  if CHECK_DOCS_SOURCE="$checker" bash "$CONTRACT" >"$out" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ] || ! grep -Fq "FAIL $anchor:" "$out"; then
    printf 'FAIL mutant %s was not killed by %s\n' "$name" "$anchor"
    return 1
  fi
  printf 'killed %s by %s\n' "$name" "$anchor"
}

if [ "${1:-}" = "--self-check-survivor" ]; then
  survivor="$(mutate survivor \
    'Every check here is one finding that a reader actually hit:' \
    'Every check here is one finding that a reader actually hit: harmless control mutation')"
  if CHECK_DOCS_SOURCE="$survivor" bash "$CONTRACT" >"$T/survivor.out" 2>&1; then
    printf 'MUTATION RESULT: SURVIVED (self-check control mutant)\n'
    exit 1
  fi
  printf 'FAIL self-check control mutant was unexpectedly killed\n'
  exit 1
fi

if ! CHECK_DOCS_SOURCE="$SOURCE" bash "$CONTRACT" >"$T/baseline.out" 2>&1; then
  printf 'FAIL unmutated documentation contract suite\n'
  python3 - "$T/baseline.out" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), end="")
PY
  exit 1
fi

assert_killed token_limit cross_project_5001_diagnostic_names_file_and_limit "$(mutate token_limit \
  'if estimated > CROSS_PROJECT_TOKEN_LIMIT:' \
  'if estimated > CROSS_PROJECT_TOKEN_LIMIT + 1:')"
assert_killed required_path cross_project_missing_diagnostic_names_fixed_path "$(mutate required_path \
  'if not os.path.isfile(path):' \
  'if False and not os.path.isfile(path):')"
assert_killed sentence_subset cross_project_non_subset_sentence_fails "$(mutate sentence_subset \
  'if unit not in full_units and unit not in BRIDGE_SENTENCES]' \
  'if False and unit not in full_units and unit not in BRIDGE_SENTENCES]')"

printf 'MUTATION RESULT: ALL KILLED: 3/3\n'

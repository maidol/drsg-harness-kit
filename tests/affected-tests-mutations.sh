#!/usr/bin/env bash
# Mutation self-check for tools/affected-tests.py. Each mutant removes one gate
# and runs only the case that gate alone decides; the paired case is first run
# on the unmutated copy and must pass, otherwise the result is NOT RUN.
# Last line: MUTATION RESULT: ALL KILLED (exit 0) / SURVIVED (1) / NOT RUN (2).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tools"
SRC="$HERE/../tools/affected-tests.py"

run_case() {  # case tool out
  ONLY="$1" AT_TOOL="$2" bash "$HERE/affected-tests.sh" >"$3" 2>&1
}

if [ "${MUTATION_SENTINEL:-}" = "1" ]; then
  # A "mutant" that changes nothing must be reported as surviving.
  if run_case py-graph "$SRC" "$T/sentinel.out"; then
    printf 'MUTATION RESULT: SURVIVED\n'
    exit 1
  fi
  printf 'MUTATION RESULT: ALL KILLED\n'
  exit 0
fi

mutants=(go-deps graph-callers graph-error stale-node conftest unknown-file
         shell-import reaches-no-test module-level blank-lines unmodeled
         go-tags nested rs-cross-workspace rs-nested-fold rs-cargo-lock-full
         rs-exclude rs-no-cargo rs-unconditional-cargo)
pairs=(go-dependents py-graph py-graph-down py-graph-missing py-conftest py-unknown
       sh-import py-untested py-module-level py-untested py-unmodeled
       go-tags py-nested rs-dependents-cross-workspace rs-ownership-nested-workspace
       rs-cargo-lock-workspace rs-args-exclude rs-no-cargo rs-no-cargo-irrelevant)

if ! command -v go >/dev/null 2>&1; then
  printf 'no go toolchain: the go-deps and go-tags mutants cannot run\n'
  printf 'MUTATION RESULT: NOT RUN\n'
  exit 2
fi

for case in $(printf '%s\n' "${pairs[@]}" | sort -u); do
  if ! run_case "$case" "$SRC" "$T/control.out"; then
    printf 'unmutated paired case failed: %s\n' "$case"
    cat "$T/control.out"
    printf 'MUTATION RESULT: NOT RUN\n'
    exit 2
  fi
  printf 'PASS unmutated control: %s\n' "$case"
done

apply_mutation() {  # mutant -> $T/tools/affected-tests.py
  MUTANT="$1" python3 - "$SRC" "$T/tools/affected-tests.py" <<'PY'
import os
import sys

source = open(sys.argv[1], encoding="utf-8").read()
mutants = {
    "go-deps": (
        "            hit = changed & (deps | {pkg})\n",
        "            hit = changed & {pkg}\n"),
    "graph-callers": (
        "                for tkey, tfile in graph.callers(key):\n",
        "                for tkey, tfile in []:\n"),
    "graph-error": (
        '        reasons.append("code graph unavailable: %s" % e)\n',
        "        pass\n"),
    "stale-node": (
        "                    if s in base_syms:\n",
        "                    if False:\n"),
    "conftest": (
        '    "conftest.py", ',
        "    "),
    "unknown-file": (
        '            out["full"].append("no rule covers %s" % path)\n',
        "            pass\n"),
    "shell-import": (
        '        for f in importers.get(os.path.basename(p)[:-3], ()):\n',
        "        for f in ():\n"),
    "reaches-no-test": (
        '    if code and not picked and not out["full"]:\n',
        "    if False:\n"),
    "module-level": (
        '                syms |= all_symbols(new_src if new_src is not None else old_src or "")\n',
        "                pass\n"),
    "blank-lines": (
        "        elif 0 < line <= len(text) and text[line - 1].strip() and \\\n"
        '                not text[line - 1].strip().startswith("#"):\n',
        "        else:\n"),
    "unmodeled": (
        '            out["full"].append("the code graph has no definitions for %s" % path)\n',
        "            pass\n"),
    "go-tags": (
        '    return os.path.basename(path) in proc.stdout.split("\\n")\n',
        "    return False\n"),
    "nested": (
        "                if isinstance(child, ast.ClassDef):\n"
        "                    walk(child, name)\n",
        "                walk(child, name)\n"),
    "rs-cross-workspace": (
        "            if target:\n                dependents.setdefault(target, set()).add(manifest)\n",
        "            if target and packages[target][0] == ws_root:\n                dependents.setdefault(target, set()).add(manifest)\n"),
    "rs-nested-fold": (
        "        return max(outer, key=lambda m: len(os.path.dirname(m))) if outer else deepest\n",
        "        return deepest\n"),
    "rs-cargo-lock-full": (
        "            if ws_root:\n                seeds.update(workspace_members[ws_root])\n            continue\n",
        "            reasons.append(\"Cargo.lock changed (dependency or test setup)\")\n            continue\n"),
    "rs-exclude": (
        "        if matches(crate_dir, excludes):\n",
        "        if False:\n"),
    "rs-no-cargo": (
        "        reasons.append(\"cargo is unavailable for Rust/Cargo changes\")\n",
        "        pass\n"),
    "rs-unconditional-cargo": (
        "    if not relevant:\n        return handled, reasons\n",
        "    if False:\n        return handled, reasons\n"),
}
old, new = mutants[os.environ["MUTANT"]]
if source.count(old) != 1:
    raise SystemExit("mutation anchor found %d times for %s"
                     % (source.count(old), os.environ["MUTANT"]))
open(sys.argv[2], "w", encoding="utf-8").write(source.replace(old, new, 1))
PY
}

killed=0
survived=0
for i in "${!mutants[@]}"; do
  mutant="${mutants[$i]}"
  case="${pairs[$i]}"
  if ! apply_mutation "$mutant" || ! python3 -m py_compile "$T/tools/affected-tests.py"; then
    printf 'mutation setup failed: %s\n' "$mutant"
    printf 'MUTATION RESULT: NOT RUN\n'
    exit 2
  fi
  # The router is found next to the tool; the stub in the test overrides it.
  if run_case "$case" "$T/tools/affected-tests.py" "$T/mutant.out"; then
    printf 'SURVIVED mutant: %s (paired case %s)\n' "$mutant" "$case"
    survived=$((survived + 1))
  else
    printf 'KILLED mutant: %s (paired case %s)\n' "$mutant" "$case"
    killed=$((killed + 1))
  fi
done

MUTATION_SENTINEL=1 bash "$0" >"$T/sentinel.out" 2>&1
sentinel_rc=$?
sentinel_result="$(tail -n 1 "$T/sentinel.out")"
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

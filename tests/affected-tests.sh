#!/usr/bin/env bash
# Contract tests for tools/affected-tests.py on synthetic repositories: a Go
# module, a Python package with a stubbed code graph, and a shell-tested repo.
# ONLY=<case> runs one case (used by affected-tests-mutations.sh); AT_TOOL
# overrides the script under test. The last line is "PASS n/n" only when every
# check ran; Go cases need a go toolchain and are reported as skipped without one.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="${AT_TOOL:-$HERE/../tools/affected-tests.py}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export GOTOOLCHAIN=local GOWORK=off GOFLAGS=-mod=mod GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test

RAN=0
OK=0
SKIPPED=""
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got [%s] want [%s]\n' "$1" "$2" "$3"
  fi
}
want() { [ -z "${ONLY:-}" ] || [ "$ONLY" = "$1" ]; }

commit_all() { git -C "$1" add -A && git -C "$1" commit -qm base; }

# Runs the tool; sets OUT (stdout+stderr) and RC.
at() {
  OUT="$(python3 "$TOOL" --repo "$REPO" "$@" 2>&1)"
  RC=$?
}
line() { printf '%s\n' "$OUT" | grep -c -F -x -- "$1"; }
has() { printf '%s\n' "$OUT" | grep -c -F -- "$1" | sed 's/^[1-9][0-9]*$/1/'; }

# ------------------------------------------------------------- Rust fixtures
cargo_repo() {
  REPO="$T/rs-$1"
  rm -rf "$REPO"
  mkdir -p "$REPO/crates/core/src" "$REPO/crates/app/src" "$REPO/crates/other/src"
  git init -q "$REPO"
  printf '[workspace]\nmembers = ["crates/core", "crates/app", "crates/other"]\nresolver = "2"\n' > "$REPO/Cargo.toml"
  printf '[package]\nname = "core-fixture"\nversion = "0.1.0"\nedition = "2021"\n' > "$REPO/crates/core/Cargo.toml"
  printf 'pub fn value() -> u8 { 1 }\n' > "$REPO/crates/core/src/lib.rs"
  printf '[package]\nname = "app-fixture"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\ncore-fixture = { path = "../core" }\n' > "$REPO/crates/app/Cargo.toml"
  printf 'pub fn app() -> u8 { core_fixture::value() }\n' > "$REPO/crates/app/src/lib.rs"
  printf '[package]\nname = "other-fixture"\nversion = "0.1.0"\nedition = "2021"\n' > "$REPO/crates/other/Cargo.toml"
  printf 'pub fn other() {}\n' > "$REPO/crates/other/src/lib.rs"
  commit_all "$REPO"
}

if command -v cargo >/dev/null 2>&1; then
  if want rs-ownership-deepest; then
    cargo_repo deepest
    mkdir -p "$REPO/crates/core/nested/src"
    printf '[package]\nname = "nested-fixture"\nversion = "0.1.0"\nedition = "2021"\n' > "$REPO/crates/core/nested/Cargo.toml"
    printf 'pub fn nested() {}\n' > "$REPO/crates/core/nested/src/lib.rs"
    printf '[workspace]\nmembers = ["crates/core", "crates/app", "crates/other", "crates/core/nested"]\nresolver = "2"\n' > "$REPO/Cargo.toml"
    commit_all "$REPO"
    printf 'pub fn nested() { }\n' > "$REPO/crates/core/nested/src/lib.rs"
    at
    check "rs: deepest crate owns files in nested package" \
      "$(line 'run: cargo test -p nested-fixture')" 1
    check "rs: deepest ownership reports why" \
      "$(has 'why: nested-fixture (.)  <- depends on nested-fixture')" 1
  fi
  if want rs-unowned-rs; then
    cargo_repo unowned-rs
    printf 'pub fn outside() {}\n' > "$REPO/outside.rs"
    at
    check "rs: unowned Rust source requires full suite" "$RC" 3
    check "rs: unowned Rust reason names the path" \
      "$(has 'full: outside.rs belongs to no Rust crate')" 1
  fi
  if want rs-metadata-failure; then
    cargo_repo metadata-failure
    printf '[package\ninvalid\n' > "$REPO/crates/core/Cargo.toml"
    at
    check "rs: invalid manifest requires full suite" "$RC" 3
    check "rs: metadata failure names its manifest" \
      "$(has 'full: cargo metadata failed for crates/core:')" 1
  fi
  if want rs-toolchain-full; then
    for trigger in rust-toolchain rust-toolchain.toml .cargo/config .cargo/config.toml; do
      cargo_repo "toolchain-${trigger//\//-}"
      mkdir -p "$(dirname "$REPO/$trigger")"
      printf 'stable\n' > "$REPO/$trigger"
      at
      check "rs: $trigger forces full suite" "$RC" 3
    done
  fi
  if want rs-dependents-workspace; then
    cargo_repo dependents-workspace
    printf 'pub fn value() -> u8 { 2 }\n' > "$REPO/crates/core/src/lib.rs"
    at
    check "rs: changed crate selects itself and path-dependent member" \
      "$(line 'run: cargo test -p app-fixture -p core-fixture')" 1
    check "rs: unrelated member is not selected" "$(has 'other-fixture')" 0
    printf 'pub fn value() -> u8 { 1 }\n' > "$REPO/crates/core/src/lib.rs"
    printf 'fixture data\n' > "$REPO/crates/core/input.dat"
    at
    check "rs: non-source file in crate directory selects crate" \
      "$(line 'run: cargo test -p app-fixture -p core-fixture')" 1
  fi
  if want rs-cargo-lock-workspace; then
    cargo_repo cargo-lock
    printf '# lock changed\n' > "$REPO/Cargo.lock"
    at
    check "rs: Cargo.lock selects workspace members" \
      "$(line 'run: cargo test -p app-fixture -p core-fixture -p other-fixture')" 1
  fi
  if want rs-virtual-workspace-manifest; then
    cargo_repo virtual-manifest
    printf '\n# workspace changed\n' >> "$REPO/Cargo.toml"
    at
    check "rs: virtual workspace Cargo.toml selects all members" \
      "$(line 'run: cargo test -p app-fixture -p core-fixture -p other-fixture')" 1
  fi
  if want rs-root-package-manifest; then
    REPO="$T/rs-root-package"
    mkdir -p "$REPO/src" "$REPO/b/src"
    git init -q "$REPO"
    printf '[package]\nname = "root-fixture"\nversion = "0.1.0"\nedition = "2021"\n[workspace]\nmembers = ["b"]\nresolver = "2"\n' > "$REPO/Cargo.toml"
    printf 'pub fn root() {}\n' > "$REPO/src/lib.rs"
    printf '[package]\nname = "b-fixture"\nversion = "0.1.0"\nedition = "2021"\n' > "$REPO/b/Cargo.toml"
    printf 'pub fn b() {}\n' > "$REPO/b/src/lib.rs"
    commit_all "$REPO"
    printf '\n# root package workspace changed\n' >> "$REPO/Cargo.toml"
    at
    check "rs: root package manifest selects every workspace member" \
      "$(line 'run: cargo test -p b-fixture -p root-fixture')" 1
  fi
  if want rs-ownership-nested-workspace; then
    cargo_repo nested-workspace
    mkdir -p "$REPO/crates/core/tests/fixtures/guest/src"
    printf '[package]\nname = "guest-fixture"\nversion = "0.1.0"\nedition = "2021"\n[workspace]\n' > "$REPO/crates/core/tests/fixtures/guest/Cargo.toml"
    printf 'pub fn guest() {}\n' > "$REPO/crates/core/tests/fixtures/guest/src/lib.rs"
    printf '# guest lock\n' > "$REPO/crates/core/tests/fixtures/guest/Cargo.lock"
    commit_all "$REPO"
    printf '\n# guest lock changed\n' >> "$REPO/crates/core/tests/fixtures/guest/Cargo.lock"
    at
    check "rs: nested workspace lock change folds back to outer crate" \
      "$(line 'run: cargo test -p app-fixture -p core-fixture')" 1
    check "rs: nested guest package is not selected" "$(has 'guest-fixture')" 0
    printf '# guest lock\n' > "$REPO/crates/core/tests/fixtures/guest/Cargo.lock"
    printf 'pub fn guest() { }\n' > "$REPO/crates/core/tests/fixtures/guest/src/lib.rs"
    at
    check "rs: nested workspace source change folds to outer crate" \
      "$(line 'run: cargo test -p app-fixture -p core-fixture')" 1
    check "rs: nested source does not test fixture crate" "$(has 'guest-fixture')" 0
  fi
  if want rs-args-exclude; then
    cargo_repo args-exclude
    printf 'pub fn value() -> u8 { 2 }\n' > "$REPO/crates/core/src/lib.rs"
    printf '{"rust":{"args":"--all-features","exclude":["crates/core"]}}\n' > "$T/rust-config.json"
    at --config "$T/rust-config.json"
    check "rs: rust.args precedes sorted package flags" \
      "$(line 'run: cargo test --all-features -p app-fixture')" 1
    check "rs: rust.exclude is reported and keeps dependents" \
      "$(line 'ignored: crates/core (config rust.exclude)')" 1
  fi
  if want rs-exclude-only; then
    cargo_repo exclude-only
    printf 'pub fn value() -> u8 { 2 }\n' > "$REPO/crates/core/src/lib.rs"
    printf '{"rust":{"exclude":["crates/*"]}}\n' > "$T/rust-config.json"
    at --config "$T/rust-config.json"
    check "rs: excluding all reached crates falls back to full" "$RC" 3
    check "rs: exclude-only uses generic no-test reason" \
      "$(has 'the change reaches no test')" 1
  fi
  if want rs-json; then
    cargo_repo json
    printf 'pub fn value() -> u8 { 2 }\n' > "$REPO/crates/core/src/lib.rs"
    at --json
    check "rs: JSON contains selected Rust command" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["mode"], d["commands"][0])')" \
      "selected cargo test -p app-fixture -p core-fixture"
    check "rs: JSON exposes Rust crate selection" "$(printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(bool(d.get("rust")))')" True
  fi
  if want rs-dependents-cross-workspace; then
    cargo_repo cross-workspace
    mkdir -p "$REPO/plugins/component/src"
    printf '[package]\nname = "plugin-fixture"\nversion = "0.1.0"\nedition = "2021"\n[workspace]\n[dependencies]\ncore-fixture = { path = "../../crates/core" }\n' > "$REPO/plugins/component/Cargo.toml"
    printf 'pub fn plugin() { core_fixture::value(); }\n' > "$REPO/plugins/component/src/lib.rs"
    commit_all "$REPO"
    printf 'pub fn value() -> u8 { 2 }\n' > "$REPO/crates/core/src/lib.rs"
    at
    check "rs: path dependents across workspaces are selected" \
      "$(line 'run: cargo test -p app-fixture -p core-fixture')" 1
    check "rs: external-workspace dependent is selected separately" \
      "$(line 'run: (cd plugins/component && cargo test -p plugin-fixture)')" 1
  fi
else
  SKIPPED="$SKIPPED (rs cases skipped: no cargo toolchain)"
fi

if want rs-no-cargo || want rs-no-cargo-irrelevant; then
  cargo_repo no-cargo
  mkdir -p "$T/no-cargo-bin"
  ln -sf "$(command -v python3)" "$T/no-cargo-bin/python3"
  ln -sf "$(command -v git)" "$T/no-cargo-bin/git"
  if want rs-no-cargo; then
    printf 'pub fn value() -> u8 { 2 }\n' > "$REPO/crates/core/src/lib.rs"
    PATH="$T/no-cargo-bin" at
    check "rs: Rust changes without cargo require full suite" "$RC" 3
    check "rs: missing cargo reason is explicit" \
      "$(has 'full: cargo is unavailable for Rust/Cargo changes')" 1
    printf 'pub fn value() -> u8 { 1 }\n' > "$REPO/crates/core/src/lib.rs"
    printf '# lock changed\n' > "$REPO/Cargo.lock"
    PATH="$T/no-cargo-bin" at
    check "rs: Cargo.lock without cargo requires full suite" "$RC" 3
    check "rs: missing cargo reason covers Cargo.* changes" \
      "$(has 'full: cargo is unavailable for Rust/Cargo changes')" 1
  fi
  if want rs-no-cargo-irrelevant; then
    printf 'pub fn value() -> u8 { 1 }\n' > "$REPO/crates/core/src/lib.rs"
    rm "$REPO/Cargo.lock"
    printf '# documentation only\n' > "$REPO/README.md"
    PATH="$T/no-cargo-bin" at
    check "rs: irrelevant doc changes do not invoke cargo" "$(line 'mode: none')" 1
    check "rs: irrelevant doc changes have no cargo full reason" \
      "$(has 'cargo')" 0
  fi
fi

# ---------------------------------------------------------------- Go fixture
go_repo() {
  REPO="$T/go-$1"
  rm -rf "$REPO"
  mkdir -p "$REPO/m/a/testdata" "$REPO/m/b" "$REPO/m/c"
  git init -q "$REPO"
  printf 'module example.test/m\n\ngo 1.21\n' > "$REPO/m/go.mod"
  printf 'package a\n\nfunc A() int { return 1 }\n' > "$REPO/m/a/a.go"
  printf 'package a\n\nimport "testing"\n\nfunc TestA(t *testing.T) {\n\tif A() != 1 {\n\t\tt.Fatal("A")\n\t}\n}\n' > "$REPO/m/a/a_test.go"
  printf 'input\n' > "$REPO/m/a/testdata/in.txt"
  printf 'package b\n\nimport "example.test/m/a"\n\nfunc B() int { return a.A() + 1 }\n' > "$REPO/m/b/b.go"
  printf 'package b\n\nimport "testing"\n\nfunc TestB(t *testing.T) {\n\tif B() != 2 {\n\t\tt.Fatal("B")\n\t}\n}\n' > "$REPO/m/b/b_test.go"
  printf 'package c\n\nfunc C() int { return 3 }\n' > "$REPO/m/c/c.go"
  printf 'package c\n\nimport "testing"\n\nfunc TestC(t *testing.T) {\n\tif C() != 3 {\n\t\tt.Fatal("C")\n\t}\n}\n' > "$REPO/m/c/c_test.go"
  commit_all "$REPO"
}

if command -v go >/dev/null 2>&1; then
  if want go-dependents; then
    go_repo dependents
    printf '\n// changed\n' >> "$REPO/m/a/a.go"
    at
    check "go: change in a selects a and its dependent b, not c" \
      "$(line 'run: (cd m && go test -count=1 ./a ./b)')" 1
    check "go: exit 0 for a selection" "$RC" 0
  fi
  if want go-leaf; then
    go_repo leaf
    printf '\n// changed\n' >> "$REPO/m/c/c.go"
    at
    check "go: change in c selects only c" "$(line 'run: (cd m && go test -count=1 ./c)')" 1
  fi
  if want go-testdata; then
    go_repo testdata
    printf 'other\n' > "$REPO/m/a/testdata/in.txt"
    at
    # A non-Go file inside a package (testdata, //go:embed) counts as a change
    # to that package, so its dependents are selected too: a safe superset.
    check "go: a non-Go file in a package counts as a change to that package" \
      "$(line 'run: (cd m && go test -count=1 ./a ./b)')" 1
  fi
  if want go-tags; then
    go_repo tags
    mkdir -p "$REPO/m/e2e"
    printf '//go:build e2e\n\npackage e2e\n\nimport "testing"\n\nfunc TestE2E(t *testing.T) {}\n' > "$REPO/m/e2e/e2e_test.go"
    at
    check "go: a file the build tags exclude is reported as ignored" \
      "$(line 'ignored: m/e2e/e2e_test.go (build constraints exclude it)')" 1
    check "go: a tag-excluded file alone runs nothing" "$(line 'mode: none')" 1
  fi
  if want go-mod; then
    go_repo mod
    printf '\n// x\n' >> "$REPO/m/go.mod"
    at
    check "go: go.mod change requires the full suite" "$RC" 3
    check "go: go.mod reason is printed" "$(has 'full: m/go.mod changed')" 1
  fi
  if want go-run; then
    go_repo run
    printf '\n// changed\n' >> "$REPO/m/c/c.go"
    at --run
    check "go: --run passes a green selection" "$RC" 0
    printf 'package c\n\nimport "testing"\n\nfunc TestC(t *testing.T) { t.Fatal("red") }\n' > "$REPO/m/c/c_test.go"
    at --run
    check "go: --run fails on a red selected test" "$RC" 1
  fi
else
  SKIPPED=" (go cases skipped: no go toolchain)"
fi

# ------------------------------------------------------------ Python fixture
cat > "$T/stub_router.py" <<'PY'
"""Stand-in for codegraph-router.py: answers the two cypher shapes the tool
sends from the JSON file in $STUB_GRAPH, or fails like an unreachable daemon."""
import json, os


def resolve_repo(token):
    if os.environ.get("STUB_MODE") == "unregistered":
        raise ValueError("no graph registered for %r" % token)
    return {"name": "fixture", "plane": "fixture", "path": token}


def call_upstream(entry, tool, args):
    if os.environ.get("STUB_MODE") == "down":
        raise ValueError("fixture's graph is not up and could not be started")
    with open(os.environ["STUB_GRAPH"], encoding="utf-8") as fh:
        g = json.load(fh)
    key = args["params"]["k"]
    if "CALLS" in args["query"]:
        rows = g["callers"].get(key, [])
    elif "f.file" in args["query"]:
        rows = [[k] for k in g["files"].get(key, [])]
    else:
        rows = [[key]] if key in g["nodes"] else []
    return json.dumps({"columns": [], "rows": rows}), False
PY
export DRSG_AFFECTED_ROUTER="$T/stub_router.py"

py_repo() {
  REPO="$T/py-$1"
  rm -rf "$REPO"
  mkdir -p "$REPO/pkg" "$REPO/tests"
  git init -q "$REPO"
  : > "$REPO/pkg/__init__.py"
  cat > "$REPO/pkg/core.py" <<'PY'
RATE = 2


def compute_total(x):
    return x * RATE


def render_label(x):
    def fmt(v):
        return "v%d" % v
    return fmt(x)
PY
  cat > "$REPO/pkg/wrap.py" <<'PY'
from pkg import core


def doubled(x):
    return core.compute_total(x) * 2
PY
  printf '{"rate": 2}\n' > "$REPO/pkg/rates.json"
  cat > "$REPO/tests/test_core.py" <<'PY'
# The expected values follow pkg/rates.json.
from pkg.core import compute_total


def test_compute_total():
    assert compute_total(2) == 4
PY
  cat > "$REPO/tests/test_wrap.py" <<'PY'
from pkg.wrap import doubled


def test_doubled():
    assert doubled(1) == 4
PY
  cat > "$REPO/tests/test_label.py" <<'PY'
from pkg.core import render_label


def test_render_label():
    assert render_label(1) == "v1"
PY
  commit_all "$REPO"
  export STUB_GRAPH="$REPO.graph.json"
  cat > "$STUB_GRAPH" <<'JSON'
{"nodes": ["pkg.core.compute_total", "pkg.core.render_label", "pkg.wrap.doubled"],
 "files": {"pkg/core.py": ["pkg.core.RATE", "pkg.core.compute_total", "pkg.core.render_label"],
           "pkg/wrap.py": ["pkg.wrap.doubled"]},
 "callers": {
  "pkg.core.compute_total": [["pkg.wrap.doubled", "pkg/wrap.py"],
                             ["tests.test_wrap.test_doubled", "tests/test_wrap.py"],
                             ["tests.test_core.test_compute_total", "tests/test_core.py"]],
  "pkg.core.render_label": [["tests.test_label.test_render_label", "tests/test_label.py"]],
  "pkg.wrap.doubled": [["tests.test_wrap.test_doubled", "tests/test_wrap.py"]]}}
JSON
  unset STUB_MODE
}

if want py-graph; then
  py_repo graph
  sed -i 's/    return x \* RATE/    return x * RATE + 0/' "$REPO/pkg/core.py"
  at
  check "py: text match selects the file, graph adds the indirect test" \
    "$(line 'run: python3 -m pytest tests/test_core.py tests/test_wrap.py::test_doubled')" 1
fi
if want py-graph-down; then
  py_repo down
  sed -i 's/    return x \* RATE/    return x * RATE + 0/' "$REPO/pkg/core.py"
  STUB_MODE=down at
  check "py: unreachable graph requires the full suite" "$RC" 3
  check "py: unreachable graph reason is printed" "$(has 'full: code graph unavailable')" 1
fi
if want py-graph-missing; then
  py_repo missing
  python3 - "$STUB_GRAPH" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
g["nodes"].remove("pkg.core.compute_total")
json.dump(g, open(sys.argv[1], "w"))
PY
  sed -i 's/    return x \* RATE/    return x * RATE + 0/' "$REPO/pkg/core.py"
  at
  check "py: symbol at the base but not in the graph requires the full suite" "$RC" 3
  check "py: missing-node reason names the key" "$(has 'graph has no node for pkg.core.compute_total')" 1
fi
if want py-unmodeled; then
  py_repo unmodeled
  python3 - "$STUB_GRAPH" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))
del g["files"]["pkg/wrap.py"]
json.dump(g, open(sys.argv[1], "w"))
PY
  sed -i 's/    return core.compute_total(x) \* 2/    return core.compute_total(x) * 2 + 0/' "$REPO/pkg/wrap.py"
  at
  check "py: a file the graph has no definitions for requires the full suite" "$RC" 3
  check "py: unmodeled reason names the file" "$(has 'full: the code graph has no definitions for pkg/wrap.py')" 1
fi
if want py-untested; then
  py_repo untested
  printf '\n\ndef brand_new_helper(x):\n    return x\n' >> "$REPO/pkg/core.py"
  at
  check "py: a change no test reaches requires the full suite" "$RC" 3
  check "py: unreached reason is printed" "$(has 'full: the change reaches no test: pkg/core.py')" 1
fi
if want py-nested; then
  py_repo nested
  sed -i 's/        return "v%d" % v/        return "v%d" % (v + 0)/' "$REPO/pkg/core.py"
  at
  check "py: a change in a nested function counts as its enclosing function" \
    "$(line 'run: python3 -m pytest tests/test_label.py')" 1
fi
if want py-conftest; then
  py_repo conftest
  printf 'import pytest\n' > "$REPO/tests/conftest.py"
  at
  check "py: conftest.py requires the full suite" "$RC" 3
  check "py: conftest reason is printed" "$(has 'full: tests/conftest.py changed')" 1
fi
if want py-module-level; then
  py_repo module
  sed -i 's/^RATE = 2$/RATE = 3/' "$REPO/pkg/core.py"
  at
  check "py: a module-level change reaches every function of the module" \
    "$(line 'run: python3 -m pytest tests/test_core.py tests/test_label.py tests/test_wrap.py::test_doubled')" 1
fi
if want py-syntax; then
  py_repo syntax
  printf '\ndef broken(:\n' >> "$REPO/pkg/core.py"
  at
  check "py: unparsable source requires the full suite" "$RC" 3
  check "py: parse reason is printed" "$(has 'full: cannot parse pkg/core.py')" 1
fi
if want py-doc; then
  py_repo doc
  printf '# notes\n' > "$REPO/README.md"
  at
  check "py: a doc-only change runs nothing" "$(line 'mode: none')" 1
  check "py: doc-only exit 0" "$RC" 0
fi
if want py-unknown; then
  py_repo unknown
  printf 'x' > "$REPO/data.bin"
  at
  check "py: a file no rule covers requires the full suite" "$RC" 3
  check "py: unknown-file reason names the file" "$(has 'full: no rule covers data.bin')" 1
fi
if want py-data; then
  py_repo data
  printf '{"rate": 3}\n' > "$REPO/pkg/rates.json"
  at
  check "py: a data file named by a test selects that test file" \
    "$(line 'run: python3 -m pytest tests/test_core.py')" 1
fi
if want py-ignore; then
  py_repo ignore
  mkdir -p "$REPO/.drsg" "$REPO/web"
  printf '{"ignore": ["web/*"]}\n' > "$REPO/.drsg/affected-tests.json"
  git -C "$REPO" add .drsg && git -C "$REPO" commit -qm cfg
  printf 'x\n' > "$REPO/web/app.js"
  at
  check "py: an ignored path is reported, not run" "$(line 'ignored: web/app.js (config ignore)')" 1
  check "py: ignored-only change runs nothing" "$(line 'mode: none')" 1
fi
if want py-test-file; then
  py_repo testfile
  printf '\n\ndef test_more():\n    assert True\n' >> "$REPO/tests/test_label.py"
  at
  check "py: a changed test file is selected whole" \
    "$(line 'run: python3 -m pytest tests/test_label.py')" 1
fi
if want py-json; then
  py_repo json
  sed -i 's/    return x \* RATE/    return x * RATE + 0/' "$REPO/pkg/core.py"
  at --json
  check "py: --json reports mode and commands" "$(printf '%s' "$OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["mode"], len(d["commands"]))')" "selected 1"
fi

# ------------------------------------------------------------- Shell fixture
sh_repo() {
  REPO="$T/sh-$1"
  rm -rf "$REPO"
  mkdir -p "$REPO/tools" "$REPO/tests" "$REPO/.drsg"
  git init -q "$REPO"
  printf 'def fa():\n    return 1\n' > "$REPO/tools/a.py"
  printf 'from a import fa\n\nprint(fa())\n' > "$REPO/tools/b.py"
  printf 'print(3)\n' > "$REPO/tools/c.py"
  printf '#!/usr/bin/env bash\npython3 "$(dirname "$0")/../tools/b.py"\n' > "$REPO/tests/t_b.sh"
  printf '#!/usr/bin/env bash\npython3 "$(dirname "$0")/../tools/c.py"\n' > "$REPO/tests/t_c.sh"
  printf '#!/usr/bin/env bash\nbash tests/t_b.sh && bash tests/t_c.sh\n' > "$REPO/tests/all.sh"
  printf '{"always": ["true"], "full": "bash tests/all.sh",\n "shell": {"tests": "tests/*.sh", "exclude": ["tests/all.sh"]}}\n' \
    > "$REPO/.drsg/affected-tests.json"
  commit_all "$REPO"
}

if want sh-import; then
  sh_repo import
  printf 'def fa():\n    return 2\n' > "$REPO/tools/a.py"
  at
  check "sh: a module change reaches the script that runs its importer" \
    "$(line 'run: bash tests/t_b.sh')" 1
  check "sh: the unrelated script is not selected" "$(line 'run: bash tests/t_c.sh')" 0
  check "sh: always-commands come first" "$(printf '%s\n' "$OUT" | grep '^run: ' | head -1)" "run: true"
fi
if want sh-script; then
  sh_repo script
  printf '# touched\n' >> "$REPO/tests/t_c.sh"
  at
  check "sh: a changed test script selects itself" "$(line 'run: bash tests/t_c.sh')" 1
fi
if want sh-full-run; then
  sh_repo fullrun
  printf 'x' > "$REPO/blob.bin"
  at --run
  check "sh: --run runs the configured full command when full is required" "$RC" 0
  check "sh: the full command is what ran" "$(line '+ bash tests/all.sh')" 1
fi

printf 'PASS %d/%d%s\n' "$OK" "$RAN" "$SKIPPED"
[ "$OK" -eq "$RAN" ] && [ "$RAN" -gt 0 ]

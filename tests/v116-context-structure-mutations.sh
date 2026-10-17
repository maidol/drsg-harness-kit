#!/usr/bin/env bash
# Each source mutant is checked only by its paired focused contract.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" "$HERE/v116-context-structure-mutations.sh" "$@" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
runner = pathlib.Path(sys.argv[2])
test = repo / "tests/hook-common.sh"


def fixture(work):
    source = work / "source"
    shutil.copytree(repo / "tools", source / "tools")
    return source


def run_case(source, case):
    env = os.environ.copy()
    env["V116_SOURCE_ROOT"] = str(source)
    env["ONLY"] = case
    return subprocess.run(
        ["bash", str(test)], text=True, capture_output=True, env=env, timeout=90,
    )


def mutate_missing_guard(source):
    path = source / "tools/templates/hooks/user_prompt.py"
    text = path.read_text(encoding="utf-8")
    old = "if _common is None:\n        hook_out()\n        return"
    assert text.count(old) == 1, "missing-module guard anchor is not unique"
    path.write_text(text.replace(old, "if False:\n        hook_out()\n        return", 1), encoding="utf-8")


def mutate_event_reinstall(source):
    path = source / "tools/install.sh"
    text = path.read_text(encoding="utf-8")
    old = "if BEGIN in existing and END in existing:"
    assert text.count(old) == 1, "Event sentinel anchor is not unique"
    path.write_text(text.replace(old, "if False and BEGIN in existing:", 1), encoding="utf-8")


def mutate_local_transport(source):
    path = source / "tools/event.py"
    with path.open("a", encoding="utf-8") as stream:
        stream.write("\ndef _urlopen(request, timeout):\n    return None\n")


def run_mutant(name, case, mutate, expected):
    with tempfile.TemporaryDirectory(prefix="v116-mutant-") as td:
        source = fixture(pathlib.Path(td))
        control = run_case(source, case)
        control_output = control.stdout + control.stderr
        if control.returncode != 0 or "FAIL " in control_output or "SKIP " in control_output:
            print(f"NOT RUN {name}: unmutated paired case failed (exit {control.returncode})")
            print(control_output.rstrip())
            return "error"
        mutate(source)
        result = run_case(source, case)
    output = result.stdout + result.stderr
    if result.returncode == 0:
        print(f"SURVIVOR {name}: paired test passed")
        return "survivor"
    if result.returncode != 1 or expected not in output or f"FAIL {case}:" not in output:
        print(f"RUNNER ERROR {name}: paired test did not fail for {expected!r}")
        print(output.rstrip())
        return "error"
    print(f"KILLED {name}: {expected}")
    return "killed"


def survivor_self_test():
    with tempfile.TemporaryDirectory(prefix="v116-survivor-") as td:
        source = fixture(pathlib.Path(td))
        result = run_case(source, "event-block-reinstall")
    if result.returncode != 0:
        print("RUNNER ERROR survivor sentinel did not survive")
        print((result.stdout + result.stderr).rstrip())
        return False
    print("SURVIVOR sentinel: event-block-reinstall unexpectedly passed")
    return True


if len(sys.argv) > 3 and sys.argv[3] == "--survivor-self-test":
    sys.exit(1 if survivor_self_test() else 2)

mutants = (
    ("missing-module-guard", "hook-missing-module", mutate_missing_guard,
     "user_prompt.py exited 1"),
    ("old-event-block-reinstall", "event-block-reinstall", mutate_event_reinstall,
     "old generated text"),
    ("local-rpc-transport", "rpc-sharing", mutate_local_transport,
     "event.py still defines _urlopen"),
)
survivors, errors = [], []
for name, case, mutate, expected in mutants:
    outcome = run_mutant(name, case, mutate, expected)
    if outcome == "survivor":
        survivors.append(name)
    elif outcome == "error":
        errors.append(name)

self_test = subprocess.run(
    ["bash", str(runner), "--survivor-self-test"],
    text=True, capture_output=True, timeout=120,
)
self_output = self_test.stdout + self_test.stderr
if self_test.returncode != 1 or "SURVIVOR sentinel" not in self_output:
    print("RUNNER ERROR survivor self-test did not return non-zero and name sentinel")
    print(self_output.rstrip())
    errors.append("survivor-self-test")
else:
    print("PASS survivor self-test: runner returned non-zero and named sentinel")

if errors:
    print("MUTATION RESULT: NOT RUN (" + ", ".join(errors) + ")")
    sys.exit(2)
if survivors:
    print("MUTATION RESULT: SURVIVED (" + ", ".join(survivors) + ")")
    sys.exit(1)
print("MUTATION RESULT: ALL KILLED; SURVIVOR SELF-TEST PASSED")
sys.exit(0)
PY

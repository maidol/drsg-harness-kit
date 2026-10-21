#!/usr/bin/env bash
# Each ownership mutation is checked only by its paired contract assertion.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
source = repo / "tools/templates/hooks/compact_handoff.py"
suite = repo / "tests/compact-handoff-ownership.sh"
mutations = [
    ("own-identity", "select-own",
     'if (current is not None and owner["pid"] == current["pid"]',
     'if (current is not None and owner["pid"] != current["pid"]'),
    ("owner-stop-state", "process-states",
     'proc[1] not in ("Z", "X")',
     'proc[1] not in ("Z", "X", "T", "t")'),
    ("pid-reuse", "pid-start-mismatch",
     'proc[0] == start', 'proc[0] != start'),
    ("lane-intersection", "lane-list-equality",
     'owner["lanes"] == current["lanes"]',
     'owner["lanes"] != current["lanes"]'),
    ("resume-session", "resume-no-match",
     'and record.get("session_id") == session_id]',
     'and record.get("session_id") != session_id]'),
    ("prune-live-owner", "limit-preserves-live",
     'index = next((i for i, item in enumerate(records) if not item[3]), None)',
     'index = next((i for i, item in enumerate(records)), None)'),
    ("unknown-current-includes-live", "unknown-current-e2",
     'elif owner_alive(record, owner_cache):',
     'elif owner_alive(record, owner_cache) and current is not None:'),
]


def run(source_path, assertion):
    env = dict(os.environ)
    env.update({"COMPACT_HANDOFF_SOURCE": str(source_path), "ONLY": assertion})
    return subprocess.run(["bash", str(suite)], cwd=repo, env=env,
                          text=True, capture_output=True)


def make_copy(directory, content):
    target_dir = pathlib.Path(directory)
    target_dir.mkdir()
    for dependency in (source.parent).glob("*.py"):
        shutil.copy2(dependency, target_dir / dependency.name)
    target = target_dir / "compact_handoff.py"
    target.write_text(content, encoding="utf-8")
    return target

killed = survived = not_run = 0
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp)
    original = source.read_text(encoding="utf-8")
    for name, assertion, old, new in mutations:
        baseline = run(source, assertion)
        if baseline.returncode or ("ok   " + assertion) not in baseline.stdout:
            print("NOT RUN: %s (paired assertion baseline failed)" % name)
            not_run += 1
            continue
        count = original.count(old)
        if count != 1:
            print("NOT RUN: %s (expected one mutation target, got %d)" % (name, count))
            not_run += 1
            continue
        target = make_copy(root / name, original.replace(old, new, 1))
        mutant = run(target, assertion)
        if mutant.returncode and ("FAIL " + assertion) in mutant.stdout:
            print("KILLED: " + name)
            killed += 1
        elif mutant.returncode == 0 and ("ok   " + assertion) in mutant.stdout:
            print("SURVIVED: " + name)
            survived += 1
        else:
            print("NOT RUN: %s (paired assertion was not the failure)" % name)
            not_run += 1

    control_baseline = run(source, "owner-record")
    control_source = original.replace(
        '"""Best-effort identity for the Claude process that ran this hook."""',
        '"""Best-effort identity for the Claude process in this hook."""', 1)
    control = make_copy(root / "control-survivor", control_source)
    control_run = run(control, "owner-record")
    if (control_baseline.returncode == 0 and "ok   owner-record" in control_baseline.stdout
            and control_run.returncode == 0 and "ok   owner-record" in control_run.stdout):
        print("SELF-CHECK VERIFIED: control mutant survived its paired assertion")
    else:
        print("NOT RUN: control mutant did not pass its paired assertion")
        not_run += 1

if not_run:
    print("MUTATION RESULT: NOT RUN (%d)" % not_run)
    raise SystemExit(2)
if survived:
    print("MUTATION RESULT: SURVIVED (%d)" % survived)
    raise SystemExit(1)
if killed != 7:
    print("MUTATION RESULT: NOT RUN (killed %d/7)" % killed)
    raise SystemExit(2)
print("MUTATION RESULT: ALL KILLED (%d)" % killed)
PY

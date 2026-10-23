#!/usr/bin/env bash
# Paired mutations for the Superpowers L4 audit contract.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import os
import pathlib
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
source_path = repo / "tools" / "audit_deployment.py"
test_path = repo / "tests" / "audit-deployment.sh"
source = source_path.read_text(encoding="utf-8")
log_dir = pathlib.Path(tempfile.mkdtemp(prefix="audit-l4-mutations-"))
env = os.environ.copy()
env["PYTHONPATH"] = str(repo / "tools") + os.pathsep + env.get("PYTHONPATH", "")

mutants = [
    (
        "duplicate archive marker check",
        '                    if starts != 1 or ends != 1:',
        '                    if starts == 0 and ends == 0:',
        "duplicate Superpowers markers are audit drift",
    ),
    (
        "reviewer-wide allow",
        "                        if covers_reviewer and candidate != expected_allow:",
        "                        if False:",
        "reviewer-wide additionalDirectory is audit drift",
    ),
    (
        "missing ownership state",
        "            if state_issue:\n                issues.append(\"Superpowers ownership state drift: \" + state_issue)",
        "            if state_issue and state_issue != \"state-missing\":\n                issues.append(\"Superpowers ownership state drift: \" + state_issue)",
        "missing ownership state is audit drift",
    ),
    (
        "fixed guard matcher",
        '            elif registrations[0][0] != "Bash|Write|Edit|NotebookEdit":',
        "            elif False:",
        "wrong guard matcher is audit drift with reason visible",
    ),
]


def run(name, content):
    audit = log_dir / (name.replace(" ", "-") + ".py")
    log = log_dir / (name.replace(" ", "-") + ".log")
    audit.write_text(content, encoding="utf-8")
    result = subprocess.run(["bash", str(test_path)], env={**env, "AUDIT_SOURCE": str(audit)},
                            capture_output=True, text=True)
    output = result.stdout + result.stderr
    log.write_text(output, encoding="utf-8")
    return result.returncode, output, log


baseline_rc, baseline_output, baseline_log = run("baseline", source)
if baseline_rc != 0:
    print("DID NOT RUN: baseline failed; raw log: %s" % baseline_log)
    print(baseline_output)
    sys.exit(2)
print("CONTROL PASS: audit-deployment.sh exit=0; raw log: %s" % baseline_log)

killed = 0
for name, old, new, paired_case in mutants:
    if source.count(old) != 1:
        print("DID NOT RUN: %s mutation anchor count=%d" % (name, source.count(old)))
        sys.exit(2)
    rc, output, log = run(name, source.replace(old, new, 1))
    failures = [line for line in output.splitlines()
                if line.startswith("FAIL ") and not line[5:6].isdigit()]
    expected = [line for line in failures if paired_case in line]
    unexpected = [line for line in failures if paired_case not in line]
    if rc == 1 and len(expected) == 1 and not unexpected:
        print("KILLED: %s | paired case: %s | rc=%d | raw log: %s" %
              (name, expected[0], rc, log))
        killed += 1
    else:
        print("DID NOT KILL: %s | paired case: %s | rc=%d | failures=%r | raw log: %s" %
              (name, paired_case, rc, failures, log))
        sys.exit(2)

noop_rc, noop_output, noop_log = run("noop-control", source)
if noop_rc != 0:
    print("NOOP CONTROL FAILED: rc=%d; raw log: %s" % (noop_rc, noop_log))
    sys.exit(2)
print("NOOP SURVIVED: unchanged audit source passes its paired contracts; rc=0; raw log: %s" %
      noop_log)

if killed != len(mutants):
    print("MUTATION RESULT: SURVIVED")
    sys.exit(1)
print("MUTATION RESULT: ALL KILLED (%d); NOOP SURVIVED" % killed)
PY

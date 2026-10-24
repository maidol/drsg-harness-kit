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
    (
        "on-demand missing-source check",
        '            issues.append(f"Missing repository source {repo_rule}")',
        "            pass",
        "on-demand-OPERATIONS-missing-source-is-reported",
        "on-demand-OPERATIONS-missing-source-is-reported",
    ),
    (
        "on-demand missing-copy check",
        '            issues.append(f"Missing {dep_rule}")',
        "            pass",
        "on-demand-OPERATIONS-missing-copy-is-reported",
        "on-demand-OPERATIONS-missing-copy-is-reported",
    ),
    (
        "on-demand content-drift check",
        "        elif digest_file(repo_rule) != digest_file(dep_rule):",
        "        elif False:",
        "on-demand-OPERATIONS-drift-is-reported",
        "on-demand-OPERATIONS-drift-is-reported",
    ),
    (
        "on-demand @-import check",
        '        for match in re.finditer(\n                rb"(?<!\\S)@\\S*AGENT-EFFICIENCY-(TESTING|OPERATIONS)\\.md", global_bytes):\n            rule = "AGENT-EFFICIENCY-" + match.group(1).decode("ascii") + ".md"\n            issues.append(f"Unexpected @-import of {rule} in {global_claude_md}")',
        '        if False:\n            pass',
        "on-demand-OPERATIONS-import-is-reported",
        "on-demand-OPERATIONS-import-is-reported",
    ),
    (
        "on-demand @-import exact-line matcher",
        '        for match in re.finditer(\n                rb"(?<!\\S)@\\S*AGENT-EFFICIENCY-(TESTING|OPERATIONS)\\.md", global_bytes):\n            rule = "AGENT-EFFICIENCY-" + match.group(1).decode("ascii") + ".md"\n            issues.append(f"Unexpected @-import of {rule} in {global_claude_md}")',
        '        for rule in (b"@AGENT-EFFICIENCY-TESTING.md", b"@AGENT-EFFICIENCY-OPERATIONS.md"):\n            if any(line.rstrip(b"\\r\\n") == rule\n                   for line in global_bytes.splitlines(keepends=True)):\n                issues.append(f"Unexpected @-import of {rule.decode()[1:]} in {global_claude_md}")',
        "on-demand-TESTING-prefixed-import-is-reported",
        "on-demand-TESTING-prefixed-import-is-reported",
    ),
]


def run(name, content, only=None):
    audit = log_dir / (name.replace(" ", "-") + ".py")
    log = log_dir / (name.replace(" ", "-") + ".log")
    audit.write_text(content, encoding="utf-8")
    run_env = {**env, "AUDIT_SOURCE": str(audit)}
    if only is None:
        run_env.pop("ONLY", None)
    else:
        run_env["ONLY"] = only
    result = subprocess.run(["bash", str(test_path)], env=run_env,
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
for mutant in mutants:
    name, old, new, paired_case = mutant[:4]
    only = mutant[4] if len(mutant) == 5 else None
    if source.count(old) != 1:
        print("DID NOT RUN: %s mutation anchor count=%d" % (name, source.count(old)))
        sys.exit(2)
    rc, output, log = run(name, source.replace(old, new, 1), only)
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

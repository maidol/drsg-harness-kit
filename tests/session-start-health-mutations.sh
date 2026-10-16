#!/usr/bin/env bash
# Four judgment-gate mutants for SessionStart health warnings.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK_SOURCE="${SESSION_START_SOURCE:-$REPO/tools/templates/hooks/session_start.py}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
python3 - "$REPO" "$HOOK_SOURCE" "$T" <<'PY'
import io
import os
import pathlib
import subprocess
import sys
from contextlib import redirect_stdout

repo, source_path, tmp = sys.argv[1:]
source_path = pathlib.Path(source_path)
source = source_path.read_text(encoding="utf-8")
test_script = pathlib.Path(repo, "tests", "session-start-health-warning.sh")


def run_case(hook_path, only):
    env = os.environ.copy()
    env["SESSION_START_SOURCE"] = str(hook_path)
    env["ONLY"] = only
    return subprocess.run(["bash", str(test_script)], cwd=repo, env=env,
                          text=True, capture_output=True, timeout=60)


def output_of(proc):
    return proc.stdout + proc.stderr


def summary_lines(proc):
    return [line for line in output_of(proc).splitlines() if line.startswith("FAIL ")]


def report_summary(survivors, runner_errors):
    if runner_errors:
        print("MUTATION RUNNER FAILED: " + "; ".join(runner_errors))
        return 2
    if survivors:
        print("SURVIVING MUTATION(S): " + ", ".join(survivors))
        return 1
    print("ALL MUTATIONS KILLED (4)")
    return 0


# This deliberately applies no mutation. The selected test passes, so the
# sentinel survives and the same summary classifier must return non-zero.
self_test = run_case(source_path, "missing-token-silent")
if self_test.returncode != 0 or "PASS missing-token-silent" not in output_of(self_test):
    print("MUTATION RUNNER FAILED: survivor self-test could not run its passing case")
    raise SystemExit(2)
self_output = io.StringIO()
with redirect_stdout(self_output):
    self_status = report_summary(["survivor-sentinel"], [])
try:
    raise SystemExit(self_status)
except SystemExit as exc:
    sentinel_rc = exc.code
if (sentinel_rc != 1 or
        "SURVIVING MUTATION(S): survivor-sentinel" not in self_output.getvalue()):
    print("MUTATION RUNNER FAILED: deliberately surviving sentinel was not classified")
    raise SystemExit(2)
print("SELF-CHECK: survivor sentinel produces non-zero and is named")

mutations = [
    ("R1 daemon notice", "daemon-down-real-loopback",
     '        system_warning, model_warning = daemon_down_messages()',
     '        system_warning, model_warning = "", ""',
     "expected fixed daemon system warning"),
    ("R2 expiry comparison", "ten-day-z-backup-main",
     '    if age.total_seconds() < 0 or age <= timedelta(days=max_age):\n        return None',
     '    if age.total_seconds() < 0 or age > timedelta(days=max_age):\n        return None',
     "expected stale-backup warning"),
    ("R2 manifest tool", "wrong-tool-does-not-hide-old-main",
     'manifest.get("tool") != "drsg-memory-backup" or',
     'False or',
     "expected invalid newest manifest not to hide stale backup"),
    ("R2 zero disables", "zero-age-disables-main",
     '    if max_age == 0:\n        return ""',
     '    if max_age < 0:\n        return ""',
     "no valid backup found"),
]

survivors = []
runner_errors = []
for index, (label, case, old, new, cause) in enumerate(mutations, 1):
    if source.count(old) != 1:
        runner_errors.append("%s: expected one unique mutation anchor, got %d" %
                             (label, source.count(old)))
        continue
    mutant = pathlib.Path(tmp, "session-start-mutant-%d.py" % index)
    mutant.write_text(source.replace(old, new, 1), encoding="utf-8")
    try:
        proc = run_case(mutant, case)
    except Exception as exc:
        runner_errors.append("%s: test process failed to run (%s)" % (label, type(exc).__name__))
        continue
    lines = summary_lines(proc)
    expected_case_failure = any(line.startswith("FAIL " + case + " ") and cause in line
                                for line in lines)
    if proc.returncode != 0 and expected_case_failure:
        print("KILLED %s — %s" % (label, next(line for line in lines if line.startswith("FAIL " + case + " "))))
    elif proc.returncode == 0:
        survivors.append(label)
        print("SURVIVED %s — selected case passed" % label)
    else:
        runner_errors.append("%s: failed for an unexpected reason; output=%r" %
                             (label, lines or output_of(proc).strip()))

raise SystemExit(report_summary(survivors, runner_errors))
PY

#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
python3 - "$REPO" "$HERE/resume-lane-owner-line.sh" "$T" <<'PY'
import os
import pathlib
import shutil
import subprocess
import sys

repo, suite, temp = map(pathlib.Path, sys.argv[1:])
hooks = repo / "tools/templates/hooks"
mutations = [
    ("same-lane-comparison", "resume-same-lane",
     "if old is None or old == new:", "if old is None:"),
    ("latest-wins", "owner-context",
     "以本条为准，更早的车道声明作废", ""),
    ("no-event-owner-context", "session-start",
     'parts = [owner_context] if owner_context else []', 'parts = []'),
    ("default-lane-comparison", "lane-to-default",
     "if old is None or old == new:",
     'if old is None or old == new or (old == ["*"] and new != ["*"]):'),
    ("pending-consume-record", "prompt-consumes-pending",
     'return write_last_lanes(proj_dir, sid, pending.get("new_lanes", []))',
     'return False'),
]
killed = survived = 0
for index, (name, only, old, new) in enumerate(mutations):
    root = pathlib.Path(temp) / ("mutation-%d" % index)
    root.mkdir()
    for source in ("drsg_hook_common.py", "session_start.py", "user_prompt.py"):
        shutil.copy2(hooks / source, root / source)
    target_name = "session_start.py" if name == "no-event-owner-context" else "drsg_hook_common.py"
    target = root / target_name
    text = target.read_text(encoding="utf-8")
    if old not in text:
        print("NOT RUN %s: mutation anchor missing" % name)
        continue
    target.write_text(text.replace(old, new, 1), encoding="utf-8")
    env = dict(os.environ, DRSG_TEST_HOOKS=str(root), ONLY=only)
    result = subprocess.run(["bash", str(suite)], cwd=repo, env=env,
                            capture_output=True, text=True)
    if result.returncode != 0:
        killed += 1
        print("killed %s" % name)
    else:
        survived += 1
        print("SURVIVED %s" % name)
        print(result.stdout)
if survived or killed != len(mutations):
    print("MUTATION RESULT: SURVIVED (%d/%d killed)" % (killed, len(mutations)))
    sys.exit(1)
print("MUTATION RESULT: ALL KILLED (%d)" % killed)
PY

#!/usr/bin/env bash
# PreCompact: compact_handoff.py prints the managed compact-instructions block
# so Claude Code appends it to the summary prompt as Additional Instructions.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
hook = pathlib.Path(os.environ.get(
    "COMPACT_HANDOFF_SOURCE", repo / "tools/templates/hooks/compact_handoff.py"))
template = (repo / "tools/templates/compact-instructions.md").read_text(encoding="utf-8")
only = os.environ.get("ONLY", "")
ran = passed = 0

BEGIN = "<!-- BEGIN DRSG COMPACT INSTRUCTIONS -->"
END = "<!-- END DRSG COMPACT INSTRUCTIONS -->"


def check(name, condition):
    global ran, passed
    if only and only != name:
        return
    ran += 1
    if condition:
        passed += 1
        print("ok   " + name)
    else:
        print("FAIL " + name)


def run(project, payload, **env):
    environ = dict(os.environ, CLAUDE_PROJECT_DIR=str(project),
                   XDG_DATA_HOME=str(project.parent / "xdg"))
    environ.pop("DRSG_COMPACT_HANDOFF", None)
    environ.update(env)
    result = subprocess.run([sys.executable, str(hook)], input=json.dumps(payload),
                            capture_output=True, text=True, env=environ, timeout=10)
    return result.returncode, result.stdout


def payload(trigger="manual"):
    return {"hook_event_name": "PreCompact", "trigger": trigger, "session_id": "s1",
            "transcript_path": "/nonexistent", "custom_instructions": None}


with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    proj = root / "proj"
    proj.mkdir()
    claude_md = proj / "CLAUDE.md"
    claude_md.write_text("# P\n\nbody\n\n%s\n%s%s\n" % (BEGIN, template, END), encoding="utf-8")

    code, out = run(proj, payload())
    check("managed block becomes the compact instructions",
          code == 0 and "# Compact instructions" in out and "[handoff:docs]" in out
          and "[handoff:files]" in out)
    check("output tells the summarizer the 交接 section is required",
          "「交接」" in out.split("# Compact instructions")[0])
    check("output is not the PostCompact empty JSON", out.strip() != "{}")
    check("alias comment is not sent to the summarizer", "handoff-aliases" not in out)
    check("project text outside the managed block is not sent", "body" not in out)
    code, auto = run(proj, payload("auto"))
    check("auto compaction gets the same instructions", code == 0 and auto == out)
    check("PreCompact writes no handoff record", not (root / "xdg").exists())

    code, out = run(proj, payload(), DRSG_COMPACT_HANDOFF="0")
    check("DRSG_COMPACT_HANDOFF=0 prints nothing", code == 0 and out == "")

    claude_md.write_text("# P\n\nno managed block\n", encoding="utf-8")
    code, out = run(proj, payload())
    check("opted-out project prints nothing", code == 0 and out == "")

    claude_md.write_text("%s\n%s\n%s\n" % (BEGIN, BEGIN, END), encoding="utf-8")
    code, out = run(proj, payload())
    check("malformed block prints nothing", code == 0 and out == "")

    claude_md.unlink()
    code, out = run(proj, payload())
    check("missing CLAUDE.md prints nothing", code == 0 and out == "")

    code, out = run(proj, {"hook_event_name": "PostCompact", "trigger": "manual"})
    check("PostCompact still emits empty JSON", code == 0 and out == "{}\n")

if only and ran == 0:
    print("FAIL requested assertion was not run: " + only)
    raise SystemExit(2)
print("PASS %d/%d" % (passed, ran))
raise SystemExit(0 if passed == ran else 1)
PY

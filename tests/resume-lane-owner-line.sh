#!/usr/bin/env bash
# Resume lane ownership state: isolated last-lane and pending contracts.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
env DRSG_EVENT_LANES=alpha sleep 300 >/dev/null 2>&1 & OWNER_A=$!
env DRSG_EVENT_LANES=beta sleep 300 >/dev/null 2>&1 & OWNER_B=$!
trap 'kill "$OWNER_A" "$OWNER_B" 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/mem" "$T/project/.drsg"
export HOME="$T/home" DRSG_MEM_DIR="$T/mem" CLAUDE_PROJECT_DIR="$T/project"
export OWNER_A OWNER_B
export EVENT_POLL_OWNER_PID="$OWNER_A"
export DRSG_EVENT_LANES="alpha"
ONLY="${ONLY:-}"
if [ "${1:-}" = "--mutations" ]; then
  exec bash "$HERE/resume-lane-owner-line-mutations.sh"
fi
python3 - "$REPO" "$T" "$ONLY" <<'PY'
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import sys

repo, temp, only = sys.argv[1:]
root = pathlib.Path(temp)
hooks = os.environ.get("DRSG_TEST_HOOKS", os.path.join(repo, "tools/templates/hooks"))
spec = importlib.util.spec_from_file_location(
    "drsg_hook_common", os.path.join(hooks, "drsg_hook_common.py"))
common = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = common
spec.loader.exec_module(common)
project = root / "project"

ran = passed = 0

def check(name, fn):
    global ran, passed
    if only and only not in (name, "all"):
        return
    ran += 1
    try:
        fn()
        passed += 1
        print("ok   " + name)
    except Exception as exc:
        print("FAIL %s: %s: %s" % (name, type(exc).__name__, exc))

def last_path(sid):
    p = hashlib.sha256(os.path.realpath(project).encode()).hexdigest()
    s = hashlib.sha256(sid.encode()).hexdigest()
    return pathlib.Path(os.environ["DRSG_MEM_DIR"]) / "hook-state/resume-lane-change" / p / (s + ".last.json")

def last_record(sid):
    return json.loads(last_path(sid).read_text(encoding="utf-8"))

def record_contract():
    writer = getattr(common, "write_last_lanes", None)
    reader = getattr(common, "read_last_lanes", None)
    assert callable(writer) and callable(reader), "last-lane helpers are missing"
    assert writer(str(project), "sid-alpha", ["alpha"])
    path = last_path("sid-alpha")
    data = json.loads(path.read_text(encoding="utf-8"))
    assert data == {"version": 1, "lanes": ["alpha"]}, data
    assert path.stat().st_mode & 0o777 == 0o600
    assert reader(str(project), "sid-alpha") == ["alpha"]
    assert writer(str(project), "sid-default", ["*"])
    assert reader(str(project), "sid-default") == ["*"]

check("last-record", record_contract)

def owner_context_contract():
    fn = getattr(common, "_owner_context", None)
    assert callable(fn), "owner context helper is missing"
    line = fn(str(project), "sid-owner", "resume")
    assert line and "resume" in line and os.environ["EVENT_POLL_OWNER_PID"] in line, repr(line)
    assert "alpha" in line and "以本条为准，更早的车道声明作废" in line, repr(line)
    assert "\n" not in line and "\r" not in line

check("owner-context", owner_context_contract)


def pending_contract():
    stage = getattr(common, "stage_resume_lane_change", None)
    take = getattr(common, "take_resume_lane_change", None)
    assert callable(stage) and callable(take), "pending helpers are missing"
    assert common.write_last_lanes(str(project), "sid-pending", ["alpha"])
    original_lanes = common._hook_lanes
    common._hook_lanes = lambda _pid: ["beta"]
    try:
        assert stage(str(project), "sid-pending")
    finally:
        common._hook_lanes = original_lanes
    assert last_record("sid-pending")["lanes"] == ["alpha"]
    pending = take(str(project), "sid-pending")
    assert pending and pending["old_lanes"] == ["alpha"] and pending["new_lanes"] == ["beta"]
    assert take(str(project), "sid-pending") is None
    assert common.write_last_lanes(str(project), "sid-corrupt", ["alpha"])
    last_path("sid-corrupt").write_text("{bad", encoding="utf-8")
    assert stage(str(project), "sid-corrupt") is None

check("pending-state", pending_contract)

def resume_same_lane_contract():
    assert common.write_last_lanes(str(project), "sid-same", ["alpha"])
    assert common.stage_resume_lane_change(str(project), "sid-same") is None
    assert common.take_resume_lane_change(str(project), "sid-same") is None

check("resume-same-lane", resume_same_lane_contract)

def default_lane_transition_contract():
    sid = "sid-default-transition"
    assert common.write_last_lanes(str(project), sid, ["*"])
    original_lanes = common._hook_lanes
    common._hook_lanes = lambda _pid: ["alpha"]
    try:
        assert common.stage_resume_lane_change(str(project), sid)
    finally:
        common._hook_lanes = original_lanes

check("lane-to-default", default_lane_transition_contract)

def prompt_consumes_pending():
    up_spec = importlib.util.spec_from_file_location(
        "user_prompt", os.path.join(hooks, "user_prompt.py"))
    up = importlib.util.module_from_spec(up_spec)
    up_spec.loader.exec_module(up)
    sid = "sid-prompt"
    assert common.write_last_lanes(str(project), sid, ["alpha"])
    original_lanes = common._hook_lanes
    common._hook_lanes = lambda _pid: ["beta"]
    try:
        assert common.stage_resume_lane_change(str(project), sid)
    finally:
        common._hook_lanes = original_lanes
    up.event_notice = lambda *_args: []
    up.fetch_facts = lambda _token: []
    up.telemetry = lambda *_args: None
    up.load_env = lambda _path: None
    os.environ["DRSG_TOKEN"] = "fixture-token"
    os.environ["DRSG_API"] = "http://127.0.0.1:1/rpc"
    def invoke(prompt):
        old_in, old_out = sys.stdin, sys.stdout
        output = io.StringIO()
        try:
            sys.stdin, sys.stdout = io.StringIO(json.dumps(
                {"prompt": prompt, "session_id": sid})), output
            up.main()
        finally:
            sys.stdin, sys.stdout = old_in, old_out
        rows = output.getvalue().splitlines()
        assert len(rows) == 1
        return json.loads(rows[0])
    first = invoke("hello")
    assert "车道已变" in first.get("systemMessage", "")
    assert last_record(sid)["lanes"] == ["beta"]
    second = invoke("again")
    assert "systemMessage" not in second

check("prompt-consumes-pending", prompt_consumes_pending)

def prompt_event_notice_lines():
    up_spec = importlib.util.spec_from_file_location(
        "user_prompt", os.path.join(hooks, "user_prompt.py"))
    up = importlib.util.module_from_spec(up_spec)
    up_spec.loader.exec_module(up)
    up.event_notice = lambda *_args: ["EVENT ONE", "EVENT TWO"]
    up.event_owner = lambda *_args: "OWNER FIXTURE"
    up.fetch_facts = lambda _token: []
    up.telemetry = lambda *_args: None
    up.load_env = lambda _path: None
    os.environ["DRSG_TOKEN"] = "fixture-token"
    os.environ["DRSG_API"] = "http://127.0.0.1:1/rpc"

    def invoke(sid):
        old_in, old_out = sys.stdin, sys.stdout
        output = io.StringIO()
        try:
            sys.stdin, sys.stdout = io.StringIO(json.dumps(
                {"prompt": "hello", "session_id": sid})), output
            up.main()
        finally:
            sys.stdin, sys.stdout = old_in, old_out
        assert len(output.getvalue().splitlines()) == 1
        return up.NOTICE

    header = "⏳ drsg memory — open for this project:"
    no_pending = invoke("sid-event-lines")
    assert no_pending.splitlines() == [header, "OWNER FIXTURE", "EVENT ONE", "EVENT TWO"]
    assert "\\n" not in no_pending

    sid = "sid-event-lines-pending"
    assert common.write_last_lanes(str(project), sid, ["alpha"])
    original_lanes = common._hook_lanes
    common._hook_lanes = lambda _pid: ["beta"]
    try:
        assert common.stage_resume_lane_change(str(project), sid)
    finally:
        common._hook_lanes = original_lanes
    with_pending = invoke(sid)
    lines = with_pending.splitlines()
    assert lines[0] == header and len(lines) == 4, lines
    assert "车道已变" in lines[1] and lines[2:] == ["EVENT ONE", "EVENT TWO"], lines
    assert with_pending.count("车道已变") == 1
    assert "\\n" not in with_pending

check("prompt-event-notice-lines", prompt_event_notice_lines)

def unconsumed_pending_survives_resume():
    sid = "sid-two-processes"
    assert common.write_last_lanes(str(project), sid, ["alpha"])
    original_pid, original_lanes = common._claude_pid, common._hook_lanes
    common._claude_pid = lambda: int(os.environ["OWNER_A"])
    common._hook_lanes = lambda _pid: ["beta"]
    try:
        assert common.stage_resume_lane_change(str(project), sid)
        common._claude_pid = lambda: int(os.environ["OWNER_B"])
        assert common.stage_resume_lane_change(str(project), sid)
        assert common.read_last_lanes(str(project), sid) == ["alpha"]
        pending = common.take_resume_lane_change(str(project), sid)
        assert pending and pending["old_lanes"] == ["alpha"]
        assert common.commit_resume_lane_change(str(project), sid, pending)
        assert common.read_last_lanes(str(project), sid) == ["beta"]
    finally:
        common._claude_pid, common._hook_lanes = original_pid, original_lanes

check("last-record", unconsumed_pending_survives_resume)

def session_start_lifecycle():
    start_spec = importlib.util.spec_from_file_location(
        "session_start", os.path.join(hooks, "session_start.py"))
    start = importlib.util.module_from_spec(start_spec)
    start_spec.loader.exec_module(start)
    sid = "sid-startup-lifecycle"
    original_lanes = common._hook_lanes
    names = ("rpc", "load_env", "project_id", "ensure_briefing", "heal_text",
             "orphan_facts", "open_events", "protocol", "telemetry")
    originals = {name: getattr(start, name) for name in names}
    lanes = ["alpha"]
    common._hook_lanes = lambda _pid: list(lanes)
    start.rpc = lambda *_args, **_kwargs: {}
    start.load_env = lambda _path: None
    start.project_id = lambda *_args: 1
    start.ensure_briefing = lambda *_args: ("", 0)
    start.heal_text = lambda *_args: 0
    start.orphan_facts = lambda *_args: []
    start.open_events = lambda *_args: []
    start.protocol = lambda *_args: "[write-memory protocol]"
    start.telemetry = lambda *_args: None
    os.environ["DRSG_TOKEN"] = "fixture-token"
    os.environ["DRSG_API"] = "http://127.0.0.1:1/rpc"
    def invoke(source):
        old_in, old_out = sys.stdin, sys.stdout
        output = io.StringIO()
        try:
            sys.stdin = io.StringIO(json.dumps({"session_id": sid, "source": source,
                                                "transcript_path": "/not/read"}))
            sys.stdout = output
            start.main()
        finally:
            sys.stdin, sys.stdout = old_in, old_out
        rows = output.getvalue().splitlines()
        assert len(rows) == 1
        return json.loads(rows[0])
    try:
        startup_output = invoke("startup")
        context = startup_output["hookSpecificOutput"].get("additionalContext", "")
        assert context.count("当前声明车道") == 1 and "以本条为准，更早的车道声明作废" in context
        original_context = common._owner_context
        try:
            common._owner_context = lambda *_args: ""
            baseline_output = invoke("startup")
        finally:
            common._owner_context = original_context
        baseline_chars = len(baseline_output["hookSpecificOutput"].get("additionalContext", ""))
        current_chars = len(context)
        print("STARTUP_ADDITIONAL_CONTEXT_DELTA=%d" % (current_chars - baseline_chars))
        assert current_chars > baseline_chars
        assert common.read_last_lanes(str(project), sid) == ["alpha"]
        lanes[:] = ["beta"]
        resume_output = invoke("resume")
        assert "来源 resume" in resume_output["hookSpecificOutput"]["additionalContext"]
        assert common.read_last_lanes(str(project), sid) == ["alpha"]
        assert common.take_resume_lane_change(str(project), sid)
        lanes[:] = ["gamma"]
        clear_output = invoke("clear")
        assert "来源 clear" in clear_output["hookSpecificOutput"]["additionalContext"]
        assert common.read_last_lanes(str(project), sid) == ["gamma"]
        lanes[:] = ["delta"]
        compact_output = invoke("compact")
        assert "来源 compact" in compact_output["hookSpecificOutput"]["additionalContext"]
        assert common.read_last_lanes(str(project), sid) == ["gamma"]

        assert common.write_last_lanes(str(project), sid, ["alpha"])
        lanes[:] = ["beta"]
        start.rpc = lambda *_args, **_kwargs: (_ for _ in ()).throw(OSError("fixture daemon down"))
        down_output = invoke("resume")
        down_context = down_output["hookSpecificOutput"].get("additionalContext", "")
        assert "当前声明车道" not in down_context
        assert common.take_resume_lane_change(str(project), sid)
    finally:
        common._hook_lanes = original_lanes
        for name, value in originals.items():
            setattr(start, name, value)
        os.environ.pop("DRSG_TOKEN", None)
        os.environ.pop("DRSG_API", None)
        no_token_sid = "sid-no-token"
        old_in, old_out = sys.stdin, sys.stdout
        output = io.StringIO()
        try:
            sys.stdin = io.StringIO(json.dumps({"session_id": no_token_sid, "source": "startup"}))
            sys.stdout = output
            start.main()
        finally:
            sys.stdin, sys.stdout = old_in, old_out
        assert not last_path(no_token_sid).exists()

check("session-start", session_start_lifecycle)

if ran == 0:
    print("FAIL unknown-only-case: " + only)
    ran = 1
print("PASS %d/%d" % (passed, ran))
sys.exit(0 if passed == ran else 1)
PY

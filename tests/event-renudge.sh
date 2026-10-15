#!/usr/bin/env bash
# Deterministic tests for one-shot reminders of still-open handoffs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY="${ONLY:-}"
case "$ONLY" in
  ""|renudge|one-shot|notice|legacy) ;;
  *) printf 'FAIL event-renudge: unknown ONLY case %s\n' "$ONLY"; exit 2 ;;
esac
python3 - "$HERE/../tools/event-poller.py" "$ONLY" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
from types import SimpleNamespace
from unittest import mock

POLLER_PATH, only = sys.argv[1:3]
POLLER_PATH = os.environ.get("POLLER", POLLER_PATH)
os.environ.pop("EVENT_POLL_RENUDGE", None)
spec = importlib.util.spec_from_file_location("event_poller_under_test", POLLER_PATH)
poller = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = poller
spec.loader.exec_module(poller)

RERUN_SENTENCE = "如果你已经在处理这条，继续做完就行，不要重做；如果你把它挂起了，现在继续，或者给发件方发一条 notice，写明在等什么。"
RENUDGE_MARKER = "↻ 再提醒（已等待 30 分钟）"
OWNER_PID, OWNER_START = 901, 90
ran = failed = 0


def check(label, got, want):
    global ran, failed
    ran += 1
    if got == want:
        print("ok   " + label)
    else:
        failed += 1
        print("FAIL %s: got %r want %r" % (label, got, want))


check("re-nudge interval defaults to 1800 seconds", poller.EVENT_POLL_RENUDGE, 1800)


class Clock:
    def __init__(self, now):
        self.now = now


def case_env(root, events, seen=None):
    project = str(root / "project")
    state = root / "state"
    state.mkdir(parents=True)
    fake = root / "events.json"
    fake.write_text(json.dumps(events), encoding="utf-8")
    seen_path = state / (poller.tag("sid", OWNER_PID) + ".seen.json")
    poller.write_json(str(state / "lease.json"), {
        "session_id": "sid", "pid": OWNER_PID, "start": OWNER_START,
        "bg": False, "updated": 100000,
    })
    if seen is not None:
        seen_path.write_text(json.dumps(seen), encoding="utf-8")
    return project, state, fake, seen_path


def run_poll(project, state, fake, clock, output):
    lanes = SimpleNamespace(
        process_lanes=lambda _pid: ["*"],
        lease_name=lambda lane: "lease.json" if lane == "*" else "lease.%s.json" % lane,
    )
    try:
        with mock.patch.dict(os.environ, {"EVENT_POLL_FAKE": str(fake)}), \
             mock.patch.object(poller, "owner_process", return_value=(OWNER_PID, OWNER_START)), \
             mock.patch.object(poller, "background", return_value=False), \
             mock.patch.object(poller, "alive",
                               side_effect=lambda pid, start: (pid, start) == (OWNER_PID, OWNER_START)), \
             mock.patch.object(poller, "event_module", return_value=lanes), \
             mock.patch.object(poller, "lane_of", return_value="*"), \
             mock.patch.object(poller, "wait", side_effect=StopIteration), \
             mock.patch.object(poller, "MIN_POLL_LIFETIME", 0, create=True), \
             mock.patch.object(poller, "EVENT_POLL_RENUDGE", 1800, create=True), \
             mock.patch.object(poller.time, "time", side_effect=lambda: clock.now), \
             mock.patch.object(poller.time, "monotonic", side_effect=lambda: clock.now), \
             contextlib.redirect_stderr(output):
            return poller.poll(project, str(state), "sid")
    except StopIteration:
        return None


def open_handoff(key="evt-old"):
    return {"key": key, "kind": "handoff", "summary": "handoff", "status": "open"}


def test_renudge(root):
    clock = Clock(100000)
    project, state, fake, _ = case_env(root, [open_handoff()])
    first_output = io.StringIO()
    first_result = run_poll(project, state, fake, clock, first_output)
    check("first handoff is announced normally", first_result, 2)
    check("first wake is not a re-nudge", RENUDGE_MARKER in first_output.getvalue(), False)

    clock.now += 1801
    output = io.StringIO()
    result = run_poll(project, state, fake, clock, output)
    text = output.getvalue()
    check("open handoff is re-announced after the interval", result, 2)
    check("re-nudge has a separate elapsed-time marker", RENUDGE_MARKER in text, True)
    check("re-nudge includes the exact continue-or-notify guidance", RERUN_SENTENCE in text, True)
    check("re-nudge identifies the original Event", "evt-old" in text, True)


def test_one_shot(root):
    clock = Clock(200000)
    project, state, fake, seen_path = case_env(root, [open_handoff("evt-once")])
    run_poll(project, state, fake, clock, io.StringIO())
    clock.now += 1801
    second_output = io.StringIO()
    second_result = run_poll(project, state, fake, clock, second_output)
    check("eligible handoff is re-nudged once", second_result, 2)
    clock.now += 1
    third_output = io.StringIO()
    third_result = run_poll(project, state, fake, clock, third_output)
    saved = json.loads(seen_path.read_text(encoding="utf-8"))
    check("third poll does not announce the handoff again", third_result, None)
    check("third poll emits no wake text", third_output.getvalue(), "")
    saved_events = saved.get("events", {}) if isinstance(saved, dict) else {}
    check("one-shot state is persisted before waking",
          saved_events.get("evt-once", {}).get("renudged"), True)


def test_notice(root):
    clock = Clock(300000)
    project, state, fake, seen_path = case_env(root, [{
        "key": "evt-notice", "kind": "notice", "summary": "notice", "status": "open",
    }])
    first_result = run_poll(project, state, fake, clock, io.StringIO())
    saved = json.loads(seen_path.read_text(encoding="utf-8"))
    saved_events = saved.get("events", {}) if isinstance(saved, dict) else {}
    check("notice first-wake metadata is stored", saved_events.get("evt-notice"),
          {"first_wake": clock.now, "renudged": False})
    clock.now += 1801
    output = io.StringIO()
    second_result = run_poll(project, state, fake, clock, output)
    check("open notice is announced once", first_result, 2)
    check("open notice is not re-nudged", second_result, None)
    check("notice produces no second wake", output.getvalue(), "")


def test_legacy(root):
    clock = Clock(400000)
    project, state, fake, seen_path = case_env(
        root, [open_handoff("evt-legacy")], seen=["evt-legacy"])
    output = io.StringIO()
    result = run_poll(project, state, fake, clock, output)
    saved = json.loads(seen_path.read_text(encoding="utf-8"))
    check("legacy seen list does not replay its Event", result, None)
    check("legacy seen list produces no wake", output.getvalue(), "")
    version = saved.get("version") if isinstance(saved, dict) else None
    saved_events = saved.get("events", {}) if isinstance(saved, dict) else {}
    check("legacy list is migrated to versioned state", version, 1)
    check("legacy key is preserved without a re-nudge timestamp",
          saved_events.get("evt-legacy"),
          {"first_wake": None, "renudged": True})


cases = [
    ("renudge", test_renudge),
    ("one-shot", test_one_shot),
    ("notice", test_notice),
    ("legacy", test_legacy),
]
with tempfile.TemporaryDirectory(prefix="event-renudge-") as temp:
    root = pathlib.Path(temp)
    for name, run in cases:
        if not only or only == name:
            case_root = root / name
            case_root.mkdir()
            run(case_root)

print("PASS %d/%d" % (ran - failed, ran))
sys.exit(1 if failed else 0)
PY

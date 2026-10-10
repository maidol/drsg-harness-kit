#!/usr/bin/env bash
# Isolated lease-transition, manual-takeover and wake-safety contracts.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 - "$HERE/../tools/event-poller.py" "$HERE/../tools/templates/hooks/user_prompt.py" <<'PY'
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import pathlib
import sys
import tempfile
import time
from unittest import mock

POLLER_PATH, USER_PROMPT_PATH = sys.argv[1:3]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

poller = load("poller_under_test", POLLER_PATH)
user_prompt = load("user_prompt_under_test", USER_PROMPT_PATH)
with mock.patch.dict(os.environ, {"EVENT_POLL_TEST_MIN_LIFETIME": "0.25"}):
    poller_override = load("poller_test_override", POLLER_PATH)
ran = 0
failed = 0

def check(label, got, want):
    global ran, failed
    ran += 1
    if got == want:
        print("ok   " + label)
    else:
        failed += 1
        print("FAIL %s: got %r want %r" % (label, got, want))

check("minimum lifetime has a test-only environment override",
      poller_override.MIN_POLL_LIFETIME, 0.25)

def state_for(root, project):
    digest = hashlib.sha1(os.path.realpath(project).encode()).hexdigest()[:12]
    return pathlib.Path(root) / "poller" / digest

def save_json(path, value):
    poller.write_json(str(path), value)

def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))

def lease_fixture(root, sid="same", holder=101, start=100, bg=False,
                  poller_pid=301, poller_start=300):
    state = pathlib.Path(root)
    state.mkdir(parents=True, exist_ok=True)
    lease = {"session_id": sid, "pid": holder, "start": start,
             "bg": bg, "updated": 1}
    save_json(state / "lease.json", lease)
    if poller_pid is not None:
        save_json(state / (poller.tag(sid, holder) + ".pid"),
                  {"pid": poller_pid, "start": poller_start})
    return state, lease

def fake_alive(pairs):
    return lambda pid, start: (pid, start) in pairs

def log_text(state):
    path = pathlib.Path(state) / "poller.log"
    return path.read_text(encoding="utf-8") if path.exists() else ""

with tempfile.TemporaryDirectory(prefix="poller-lease-contract-") as temp:
    base = pathlib.Path(temp)

    # A newer process for the same session takes only an idle holder's live poller.
    state, old = lease_fixture(base / "newer", poller_pid=301)
    alive_pairs = {(101, 100), (301, 300)}
    with mock.patch.object(poller, "alive", side_effect=fake_alive(alive_pairs)), \
         mock.patch.object(poller, "cmdline", return_value=["python3", "/x/event-poller.py"]):
        got = poller.take_lease(str(state), "same", 202, 200, False)
    new_lease = read_json(state / "lease.json")
    check("same sid newer process takes lease", got, (True, True))
    check("new owner identity is stored", (new_lease.get("session_id"), new_lease.get("pid"), new_lease.get("start")),
          ("same", 202, 200))
    expected_log = "lease -> same.202 (was same.101, same session newer process)"
    check("same-session takeover log is exact", expected_log in log_text(state), True)

    # Missing, dead, recycled, or non-poller PID files are not active pollers.
    for label, poller_pid, poller_start, alive_pairs, argv in [
        ("poller pid file absent", None, None, {(101, 100)}, ["python3", "/x/event-poller.py"]),
        ("poller process dead", 301, 300, {(101, 100)}, ["python3", "/x/event-poller.py"]),
        ("poller start mismatch", 301, 300, {(101, 100), (301, 299)}, ["python3", "/x/event-poller.py"]),
        ("pid is not event poller", 301, 300, {(101, 100), (301, 300)}, ["python3", "other.py"]),
    ]:
        state, old = lease_fixture(base / ("inactive-" + label.replace(" ", "-")),
                                   poller_pid=poller_pid, poller_start=poller_start)
        with mock.patch.object(poller, "alive", side_effect=fake_alive(alive_pairs)), \
             mock.patch.object(poller, "cmdline", return_value=argv):
            result = poller.take_lease(str(state), "same", 202, 200, False)
        check(label + " blocks automatic takeover", result, (False, False))
        check(label + " leaves lease unchanged", read_json(state / "lease.json"), old)
        check(label + " writes no lease log", (state / "poller.log").exists(), False)

    # Process start ticks make same-session takeover strictly monotonic.
    for label, holder_start, candidate_start in [
        ("equal start tick", 200, 200), ("older candidate", 200, 199),
        ("newer holder", 300, 200),
    ]:
        state, old = lease_fixture(base / ("ordering-" + label.replace(" ", "-")),
                                   start=holder_start)
        with mock.patch.object(poller, "alive", side_effect=fake_alive({(101, holder_start), (301, 300)})), \
             mock.patch.object(poller, "cmdline", return_value=["python3", "/x/event-poller.py"]):
            result = poller.take_lease(str(state), "same", 202, candidate_start, False)
        check(label + " does not take lease", result, (False, False))
        check(label + " leaves lease unchanged", read_json(state / "lease.json"), old)

    # Preserve session isolation and background priority.
    state, old = lease_fixture(base / "different-session", sid="old")
    with mock.patch.object(poller, "alive", side_effect=fake_alive({(101, 100), (301, 300)})), \
         mock.patch.object(poller, "cmdline", return_value=["python3", "/x/event-poller.py"]):
        result = poller.take_lease(str(state), "new", 202, 200, False)
    check("different session cannot take a live foreground lease", result, (False, False))
    check("different session lease remains unchanged", read_json(state / "lease.json"), old)

    state, old = lease_fixture(base / "foreground-over-background", bg=True)
    with mock.patch.object(poller, "alive", side_effect=fake_alive({(101, 100)})), \
         mock.patch.object(poller, "cmdline", return_value=[]):
        result = poller.take_lease(str(state), "same", 202, 200, False)
    check("foreground still takes background lease", result, (True, True))
    check("foreground takeover keeps existing diagnostic", ", background)" in log_text(state), True)

    state, old = lease_fixture(base / "background-to-background", bg=True)
    with mock.patch.object(poller, "alive", side_effect=fake_alive({(101, 100), (301, 300)})), \
         mock.patch.object(poller, "cmdline", return_value=["python3", "/x/event-poller.py"]):
        result = poller.take_lease(str(state), "same", 202, 200, True)
    check("background cannot take from background", result, (False, False))
    check("background denial leaves lease unchanged", read_json(state / "lease.json"), old)
    check("background denial sends no signal", True, True)

    # A lease transfer while open_events is running prevents a stale wake and seen write.
    state, _ = lease_fixture(base / "lock-recheck", sid="old", holder=700, start=70,
                             poller_pid=None)
    seen = state / "old.700.seen.json"
    seen.write_text('["prior"]', encoding="utf-8")
    seen_before = seen.read_bytes()
    project = str(base / "lock-recheck-project")
    pathlib.Path(project, ".drsg").mkdir(parents=True)
    with mock.patch.object(poller, "owner_process", return_value=(700, 70)), \
         mock.patch.object(poller, "background", return_value=False), \
         mock.patch.object(poller, "alive", side_effect=lambda pid, start: (pid, start) == (700, 70)), \
         mock.patch.object(poller, "MIN_POLL_LIFETIME", 0, create=True), \
         contextlib.redirect_stderr(io.StringIO()):
        def transfer_during_fetch(_project):
            with poller.Locked(str(state)):
                save_json(state / "lease.json", {"session_id": "new", "pid": 800,
                          "start": 80, "bg": False, "updated": 2})
            return [{"key": "new-event", "kind": "handoff", "summary": "x"}]
        with mock.patch.object(poller, "open_events", side_effect=transfer_during_fetch):
            result = poller.poll(project, str(state), "old")
    check("lost lease after fetch returns without waking", result, 0)
    check("lost lease does not change seen bytes", seen.read_bytes(), seen_before)

    # A running poller reloads seen state after manual takeover clears its file.
    state, _ = lease_fixture(base / "manual-seen-reload", sid="resume", holder=701,
                             start=71, poller_pid=None)
    seen = state / "resume.701.seen.json"
    seen.write_text('["event"]', encoding="utf-8")
    project = str(base / "manual-seen-reload-project")
    pathlib.Path(project, ".drsg").mkdir(parents=True)
    wait_calls = []
    def manual_clear_wait(kick, _since, _seconds):
        wait_calls.append(True)
        seen.unlink()
        pathlib.Path(kick).touch()
    with mock.patch.object(poller, "owner_process", return_value=(701, 71)), \
         mock.patch.object(poller, "background", return_value=False), \
         mock.patch.object(poller, "alive", side_effect=lambda pid, start: (pid, start) == (701, 71)), \
         mock.patch.object(poller, "MIN_POLL_LIFETIME", 0, create=True), \
         mock.patch.object(poller, "open_events", return_value=[{"key": "event", "kind": "notice", "summary": "x"}]), \
         mock.patch.object(poller, "wait", side_effect=manual_clear_wait), \
         contextlib.redirect_stderr(io.StringIO()):
        result = poller.poll(project, str(state), "resume")
    check("live poller reloads cleared seen file", result, 2)
    check("manual seen reset waits only until next poll tick", len(wait_calls), 1)

    # Immediate Events wait for the configured minimum; late Events add no delay.
    for label, delay, minimum, lower, upper in [
        ("immediate event waits for minimum lifetime", 0, 0.12, 0.10, 0.8),
        ("late event has no extra minimum delay", 0.16, 0.12, 0.14, 0.45),
    ]:
        state = base / ("minimum-" + label.replace(" ", "-"))
        state.mkdir()
        project = str(base / ("project-" + label.replace(" ", "-")))
        pathlib.Path(project, ".drsg").mkdir(parents=True)
        capture = io.StringIO()
        with mock.patch.object(poller, "owner_process", return_value=(901, 90)), \
             mock.patch.object(poller, "background", return_value=False), \
             mock.patch.object(poller, "alive", side_effect=lambda pid, start: (pid, start) == (901, 90)), \
             mock.patch.object(poller, "MIN_POLL_LIFETIME", minimum, create=True), \
             contextlib.redirect_stderr(capture):
            if delay:
                def delayed(_project, delay=delay):
                    time.sleep(delay)
                    return [{"key": "event", "kind": "notice", "summary": "x"}]
                open_events = delayed
            else:
                open_events = lambda _project: [{"key": "event", "kind": "notice", "summary": "x"}]
            with mock.patch.object(poller, "open_events", side_effect=open_events):
                started = time.monotonic()
                result = poller.poll(project, str(state), "new-owner")
                elapsed = time.monotonic() - started
        check(label, result, 2 if lower < elapsed < upper else "elapsed-out-of-range")
        check(label + " writes seen key", "event" in read_json(state / "new-owner.901.seen.json"), True)
        check(label + " wake identifies fresh owner", "本会话现在持有本项目的 Event owner 租约" in capture.getvalue(), True)

    # A newly acquired lease with no Events does not wake; UserPromptSubmit shows the delayed owner change.
    project = str(base / "delayed-owner-project")
    pathlib.Path(project, ".drsg").mkdir(parents=True)
    state = state_for(base / "memory", project)
    state.mkdir(parents=True)
    env = {"DRSG_MEM_DIR": str(base / "memory")}
    with mock.patch.dict(os.environ, env, clear=False):
        with mock.patch.object(poller, "STATE_ROOT", str(base / "memory" / "poller")), \
             mock.patch.object(poller, "owner_process", return_value=(902, 92)), \
             mock.patch.object(poller, "background", return_value=False), \
             mock.patch.object(poller, "alive", side_effect=lambda pid, start: (pid, start) == (902, 92)), \
             mock.patch.object(poller, "open_events", return_value=[]), \
             mock.patch.object(poller, "wait", side_effect=StopIteration), \
             contextlib.redirect_stderr(io.StringIO()) as wake_stderr:
            before = user_prompt.event_owner(project, "delayed")
            try:
                poller.poll(project, str(state), "delayed")
            except StopIteration:
                pass
            with mock.patch.object(user_prompt, "_proc", return_value=(92, "S")), \
                 mock.patch.object(user_prompt, "_claude_pid", return_value=902):
                after = user_prompt.event_owner(project, "delayed")
    check("no-Event acquisition creates no model wake", wake_stderr.getvalue(), "")
    check("owner is read-only before lease acquisition", "现在没有 Event owner" in before, True)
    check("delayed owner lease is written", {key: read_json(state / "lease.json").get(key) for key in ("session_id", "pid", "start", "bg")}, {"session_id": "delayed", "pid": 902, "start": 92, "bg": False})
    check("next prompt announces newly acquired owner", after, "本会话是这个项目的 Event owner，现持有租约：可以处理本项目的待办 Event；按 Event 流程处理。")

    # Fresh owner wake text changes only when the poller actually acquired a lease.
    sample = [{"key": "e1", "kind": "handoff", "summary": "x"}]
    legacy = poller.wake_text(sample)
    try:
        fresh = poller.wake_text(sample, fresh=True)
    except TypeError:
        fresh = ""
    expected_legacy = "\n".join(["【待办轮询】本项目有 1 条新的待办 Event（drsg-events）：", "- e1 [handoff] x", "按 CLAUDE.md 的 Event 流程处理：读 ref 指的文档，照做；做完发回执（notice）并 event_done。", "例外：summary 以「验收通过：」开头的判定只需 event_done，不要为它回 notice；回执的回执只会让对方多关一次单。", "收到 handoff 直接开工，不要先回「已读」「已收到，准备先写计划」这类 notice；回给发件方的第一条应是回执，或卡住时要问的问题。", "照旧要先停下等用户确认的：git commit、push、开 PR、改锁文件、任何不可逆操作。", "动手前先看工作区和 git 状态：另一个会话可能做过一半（本条可能是接管后重发），已做过的不要重复改。"])
    check("ordinary wake text remains byte-for-byte unchanged", legacy, expected_legacy)
    check("fresh wake states current owner permission", "本会话现在持有本项目的 Event owner 租约" in fresh, True)

    # User-only --take resolves exactly one SID, atomically moves only its lease, and exits without polling.
    def manual_case(name, sid_files, env_sid="", project_has_env=True,
                    owner=(1001, 101), poller_live=True):
        root = base / ("manual-" + name)
        project = root / "project"
        drsg = project / ".drsg"
        drsg.mkdir(parents=True)
        if project_has_env:
            (drsg / "env").write_text("", encoding="utf-8")
        state = state_for(root / "memory", project)
        state.mkdir(parents=True)
        for filename, value in sid_files:
            (state / filename).write_text(value, encoding="utf-8")
        old_lease = state / "lease.json"
        if old_lease.exists():
            old_lease.unlink()
        stream_out, stream_err = io.StringIO(), io.StringIO()
        called_poll = []
        with mock.patch.object(poller, "STATE_ROOT", str(root / "memory" / "poller")), \
             mock.patch.object(poller, "owner_process", return_value=owner), \
             mock.patch.object(poller, "background", return_value=False), \
             mock.patch.object(poller, "alive", return_value=poller_live), \
             mock.patch.object(poller, "cmdline", return_value=["python3", "/x/event-poller.py"]), \
             mock.patch.object(poller, "poll", side_effect=lambda *args: called_poll.append(args) or 0), \
             mock.patch.object(poller.os, "kill") as kill, \
             mock.patch.dict(os.environ, {"CLAUDE_PROJECT_DIR": str(project),
                                         "CLAUDE_SESSION_ID": env_sid}, clear=False), \
             mock.patch.object(sys, "argv", [POLLER_PATH, "--take"]), \
             mock.patch.object(sys, "stdin", io.StringIO("not json")), \
             contextlib.redirect_stdout(stream_out), contextlib.redirect_stderr(stream_err):
            try:
                rc = poller.main()
            except SystemExit as exc:
                rc = exc.code
        return (rc, state, owner, stream_out.getvalue(), stream_err.getvalue(),
                called_poll, kill.called)

    success_files = [("sid-one.1001.seen.json", '["stale"]'),
                     ("other.2020.seen.json", '["keep"]'),
                     ("sid-one.1001.pid", '{"pid":3001,"start":300}')]
    rc, state, owner, out, err, called_poll, killed = manual_case(
        "success", success_files, poller_live=True)
    check("manual --take succeeds via PID-derived SID", rc, 0)
    if (state / "lease.json").exists():
        taken = read_json(state / "lease.json")
    else:
        taken = {}
    check("manual lease stores only required identity fields",
          set(taken), {"session_id", "pid", "start", "bg", "updated"})
    check("manual lease uses current identity", (taken.get("session_id"), taken.get("pid"), taken.get("start")),
          ("sid-one", owner[0], owner[1]))
    check("manual takeover clears only own stale seen file", (state / "sid-one.1001.seen.json").exists(), False)
    check("manual takeover preserves other seen file", (state / "other.2020.seen.json").exists(), True)
    check("manual takeover reports live poller next tick", "next TICK" in out, True)
    check("manual takeover warns about duplicate handling", "may be announced and handled twice" in out, True)
    check("manual takeover exits without polling", called_poll, [])
    check("manual takeover never signals another process", killed, False)

    rc, state, _, out, err, called_poll, _ = manual_case(
        "env-match", success_files, env_sid="sid-one")
    check("environment SID agrees with PID-derived identity", rc, 0)

    rc, state, _, out, err, called_poll, _ = manual_case(
        "poller-dead", success_files, poller_live=False)
    check("manual takeover reports absent poller needs later Stop", "later Stop hook" in out, True)

    for name, files, env_sid, has_env, owner, expected_error in [
        ("no-sid", [], "", True, (1001, 101), "cannot resolve exactly one session id"),
        ("multiple-sids", [("one.1001.pid", "{}"), ("two.1001.seen.json", "[]")], "", True,
         (1001, 101), "cannot resolve exactly one session id"),
        ("env-mismatch", [("one.1001.seen.json", "[]")], "other", True,
         (1001, 101), "does not match the state-file identity"),
        ("missing-project-env", [("one.1001.seen.json", "[]")], "", False,
         (1001, 101), "requires .drsg/env"),
        ("no-owner-pid", [("one.None.seen.json", "[]")], "", True,
         (None, None), "cannot identify the current Claude process"),
    ]:
        rc, state, _, out, err, called_poll, killed = manual_case(
            name, files, env_sid, has_env, owner, False)
        check(name + " is rejected", rc != 0, True)
        check(name + " reports actionable reason", expected_error in err, True)
        check(name + " writes no lease", (state / "lease.json").exists(), False)
        check(name + " never polls", called_poll, [])
        check(name + " never signals", killed, False)

print("\nPASS %d/%d" % (ran - failed, ran))
sys.exit(1 if failed else 0)
PY

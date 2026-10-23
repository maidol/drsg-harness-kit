#!/usr/bin/env bash
# Hermetic ownership contracts for compact handoff records.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import types

repo = pathlib.Path(sys.argv[1])
hook_path = pathlib.Path(os.environ.get(
    "COMPACT_HANDOFF_SOURCE", repo / "tools/templates/hooks/compact_handoff.py"))
spec = importlib.util.spec_from_file_location("compact_handoff_ownership_test", hook_path)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
only = set(filter(None, os.environ.get("ONLY", "").split(",")))
ran = passed = 0


def check(name, body):
    global ran, passed
    if only and name not in only:
        return
    ran += 1
    if body():
        passed += 1
        print("ok   " + name)
    else:
        print("FAIL " + name)


def project(path):
    path.mkdir()
    subprocess.run(["git", "-C", str(path), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "Test"], check=True)
    transcript = path / "transcript.jsonl"
    transcript.write_text("fixture\n", encoding="utf-8")
    (path / "tracked.txt").write_text("fixture\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "transcript.jsonl", "tracked.txt"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "fixture"], check=True)
    return transcript


def install_common(pid=4101, proc=(701, "S", 1), lanes=("alpha", "beta")):
    hook._common = types.SimpleNamespace(
        _claude_pid=lambda: pid,
        _proc=lambda value: proc,
        _hook_lanes=lambda value: list(lanes))


def write_fixture(root, session_id, summary, **extra):
    proj = root / "project"
    transcript = proj / "transcript.jsonl"
    data = {"trigger": "manual", "session_id": session_id,
            "transcript_path": str(transcript), "compact_summary": summary}
    data.update(extra)
    hook.write_record(data)
    return proj


def owner_record_case():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg"),
                           "DRSG_COMPACT_HANDOFF": "1"})
        hook.open_events = lambda _project: []
        install_common()
        write_fixture(root, "owner-record", "owner summary")
        _, directory = hook.storage_dir(str(proj.resolve()))
        records = list(pathlib.Path(directory).glob("*.json"))
        saved = json.loads(records[0].read_text(encoding="utf-8"))
        return saved.get("owner") == {
            "pid": 4101, "start": 701, "lanes": ["alpha", "beta"]}


check("owner-record", owner_record_case)

def unknown_owner_case():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg")})
        hook.open_events = lambda _project: []
        def broken_pid():
            raise OSError("fixture")
        hook._common = types.SimpleNamespace(_claude_pid=broken_pid)
        write_fixture(root, "unknown-owner", "synthetic summary")
        _, directory = hook.storage_dir(str(proj.resolve()))
        saved = json.loads(next(pathlib.Path(directory).glob("*.json")).read_text())
        return "owner" in saved and saved["owner"] is None and saved["summary"] == "synthetic summary"


def unknown_owner_proc_case():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg")})
        hook.open_events = lambda _project: []
        hook._common = types.SimpleNamespace(_claude_pid=lambda: 4101,
                                             _proc=lambda _pid: None,
                                             _hook_lanes=lambda _pid: ["alpha"])
        write_fixture(root, "unknown-owner-proc", "synthetic summary")
        _, directory = hook.storage_dir(str(proj.resolve()))
        saved = json.loads(next(path for path in pathlib.Path(directory).glob("*.json")
                                if json.loads(path.read_text()).get("session_id") == "unknown-owner-proc").read_text())
        return saved.get("owner") is None and saved["summary"] == "synthetic summary"


check("owner-unknown", unknown_owner_case)
check("owner-unknown-proc", unknown_owner_proc_case)

def owner_lanes_case():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg")})
        hook.open_events = lambda _project: []
        install_common(lanes=("beta", "alpha", "beta"))
        write_fixture(root, "owner-lanes", "synthetic summary")
        _, directory = hook.storage_dir(str(proj.resolve()))
        saved = json.loads(next(pathlib.Path(directory).glob("*.json")).read_text())
        return saved.get("owner", {}).get("lanes") == ["alpha", "beta"]


check("owner-lanes", owner_lanes_case)

def owner_default_lane_case():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg")})
        hook.open_events = lambda _project: []
        install_common(lanes=())
        write_fixture(root, "owner-default-lane", "synthetic summary")
        _, directory = hook.storage_dir(str(proj.resolve()))
        saved = json.loads(next(pathlib.Path(directory).glob("*.json")).read_text())
        return saved.get("owner", {}).get("lanes") == ["*"]


check("owner-default-lane", owner_default_lane_case)

def legacy_owner_case():
    legacy = {"session_id": "legacy", "summary": "legacy summary"}
    normalized = getattr(hook, "normalize_owner", lambda _record: None)(legacy)
    return normalized == {"pid": None, "start": None, "lanes": ["*"]}

check("legacy-owner", legacy_owner_case)

def overwrite_same_session_case():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        transcript = project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg")})
        hook.open_events = lambda _project: []
        install_common()
        data = {"trigger": "manual", "session_id": "same-session",
                "transcript_path": str(transcript), "compact_summary": "first"}
        hook.write_record(data)
        hook.write_record({**data, "compact_summary": "second"})
        _, directory = hook.storage_dir(str(proj.resolve()))
        files = list(pathlib.Path(directory).glob("*.json"))
        record = json.loads(files[0].read_text())
        return len(files) == 1 and record["summary"] == "second"


check("overwrite-same-session", overwrite_same_session_case)

def sidechain_no_write_case():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        transcript = project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg")})
        hook.open_events = lambda _project: []
        install_common()
        data = {"trigger": "manual", "session_id": "sidechain",
                "transcript_path": str(transcript), "compact_summary": "synthetic"}
        for flags in ({"is_sidechain": True}, {"is_fork": True},
                      {"parent_session_id": "parent"}, {"agent_type": "fork"}):
            hook.write_record({**data, **flags})
        _, directory = hook.storage_dir(str(proj.resolve()))
        return not list(pathlib.Path(directory).glob("*.json"))


check("sidechain-no-write", sidechain_no_write_case)

from contextlib import contextmanager
import threading


@contextmanager
def sandbox():
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        transcript = project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj),
                           "XDG_DATA_HOME": str(root / "xdg"),
                           "DRSG_COMPACT_HANDOFF": "1"})
        hook.open_events = lambda _project: []
        yield root, proj, transcript


def saved_record(proj, session_id, owner, body, epoch=100, consumed=False):
    _, directory = hook.storage_dir(str(proj.resolve()))
    pathlib.Path(directory).mkdir(parents=True, exist_ok=True)
    path = pathlib.Path(directory) / (session_id + ".json")
    record = {"version": 1, "compaction_id": "id-" + session_id,
              "session_id": session_id, "project_path": str(proj.resolve()),
              "transcript_path": str(proj / "transcript.jsonl"),
              "created_at": str(epoch), "created_at_epoch": time.time() + epoch,
              "trigger": "manual", "summary": "## 交接\\n" + body,
              "consumed": consumed, "consumed_at": None, "owner": owner}
    path.write_text(json.dumps(record), encoding="utf-8")
    return path


def configure(current_pid=4101, current_start=701, current_lanes=("alpha",), proc_map=None, calls=None):
    proc_map = proc_map or {}
    calls = calls if calls is not None else {}
    def proc(pid):
        calls[pid] = calls.get(pid, 0) + 1
        if pid in proc_map:
            value = proc_map[pid]
            if isinstance(value, BaseException):
                raise value
            return value
        if pid == current_pid:
            return (current_start, "S", 1)
        return None
    hook._common = types.SimpleNamespace(
        _claude_pid=lambda: current_pid,
        _proc=proc,
        _hook_lanes=lambda _pid: list(current_lanes))
    return calls


def test_selection(name, records, current_pid=4101, current_start=701,
                   current_lanes=("alpha",), proc_map=None, expected=None):
    def body():
        with sandbox() as (_, proj, _):
            for args in records:
                saved_record(proj, *args)
            configure(current_pid, current_start, current_lanes, proc_map)
            text, pending = hook.prepare_handoff(str(proj), "clear", {})
            result = expected(text, pending, proj) if expected else bool(text and pending)
            if pending:
                pending.finish(False)
            return result
    check(name, body)


test_selection("legacy-record", [("legacy", None, "legacy owner sentinel", 90)],
    current_lanes=("*",),
    expected=lambda text, pending, _proj: bool(text and "legacy owner sentinel" in text and pending))

test_selection("pid-start-mismatch",
    [("old", {"pid": 4101, "start": 700, "lanes": ["alpha"]}, "old owner", 90)],
    expected=lambda text, pending, _proj: bool(text and "old owner" in text and pending))

for state in ("T", "t"):
    test_selection("process-states", [("paused", {"pid": 4201, "start": 801, "lanes": ["alpha"]},
                                      "paused sentinel", 90)],
        proc_map={4201: (801, state, 1)},
        expected=lambda text, pending, _proj: bool(text and "paused sentinel" not in text and
                                                   "仅计数" in text and pending is None))
for state in ("Z", "X"):
    test_selection("process-states", [("dead", {"pid": 4201, "start": 801, "lanes": ["alpha"]},
                                      "dead sentinel", 90)],
        proc_map={4201: (801, state, 1)},
        expected=lambda text, pending, _proj: bool(text and "dead sentinel" in text and pending))

def test_per_pid_cache():
    with sandbox() as (_, proj, _):
        for i in range(2):
            saved_record(proj, "same-owner-%d" % i,
                         {"pid": 4201, "start": 801, "lanes": ["alpha"]},
                         "same owner %d" % i, 90 + i)
        calls = configure(4301, 901, ("beta",), {4201: (801, "S", 1)})
        text, pending = hook.prepare_handoff(str(proj), "clear", {})
        if pending:
            pending.finish(False)
        return calls.get(4201) == 1 and text and "仍有 1 个" in text

check("per-pid-cache", test_per_pid_cache)

test_selection("lane-list-equality",
    [("single-lane", {"pid": 4201, "start": 801, "lanes": ["a"]}, "single lane sentinel", 90)],
    current_lanes=("a", "b"), proc_map={4201: (801, "Z", 1)},
    expected=lambda text, pending, _proj: bool(text and "single lane sentinel" not in text and
                                               "其他车道的已退出交接" in text and pending is None))

test_selection("select-own", [
    ("own", {"pid": 4101, "start": 701, "lanes": ["alpha"]}, "own sentinel", 90),
    ("dead", {"pid": 4201, "start": 801, "lanes": ["alpha"]}, "dead sentinel", 110)],
    proc_map={4201: (801, "Z", 1)},
    expected=lambda text, pending, _proj: bool(text and "own sentinel" in text and
                                               "dead sentinel" not in text and pending and
                                               len(pending.records) == 1))

test_selection("select-dead-same-lane",
    [("dead", {"pid": 4201, "start": 801, "lanes": ["alpha"]}, "dead same-lane sentinel", 90)],
    proc_map={4201: (801, "Z", 1)},
    expected=lambda text, pending, _proj: bool(text and "dead same-lane sentinel" in text and pending))

test_selection("list-dead-other-lane",
    [("other", {"pid": 4201, "start": 801, "lanes": ["beta"]}, "dead private sentinel", 90)],
    proc_map={4201: (801, "Z", 1)},
    expected=lambda text, pending, _proj: bool(text and "dead private sentinel" not in text and
                                               "其他车道的已退出交接" in text and
                                               "历史压缩交接" not in text and pending is None))

test_selection("count-live-other",
    [("live", {"pid": 4201, "start": 801, "lanes": ["alpha"]}, "live private sentinel", 90)],
    proc_map={4201: (801, "S", 1)},
    expected=lambda text, pending, _proj: bool(text and "live private sentinel" not in text and
                                               "仍有 1 个" in text and ".json" not in text and
                                               "历史压缩交接" not in text and pending is None))

test_selection("notice-order-and-combination", [
    ("own", {"pid": 4101, "start": 701, "lanes": ["alpha"]}, "own summary sentinel", 90),
    ("dead-other", {"pid": 4201, "start": 801, "lanes": ["beta"]}, "dead private sentinel", 91),
    ("live-other", {"pid": 4202, "start": 802, "lanes": ["alpha"]}, "live private sentinel", 92)],
    proc_map={4201: (801, "Z", 1), 4202: (802, "S", 1)},
    expected=lambda text, pending, _proj: bool(text and pending and
        text.index("own summary sentinel") < text.index("其他车道的已退出交接") < text.index("仍有 1 个") and
        "dead private sentinel" not in text and "live private sentinel" not in text))

test_selection("unknown-current-e2", [
    ("dead", {"pid": 4201, "start": 801, "lanes": ["legacy"]}, "eligible dead sentinel", 90),
    ("live-newest", {"pid": 4202, "start": 802, "lanes": ["other"]}, "live newest sentinel", 120)],
    current_pid=None, proc_map={4201: None, 4202: (802, "S", 1)},
    expected=lambda text, pending, _proj: bool(text and "eligible dead sentinel" in text and
                                               "live newest sentinel" not in text and pending))

test_selection("unknown-current-proc-unreadable", [
    ("fallback-old", {"pid": 4203, "start": 803, "lanes": ["x"]}, "fallback older", 90),
    ("fallback-new", {"pid": 4204, "start": 804, "lanes": ["y"]}, "fallback newest", 100)],
    current_pid=None, proc_map={4203: OSError("fixture"), 4204: OSError("fixture")},
    expected=lambda text, pending, _proj: bool(text and "fallback newest" in text and pending and
                                               len(pending.records) == 2))

def test_concurrent_clear():
    with sandbox() as (_, proj, _):
        saved_record(proj, "race", {"pid": 4101, "start": 701, "lanes": ["alpha"]},
                     "race sentinel", 90)
        configure()
        results = []
        def consume():
            text, pending = hook.prepare_handoff(str(proj), "clear", {})
            results.append(bool(text and "race sentinel" in text))
            if pending:
                pending.finish(bool(text))
        threads = [threading.Thread(target=consume) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        return results.count(True) == 1

check("concurrent-clear", test_concurrent_clear)

def test_render_compat():
    with sandbox() as (_, proj, _):
        path = saved_record(proj, "own", {"pid": 4101, "start": 701, "lanes": ["alpha"]},
                            "exact bytes", 90)
        record = json.loads(path.read_text())
        configure()
        text, pending = hook.prepare_handoff(str(proj), "startup", {})
        expected = hook.render_handoff(str(proj.resolve()), [(str(path), record)])
        if pending:
            pending.finish(False)
        return text == expected

check("render-single-byte-compat", test_render_compat)

test_selection("nothing-to-say-byte-compat", [],
    expected=lambda text, pending, _proj: text is None and pending is None)

def test_resume():
    with sandbox() as (_, proj, _):
        target = saved_record(proj, "resume-target", {"pid": 4101, "start": 701, "lanes": ["alpha"]},
                              "resume target sentinel", 90)
        saved_record(proj, "resume-other", {"pid": 4201, "start": 801, "lanes": ["alpha"]},
                     "other resume sentinel", 91)
        configure()
        text, pending = hook.prepare_handoff(str(proj), "resume", {"session_id": "resume-target"})
        matched = text is None and pending is not None and len(pending.records) == 1 and \
                  pending.records[0][0] == str(target)
        if pending:
            pending.finish(True)
        saved = json.loads(target.read_text())
        return matched and saved.get("consumed") is True

check("resume-consumes-own", test_resume)


def resume_no_injection_case():
    with sandbox() as (_, proj, _):
        saved_record(proj, "resume-target", {"pid": 4101, "start": 701, "lanes": ["alpha"]},
                     "resume target sentinel", 90)
        saved_record(proj, "resume-other", {"pid": 4201, "start": 801, "lanes": ["alpha"]},
                     "other resume sentinel", 91)
        configure()
        text, pending = hook.prepare_handoff(str(proj), "resume", {"session_id": "resume-target"})
        if pending:
            pending.finish(True)
        return text is None


def resume_no_match_case():
    with sandbox() as (_, proj, _):
        saved_record(proj, "resume-target", {"pid": 4101, "start": 701, "lanes": ["alpha"]},
                     "resume target sentinel", 90)
        saved_record(proj, "resume-other", {"pid": 4201, "start": 801, "lanes": ["alpha"]},
                     "other resume sentinel", 91)
        configure()
        text, pending = hook.prepare_handoff(str(proj), "resume", {"session_id": "missing"})
        return text is None and pending is None


check("resume-no-injection", resume_no_injection_case)
check("resume-no-match", resume_no_match_case)

def ttl_unchanged_case():
    with sandbox() as (_, proj, _):
        expired = saved_record(proj, "expired", {"pid": 4201, "start": 801, "lanes": ["alpha"]},
                               "expired sentinel", -73 * 3600)
        saved_record(proj, "fresh", {"pid": 4101, "start": 701, "lanes": ["alpha"]},
                     "fresh sentinel", 0)
        configure()
        hook.cleanup(str(hook.storage_dir(str(proj.resolve()))[1]), hook.time.time())
        return not expired.exists()


def limit_preserves_live_case():
    with sandbox() as (_, proj, _):
        saved_record(proj, "fresh", {"pid": 4101, "start": 701, "lanes": ["alpha"]},
                     "fresh sentinel", 0)
        for i in range(12):
            saved_record(proj, "live-%d" % i, {"pid": 5000 + i, "start": 900 + i,
                         "lanes": ["alpha"]}, "live %d" % i, 100 + i)
        configure(4101, 701, ("alpha",), {5000 + i: (900 + i, "S", 1) for i in range(12)})
        _, directory = hook.storage_dir(str(proj.resolve()))
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            hook.cleanup(directory, 200)
        live_records = [json.loads(path.read_text()) for path in pathlib.Path(directory).glob("*.json")]
        warning = stderr.getvalue()
        return (len(live_records) == 13 and all(not record.get("consumed") for record in live_records) and
                warning.count("record limit exceeded") == 1 and "live 0" not in warning)


check("ttl-unchanged", ttl_unchanged_case)
check("limit-preserves-live", limit_preserves_live_case)

def test_limit_prunes_dead():
    with sandbox() as (_, proj, _):
        for i in range(11):
            saved_record(proj, "dead-%02d" % i, {"pid": 5000 + i, "start": 900 + i,
                         "lanes": ["alpha"]}, "dead %d" % i, 100 + i)
        saved_record(proj, "consumed", {"pid": 5200, "start": 1200, "lanes": ["alpha"]},
                     "consumed sentinel", 200, consumed=True)
        proc_map = {5000 + i: (900 + i, "Z", 1) for i in range(11)}
        proc_map[5200] = (1200, "Z", 1)
        configure(4101, 701, ("alpha",), proc_map)
        _, directory = hook.storage_dir(str(proj.resolve()))
        hook.cleanup(directory, 300)
        remaining = [json.loads(path.read_text())["session_id"] for path in pathlib.Path(directory).glob("*.json")]
        return len(remaining) == 10 and "dead-00" not in remaining and "consumed" not in remaining

check("limit-prunes-dead", test_limit_prunes_dead)

def test_owner_scan_p95():
    with sandbox() as (_, proj, _):
        owners = {5000 + i: (900 + i, "S", 1) for i in range(10)}
        for i in range(10):
            saved_record(proj, "perf-%02d" % i,
                         {"pid": 5000 + i, "start": 900 + i, "lanes": ["alpha"]},
                         "synthetic", i)
        calls = configure(4101, 701, ("alpha",), owners)
        timings = []
        for _ in range(101):
            started = time.perf_counter()
            _, pending = hook.prepare_handoff(str(proj), "clear", {})
            if pending:
                pending.finish(False)
            timings.append((time.perf_counter() - started) * 1000)
        ordered = sorted(timings)
        p95 = ordered[int(len(ordered) * .95)]
        print("OWNER_SCAN_P95_MS=%.3f" % p95)
        return p95 <= 50 and all(calls.get(pid) == 101 for pid in owners)

check("owner-scan-p95", test_owner_scan_p95)

def test_readonly_doc_commands():
    import re
    checks = [
        (repo / "README.md", r"On Linux, list ownership metadata without printing summary or Event fields:"),
        (repo / "README.zh-CN.md", r"Linux 上可只列出 owner 元数据，不打印摘要或 Event 字段："),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        proj = root / "project"
        project(proj)
        data_home = root / "xdg"
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(data_home)})
        install_common()
        write_fixture(root, "doc-listing", "SECRET-SUMMARY-SENTINEL")
        _, directory = hook.storage_dir(str(proj.resolve()))
        for doc, heading in checks:
            content = doc.read_text(encoding="utf-8")
            match = re.search(heading + r"\n\n```bash\npython3 - <<'PY'\n(.*?)\nPY\n```", content, re.S)
            if not match:
                check("readonly-listing-commands", lambda: False)
                continue
            env = dict(os.environ)
            run = subprocess.run(["python3", "-"], input=match.group(1), text=True,
                                 capture_output=True, env=env)
            output = run.stdout
            check("readonly-listing-commands", lambda: run.returncode == 0 and
                  "SECRET-SUMMARY-SENTINEL" not in output and "5501" not in output and
                  "4101" in output and "alpha,beta" in output and
                  "/compact-handoffs/" in output and "False" in output)

if not only or "readonly-listing-commands" in only:
    test_readonly_doc_commands()

if only and ran == 0:
    print("NOT RUN: no selected ownership assertion matched")
    raise SystemExit(2)
print("OWNERSHIP RESULT: %d/%d" % (passed, ran))
raise SystemExit(0 if ran == passed else 1)
PY

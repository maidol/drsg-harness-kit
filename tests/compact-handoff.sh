#!/usr/bin/env bash
# Hermetic contracts for the PostCompact handoff writer.
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
import stat
import subprocess
import sys
import tempfile
import time

repo = pathlib.Path(sys.argv[1])
hook_path = pathlib.Path(os.environ.get(
    "COMPACT_HANDOFF_SOURCE", repo / "tools/templates/hooks/compact_handoff.py"))
spec = importlib.util.spec_from_file_location("compact_handoff_test", hook_path)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
default_open_events = hook.open_events
sys.modules["compact_handoff"] = hook
only = os.environ.get("ONLY", "")
ran = passed = 0


def check(name, body):
    global ran, passed
    if only and only != name:
        return
    ran += 1
    if body():
        passed += 1
        print("ok   " + name)
    else:
        print("FAIL " + name)


heading_forms = ("**交接**", "交接:", "## 交接", "10. 交接", "**10. 交接**")
check("all supported handoff heading forms are recognized", lambda: all(
    [title for _, title, _ in hook.selected_sections(
        heading + "\nbody\n\n1. Primary Request:\nrequest\n")] == ["交接"]
    for heading in heading_forms))
summary_with_close = "## 9 Optional Next Step\n继续验证。\n</summary>"
check("selected section omits closing summary tag", lambda: all(
    "</summary>" not in text
    for _, _, text in hook.selected_sections(summary_with_close)))


def project(path):
    path.mkdir()
    subprocess.run(["git", "-C", str(path), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.email", "test@example.com"], check=True)
    subprocess.run(["git", "-C", str(path), "config", "user.name", "Test"], check=True)
    (path / "tracked.txt").write_text("tracked\n", encoding="utf-8")
    transcript = path / "transcript.jsonl"
    transcript.write_text("not read by the hook\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "tracked.txt", "transcript.jsonl"], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-qm", "fixture"], check=True)
    return transcript


@contextlib.contextmanager
def writer_fixture():
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        proj = root / "project"
        transcript = project(proj)
        data_home = root / "xdg"
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(data_home),
                           "DRSG_API": "http://127.0.0.1:1/rpc", "DRSG_TOKEN": "fake-token",
                           "DRSG_PLANE": "memory"})
        old_events = hook.open_events
        hook.open_events = lambda path: [{"key": "event-%d" % i, "summary": "event %d" % i}
                                          for i in range(15)]
        fake_key = "sk-" + "x" * 32
        summary = "## 8 Current Work\nKeep <hidden> and redact " + fake_key + "."
        base = {"trigger": "manual", "session_id": "session-1",
                "transcript_path": str(transcript), "compact_summary": summary}
        try:
            hook.write_record(base)
            _, directory = hook.storage_dir(str(proj.resolve()))
            files = list(pathlib.Path(directory).glob("*.json"))
            record = json.loads(files[0].read_text(encoding="utf-8"))
            yield root, proj, transcript, base, fake_key, directory, files, record
        finally:
            hook.open_events = old_events


def project_key_case():
    with writer_fixture() as (_, proj, _, _, _, directory, _, _):
        return pathlib.Path(directory).name == __import__("hashlib").sha256(
            str(proj.resolve()).encode()).hexdigest()


def permissions_case():
    with writer_fixture() as (_, _, _, _, _, directory, files, _):
        return (stat.S_IMODE(pathlib.Path(directory).stat().st_mode) == 0o700 and
                stat.S_IMODE(files[0].stat().st_mode) == 0o600)


def safe_summary_case():
    fake_key = "sk-" + "x" * 32
    return fake_key not in hook.safe_summary(fake_key)


def persisted_summary_case():
    with writer_fixture() as (_, _, _, _, fake_key, _, files, record):
        return fake_key not in files[0].read_text() and "<hidden>" in record["summary"]


def events_bounded_case():
    with writer_fixture() as (_, _, _, _, _, _, _, record):
        return len(record["events"]) == 10 and record["events"][0]["summary"] == "event 0"


def git_metadata_case():
    with writer_fixture() as (_, _, _, _, _, _, _, record):
        return (record["branch"] != "unavailable" and
                len(record["git_status"]["paths"]) <= 50 and record["git_status"]["total"] == 0)


def same_session_case():
    with writer_fixture() as (_, _, _, base, _, directory, files, _):
        hook.write_record({**base, "compact_summary": "replacement"})
        return (len(list(pathlib.Path(directory).glob("*.json"))) == 1 and
                json.loads(files[0].read_text(encoding="utf-8"))["summary"] == "replacement")


def ten_records_case():
    with writer_fixture() as (_, _, _, base, _, directory, _, _):
        old_common = hook._common
        hook._common = type("NoOwner", (), {"_claude_pid": staticmethod(lambda: None)})()
        try:
            for i in range(12):
                hook.write_record({**base, "session_id": "session-%d" % i,
                                   "compact_summary": "summary %d" % i})
        finally:
            hook._common = old_common
        return len(list(pathlib.Path(directory).glob("*.json"))) == 10


def dirty_paths_case():
    with writer_fixture() as (_, proj, _, _, _, _, _, _):
        for i in range(55):
            (proj / ("dirty-%02d" % i)).write_text("x", encoding="utf-8")
        status = hook.git_status(str(proj))
        return len(status["paths"]) == 50 and status["total"] == 55


def unsupported_record_case():
    with writer_fixture() as (_, proj, _, base, _, directory, _, _):
        before = len(list(pathlib.Path(directory).glob("*.json")))
        hook.write_record({**base, "trigger": "other"})
        hook.write_record({**base, "is_sidechain": True})
        hook.write_record({**base, "compact_summary": ""})
        hook.write_record({**base, "transcript_path": str(proj / "missing")})
        return len(list(pathlib.Path(directory).glob("*.json"))) == before


def inside_project_storage_case():
    with writer_fixture() as (_, proj, _, _, _, _, _, _):
        os.environ["XDG_DATA_HOME"] = str(proj / "inside")
        try:
            hook.storage_dir(str(proj.resolve()))
            return False
        except ValueError:
            return True


check("realpath SHA-256 project key", project_key_case)
check("directory and record permissions", permissions_case)
check("safe_summary redacts before persistence", safe_summary_case)
check("summary redacted before disk", persisted_summary_case)
check("daemon failure keeps write and Event list is bounded", events_bounded_case)
check("Git metadata and status path bound", git_metadata_case)
# The same session replaces its prior summary; separate sessions are capped at ten.
check("same-session record replaced", same_session_case)
# Unknown owners are eligible for the legacy ten-record cap.
check("at most ten records retained", ten_records_case)
# More than fifty dirty paths are truncated without exposing porcelain status codes.
check("dirty path list capped at 50 with total", dirty_paths_case)
check("unsupported trigger, sidechain, empty summary and bad transcript skipped", unsupported_record_case)
# XDG storage resolving inside a project must fail closed.
check("XDG root inside project rejected", inside_project_storage_case)

@contextlib.contextmanager
def session_fixture(dirty=False):
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        proj = root / "start-project"
        transcript = project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(root / "xdg"),
                           "DRSG_COMPACT_HANDOFF": "1"})
        os.environ.pop("DRSG_TOKEN", None)
        old_events = hook.open_events
        hook.open_events = lambda path: [{"key": "event-%d" % i, "summary": "open event %d" % i}
                                          for i in range(15)]
        (proj / "changed.txt").write_text("changed\n", encoding="utf-8")
        if dirty:
            for i in range(50):
                (proj / ("dirty-%02d" % i)).write_text("dirty\n", encoding="utf-8")
        compact = {"trigger": "auto", "session_id": "start-session",
                   "transcript_path": str(transcript),
                   "compact_summary": ("## 交接\n第一步已完成。\n\n"
                                       "## 6 All user messages\n用户要求持续验证。\n\n"
                                       "## 7 Pending Tasks\n完成剩余测试。\n\n"
                                       "## 8 Current Work\n编写消费逻辑。\n\n"
                                       "## 9 Optional Next Step\n运行验收。")}
        hook.write_record(compact)
        ss_spec = importlib.util.spec_from_file_location(
            "session_start", repo / "tools/templates/hooks/session_start.py")
        ss = sys.modules.get("session_start") or importlib.util.module_from_spec(ss_spec)
        if not getattr(ss, "main", None):
            sys.modules["session_start"] = ss
            ss_spec.loader.exec_module(ss)

        def invoke(source="startup", **extra):
            old_in, old_out = sys.stdin, sys.stdout
            out = io.StringIO()
            sys.stdin, sys.stdout = io.StringIO(json.dumps({"source": source, **extra})), out
            try:
                ss.main()
            finally:
                sys.stdin, sys.stdout = old_in, old_out
            return json.loads(out.getvalue())

        try:
            yield root, proj, transcript, compact, invoke
        finally:
            hook.open_events = old_events


def tokenless_session_case():
    with session_fixture() as (_, _, _, _, invoke):
        context = invoke("startup")["hookSpecificOutput"].get("additionalContext", "")
        return "第一步已完成" in context and "压缩步骤中的" in context


def session_metadata_case():
    with session_fixture() as (_, proj, _, _, invoke):
        context = invoke("startup")["hookSpecificOutput"].get("additionalContext", "")
        saved_path = next(path for path in pathlib.Path(hook.storage_dir(str(proj.resolve()))[1]).glob("*.json")
                          if json.loads(path.read_text()).get("session_id") == "start-session")
        saved = json.loads(saved_path.read_text(encoding="utf-8"))
        return all(value in context for value in (
            "项目路径：" + str(proj.resolve()), "session_id：start-session",
            "UTC 时间：" + saved["created_at"], "trigger：auto", "branch：" + saved["branch"],
            "HEAD：" + saved["head"], "changed.txt", "event-0 | open event 0"))


def current_record_not_listed_case():
    with session_fixture() as (_, _, _, _, invoke):
        context = invoke("startup")["hookSpecificOutput"].get("additionalContext", "")
        return "其他未消费交接：\n- 无" in context


def session_bounds_case():
    with session_fixture(dirty=True) as (_, _, _, _, invoke):
        context = invoke("startup")["hookSpecificOutput"].get("additionalContext", "")
        return ("dirty-48" in context and "event-9 | open event 9" in context and
                "dirty-49" not in context and "event-10 | open event 10" not in context)


def successful_consumption_case():
    with session_fixture() as (_, _, _, _, invoke):
        invoke("startup")
        second = invoke("startup")
        return "第一步已完成" not in second["hookSpecificOutput"].get("additionalContext", "")


def clear_injection_case():
    with session_fixture() as (_, _, _, compact, invoke):
        invoke("startup")
        invoke("startup")
        hook.write_record({**compact, "session_id": "clear-session"})
        cleared = invoke("clear")
        return "第一步已完成" in cleared["hookSpecificOutput"].get("additionalContext", "")


def resume_filter_case():
    with session_fixture() as (_, proj, _, compact, _):
        hook.write_record({**compact, "session_id": "resume-filter"})
        text, pending = hook.prepare_handoff(str(proj), "resume", {})
        return text is None and pending is None


def sidechain_filter_case():
    with session_fixture() as (_, proj, _, compact, _):
        hook.write_record({**compact, "session_id": "resume-filter"})
        text, pending = hook.prepare_handoff(str(proj), "startup", {"is_sidechain": True})
        return text is None and pending is None


def failed_output_case():
    with session_fixture() as (_, proj, _, compact, _):
        hook.write_record({**compact, "session_id": "abort-session"})
        _, pending = hook.prepare_handoff(str(proj), "clear", {})
        pending.finish(False)
        _, directory = hook.storage_dir(str(proj.resolve()))
        unconsumed = [json.loads(path.read_text()) for path in pathlib.Path(directory).glob("*.json")
                      if json.loads(path.read_text()).get("session_id") == "abort-session"]
        return bool(unconsumed) and not unconsumed[0].get("consumed")


def transcript_mtime_within_case():
    with session_fixture() as (root, proj, _, compact, _):
        long_transcript = root / "large-transcript.jsonl"
        long_transcript.write_text("line\n" * 50000, encoding="utf-8")
        hook.write_record({**compact, "session_id": "mtime-session",
                           "transcript_path": str(long_transcript)})
        os.utime(long_transcript, (time.time() + 300, time.time() + 300))
        text, pending = hook.prepare_handoff(str(proj), "startup", {})
        pending.finish(False)
        return "这个会话在压缩之后又继续工作到" not in text


def transcript_mtime_late_case():
    import builtins
    with session_fixture() as (root, proj, _, compact, _):
        long_transcript = root / "large-transcript.jsonl"
        long_transcript.write_text("line\n" * 50000, encoding="utf-8")
        hook.write_record({**compact, "session_id": "mtime-session",
                           "transcript_path": str(long_transcript)})
        os.utime(long_transcript, (time.time() + 700, time.time() + 700))
        original_open = builtins.open
        def guarded_open(file, *args, **kwargs):
            if os.fspath(file) == str(long_transcript):
                raise AssertionError("transcript content must not be read")
            return original_open(file, *args, **kwargs)
        builtins.open = guarded_open
        try:
            text, pending = hook.prepare_handoff(str(proj), "startup", {})
        finally:
            builtins.open = original_open
        pending.finish(False)
        return "这个会话在压缩之后又继续工作到" in text and "第一步已完成" in text


def rendered_cap_case():
    with session_fixture() as (_, proj, _, compact, _):
        hook.write_record({**compact, "session_id": "long-session",
                           "compact_summary": "## 交接\n" + "内容" * 12000})
        text, pending = hook.prepare_handoff(str(proj), "startup", {})
        pending.finish(False)
        return len(text) <= 8000 and "交接块已截断" in text


def bold_priority_case():
    with session_fixture() as (_, _, _, compact, invoke):
        priority_summary = ("**交接**\n交接优先标记必须保留。\n\n"
                            "## 6 All user messages\n" + "用户消息" * 1800 + "\n\n"
                            "## 7 Pending Tasks\n" + "待办" * 1800 + "\n\n"
                            "## 8 Current Work\n" + "当前工作" * 1800 + "\n\n"
                            "## 9 Optional Next Step\n" + "下一步" * 1800)
        hook.write_record({**compact, "session_id": "bold-priority-session",
                           "compact_summary": priority_summary})
        priority = invoke("startup")["hookSpecificOutput"]["additionalContext"]
        return (len(priority) <= 8000 and "交接优先标记必须保留" in priority and
                "交接块已截断" in priority and
                priority.index("交接优先标记必须保留") < priority.index("6 All user messages"))


def nongit_metadata_case():
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        nongit = root / "not-a-git-project"
        nongit.mkdir()
        transcript = nongit / "transcript.jsonl"
        transcript.write_text("unused\n", encoding="utf-8")
        os.environ.update({"CLAUDE_PROJECT_DIR": str(nongit), "XDG_DATA_HOME": str(root / "nongit-xdg")})
        hook.open_events = lambda path: []
        hook.write_record({"trigger": "manual", "session_id": "nongit-session",
                           "transcript_path": str(transcript), "compact_summary": "## 交接\n继续。"})
        ss_spec = importlib.util.spec_from_file_location(
            "session_start", repo / "tools/templates/hooks/session_start.py")
        ss = sys.modules.get("session_start") or importlib.util.module_from_spec(ss_spec)
        if not getattr(ss, "main", None):
            sys.modules["session_start"] = ss
            ss_spec.loader.exec_module(ss)
        old_in, old_out = sys.stdin, sys.stdout
        out = io.StringIO()
        sys.stdin, sys.stdout = io.StringIO(json.dumps({"source": "clear"})), out
        try:
            ss.main()
        finally:
            sys.stdin, sys.stdout = old_in, old_out
        context = json.loads(out.getvalue())["hookSpecificOutput"]["additionalContext"]
        return "branch：无" in context and "HEAD：无" in context


check("tokenless SessionStart injects handoff", tokenless_session_case)
check("SessionStart output includes all S1 metadata", session_metadata_case)
check("current record is not listed as another pending handoff", current_record_not_listed_case)
check("SessionStart output bounds changed paths and open Events", session_bounds_case)
check("successful output consumes record once", successful_consumption_case)
check("clear injects a fresh handoff", clear_injection_case)
check("resume does not read or consume handoff", resume_filter_case)
check("sidechain does not read or consume handoff", sidechain_filter_case)
check("failed output leaves record unconsumed", failed_output_case)
check("transcript mtime within 10 minutes adds no D2 notice", transcript_mtime_within_case)
check("late transcript mtime adds D2 notice without reading content", transcript_mtime_late_case)
check("rendered handoff is capped at 8,000 with truncation marker", rendered_cap_case)
check("bold handoff at summary start survives context truncation", bold_priority_case)
check("non-Git SessionStart metadata says branch and HEAD are unavailable", nongit_metadata_case)

# Expired records are removed before selection and cannot be injected.
@contextlib.contextmanager
def expired_fixture():
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        proj = root / "expired-project"
        transcript = project(proj)
        os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(root / "xdg"),
                           "DRSG_COMPACT_HANDOFF": "1"})
        old_events = hook.open_events
        hook.open_events = lambda path: []
        try:
            hook.write_record({"trigger": "manual", "session_id": "expired-session",
                               "transcript_path": str(transcript), "compact_summary": "expired body"})
            _, directory = hook.storage_dir(str(proj.resolve()))
            path = next(pathlib.Path(directory).glob("*.json"))
            record = json.loads(path.read_text(encoding="utf-8"))
            record["created_at_epoch"] = time.time() - hook.ttl_seconds() - 1
            hook.atomic_write(str(path), record)
            yield proj, directory, path
        finally:
            hook.open_events = old_events


def expired_selection_case():
    with expired_fixture() as (proj, _, _):
        cleanup = hook.cleanup
        hook.cleanup = lambda directory, now: None
        try:
            text, pending = hook.prepare_handoff(str(proj), "startup", {})
        finally:
            hook.cleanup = cleanup
        if pending:
            pending.finish(False)
        return text is None and pending is None


def expired_cleanup_case():
    with expired_fixture() as (_, directory, path):
        hook.cleanup(directory, time.time())
        return not path.exists()


check("expired record is ignored by selection gate", expired_selection_case)
check("expired record cleanup prunes file", expired_cleanup_case)

def load_session_start():
    ss_spec = importlib.util.spec_from_file_location(
        "session_start", repo / "tools/templates/hooks/session_start.py")
    ss = sys.modules.get("session_start") or importlib.util.module_from_spec(ss_spec)
    if not getattr(ss, "main", None):
        sys.modules["session_start"] = ss
        ss_spec.loader.exec_module(ss)
    return ss


def timed_sample(ss, source="startup"):
    old_in, old_out = sys.stdin, sys.stdout
    sys.stdin, sys.stdout = io.StringIO(json.dumps({"source": source})), io.StringIO()
    start = time.perf_counter()
    try:
        ss.main()
    finally:
        elapsed = (time.perf_counter() - start) * 1000
        sys.stdin, sys.stdout = old_in, old_out
    return elapsed


def sessionstart_p95_case():
    old_events = hook.open_events
    try:
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            proj = root / "latency-project"
            project(proj)
            large = root / "50k-lines.jsonl"
            large.write_text("line\n" * 50000, encoding="utf-8")
            os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(root / "xdg"),
                               "DRSG_COMPACT_HANDOFF": "1"})
            os.environ.pop("DRSG_TOKEN", None)
            hook.open_events = lambda path: []
            ss = load_session_start()
            empty_samples = [timed_sample(ss) for _ in range(100)]
            hook.write_record({"trigger": "manual", "session_id": "latency-session",
                               "transcript_path": str(large), "compact_summary": "## 交接\nsynthetic"})
            _, directory = hook.storage_dir(str(proj.resolve()))
            record_path = next(path for path in pathlib.Path(directory).glob("*.json")
                               if json.loads(path.read_text()).get("session_id") == "latency-session")
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record["summary"] = "## 交接\nsynthetic handoff\n"
            record["handoff_check"] = {
                "version": 1, "section_present": True,
                "fields": [{"name": "synthetic field", "present": True, "by": "name"}],
                "missing_fields": [],
            }
            hook.atomic_write(str(record_path), record)
            present_samples = []
            for _ in range(100):
                record = json.loads(record_path.read_text())
                record["consumed"], record["consumed_at"] = False, None
                hook.atomic_write(str(record_path), record)
                present_samples.append(timed_sample(ss))
            p95 = lambda values: sorted(values)[94]
            print("HANDOFF_LATENCY_BASELINE_MS=" + json.dumps(empty_samples))
            print("HANDOFF_LATENCY_PRESENT_MS=" + json.dumps(present_samples))
            print("HANDOFF_P95_BASELINE_MS=%.3f" % p95(empty_samples))
            print("HANDOFF_P95_PRESENT_MS=%.3f" % p95(present_samples))
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record["handoff_check"] = {
                "version": 1, "section_present": True,
                "fields": [{"name": "synthetic field", "present": False, "by": None}],
                "missing_fields": ["synthetic field"],
            }
            hook.atomic_write(str(record_path), record)
            missing_samples = []
            for _ in range(100):
                record = json.loads(record_path.read_text())
                record["consumed"], record["consumed_at"] = False, None
                hook.atomic_write(str(record_path), record)
                missing_samples.append(timed_sample(ss))
            print("HANDOFF_LATENCY_MISSING_MS=" + json.dumps(missing_samples))
            print("HANDOFF_P95_MISSING_MS=%.3f" % p95(missing_samples))
            return p95(present_samples) <= 50 and p95(missing_samples) <= 50
    finally:
        hook.open_events = old_events


def lock_contention_case():
    old_events = hook.open_events
    try:
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            proj = root / "latency-project"
            transcript = project(proj)
            os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(root / "xdg"),
                               "DRSG_COMPACT_HANDOFF": "1"})
            os.environ.pop("DRSG_TOKEN", None)
            hook.open_events = lambda path: []
            hook.write_record({"trigger": "manual", "session_id": "latency-session",
                               "transcript_path": str(transcript), "compact_summary": "## 交接\nsynthetic"})
            _, directory = hook.storage_dir(str(proj.resolve()))
            record_path = next(pathlib.Path(directory).glob("*.json"))
            record = json.loads(record_path.read_text(encoding="utf-8"))
            record["summary"] = "## 交接\nsynthetic handoff\n"
            record["handoff_check"] = {
                "version": 1, "section_present": True,
                "fields": [{"name": "synthetic field", "present": False, "by": None}],
                "missing_fields": ["synthetic field"],
            }
            hook.atomic_write(str(record_path), record)
            record["consumed"], record["consumed_at"] = False, None
            hook.atomic_write(str(record_path), record)
            holder = (
                "import sys,time; sys.path.insert(0, %r); import compact_handoff as h; "
                "lock=h.DirectoryLock(sys.argv[1]); lock.__enter__(); "
                "print('READY', flush=True); time.sleep(0.05); lock.__exit__(None,None,None)"
            ) % str(repo / "tools/templates/hooks")
            worker = subprocess.Popen([sys.executable, "-c", holder, directory],
                                      stdout=subprocess.PIPE, text=True)
            ready = worker.stdout.readline().strip()
            start = time.perf_counter()
            text, pending = hook.prepare_handoff(str(proj), "startup", {})
            contention_ms = (time.perf_counter() - start) * 1000
            if pending:
                pending.finish(False)
            worker.wait(timeout=3)
            print("HANDOFF_LOCK_CONTENTION_MS=%.3f" % contention_ms)
            return ready == "READY" and text is not None and contention_ms <= 200
    finally:
        hook.open_events = old_events


check("SessionStart handoff p95 stays within 50ms", sessionstart_p95_case)
check("second process lock contention remains bounded", lock_contention_case)

# A daemon that accepts the RPC but never replies must not block the write >4s.
import socket
import threading
def slow_rpc_case():
    old_events = hook.open_events
    old_token = os.environ.pop("DRSG_TOKEN", None)
    listener = socket.socket()
    server = None
    try:
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            proj = root / "slow-daemon-project"
            transcript = project(proj)
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            def stall_rpc():
                conn, _ = listener.accept()
                with conn:
                    while conn.recv(65536):
                        pass
                listener.close()
            server = threading.Thread(target=stall_rpc, daemon=True)
            server.start()
            api = "http://127.0.0.1:%d/rpc" % port
            (proj / ".drsg").mkdir()
            (proj / ".drsg/env").write_text(
                "DRSG_TOKEN=fake-token\nDRSG_API=%s\nDRSG_PLANE=memory\n" % api,
                encoding="utf-8")
            os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(root / "xdg"),
                               "DRSG_API": api, "DRSG_TOKEN": "fake-token", "DRSG_PLANE": "memory"})
            hook.open_events = default_open_events
            started = time.perf_counter()
            hook.write_record({"trigger": "manual", "session_id": "slow-rpc",
                               "transcript_path": str(transcript), "compact_summary": "## 交接\nkeep"})
            elapsed = time.perf_counter() - started
            _, directory = hook.storage_dir(str(proj.resolve()))
            saved = next(pathlib.Path(directory).glob("*.json"))
            record = json.loads(saved.read_text(encoding="utf-8"))
            return record["events"] == [] and elapsed <= 4.0
    finally:
        hook.open_events = old_events
        if old_token is not None:
            os.environ["DRSG_TOKEN"] = old_token
        if server:
            server.join(timeout=1)
        listener.close()


check("silent RPC timeout still saves record and empty Events", slow_rpc_case)

# The command-line hook always emits one legal empty JSON object on malformed input.
def malformed_input_case():
    old_stdin, old_stdout = sys.stdin, sys.stdout
    out = io.StringIO()
    sys.stdin, sys.stdout = io.StringIO("not-json"), out
    try:
        hook.main()
    finally:
        sys.stdin, sys.stdout = old_stdin, old_stdout
    return out.getvalue() == "{}\n"


check("malformed input emits legal hook output", malformed_input_case)
if only and ran == 0:
    print("FAIL requested assertion was not run: " + only)
    raise SystemExit(2)
print("PASS %d/%d" % (passed, ran))
raise SystemExit(0 if passed == ran else 1)
PY

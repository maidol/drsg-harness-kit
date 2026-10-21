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
sys.modules["compact_handoff"] = hook
only = os.environ.get("ONLY", "")
ran = passed = 0


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


heading_forms = ("**交接**", "交接:", "## 交接", "10. 交接", "**10. 交接**")
check("all supported handoff heading forms are recognized", all(
    [title for _, title, _ in hook.selected_sections(
        heading + "\nbody\n\n1. Primary Request:\nrequest\n")] == ["交接"]
    for heading in heading_forms))
summary_with_close = "## 9 Optional Next Step\n继续验证。\n</summary>"
check("selected section omits closing summary tag", all(
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
    hook.write_record(base)
    _, directory = hook.storage_dir(str(proj.resolve()))
    files = list(pathlib.Path(directory).glob("*.json"))
    record = json.loads(files[0].read_text(encoding="utf-8"))
    check("realpath SHA-256 project key", pathlib.Path(directory).name ==
          __import__("hashlib").sha256(str(proj.resolve()).encode()).hexdigest())
    check("directory and record permissions", stat.S_IMODE(pathlib.Path(directory).stat().st_mode) == 0o700 and
          stat.S_IMODE(files[0].stat().st_mode) == 0o600)
    check("safe_summary redacts before persistence", fake_key not in
          hook.safe_summary(fake_key))
    check("summary redacted before disk", fake_key not in files[0].read_text() and
          "<hidden>" in record["summary"])
    check("daemon failure keeps write and Event list is bounded", len(record["events"]) == 10 and
          record["events"][0]["summary"] == "event 0")
    check("Git metadata and status path bound", record["branch"] != "unavailable" and
          len(record["git_status"]["paths"]) <= 50 and record["git_status"]["total"] == 0)

    # The same session replaces its prior summary; separate sessions are capped at ten.
    hook.write_record({**base, "compact_summary": "replacement"})
    check("same-session record replaced", len(list(pathlib.Path(directory).glob("*.json"))) == 1 and
          json.loads(files[0].read_text(encoding="utf-8"))["summary"] == "replacement")
    for i in range(12):
        hook.write_record({**base, "session_id": "session-%d" % i,
                           "compact_summary": "summary %d" % i})
    check("at most ten records retained", len(list(pathlib.Path(directory).glob("*.json"))) == 10)

    # More than fifty dirty paths are truncated without exposing porcelain status codes.
    for i in range(55):
        (proj / ("dirty-%02d" % i)).write_text("x", encoding="utf-8")
    status = hook.git_status(str(proj))
    check("dirty path list capped at 50 with total", len(status["paths"]) == 50 and status["total"] == 55)

    before = len(list(pathlib.Path(directory).glob("*.json")))
    hook.write_record({**base, "trigger": "other"})
    hook.write_record({**base, "is_sidechain": True})
    hook.write_record({**base, "compact_summary": ""})
    hook.write_record({**base, "transcript_path": str(proj / "missing")})
    check("unsupported trigger, sidechain, empty summary and bad transcript skipped",
          len(list(pathlib.Path(directory).glob("*.json"))) == before)

    # XDG storage resolving inside a project must fail closed.
    os.environ["XDG_DATA_HOME"] = str(proj / "inside")
    try:
        hook.storage_dir(str(proj.resolve()))
        outside_ok = False
    except ValueError:
        outside_ok = True
    check("XDG root inside project rejected", outside_ok)
    hook.open_events = old_events

# SessionStart consumes locally before token/daemon early returns and only once.
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp)
    proj = root / "start-project"
    transcript = project(proj)
    data_home = root / "xdg"
    os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(data_home),
                       "DRSG_COMPACT_HANDOFF": "1"})
    os.environ.pop("DRSG_TOKEN", None)
    hook.open_events = lambda path: [{"key": "event-%d" % i, "summary": "open event %d" % i}
                                      for i in range(15)]
    (proj / "changed.txt").write_text("changed\n", encoding="utf-8")
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
    ss = importlib.util.module_from_spec(ss_spec)
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

    first = invoke("startup")
    first_context = first["hookSpecificOutput"].get("additionalContext", "")
    check("tokenless SessionStart injects handoff", "第一步已完成" in first_context and
          "压缩步骤中的" in first_context)
    saved_path = next(path for path in pathlib.Path(hook.storage_dir(str(proj.resolve()))[1]).glob("*.json")
                      if json.loads(path.read_text()).get("session_id") == "start-session")
    saved = json.loads(saved_path.read_text(encoding="utf-8"))
    check("SessionStart output includes all S1 metadata", all(value in first_context for value in (
        "项目路径：" + str(proj.resolve()), "session_id：start-session",
        "UTC 时间：" + saved["created_at"], "trigger：auto", "branch：" + saved["branch"],
        "HEAD：" + saved["head"], "changed.txt", "event-0 | open event 0")))
    check("current record is not listed as another pending handoff",
          "其他未消费交接：\n- 无" in first_context)
    check("SessionStart output bounds changed paths and open Events",
          "dirty-48" in first_context and "event-9 | open event 9" in first_context and
          "dirty-49" not in first_context and "event-10 | open event 10" not in first_context)
    second = invoke("startup")
    check("successful output consumes record once", "第一步已完成" not in
          second["hookSpecificOutput"].get("additionalContext", ""))
    hook.write_record({**compact, "session_id": "clear-session"})
    cleared = invoke("clear")
    check("clear injects a fresh handoff", "第一步已完成" in
          cleared["hookSpecificOutput"].get("additionalContext", ""))

    hook.write_record({**compact, "session_id": "resume-filter"})
    text, pending = hook.prepare_handoff(str(proj), "resume", {})
    check("resume does not read or consume handoff", text is None and pending is None)
    text, pending = hook.prepare_handoff(str(proj), "startup", {"is_sidechain": True})
    check("sidechain does not read or consume handoff", text is None and pending is None)

    hook.write_record({**compact, "session_id": "abort-session"})
    text, pending = hook.prepare_handoff(str(proj), "clear", {})
    pending.finish(False)
    _, directory = hook.storage_dir(str(proj.resolve()))
    unconsumed = [json.loads(path.read_text()) for path in pathlib.Path(directory).glob("*.json")
                  if json.loads(path.read_text()).get("session_id") == "abort-session"]
    check("failed output leaves record unconsumed", bool(unconsumed) and
          not unconsumed[0].get("consumed"))

    # D2 inspects transcript metadata only; a 50,000-line file is never opened.
    long_transcript = root / "large-transcript.jsonl"
    long_transcript.write_text("line\n" * 50000, encoding="utf-8")
    hook.write_record({**compact, "session_id": "mtime-session",
                       "transcript_path": str(long_transcript)})
    target = next(path for path in pathlib.Path(directory).glob("*.json")
                  if json.loads(path.read_text()).get("session_id") == "mtime-session")
    os.utime(long_transcript, (time.time() + 300, time.time() + 300))
    text, pending = hook.prepare_handoff(str(proj), "startup", {})
    check("transcript mtime within 10 minutes adds no D2 notice",
          "这个会话在压缩之后又继续工作到" not in text)
    pending.finish(False)
    os.utime(long_transcript, (time.time() + 700, time.time() + 700))
    import builtins
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
    check("late transcript mtime adds D2 notice without reading content",
          "这个会话在压缩之后又继续工作到" in text and
          "第一步已完成" in text)
    pending.finish(False)

    hook.write_record({**compact, "session_id": "long-session",
                       "compact_summary": "## 交接\n" + "内容" * 12000})
    text, pending = hook.prepare_handoff(str(proj), "startup", {})
    pending.finish(False)
    check("rendered handoff is capped at 8,000 with truncation marker",
          len(text) <= 8000 and "交接块已截断" in text)

    priority_summary = ("**交接**\n交接优先标记必须保留。\n\n"
                        "## 6 All user messages\n" + "用户消息" * 1800 + "\n\n"
                        "## 7 Pending Tasks\n" + "待办" * 1800 + "\n\n"
                        "## 8 Current Work\n" + "当前工作" * 1800 + "\n\n"
                        "## 9 Optional Next Step\n" + "下一步" * 1800)
    hook.write_record({**compact, "session_id": "bold-priority-session",
                       "compact_summary": priority_summary})
    priority = invoke("startup")["hookSpecificOutput"]["additionalContext"]
    check("bold handoff at summary start survives context truncation", len(priority) <= 8000 and
          "交接优先标记必须保留" in priority and "交接块已截断" in priority and
          priority.index("交接优先标记必须保留") < priority.index("6 All user messages"))

    nongit = root / "not-a-git-project"
    nongit.mkdir()
    nongit_transcript = nongit / "transcript.jsonl"
    nongit_transcript.write_text("unused\n", encoding="utf-8")
    os.environ.update({"CLAUDE_PROJECT_DIR": str(nongit), "XDG_DATA_HOME": str(root / "nongit-xdg")})
    hook.open_events = lambda path: []
    hook.write_record({"trigger": "manual", "session_id": "nongit-session",
                       "transcript_path": str(nongit_transcript), "compact_summary": "## 交接\n继续。"})
    nongit_context = invoke("clear")["hookSpecificOutput"]["additionalContext"]
    check("non-Git SessionStart metadata says branch and HEAD are unavailable",
          "branch：无" in nongit_context and "HEAD：无" in nongit_context)

# Expired records are removed before selection and cannot be injected.
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp)
    proj = root / "expired-project"
    transcript = project(proj)
    os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(root / "xdg"),
                       "DRSG_COMPACT_HANDOFF": "1"})
    hook.open_events = lambda path: []
    hook.write_record({"trigger": "manual", "session_id": "expired-session",
                       "transcript_path": str(transcript), "compact_summary": "expired body"})
    _, directory = hook.storage_dir(str(proj.resolve()))
    path = next(pathlib.Path(directory).glob("*.json"))
    record = json.loads(path.read_text(encoding="utf-8"))
    record["created_at_epoch"] = time.time() - hook.ttl_seconds() - 1
    hook.atomic_write(str(path), record)
    cleanup = hook.cleanup
    hook.cleanup = lambda directory, now: None
    try:
        text, pending = hook.prepare_handoff(str(proj), "startup", {})
    finally:
        hook.cleanup = cleanup
    if pending:
        pending.finish(False)
    check("expired record is ignored by selection gate", text is None and pending is None)
    hook.cleanup(directory, time.time())
    check("expired record cleanup prunes file", not path.exists())

# Compare 100 daemon-down SessionStart handoff and no-handoff fast-path samples.
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp)
    proj = root / "latency-project"
    transcript = project(proj)
    large = root / "50k-lines.jsonl"
    large.write_text("line\n" * 50000, encoding="utf-8")
    os.environ.update({"CLAUDE_PROJECT_DIR": str(proj), "XDG_DATA_HOME": str(root / "xdg"),
                       "DRSG_COMPACT_HANDOFF": "1"})
    os.environ.pop("DRSG_TOKEN", None)
    hook.open_events = lambda path: []
    ss_spec = importlib.util.spec_from_file_location(
        "session_start", repo / "tools/templates/hooks/session_start.py")
    ss = sys.modules.get("session_start") or importlib.util.module_from_spec(ss_spec)
    sys.modules["session_start"] = ss
    if not getattr(ss, "main", None):
        ss_spec.loader.exec_module(ss)

    def sample(source="startup"):
        old_in, old_out = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO(json.dumps({"source": source})), io.StringIO()
        start = time.perf_counter()
        try:
            ss.main()
        finally:
            elapsed = (time.perf_counter() - start) * 1000
            sys.stdin, sys.stdout = old_in, old_out
        return elapsed

    empty_samples = [sample() for _ in range(100)]
    hook.write_record({"trigger": "manual", "session_id": "latency-session",
                       "transcript_path": str(large), "compact_summary": compact["compact_summary"]})
    _, directory = hook.storage_dir(str(proj.resolve()))
    record_path = next(path for path in pathlib.Path(directory).glob("*.json")
                       if json.loads(path.read_text()).get("session_id") == "latency-session")
    present_samples = []
    for _ in range(100):
        record = json.loads(record_path.read_text())
        record["consumed"], record["consumed_at"] = False, None
        hook.atomic_write(str(record_path), record)
        present_samples.append(sample())
    p95 = lambda values: sorted(values)[94]
    print("HANDOFF_LATENCY_BASELINE_MS=" + json.dumps(empty_samples))
    print("HANDOFF_LATENCY_PRESENT_MS=" + json.dumps(present_samples))
    print("HANDOFF_P95_BASELINE_MS=%.3f" % p95(empty_samples))
    print("HANDOFF_P95_PRESENT_MS=%.3f" % p95(present_samples))
    check("SessionStart handoff p95 stays within 200ms", p95(present_samples) <= 200)

    record = json.loads(record_path.read_text())
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
    check("second process lock contention remains bounded", ready == "READY" and
          text is not None and contention_ms <= 200)

# A daemon that accepts the RPC but never replies must not block the write >4s.
import socket
import threading
with tempfile.TemporaryDirectory() as temp:
    root = pathlib.Path(temp)
    proj = root / "slow-daemon-project"
    transcript = project(proj)
    listener = socket.socket()
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
    hook.open_events = old_events
    started = time.perf_counter()
    hook.write_record({"trigger": "manual", "session_id": "slow-rpc",
                       "transcript_path": str(transcript), "compact_summary": "## 交接\nkeep"})
    elapsed = time.perf_counter() - started
    _, directory = hook.storage_dir(str(proj.resolve()))
    saved = next(pathlib.Path(directory).glob("*.json"))
    record = json.loads(saved.read_text(encoding="utf-8"))
    check("silent RPC timeout still saves record and empty Events",
          record["events"] == [] and elapsed <= 4.0)
    server.join(timeout=1)
    os.environ.pop("DRSG_TOKEN", None)

# The command-line hook always emits one legal empty JSON object on malformed input.
old_stdin, old_stdout = sys.stdin, sys.stdout
out = io.StringIO()
sys.stdin, sys.stdout = io.StringIO("not-json"), out
try:
    hook.main()
finally:
    sys.stdin, sys.stdout = old_stdin, old_stdout
check("malformed input emits legal hook output", out.getvalue() == "{}\n")
if only and ran == 0:
    print("FAIL requested assertion was not run: " + only)
    raise SystemExit(2)
print("PASS %d/%d" % (passed, ran))
raise SystemExit(0 if passed == ran else 1)
PY

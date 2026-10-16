#!/usr/bin/env bash
# SessionStart daemon and local-backup warning contracts.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOK_SOURCE="${SESSION_START_SOURCE:-$REPO/tools/templates/hooks/session_start.py}"
python3 - "$REPO" "$HOOK_SOURCE" <<'PY'
import datetime
import importlib.util
import inspect
import io
import json
import os
import socket
import statistics
import shlex
import subprocess
import sys
import tempfile
from contextlib import contextmanager

repo, hook_source = sys.argv[1:]
FAKE_TOKEN = "test-only-fake-token-not-a-credential"
DAEMON_TEXT = "DrSG memory daemon is unreachable"
EVENT_TEXT = "Event list is not trustworthy"
BACKUP_TEXT = "DrSG memory backup:"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load module from " + path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ss = load_module("session_start_health_test", hook_source)
checks = []
metrics = []


def check(name, fn):
    try:
        fn()
    except Exception as exc:
        checks.append((name, False, "%s: %s" % (type(exc).__name__, exc)))
    else:
        checks.append((name, True, ""))


def temp_paths():
    tmp = tempfile.TemporaryDirectory(prefix="session-start-health-")
    project = os.path.join(tmp.name, "project")
    mem_dir = os.path.join(tmp.name, "memory")
    os.mkdir(project)
    os.mkdir(mem_dir)
    return tmp, project, mem_dir


def make_backup(mem_dir, age_days, now=None, tool="drsg-memory-backup",
                schema_version=1, backup_time=None):
    if now is None:
        now = datetime.datetime.now(datetime.timezone.utc)
    root = os.path.join(mem_dir, "backups")
    os.makedirs(root, exist_ok=True)
    suffix = len(os.listdir(root)) + 1
    stamp = now - datetime.timedelta(days=age_days)
    dirname_time = stamp.strftime("%Y%m%dT%H%M%S%fZ")
    path = os.path.join(root, "backup-%s-%08x" % (dirname_time, suffix))
    os.mkdir(path)
    if backup_time is None:
        backup_time = stamp.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    with open(os.path.join(path, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump({"tool": tool, "schema_version": schema_version,
                   "backup_time": backup_time}, fh)
    return path


@contextmanager
def patched_environment(values):
    names = ("CLAUDE_PROJECT_DIR", "DRSG_API", "DRSG_TOKEN", "DRSG_MEM_DIR",
             "DRSG_BACKUP_MAX_AGE_DAYS", "DRSG_PLANE", "DRSG_BRIEFING_MAX_CHARS")
    prior = {name: os.environ.get(name) for name in names}
    for name in names:
        os.environ.pop(name, None)
    os.environ.update(values)
    try:
        yield
    finally:
        for name in names:
            os.environ.pop(name, None)
            if prior[name] is not None:
                os.environ[name] = prior[name]


def run_main(project, mem_dir, source="startup", api="http://127.0.0.1:7700/rpc",
             token=FAKE_TOKEN, db_up=True, now=None, extra_env=None):
    old_rpc = ss.rpc
    old_api, old_plane, old_limit = ss.API, ss.PLANE, ss.BRIEFING_MAX_CHARS
    old_in, old_out, old_err = sys.stdin, sys.stdout, sys.stderr
    calls = []

    def stub(method, params, rpc_token):
        calls.append(method)
        if method == "db.stats" and not db_up:
            raise OSError("test socket failure; must not escape to hook output")
        return {}

    env = {"CLAUDE_PROJECT_DIR": project, "DRSG_API": api,
           "DRSG_MEM_DIR": mem_dir, "DRSG_PLANE": "memory"}
    if token:
        env["DRSG_TOKEN"] = token
    if extra_env:
        env.update(extra_env)
    payload = {"session_id": "health-test-session", "source": source, "cwd": project}
    stdout, stderr = io.StringIO(), io.StringIO()
    try:
        with patched_environment(env):
            ss.rpc = stub
            sys.stdin = io.StringIO(json.dumps(payload))
            sys.stdout, sys.stderr = stdout, stderr
            if now is not None and "now" in inspect.signature(ss.main).parameters:
                ss.main(now=now)
            else:
                ss.main()
    finally:
        ss.rpc = old_rpc
        ss.API, ss.PLANE, ss.BRIEFING_MAX_CHARS = old_api, old_plane, old_limit
        sys.stdin, sys.stdout, sys.stderr = old_in, old_out, old_err
    lines = stdout.getvalue().splitlines()
    if len(lines) != 1:
        raise AssertionError("expected one JSON object, got %d lines" % len(lines))
    result = json.loads(lines[0])
    return result, result.get("hookSpecificOutput", {}), calls, stderr.getvalue()


def sys_message(result):
    return result.get("systemMessage", "") or ""


def context(result, hook_specific):
    return hook_specific.get("additionalContext", "") or ""


def expected_backup_message(reason, mem_dir):
    tool = shlex.quote(os.path.join(os.path.expanduser(mem_dir), "tools", "memory-backup.py"))
    command = "python3 " + tool
    return "⚠ DrSG memory backup: %s. Run: %s backup; then %s drill" % (
        reason, command, command)


def assert_daemon_down(result, hook_specific, source="startup"):
    assert DAEMON_TEXT in sys_message(result), "expected fixed daemon warning; got %r" % sys_message(result)
    assert "serve.sh" in sys_message(result) and "start" in sys_message(result), sys_message(result)
    expected_context = ("DrSG memory is unavailable; this session's Event list is not "
                        "trustworthy. Restore the daemon before checking open Events.")
    if source == "compact":
        expected_context = ss.COMPACT_CONTEXT + "\n\n" + expected_context
    assert context(result, hook_specific) == expected_context, context(result, hook_specific)


def read_main_ms(project):
    path = os.path.join(project, ".drsg", "recall.jsonl")
    with open(path, encoding="utf-8") as fh:
        records = [json.loads(line) for line in fh if line.strip()]
    briefing = [row["ms"] for row in records if row.get("event") == "briefing" and "ms" in row]
    if not briefing:
        raise AssertionError("main() did not append briefing ms to recall.jsonl")
    return briefing[-1]


def cold_r2_imports():
    # Re-import local-only R2 modules for each sample, approximating a fresh hook.
    for name in ("ipaddress", "datetime", "urllib.parse"):
        sys.modules.pop(name, None)
    urllib = sys.modules.get("urllib")
    if urllib is not None and hasattr(urllib, "parse"):
        delattr(urllib, "parse")


def test_daemon_down_real_loopback_subprocess():
    tmp, project, mem_dir = temp_paths()
    try:
        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        env = os.environ.copy()
        env.update({"CLAUDE_PROJECT_DIR": project, "DRSG_API": "http://127.0.0.1:%d/rpc" % port,
                    "DRSG_TOKEN": FAKE_TOKEN, "DRSG_MEM_DIR": "", "DRSG_PLANE": "memory"})
        proc = subprocess.run([sys.executable, hook_source], input=json.dumps({
            "session_id": "daemon-down-health-test", "source": "startup", "cwd": project}),
            text=True, capture_output=True, env=env, timeout=5)
        assert proc.returncode == 0, "exit=%d stderr=%r" % (proc.returncode, proc.stderr)
        lines = proc.stdout.splitlines()
        assert len(lines) == 1, "stdout must be one JSON object: %r" % proc.stdout
        result = json.loads(lines[0])
        hook_specific = result.get("hookSpecificOutput", {})
        expected_system = ("⚠ DrSG memory daemon is unreachable. This session has no briefing, "
                           "Events, or recall. Restore it with: ~/.drsg-memory/tools/serve.sh start")
        assert sys_message(result) == expected_system, "expected fixed daemon system warning, got %r" % sys_message(result)
        assert_daemon_down(result, hook_specific)
        assert FAKE_TOKEN not in proc.stdout + proc.stderr
        assert "test socket failure" not in proc.stdout + proc.stderr
    finally:
        tmp.cleanup()


def test_missing_token_stays_silent():
    tmp, project, mem_dir = temp_paths()
    try:
        result, hook_specific, _, _ = run_main(project, mem_dir, token="")
        assert DAEMON_TEXT not in sys_message(result) + context(result, hook_specific)
        assert BACKUP_TEXT not in sys_message(result)
    finally:
        tmp.cleanup()


def test_missing_backup_directory_warns_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        result, _, _, _ = run_main(project, mem_dir)
        message = sys_message(result)
        expected = expected_backup_message("no valid backup found", mem_dir)
        assert message == expected, "expected missing-backup warning %r, got %r" % (expected, message)
    finally:
        tmp.cleanup()


def test_one_day_z_backup_is_fresh_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        now = datetime.datetime.now(datetime.timezone.utc)
        make_backup(mem_dir, 1, now=now)
        result, _, _, _ = run_main(project, mem_dir, now=now)
        assert BACKUP_TEXT not in sys_message(result), sys_message(result)
    finally:
        tmp.cleanup()


def test_ten_day_z_backup_warns_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        now = datetime.datetime.now(datetime.timezone.utc)
        make_backup(mem_dir, 10, now=now)
        result, _, _, _ = run_main(project, mem_dir, now=now)
        message = sys_message(result)
        expected = expected_backup_message("latest valid backup is 10 days ago", mem_dir)
        assert message == expected, "expected stale-backup warning %r, got %r" % (expected, message)
    finally:
        tmp.cleanup()


def test_wrong_tool_manifest_does_not_hide_old_backup_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        now = datetime.datetime.now(datetime.timezone.utc)
        make_backup(mem_dir, 1, now=now, tool="not-drsg-memory-backup")
        make_backup(mem_dir, 10, now=now)
        result, _, _, _ = run_main(project, mem_dir, now=now)
        message = sys_message(result)
        expected = expected_backup_message("latest valid backup is 10 days ago", mem_dir)
        assert message == expected, "expected invalid newest manifest not to hide stale backup; got %r" % message
    finally:
        tmp.cleanup()


def test_zero_age_limit_disables_scan_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        backup_root = os.path.join(mem_dir, "backups")
        calls = []
        original = ss.os.listdir

        def track(path):
            if os.fspath(path) == backup_root:
                calls.append(os.fspath(path))
            return original(path)

        ss.os.listdir = track
        try:
            result, _, _, _ = run_main(project, mem_dir,
                extra_env={"DRSG_BACKUP_MAX_AGE_DAYS": "0"})
        finally:
            ss.os.listdir = original
        assert BACKUP_TEXT not in sys_message(result), sys_message(result)
        assert not calls, "zero threshold enumerated backups: %r" % calls
    finally:
        tmp.cleanup()


def test_non_loopback_api_skips_backup_scan_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        backup_root = os.path.join(mem_dir, "backups")
        calls = []
        original = ss.os.listdir

        def track(path):
            if os.fspath(path) == backup_root:
                calls.append(os.fspath(path))
            return original(path)

        ss.os.listdir = track
        try:
            result, _, rpc_calls, _ = run_main(project, mem_dir, api="http://memory.example.test/rpc")
        finally:
            ss.os.listdir = original
        assert BACKUP_TEXT not in sys_message(result), sys_message(result)
        assert not calls, "non-loopback API scanned backups: %r" % calls
        assert rpc_calls.count("db.stats") == 1, rpc_calls
    finally:
        tmp.cleanup()


def test_resume_compact_skip_backup_but_keep_down_warning_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        backup_root = os.path.join(mem_dir, "backups")
        for source in ("resume", "compact"):
            down, down_ctx, _, _ = run_main(project, mem_dir, source=source, db_up=False)
            assert_daemon_down(down, down_ctx, source=source)
            healthy, _, _, _ = run_main(project, mem_dir, source=source)
            assert BACKUP_TEXT not in sys_message(healthy), sys_message(healthy)
            assert not os.path.exists(backup_root), "resume/compact created backup data"
    finally:
        tmp.cleanup()


def test_template_regex_matches_backup_tool():
    backup = load_module("memory_backup_health_test", os.path.join(repo, "tools", "memory-backup.py"))
    assert ss.BACKUP_RE.pattern == backup.BACKUP_RE.pattern, (ss.BACKUP_RE.pattern, backup.BACKUP_RE.pattern)


def test_z_timestamp_parses_as_utc():
    parsed = ss.parse_backup_time("2026-10-16T04:54:42.123456Z")
    assert parsed == datetime.datetime(2026, 10, 16, 4, 54, 42, 123456,
                                       tzinfo=datetime.timezone.utc), repr(parsed)
    assert parsed.utcoffset() == datetime.timedelta(0), repr(parsed)


def test_custom_mem_dir_is_shell_quoted_in_daemon_command():
    tmp, project, mem_dir = temp_paths()
    try:
        custom = mem_dir + " with spaces"
        os.mkdir(custom)
        down, down_ctx, _, _ = run_main(project, custom, db_up=False)
        assert_daemon_down(down, down_ctx)
        assert "'%s/tools/serve.sh' start" % custom in sys_message(down), sys_message(down)
    finally:
        tmp.cleanup()


def test_corrupt_manifest_is_invalid_not_fatal():
    tmp, project, mem_dir = temp_paths()
    try:
        root = os.path.join(mem_dir, "backups")
        os.makedirs(root)
        path = os.path.join(root, "backup-20261016T045442123456Z-00000001")
        os.mkdir(path)
        with open(os.path.join(path, "manifest.json"), "w", encoding="utf-8") as fh:
            fh.write("{")
        result, _, _, stderr = run_main(project, mem_dir)
        expected = expected_backup_message("no valid backup found", mem_dir)
        assert sys_message(result) == expected, "expected invalid backup candidates to produce a no-valid-backup warning; got %r" % sys_message(result)
        assert "JSONDecodeError" not in stderr
    finally:
        tmp.cleanup()


def test_symlink_candidates_are_not_backups():
    tmp, project, mem_dir = temp_paths()
    try:
        root = os.path.join(mem_dir, "backups")
        os.makedirs(root)
        target = os.path.join(tmp.name, "target")
        os.mkdir(target)
        with open(os.path.join(target, "manifest.json"), "w", encoding="utf-8") as fh:
            json.dump({"tool": "drsg-memory-backup", "schema_version": 1,
                       "backup_time": "2026-10-16T04:54:42.123456Z"}, fh)
        os.symlink(target, os.path.join(root, "backup-20261016T045442123456Z-00000002"))
        result, _, _, _ = run_main(project, mem_dir)
        expected = expected_backup_message("no valid backup found", mem_dir)
        assert sys_message(result) == expected, "expected invalid backup candidates to produce a no-valid-backup warning; got %r" % sys_message(result)
    finally:
        tmp.cleanup()


def test_symlink_manifest_is_not_a_backup():
    tmp, project, mem_dir = temp_paths()
    try:
        root = os.path.join(mem_dir, "backups")
        candidate = os.path.join(root, "backup-20261016T045442123456Z-00000003")
        os.makedirs(candidate)
        target = os.path.join(tmp.name, "manifest.json")
        with open(target, "w", encoding="utf-8") as fh:
            json.dump({"tool": "drsg-memory-backup", "schema_version": 1,
                       "backup_time": "2026-10-16T04:54:42.123456Z"}, fh)
        os.symlink(target, os.path.join(candidate, "manifest.json"))
        result, _, _, _ = run_main(project, mem_dir)
        expected = expected_backup_message("no valid backup found", mem_dir)
        assert sys_message(result) == expected, "expected symlink manifest to be invalid; got %r" % sys_message(result)
    finally:
        tmp.cleanup()


def test_backup_root_symlink_is_not_followed():
    tmp, project, mem_dir = temp_paths()
    try:
        target_root = os.path.join(tmp.name, "backups-target")
        os.mkdir(target_root)
        candidate = os.path.join(target_root, "backup-20261016T045442123456Z-00000004")
        os.mkdir(candidate)
        with open(os.path.join(candidate, "manifest.json"), "w", encoding="utf-8") as fh:
            json.dump({"tool": "drsg-memory-backup", "schema_version": 1,
                       "backup_time": "2026-10-16T04:54:42.123456Z"}, fh)
        os.symlink(target_root, os.path.join(mem_dir, "backups"))
        result, _, _, _ = run_main(project, mem_dir)
        expected = expected_backup_message("no valid backup found", mem_dir)
        assert sys_message(result) == expected, "expected backup root symlink not to be followed; got %r" % sys_message(result)
    finally:
        tmp.cleanup()


def test_timezone_missing_manifest_is_invalid():
    tmp, project, mem_dir = temp_paths()
    try:
        now = datetime.datetime.now(datetime.timezone.utc)
        make_backup(mem_dir, 1, now=now, backup_time="2026-10-16T04:54:42.123456")
        result, _, _, _ = run_main(project, mem_dir, now=now)
        expected = expected_backup_message("no valid backup found", mem_dir)
        assert sys_message(result) == expected, "expected timestamp without timezone to be invalid; got %r" % sys_message(result)
    finally:
        tmp.cleanup()


def test_wrong_schema_manifest_does_not_hide_old_backup():
    tmp, project, mem_dir = temp_paths()
    try:
        now = datetime.datetime.now(datetime.timezone.utc)
        make_backup(mem_dir, 1, now=now, schema_version=2)
        make_backup(mem_dir, 10, now=now)
        result, _, _, _ = run_main(project, mem_dir, now=now)
        expected = expected_backup_message("latest valid backup is 10 days ago", mem_dir)
        assert sys_message(result) == expected, "expected invalid schema not to hide stale backup; got %r" % sys_message(result)
    finally:
        tmp.cleanup()


def test_unreadable_backup_root_silently_skips():
    tmp, project, mem_dir = temp_paths()
    try:
        root = os.path.join(mem_dir, "backups")
        os.mkdir(root)
        original = ss.os.listdir

        def denied(path):
            if os.fspath(path) == root:
                raise PermissionError("synthetic denial")
            return original(path)

        ss.os.listdir = denied
        try:
            result, _, _, stderr = run_main(project, mem_dir)
        finally:
            ss.os.listdir = original
        assert BACKUP_TEXT not in sys_message(result), sys_message(result)
        assert "synthetic denial" not in stderr
    finally:
        tmp.cleanup()


def test_invalid_age_value_falls_back_to_seven_via_main():
    tmp, project, mem_dir = temp_paths()
    try:
        now = datetime.datetime.now(datetime.timezone.utc)
        make_backup(mem_dir, 10, now=now)
        result, _, _, _ = run_main(project, mem_dir, now=now,
            extra_env={"DRSG_BACKUP_MAX_AGE_DAYS": "not-an-integer"})
        expected = expected_backup_message("latest valid backup is 10 days ago", mem_dir)
        assert sys_message(result) == expected, "expected invalid age to fall back to 7; got %r" % sys_message(result)
    finally:
        tmp.cleanup()


def test_bounded_scan_with_300_unrelated_entries():
    tmp, project, mem_dir = temp_paths()
    try:
        root = os.path.join(mem_dir, "backups")
        os.makedirs(root)
        for i in range(300):
            os.mkdir(os.path.join(root, "unrelated-%04d" % i))
        for i in range(7):
            dirname = "backup-20261016T120000%06dZ-%08x" % (i, i + 1)
            path = os.path.join(root, dirname)
            os.mkdir(path)
            with open(os.path.join(path, "manifest.json"), "w", encoding="utf-8") as fh:
                json.dump({"tool": "drsg-memory-backup", "schema_version": 1,
                           "backup_time": "not-a-time"}, fh)
        opened = []
        original_open = open

        def count_manifest_open(file, *args, **kwargs):
            if os.fspath(file).endswith("manifest.json"):
                opened.append(os.fspath(file))
            return original_open(file, *args, **kwargs)

        import builtins
        old_open = builtins.open
        builtins.open = count_manifest_open
        try:
            repetitions = 30 if os.environ.get("N2_BENCHMARK") == "1" else 1
            for _ in range(repetitions):
                cold_r2_imports()
                result, _, _, _ = run_main(project, mem_dir)
                metrics.append(read_main_ms(project))
        finally:
            builtins.open = old_open
        expected = expected_backup_message("no valid backup found", mem_dir)
        assert sys_message(result) == expected, "expected invalid backup candidates to produce a no-valid-backup warning; got %r" % sys_message(result)
        assert len(opened) <= repetitions * 7, "opened %d manifests for %d runs" % (len(opened), repetitions)
        metrics_for_scan = metrics[-repetitions:]
        print("BENCH 300 unrelated + 7 invalid candidates: main ms median=%s p95=%s n=%d" % (
            statistics.median(metrics_for_scan), sorted(metrics_for_scan)[int((len(metrics_for_scan) - 1) * 0.95)], repetitions))
    finally:
        tmp.cleanup()


def test_no_backup_scan_rpc_is_added():
    tmp, project, mem_dir = temp_paths()
    try:
        result, _, calls, _ = run_main(project, mem_dir)
        assert calls.count("db.stats") == 1, calls
        assert not any("backup" in method.lower() for method in calls), calls
    finally:
        tmp.cleanup()


def benchmark_no_backup_main():
    tmp, project, mem_dir = temp_paths()
    try:
        samples = []
        for _ in range(30):
            cold_r2_imports()
            run_main(project, mem_dir)
            samples.append(read_main_ms(project))
        print("BENCH no backup directory: main ms median=%s p95=%s n=30" % (
            statistics.median(samples), sorted(samples)[int((len(samples) - 1) * 0.95)]))
    finally:
        tmp.cleanup()


test_cases = [
    ("daemon-down-real-loopback", test_daemon_down_real_loopback_subprocess),
    ("missing-token-silent", test_missing_token_stays_silent),
    ("missing-backup-main", test_missing_backup_directory_warns_via_main),
    ("one-day-z-backup-main", test_one_day_z_backup_is_fresh_via_main),
    ("ten-day-z-backup-main", test_ten_day_z_backup_warns_via_main),
    ("wrong-tool-does-not-hide-old-main", test_wrong_tool_manifest_does_not_hide_old_backup_via_main),
    ("zero-age-disables-main", test_zero_age_limit_disables_scan_via_main),
    ("non-loopback-skips-main", test_non_loopback_api_skips_backup_scan_via_main),
    ("resume-compact-main", test_resume_compact_skip_backup_but_keep_down_warning_via_main),
    ("regex-equals-backup-tool", test_template_regex_matches_backup_tool),
    ("z-time-parses-as-utc", test_z_timestamp_parses_as_utc),
    ("custom-mem-dir-command", test_custom_mem_dir_is_shell_quoted_in_daemon_command),
    ("corrupt-manifest-invalid", test_corrupt_manifest_is_invalid_not_fatal),
    ("symlink-candidate-invalid", test_symlink_candidates_are_not_backups),
    ("symlink-manifest-invalid", test_symlink_manifest_is_not_a_backup),
    ("symlink-root-not-followed", test_backup_root_symlink_is_not_followed),
    ("timezone-required", test_timezone_missing_manifest_is_invalid),
    ("schema-version-required", test_wrong_schema_manifest_does_not_hide_old_backup),
    ("unreadable-root-silent", test_unreadable_backup_root_silently_skips),
    ("invalid-age-defaults-seven", test_invalid_age_value_falls_back_to_seven_via_main),
    ("bounded-scan-300-unrelated", test_bounded_scan_with_300_unrelated_entries),
    ("no-backup-rpc-added", test_no_backup_scan_rpc_is_added),
]
only = os.environ.get("ONLY", "")
for name, fn in test_cases:
    if only and only != name:
        continue
    check(name, fn)
if only and not checks:
    check("unknown-only-case", lambda: (_ for _ in ()).throw(AssertionError(only)))
if os.environ.get("N2_BENCHMARK") == "1":
    benchmark_no_backup_main()
for name, passed, detail in checks:
    print(("PASS " if passed else "FAIL ") + name + (" — " + detail if detail else ""))
failed = sum(not passed for _, passed, _ in checks)
print("RESULT: %d/%d passed" % (len(checks) - failed, len(checks)))
sys.exit(1 if failed else 0)
PY

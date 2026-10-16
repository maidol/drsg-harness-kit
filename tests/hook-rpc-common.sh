#!/usr/bin/env bash
# Contracts for the shared SessionEnd/L3 RPC helper and its fail-open boundary.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SOURCE_ROOT="${V116_SOURCE_ROOT:-$REPO}"
ONLY="${ONLY:-all}"
env -u PYTHONPATH python3 - "$SOURCE_ROOT" "$ONLY" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
only = sys.argv[2]
hooks = repo / "tools/templates/hooks"
failures = []
ran = 0


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(name, fn):
    global ran
    if only not in ("all", name):
        return
    ran += 1
    try:
        fn()
    except Exception as exc:
        failures.append(name)
        print(f"FAIL {name}: {type(exc).__name__}: {exc}")
    else:
        print(f"PASS {name}")


def test_shared_calls_and_timeouts(target="both"):
    sys.path.insert(0, str(hooks))
    common = load("hook_rpc_common", hooks / "drsg_hook_common.py")
    sys.modules["drsg_hook_common"] = common
    se = load("hook_rpc_session_end", hooks / "session_end.py")
    l3 = load("hook_rpc_l3_digest", hooks / "l3_digest.py")
    assert se._common is common and l3._common is common
    calls = []
    def stub(method, params, token, timeout=3):
        calls.append((method, timeout))
        return {"nodes": []}
    common.rpc = stub
    old_env = {key: os.environ.get(key) for key in (
        "DRSG_TOKEN", "DRSG_API", "DRSG_PLANE", "DRSG_L3_CHAT", "DRSG_MEM_DIR",
        "CLAUDE_PROJECT_DIR")}
    with tempfile.TemporaryDirectory() as td:
        os.environ.update({"DRSG_TOKEN": "fake-token", "DRSG_API": "http://127.0.0.1:1/rpc",
                           "DRSG_PLANE": "memory", "DRSG_MEM_DIR": td,
                           "CLAUDE_PROJECT_DIR": td})
        os.environ.pop("DRSG_L3_CHAT", None)
        if target in ("both", "session"):
            se.mine = lambda path: ({}, {}, {}, {}, {}, {"lines": 0, "truncated": False})
            se.telemetry = lambda *args: None
            previous = sys.stdin
            try:
                sys.stdin = io.StringIO(json.dumps({"session_id": "s-test", "transcript_path": ""}))
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    se.main()
            finally:
                sys.stdin = previous
        if target in ("both", "l3"):
            transcript = pathlib.Path(td) / "transcript.jsonl"
            transcript.write_text(json.dumps({"type": "user", "message": {
                "content": "x" * 500}}) + "\n", encoding="utf-8")
            l3.DRSG_DIR = td
            os.environ["DRSG_L3_CHAT"] = "openai"
            previous_argv = sys.argv
            try:
                sys.argv = [str(hooks / "l3_digest.py"), "s-test", str(transcript)]
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    try:
                        l3.main()
                    except SystemExit as exc:
                        assert exc.code in (None, 0), exc.code
            finally:
                sys.argv = previous_argv
    for key, value in old_env.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
    expected = []
    if target in ("both", "session"):
        expected.append(("node.update", 2))
    if target in ("both", "l3"):
        expected.append(("digest.run", l3.RPC_TIMEOUT))
    assert calls == expected, calls


def test_common_timeout_passthrough():
    import urllib.request
    sys.path.insert(0, str(hooks))
    common = load("hook_rpc_timeout", hooks / "drsg_hook_common.py")
    old_api = os.environ.get("DRSG_API")
    seen = []
    class FakeSocket:
        def __init__(self):
            self.received = False
        def __enter__(self):
            return self
        def __exit__(self, *args):
            return False
        def sendall(self, data):
            pass
        def recv(self, size):
            if self.received:
                return b""
            self.received = True
            return b"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"result\":{}}"
    original_socket = common.socket.create_connection
    original_urlopen = urllib.request.urlopen
    common.socket.create_connection = lambda address, timeout: (
        seen.append((address, timeout)) or FakeSocket())
    try:
        os.environ["DRSG_API"] = "http://127.0.0.1:7700/rpc"
        assert common.rpc("db.stats", {}, "fake-token", timeout=2) == {}
        os.environ["DRSG_API"] = "https://example.invalid/rpc"
        def fake_urlopen(request, timeout):
            seen.append(("urlopen", timeout))
            return io.BytesIO(b"{\"result\":{}}")
        urllib.request.urlopen = fake_urlopen
        assert common.rpc("db.stats", {}, "fake-token", timeout=7) == {}
    finally:
        common.socket.create_connection = original_socket
        urllib.request.urlopen = original_urlopen
        if old_api is None:
            os.environ.pop("DRSG_API", None)
        else:
            os.environ["DRSG_API"] = old_api
    assert seen[0] == (("127.0.0.1", 7700), 2), seen
    assert seen[-1] == ("urlopen", 7), seen


def test_missing_helper_fails_open():
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        hook_dir = root / "project/.claude/hooks"
        hook_dir.mkdir(parents=True)
        project = root / "project"
        shutil.copy2(hooks / "session_end.py", hook_dir / "session_end.py")
        shutil.copy2(hooks / "l3_digest.py", hook_dir / "l3_digest.py")
        shutil.copy2(hooks / "secret_redact.py", hook_dir / "secret_redact.py")
        transcript = root / "transcript.jsonl"
        transcript.write_text(json.dumps({"type": "user", "message": {
            "content": "x" * 500}}) + "\n", encoding="utf-8")
        marker = root / "rpc-called"
        wrapper = (
            "import os, runpy, socket, sys\n"
            "def blocked(*a, **k):\n"
            " open(os.environ['HOOK_RPC_MARKER'], 'a').write('rpc\\n')\n"
            " raise OSError('unexpected rpc')\n"
            "socket.create_connection = blocked\n"
            "sys.argv = [sys.argv[1]] + sys.argv[2:]\n"
            "runpy.run_path(sys.argv[0], run_name='__main__')\n")
        env = os.environ.copy()
        env.pop("PYTHONPATH", None)
        env.update({"DRSG_TOKEN": "fake-token", "DRSG_API": "http://127.0.0.1:1/rpc",
                    "DRSG_L3_CHAT": "openai", "CLAUDE_PROJECT_DIR": str(project),
                    "HOOK_RPC_MARKER": str(marker)})
        end = subprocess.run([sys.executable, "-c", wrapper, str(hook_dir / "session_end.py")],
                             input=json.dumps({"session_id": "s-test", "transcript_path": ""}),
                             text=True, capture_output=True, env=env, timeout=5)
        assert end.returncode == 0 and not end.stderr, (end.returncode, end.stderr)
        assert not marker.exists(), "SessionEnd attempted an RPC without the helper"
        digest = subprocess.run([sys.executable, "-c", wrapper,
                                 str(hook_dir / "l3_digest.py"), "s-test", str(transcript)],
                                text=True, capture_output=True, env=env, timeout=5)
        assert digest.returncode == 0, (digest.returncode, digest.stderr)
        assert not digest.stderr and "Traceback" not in digest.stdout, digest.stdout + digest.stderr
        assert not marker.exists(), "L3 attempted an RPC without the helper"
        log = project / ".drsg/l3.log"
        lines = log.read_text(encoding="utf-8").splitlines()
        missing = [line for line in lines if "drsg_hook_common" in line]
        assert len(missing) == 1 and "missing" in missing[0].lower(), lines


run("g4-session-end-rpc", lambda: test_shared_calls_and_timeouts("session"))
run("g4-l3-digest-rpc", lambda: test_shared_calls_and_timeouts("l3"))
run("g4-common-timeout-passthrough", test_common_timeout_passthrough)
run("g4-missing-common", test_missing_helper_fails_open)
if only != "all" and ran == 0:
    print("FAIL unknown-only-case: " + only)
    raise SystemExit(1)
if failures:
    print("FAILED %d case(s): %s" % (len(failures), ", ".join(failures)))
    raise SystemExit(1)
print("ALL SELECTED CASES PASSED")
PY

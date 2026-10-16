#!/usr/bin/env bash
# Focused contracts for the v1.16 hook and transport consolidation.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
ONLY="${ONLY:-all}"
V116_SOURCE_ROOT="${V116_SOURCE_ROOT:-$REPO}"

python3 - "$REPO" "$V116_SOURCE_ROOT" "$ONLY" <<'PY'
import ast
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
only = sys.argv[3]
failures = []


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run_case(name, fn):
    if only not in ("all", name):
        return
    try:
        fn()
    except Exception as exc:
        failures.append(name)
        print(f"FAIL {name}: {type(exc).__name__}: {exc}")
    else:
        print(f"PASS {name}")


def hook_share():
    hooks = root / "tools/templates/hooks"
    common_path = hooks / "drsg_hook_common.py"
    assert common_path.is_file(), "drsg_hook_common.py is missing"
    sys.path.insert(0, str(hooks))
    common = importlib.import_module("drsg_hook_common")
    names = (
        "rpc", "load_env", "telemetry", "_proc", "_claude_pid", "_hook_lanes",
        "_hook_lease", "_hook_lane_names", "_hook_idle", "_lane_owner_line",
        "event_owner", "mark_events_shown", "ack_events", "retired",
    )
    modules = [
        load("v116_session_start", hooks / "session_start.py"),
        load("v116_user_prompt", hooks / "user_prompt.py"),
    ]
    for name in names:
        shared = getattr(common, name)
        assert all(getattr(module, name, None) is shared for module in modules), (
            f"{name} is not imported by identity from drsg_hook_common"
        )
    for module, path in zip(modules, (hooks / "session_start.py", hooks / "user_prompt.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        local = {node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
        duplicates = local.intersection(names)
        assert not duplicates, f"{path.name} still defines shared helpers: {sorted(duplicates)}"


def hook_owner_parity():
    hooks = root / "tools/templates/hooks"
    sys.path.insert(0, str(hooks))
    start = load("v116_owner_start", hooks / "session_start.py")
    prompt = load("v116_owner_prompt", hooks / "user_prompt.py")
    # These deterministic lease results exercise the shared wording without
    # depending on a machine's live poller state.
    common = start._common
    assert common is prompt._common
    original = {name: getattr(common, name) for name in (
        "_claude_pid", "_hook_lanes", "_hook_lease", "_hook_lane_names")}
    common._claude_pid = lambda: 12345
    common._hook_lanes = lambda pid: ["*"]
    common._hook_lease = lambda state, lane: {"session_id": "session-v116", "pid": 12345}
    common._hook_lane_names = lambda state: []
    try:
        with tempfile.TemporaryDirectory() as td:
            left = start.event_owner(td, "session-v116")
            right = prompt.event_owner(td, "session-v116")
        assert left == right, f"event_owner wording differs: {left!r} != {right!r}"
    finally:
        for name, value in original.items():
            setattr(common, name, value)


def hook_ack_semantics():
    hooks = root / "tools/templates/hooks"
    sys.path.insert(0, str(hooks))
    common = importlib.import_module("drsg_hook_common")
    original_rpc = common.rpc
    stderr = io.StringIO()
    try:
        common.rpc = lambda *args, **kwargs: {}
        with contextlib.redirect_stderr(stderr):
            common.ack_events(["evt-test"], "session-test", "x")
        assert "changed nothing" in stderr.getvalue(), stderr.getvalue()
        stderr.seek(0)
        stderr.truncate(0)
        with contextlib.redirect_stderr(stderr):
            common.ack_events(["evt-test"], "session-test", "x", quiet=True)
        assert stderr.getvalue() == "", stderr.getvalue()
        common.rpc = lambda *args, **kwargs: (_ for _ in ()).throw(OSError("fixture"))
        with contextlib.redirect_stderr(stderr):
            common.ack_events(["evt-test"], "session-test", "x")
        assert "ack events: fixture" in stderr.getvalue(), stderr.getvalue()
        stderr.seek(0)
        stderr.truncate(0)
        with contextlib.redirect_stderr(stderr):
            common.ack_events(["evt-test"], "session-test", "x", quiet=True)
        assert stderr.getvalue() == "", stderr.getvalue()
    finally:
        common.rpc = original_rpc


def hook_missing_module():
    hooks = root / "tools/templates/hooks"
    with tempfile.TemporaryDirectory() as td:
        work = pathlib.Path(td)
        copied = work / "hooks"
        copied.mkdir()
        for name in ("session_start.py", "user_prompt.py", "session_end.py"):
            shutil.copy2(hooks / name, copied / name)
        site = work / "site"
        site.mkdir()
        (site / "sitecustomize.py").write_text(
            "import os, socket, urllib.request\n"
            "def blocked(*a, **k):\n"
            "    with open(os.environ['V116_RPC_MARKER'], 'a') as f: f.write('rpc\\n')\n"
            "    raise OSError('unexpected RPC in missing-module test')\n"
            "urllib.request.urlopen = blocked\n"
            "socket.create_connection = blocked\n",
            encoding="utf-8",
        )
        marker = work / "rpc-called"
        env = os.environ.copy()
        env.update({
            "PYTHONPATH": str(site),
            "V116_RPC_MARKER": str(marker),
            "DRSG_API": "http://127.0.0.1:1/rpc",
            "DRSG_TOKEN": "v116-fake-token",
            "DRSG_MEM_DIR": str(work / "memory"),
            "CLAUDE_PROJECT_DIR": str(work / "project"),
        })
        (work / "project").mkdir()
        cases = (
            ("session_start.py", {"session_id": "session-v116", "source": "startup"}, "SessionStart"),
            ("user_prompt.py", {"session_id": "session-v116", "prompt": "hello"}, "UserPromptSubmit"),
        )
        for script, payload, event_name in cases:
            result = subprocess.run(
                [sys.executable, str(copied / script)], input=json.dumps(payload),
                text=True, capture_output=True, env=env, timeout=5,
            )
            assert result.returncode == 0, f"{script} exited {result.returncode}: {result.stderr}"
            assert not result.stderr, f"{script} wrote stderr: {result.stderr}"
            output = json.loads(result.stdout)
            assert output["hookSpecificOutput"]["hookEventName"] == event_name
            assert not marker.exists(), f"{script} attempted RPC while drsg_hook_common.py was absent"
        result = subprocess.run(
            [sys.executable, str(copied / "session_end.py")],
            input=json.dumps({"session_id": "session-v116"}),
            text=True, capture_output=True, env=env, timeout=5,
        )
        assert result.returncode == 0, f"session_end.py exited {result.returncode}: {result.stderr}"


def template_install_audit():
    hooks = root / "tools/templates/hooks"
    py_templates = sorted(hooks.glob("*.py"))
    assert len(py_templates) == 7, f"expected 7 hook templates, found {len(py_templates)}"
    common = hooks / "drsg_hook_common.py"
    assert common.is_file(), "the shared helper is not an installer template"
    with tempfile.TemporaryDirectory() as td:
        project = pathlib.Path(td) / "project"
        target = project / ".claude/hooks"
        target.mkdir(parents=True)
        for path in py_templates:
            if path.name != common.name:
                shutil.copy2(path, target / path.name)
        check = subprocess.run(
            ["bash", str(root / "tools/install.sh"), str(project), "--check"],
            text=True, capture_output=True, timeout=30,
        )
        assert check.returncode != 0, "install.sh --check missed the absent shared hook module"
        assert "drsg_hook_common.py" in check.stdout + check.stderr
        shutil.copy2(common, target / common.name)
        for path in target.glob("*.py"):
            path.chmod(0o755)
        check = subprocess.run(
            ["bash", str(root / "tools/install.sh"), str(project), "--check"],
            text=True, capture_output=True, timeout=30,
        )
        assert check.returncode == 0, f"complete hook set drifted: {check.stdout}{check.stderr}"
        audit = load("v116_deployment_audit", root / "tools/audit_deployment.py")
        result = audit.check_layer3(str(hooks), str(project))
        assert result["ok"], result
        assert "All 7 hook templates" in result["details"][0], result


def event_block_size():
    source = (root / "tools/install.sh").read_text(encoding="utf-8")
    match = re.search(r'block = f"""(.*?)"""', source, re.S)
    assert match, "generated Event block was not found"
    generated = match.group(1).replace("{BEGIN}", "<!-- drsg-memory:events:begin -->")
    generated = generated.replace("{END}", "<!-- drsg-memory:events:end -->")
    generated = generated.replace("{plane}", "memory").replace("{tools_dir}", "tools")
    assert len(generated) <= 700, f"Event block template is {len(generated)} characters"
    for description, fragments in (
        ("Event not Fact", ("`Event`", "`Fact`", "not")),
        ("MCP not hand-written Cypher", ("`drsg-events` MCP", "Cypher")),
        ("graph fields", ("`symbols`", "`verb`", "`summary`")),
        ("receiving without a call", ("Receiving", "no call")),
        ("no Bash event.py", ("Bash", "`event.py`")),
    ):
        assert all(fragment in generated for fragment in fragments), f"missing {description} rule"


def event_block_reinstall():
    source = (root / "tools/install.sh").read_text(encoding="utf-8")
    match = re.search(r'python3 - "\$PROJECT_DIR" "\$PLANE" "\$TOOLS_DIR" <<\'PYEOF\'\n(.*?)\nPYEOF', source, re.S)
    assert match, "generated Event block writer was not found"
    script = match.group(1)
    with tempfile.TemporaryDirectory() as td:
        project = pathlib.Path(td)
        (project / "CLAUDE.md").write_text(
            "before\n\n<!-- drsg-memory:events:begin -->\n" + "old generated text\n" * 40
            + "<!-- drsg-memory:events:end -->\n\nafter\n",
            encoding="utf-8",
        )
        for _ in range(2):
            result = subprocess.run(
                [sys.executable, "-", str(project), "memory", str(root / "tools")],
                input=script, text=True, capture_output=True, timeout=5,
            )
            assert result.returncode == 0, f"generated writer failed: {result.stderr}"
        installed = (project / "CLAUDE.md").read_text(encoding="utf-8")
        assert installed.startswith("before\n") and installed.rstrip().endswith("after"), installed
        assert installed.count("<!-- drsg-memory:events:begin -->") == 1, installed
        assert installed.count("<!-- drsg-memory:events:end -->") == 1, installed
        section = installed.split("<!-- drsg-memory:events:begin -->", 1)[1].split(
            "<!-- drsg-memory:events:end -->", 1
        )[0]
        assert "old generated text" not in section
        assert len(section.strip()) <= 700, f"installed Event block is {len(section.strip())} characters"


def rpc_sharing():
    names = (
        "analyze_events.py", "analyze_recall.py", "backfill_text.py",
        "event.py", "migrate.py", "project_registry.py",
    )
    tools = root / "tools"
    for name in names:
        source = (tools / name).read_text(encoding="utf-8")
        assert "ProxyHandler({})" not in source, f"{name} still disables proxies locally"
        assert not re.search(r"^\s*def _urlopen\s*\(", source, re.M), f"{name} still defines _urlopen"
    helper = tools / "drsg_rpc.py"
    assert helper.is_file(), "shared drsg_rpc.py is missing"
    with tempfile.TemporaryDirectory() as td:
        copied = pathlib.Path(td)
        for name in (*names, "drsg_rpc.py"):
            shutil.copy2(tools / name, copied / name)
        sys.path.insert(0, str(copied))
        sys.modules.pop("drsg_rpc", None)
        transport = importlib.import_module("drsg_rpc")
        calls = []
        transport.rpc = lambda api, token, method, params, timeout=5: (
            calls.append((api, token, method, params, timeout)) or {
                "result": {"nodes": [], "rows": []}
            }
        )
        modules = [
            load("v116_client_" + str(i), copied / name)
            for i, name in enumerate(names)
        ]
        api = "http://127.0.0.1:1/rpc"
        test_key = "t"
        daemon_env = copied / "daemon.env"
        daemon_env.write_text("DRSG_TOKEN=" + test_key + "\n", encoding="utf-8")
        calls_to_make = (
            lambda: modules[0].rpc("db.stats", {}, test_key),
            lambda: modules[1].rpc(api, "db.stats", {}, test_key),
            lambda: modules[2].rpc("db.stats", {}, test_key),
            lambda: modules[3].rpc("db.stats", {}, test_key),
            lambda: modules[4].rpc(api, test_key, "db.stats", {}),
            lambda: modules[5].known_projects(str(daemon_env), api, "memory"),
        )
        for call in calls_to_make:
            call()
        assert len(calls) == 6, f"six clients did not reach shared rpc stub: {calls}"
        assert all(call[1] == test_key for call in calls), f"shared RPC received unexpected args: {calls}"


def mcp_events_clean_copy():
    with tempfile.TemporaryDirectory() as td:
        copied = pathlib.Path(td)
        names = ("event.py", "event-poller.py", "mcp_events.py", "secret_redact.py", "drsg_rpc.py")
        for name in names:
            source = root / "tools" / name
            if source.exists():
                shutil.copy2(source, copied / name)
        assert (copied / "drsg_rpc.py").is_file(), "shared RPC module missing from clean copy"
        sys.path.insert(0, str(copied))
        sys.modules.pop("drsg_rpc", None)
        transport = importlib.import_module("drsg_rpc")
        calls = []
        transport.rpc = lambda api, token, method, params, timeout=5: (
            calls.append((method, params)) or {"result": {"nodes": [{
                    "external_key": "evt-v116-clean-copy",
                    "properties": {
                        "status": "open", "kind": "notice",
                        "from_project": "example-project", "summary": "clean copy event",
                    },
                }], "rows": []}}
        )
        os.environ["DRSG_API"] = "http://127.0.0.1:1/rpc"
        os.environ["DRSG_TOKEN"] = "v116-fake-token"
        os.environ["CLAUDE_PROJECT_DIR"] = str(copied)
        module = load("v116_mcp_events", copied / "mcp_events.py")
        result = module.call_tool("event_list", {"project": str(copied), "status": "open"}, "v116-fake-token")
        assert calls, "dynamic event.py import did not reach the shared RPC stub"
        assert "evt-v116-clean-copy" in json.dumps(result), result


run_case("hook-share", hook_share)
run_case("hook-owner-parity", hook_owner_parity)
run_case("hook-ack-semantics", hook_ack_semantics)
run_case("hook-missing-module", hook_missing_module)
run_case("template-install-audit", template_install_audit)
run_case("event-block", event_block_size)
run_case("event-block-reinstall", event_block_reinstall)
run_case("rpc-sharing", rpc_sharing)
run_case("mcp-events-clean-copy", mcp_events_clean_copy)
if failures:
    print(f"FAILED {len(failures)} case(s): {', '.join(failures)}")
    sys.exit(1)
print("ALL SELECTED CASES PASSED")
PY

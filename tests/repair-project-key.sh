#!/usr/bin/env bash
# Project-key repair integration tests: an isolated daemon and database only.
set -euo pipefail
unset DRSG_API DRSG_TOKEN DRSG_PLANE
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
[ -x "$BIN" ] || BIN="$(command -v drsg || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "SKIP repair-project-key: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi
for tool in curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP repair-project-key: missing $tool"
    exit 0
  fi
done

T="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
DEAD_PORT="$(python3 - "$PORT" <<'PY'
import socket
import sys
avoid = int(sys.argv[1])
while True:
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    if port != avoid:
        print(port)
        break
PY
)"
TOKEN="repair-project-test-token"
API="http://127.0.0.1:$PORT/rpc"
HOOKS="$T/hooks"
mkdir -p "$HOOKS"
cp -R "$REPO/tools/templates/hooks/." "$HOOKS/"
if [ -n "${REPAIR_TEST_COMMON:-}" ]; then
  cp "$REPAIR_TEST_COMMON" "$HOOKS/drsg_hook_common.py"
fi
python3 - "$HOOKS/user_prompt.py" "$DEAD_PORT" <<'PY'
from pathlib import Path
import sys
path, port = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
old = 'API = "http://127.0.0.1:7700/rpc"'
new = 'API = "http://127.0.0.1:%s/rpc"' % port
if text.count(old) != 1:
    raise SystemExit("FAIL test hook copy: expected exactly one production-address line")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
DRSG_TOKEN="$TOKEN" "$BIN" --db "$T/memory.drsg" serve --addr "127.0.0.1:$PORT" \
  >"$T/daemon.log" 2>&1 &
DAEMON=$!
cleanup() {
  kill "$DAEMON" 2>/dev/null || true
  wait "$DAEMON" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT
for _ in $(seq 1 60); do
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
    curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.2
done
if ! NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
     curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "FAIL repair-project-key: temporary daemon did not start"
  exit 1
fi

NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
REPAIR_TEST_ROOT="$T" REPAIR_TEST_API="$API" REPAIR_TEST_TOKEN="$TOKEN" \
REPAIR_TEST_HOOKS="$HOOKS" REPAIR_TEST_SCRIPT="${REPAIR_SCRIPT:-$REPO/tools/repair_project_key.py}" \
python3 - "$REPO" <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import urllib.request

repo = Path(sys.argv[1])
root = Path(os.environ["REPAIR_TEST_ROOT"])
api = os.environ["REPAIR_TEST_API"]
token = os.environ["REPAIR_TEST_TOKEN"]
hooks = Path(os.environ["REPAIR_TEST_HOOKS"])
script = Path(os.environ["REPAIR_TEST_SCRIPT"])
only = os.environ.get("ONLY", "")
case_names = (
    "full-edge-preservation",
    "dry-run-no-write",
    "snapshot-failure-no-delete",
    "edge-create-exception",
    "edge-create-empty",
    "edge-create-fake-success",
    "seed-truncated",
    "self-loop-preservation",
)


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1,
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=5) as response:
        result = json.load(response)
    if "error" in result:
        raise AssertionError("fixture RPC failed: " + str(result["error"].get("code")))
    return result.get("result")


def seed():
    return rpc("graph.seed", {"plane": "memory", "limit": 100000})


def props(node):
    return node.get("properties") or {}


def edge_signature(edge, old_id=None, new_id=None):
    src = new_id if edge.get("src") == old_id else edge.get("src")
    dst = new_id if edge.get("dst") == old_id else edge.get("dst")
    return (src, dst, edge.get("type"),
            json.dumps(edge.get("properties") or {}, sort_keys=True, separators=(",", ":")))


def fixture(name, self_loop=False, include_unkeyed=True):
    case_dir = root / name
    case_dir.mkdir()
    project_dir = case_dir / "project"
    (project_dir / ".drsg").mkdir(parents=True)
    project_key = "repair-project-" + name
    project_path = str(project_dir)
    (project_dir / ".drsg" / "env").write_text(
        "DRSG_API=%s\nDRSG_TOKEN=%s\nDRSG_PLANE=memory\n" % (api, token),
        encoding="utf-8")
    project = rpc("node.create", {"plane": "memory", "key": project_key,
                                  "labels": ["Project", "Fixture"],
                                  "properties": {"path": project_path, "fixture": name}})
    old_id = project["id"]
    nodes = {}

    def node(label, key, properties):
        params = {"plane": "memory", "labels": [label], "properties": properties}
        if key is not None:
            params["key"] = key
        created = rpc("node.create", params)
        return created["id"]

    edges = []

    def edge(src, dst, kind, properties):
        created = rpc("edge.create", {"plane": "memory", "src": src, "dst": dst,
                                      "type": kind, "properties": properties})
        edges.append(created)
        return created

    if self_loop:
        edge(old_id, old_id, "SELF", {"marker": "one"})
        return {"case_dir": case_dir, "project_dir": project_dir,
                "project_key": project_key, "project_path": project_path,
                "old": project, "old_id": old_id, "edges": edges,
                "nodes": nodes, "unrelated_edge": None}

    nodes["keyed_fact"] = node("Fact", "repair-fact-key-" + name, {"text": "keyed"})
    if include_unkeyed:
        nodes["plain_fact"] = node("Fact", None, {"text": "unkeyed"})
    nodes["session"] = node("Session", "repair-session-" + name, {"session": name})
    nodes["event"] = node("Event", "repair-event-" + name, {"summary": "fixture"})
    nodes["outgoing"] = node("Fact", "repair-outgoing-" + name, {"text": "outgoing"})
    edge(nodes["keyed_fact"], old_id, "ABOUT", {"w": 1})
    if include_unkeyed:
        edge(nodes["plain_fact"], old_id, "ABOUT", {"plain": True})
    edge(nodes["session"], old_id, "BELONGS_TO", {"slot": 2})
    edge(nodes["event"], old_id, "NOTIFY", {"notify": "handoff"})
    edge(old_id, nodes["outgoing"], "RELATED_TO", {"direction": "out"})
    unrelated = rpc("node.create", {"plane": "memory", "key": "repair-unrelated-" + name,
                                     "labels": ["Project"],
                                     "properties": {"path": str(case_dir / "unrelated")}})
    unrelated_fact = node("Fact", "repair-unrelated-fact-" + name, {"text": "unrelated"})
    unrelated_edge = rpc("edge.create", {"plane": "memory", "src": unrelated_fact,
                                           "dst": unrelated["id"], "type": "ABOUT",
                                           "properties": {"unrelated": True}})
    return {"case_dir": case_dir, "project_dir": project_dir,
            "project_key": project_key, "project_path": project_path,
            "old": project, "old_id": old_id, "edges": edges,
            "nodes": nodes, "unrelated_edge": unrelated_edge}


def install_shim(fault):
    shim_dir = root / ("shim-" + fault)
    shim_dir.mkdir()
    source = '''import json, os, sys\n\nhooks = os.environ["DRSG_HOOKS_DIR"]\nsys.path.insert(0, hooks)\nfault = os.environ["REPAIR_TEST_FAULT"]\nsys.stderr.write("repair-test-shim: active %s\\n" % fault)\nimport user_prompt\noriginal_rpc = user_prompt.rpc\ndef rpc(method, params, token):\n    if fault == "seed-truncated" and method == "graph.seed":\n        result = original_rpc(method, params, token)\n        result["truncated"] = True\n        return result\n    if method == "edge.create" and params.get("type") == "NOTIFY":\n        if fault == "edge-create-exception":\n            raise RuntimeError("injected repair-test edge failure")\n        if fault == "edge-create-empty":\n            return {}\n        if fault == "edge-create-fake-success":\n            return {"id": 9000001, "src": params.get("src"),\n                    "dst": params.get("dst"), "type": "NOTIFY",\n                    "properties": params.get("properties", {})}\n    return original_rpc(method, params, token)\nuser_prompt.rpc = rpc\n'''
    (shim_dir / "sitecustomize.py").write_text(source, encoding="utf-8")
    return shim_dir


def child_run(f, apply=True, snapshot_path=None, fault=None):
    env = os.environ.copy()
    for name in ("DRSG_API", "DRSG_TOKEN", "DRSG_PLANE"):
        env.pop(name, None)
    env["DRSG_PROJECT_DIR"] = str(f["project_dir"])
    env["DRSG_HOOKS_DIR"] = str(hooks)
    if fault:
        shim_dir = install_shim(fault)
        env["PYTHONPATH"] = str(shim_dir)
        env["REPAIR_TEST_FAULT"] = fault
    args = [sys.executable, str(script), "memory", f["project_path"], f["project_key"]]
    if apply:
        args.append("--apply")
    if snapshot_path is not None:
        args.extend(("--snapshot", str(snapshot_path)))
    return subprocess.run(args, cwd=f["case_dir"], env=env,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def current_target(f):
    nodes = seed().get("nodes", [])
    found = [n for n in nodes if "Project" in (n.get("labels") or [])
             and props(n).get("path") == f["project_path"]]
    return found[0] if len(found) == 1 else None


def target_edges(f, project_id):
    return [edge for edge in seed().get("edges", [])
            if edge.get("src") == project_id or edge.get("dst") == project_id]


def check_full_edge_preservation():
    f = fixture("full")
    snapshot_path = f["case_dir"] / "snapshot.json"
    result = child_run(f, snapshot_path=snapshot_path)
    assert result.returncode == 0, "expected rc 0; got %d\n%s\n%s" % (
        result.returncode, result.stdout, result.stderr)
    assert "PASS" in result.stdout, result.stdout
    rebuilt = current_target(f)
    assert rebuilt is not None, "target Project missing or duplicated"
    actual = [edge_signature(e) for e in target_edges(f, rebuilt["id"])]
    expected = [edge_signature(e, f["old_id"], rebuilt["id"]) for e in f["edges"]]
    assert sorted(actual) == sorted(expected), "target incident edges differ: %r != %r" % (actual, expected)
    assert rebuilt.get("labels") == f["old"].get("labels"), "labels changed"
    assert props(rebuilt) == props(f["old"]), "Project properties changed"
    node_by_key = rpc("node.get", {"plane": "memory", "key": f["project_key"]})
    assert node_by_key and node_by_key.get("id") == rebuilt.get("id"), "node.get by key mismatch"
    unrelated = seed().get("edges", [])
    assert any(edge_signature(e) == edge_signature(f["unrelated_edge"]) for e in unrelated), "unrelated Project edge changed"
    snap = json.loads(snapshot_path.read_text(encoding="utf-8"))
    assert len(snap.get("edges", [])) == 5, "snapshot must contain exactly five incident edges"
    saved_node = snap.get("node") or {}
    assert (saved_node.get("id"), saved_node.get("key"), saved_node.get("labels"),
            saved_node.get("properties")) == (
                f["old"].get("id"), f["project_key"], f["old"].get("labels"), props(f["old"])), "snapshot node mismatch"
    return True


def check_dry_run_no_write():
    f = fixture("dry")
    before_id = f["old_id"]
    before_edges = sorted(edge_signature(e) for e in target_edges(f, before_id))
    result = child_run(f, apply=False)
    assert result.returncode == 0, "expected rc 0; got %d\n%s\n%s" % (
        result.returncode, result.stdout, result.stderr)
    after = current_target(f)
    assert after and after["id"] == before_id, "dry run changed Project id"
    assert sorted(edge_signature(e) for e in target_edges(f, before_id)) == before_edges, "dry run changed edges"
    assert not list(f["case_dir"].glob("repair-project-key-*.json")), "dry run wrote a snapshot"
    return True


def check_snapshot_failure_no_delete():
    f = fixture("snapshot-failure")
    before_edges = sorted(edge_signature(e) for e in target_edges(f, f["old_id"]))
    bad_path = f["case_dir"] / "missing" / "snapshot.json"
    result = child_run(f, snapshot_path=bad_path)
    assert result.returncode == 3, "expected rc 3; got %d\n%s\n%s" % (
        result.returncode, result.stdout, result.stderr)
    after = current_target(f)
    assert after and after["id"] == f["old_id"], "old Project was deleted before snapshot failure"
    assert sorted(edge_signature(e) for e in target_edges(f, f["old_id"])) == before_edges, "edges changed on snapshot failure"
    return True


def check_injected_edge_failure(fault, expected_rc):
    f = fixture(fault, include_unkeyed=(fault != "edge-create-fake-success"))
    snapshot_path = f["case_dir"] / "snapshot.json"
    result = child_run(f, snapshot_path=snapshot_path, fault=fault)
    marker = "repair-test-shim: active " + fault
    assert marker in result.stderr, "fault shim did not activate; stderr=%r" % result.stderr
    assert result.returncode == expected_rc, "expected rc %d; got %d\n%s\n%s" % (
        expected_rc, result.returncode, result.stdout, result.stderr)
    assert str(snapshot_path) in result.stdout, "snapshot path missing from output"
    saved = json.loads(snapshot_path.read_text(encoding="utf-8"))
    failed_edges = [e for e in saved.get("edges", []) if e.get("type") == "NOTIFY"]
    assert len(failed_edges) == 1, "snapshot does not contain exactly one NOTIFY edge"
    if fault != "edge-create-fake-success":
        edge_json = json.dumps(failed_edges[0], sort_keys=True)
        assert edge_json in result.stdout, "complete failed edge JSON missing from output"
    rebuilt = current_target(f)
    assert rebuilt is not None, "recreated Project missing"
    remaining = target_edges(f, rebuilt["id"])
    for edge in saved["edges"]:
        if edge.get("type") != "NOTIFY":
            assert any(edge_signature(got) == edge_signature(edge, f["old_id"], rebuilt["id"])
                       for got in remaining), "repair did not continue after NOTIFY failure"
    if fault == "edge-create-fake-success":
        assert result.stdout.splitlines()[-1] == "FAIL", "verify failure must be the final line"
        assert "NOTIFY in want 1 got 0" in result.stdout, result.stdout
    return True


def check_seed_truncated():
    f = fixture("truncated")
    before_edges = sorted(edge_signature(e) for e in target_edges(f, f["old_id"]))
    result = child_run(f, snapshot_path=f["case_dir"] / "snapshot.json", fault="seed-truncated")
    assert "repair-test-shim: active seed-truncated" in result.stderr, "fault shim did not activate"
    assert result.returncode == 3, "expected rc 3; got %d\n%s\n%s" % (
        result.returncode, result.stdout, result.stderr)
    after = current_target(f)
    assert after and after["id"] == f["old_id"], "truncated plane changed Project id"
    assert sorted(edge_signature(e) for e in target_edges(f, f["old_id"])) == before_edges, "truncated plane changed edges"
    return True


def check_self_loop():
    f = fixture("self-loop", self_loop=True)
    snapshot_path = f["case_dir"] / "snapshot.json"
    result = child_run(f, snapshot_path=snapshot_path)
    assert result.returncode == 0, "expected rc 0; got %d\n%s\n%s" % (
        result.returncode, result.stdout, result.stderr)
    assert result.stdout.splitlines()[-1] == "PASS", result.stdout
    assert "SELF self want 1 got 1" in result.stdout, result.stdout
    rebuilt = current_target(f)
    assert rebuilt is not None, "self-loop Project missing"
    loops = [e for e in target_edges(f, rebuilt["id"])
             if e.get("src") == rebuilt["id"] and e.get("dst") == rebuilt["id"]]
    assert len(loops) == 1, "self-loop not restored exactly once"
    snap = json.loads(snapshot_path.read_text(encoding="utf-8"))
    assert len(snap.get("edges", [])) == 1, "self-loop snapshot duplicated the edge"
    return True


def run_case(name, test):
    global ran, passed
    if only and only != name:
        return
    ran += 1
    try:
        test()
    except Exception as error:
        print("FAIL %s: %s: %s" % (name, type(error).__name__, error))
        return
    passed += 1
    print("PASS %s" % name)


rpc("plane.create", {"name": "memory"})
if only and only not in case_names:
    print("FAIL unknown-only-case: " + only)
    print("PASS 0/1")
    sys.exit(1)
ran = passed = 0
run_case("full-edge-preservation", check_full_edge_preservation)
run_case("dry-run-no-write", check_dry_run_no_write)
run_case("snapshot-failure-no-delete", check_snapshot_failure_no_delete)
run_case("edge-create-exception", lambda: check_injected_edge_failure("edge-create-exception", 2))
run_case("edge-create-empty", lambda: check_injected_edge_failure("edge-create-empty", 2))
run_case("edge-create-fake-success", lambda: check_injected_edge_failure("edge-create-fake-success", 1))
run_case("seed-truncated", check_seed_truncated)
run_case("self-loop-preservation", check_self_loop)
if ran == 0:
    print("FAIL unknown-only-case: " + (only or "<none>"))
    ran = 1
print("PASS %d/%d" % (passed, ran))
sys.exit(0 if ran and passed == ran else 1)
PY

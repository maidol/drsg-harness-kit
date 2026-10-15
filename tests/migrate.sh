#!/usr/bin/env bash
# Migration contract tests run against one throwaway daemon and database.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
[ -x "$BIN" ] || BIN="$(command -v drsg || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "SKIP migrate: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi
for tool in curl python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP migrate: missing $tool"
    exit 0
  fi
done

T="$(mktemp -d)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
TOKEN="migrate-test-token"
API="http://127.0.0.1:$PORT/rpc"
DRSG_TOKEN="$TOKEN" "$BIN" --db "$T/memory.drsg" serve \
  --addr "127.0.0.1:$PORT" >"$T/daemon.log" 2>&1 &
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
  echo "FAIL migrate: temporary daemon did not start"
  exit 1
fi

NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
MIGRATE_TEST_ROOT="$T" MIGRATE_TEST_API="$API" MIGRATE_TEST_TOKEN="$TOKEN" \
MIGRATE_TEST_SCRIPT="${MIGRATE_SCRIPT:-$REPO/tools/migrate.py}" \
python3 - <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

root = Path(os.environ["MIGRATE_TEST_ROOT"])
api = os.environ["MIGRATE_TEST_API"]
token = os.environ["MIGRATE_TEST_TOKEN"]
script = Path(os.environ["MIGRATE_TEST_SCRIPT"])
only = os.environ.get("ONLY", "")
cases = (
    "load-rerun-no-duplicate",
    "properties-distinguish-edges",
    "dump-truncated",
    "load-target-truncated",
    "load-write-failure",
    "load-dry-run",
    "properties-key-order",
)


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1,
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=5) as response:
        out = json.load(response)
    if "error" in out:
        raise AssertionError("fixture RPC failed: " + str(out["error"].get("code")))
    return out.get("result")


def seed(plane, limit=100000):
    return rpc("graph.seed", {"plane": plane, "limit": limit})


def run(*args):
    return subprocess.run([sys.executable, str(script), *map(str, args)],
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def dump_file(name, nodes, edges):
    path = root / (name + ".json")
    path.write_text(json.dumps({"nodes": nodes, "edges": edges},
                               ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def node(plane, key, labels=None, properties=None):
    return rpc("node.create", {"plane": plane, "key": key,
                               "labels": labels or ["Fact"],
                               "properties": properties or {}})


def edge(plane, src, dst, kind="R", properties=None):
    return rpc("edge.create", {"plane": plane, "src": src, "dst": dst,
                               "type": kind, "properties": properties or {}})


def exit_assertions(condition, message, result):
    if not condition:
        raise AssertionError(message + "\nrc=%d\nstdout=%s\nstderr=%s" %
                             (result.returncode, result.stdout, result.stderr))


def case_load_rerun():
    src, dst = "src-rerun", "dst-rerun"
    src_nodes = [node(src, "rerun-a"), node(src, "rerun-b"), node(src, "rerun-c")]
    edge(src, src_nodes[0]["id"], src_nodes[1]["id"], properties={"w": 1})
    edge(src, src_nodes[1]["id"], src_nodes[2]["id"])
    dump = root / "rerun.json"
    first_dump = run("dump", "--api", api, "--token", token, "--plane", src, "--out", dump)
    exit_assertions(first_dump.returncode == 0, "dump should succeed", first_dump)
    first = run("load", "--api", api, "--token", token, "--plane", dst, "--in", dump)
    exit_assertions(first.returncode == 0, "first load should succeed", first)
    second = run("load", "--api", api, "--token", token, "--plane", dst, "--in", dump)
    counts = seed(dst)
    success = (second.returncode == 0 and
               "edges created=0 skipped=2" in second.stdout and
               len(counts["nodes"]) == 3 and len(counts["edges"]) == 2)
    exit_assertions(success,
                     "rerun should skip both existing edges and leave 3 nodes / 2 edges",
                     second)
    return True


def case_properties_distinguish():
    src, dst = "src-properties", "dst-properties"
    a, b = node(src, "properties-a"), node(src, "properties-b")
    edge(src, a["id"], b["id"], "R", {"v": 1})
    dump = root / "properties.json"
    result = run("dump", "--api", api, "--token", token, "--plane", src, "--out", dump)
    exit_assertions(result.returncode == 0, "dump should succeed", result)
    node(dst, "properties-a"), node(dst, "properties-b")
    dst_nodes = {n["external_key"]: n for n in seed(dst)["nodes"]}
    edge(dst, dst_nodes["properties-a"]["id"], dst_nodes["properties-b"]["id"],
         "R", {"v": 2})
    result = run("load", "--api", api, "--token", token, "--plane", dst, "--in", dump)
    exit_assertions(result.returncode == 0, "load should add the distinct-property edge", result)
    loaded = seed(dst)
    signatures = {(e["type"], json.dumps(e.get("properties") or {}, sort_keys=True))
                  for e in loaded["edges"]}
    assert signatures == {("R", '{"v": 1}'), ("R", '{"v": 2}')}, signatures
    return True


def case_dump_truncated():
    src = "src-truncated"
    node(src, "truncated-a"), node(src, "truncated-b"), node(src, "truncated-c")
    out = root / "truncated-out.json"
    result = run("dump", "--api", api, "--token", token, "--plane", src,
                 "--limit", 2, "--out", out)
    exit_assertions(result.returncode == 3 and not out.exists(),
                    "truncated dump must exit 3 without creating the output", result)
    assert "truncated" in result.stderr.lower() and "--limit" in result.stderr
    return True


def case_load_target_truncated():
    dst = "dst-truncated"
    node(dst, "existing-a"), node(dst, "existing-b"), node(dst, "existing-c")
    before = seed(dst)
    dump = dump_file("target-truncated", [
        {"key": "new-target-node", "labels": ["Fact"], "properties": {"new": True}},
        {"key": "new-target-peer", "labels": ["Fact"], "properties": {"peer": True}},
    ], [{"src_key": "new-target-node", "dst_key": "new-target-peer",
         "type": "R", "properties": {"new-edge": True}}])
    result = run("load", "--api", api, "--token", token, "--plane", dst,
                 "--limit", 2, "--in", dump)
    after = seed(dst)
    unchanged = (len(before["nodes"]) == len(after["nodes"]) == 3 and
                 len(before["edges"]) == len(after["edges"]))
    exit_assertions(result.returncode == 3 and unchanged,
                    "truncated target must exit 3 before node/edge writes", result)
    return True


def case_load_write_failure():
    dst = "dst-write-failure"
    dump = dump_file("write-failure", [
        {"key": "failure-a", "labels": ["Fact"], "properties": {}},
    ], [{"src_key": "failure-a", "dst_key": "missing-destination-key",
         "type": "R", "properties": {"bad": True}}])
    result = run("load", "--api", api, "--token", token, "--plane", dst, "--in", dump)
    success = (result.returncode == 1 and "FAIL edge failure-a -[R]-> missing-destination-key" in result.stderr
               and "verify:" in result.stdout and "-> PASS" not in result.stdout)
    exit_assertions(success, "edge failure must be nonzero and verification must not pass", result)
    return True


def case_load_dry_run():
    src, dst = "src-dry-run", "dst-dry-run"
    a, b, c = node(src, "dry-a"), node(src, "dry-b"), node(src, "dry-c")
    edge(src, a["id"], b["id"], properties={"dry": True})
    edge(src, b["id"], c["id"], properties={"dry": False})
    dump = root / "dry-run.json"
    dumped = run("dump", "--api", api, "--token", token, "--plane", src, "--out", dump)
    exit_assertions(dumped.returncode == 0, "dump should succeed", dumped)

    dst_a, dst_b = node(dst, "dry-a"), node(dst, "dry-b")
    edge(dst, dst_a["id"], dst_b["id"], properties={"dry": True})
    before = seed(dst)
    result = run("load", "--api", api, "--token", token, "--plane", dst,
                 "--in", dump, "--dry-run")
    after = seed(dst)
    counts = ("would create 1 nodes / would skip 2; "
              "would create 1 edges / would skip 1")
    unchanged = (len(before["nodes"]) == len(after["nodes"]) == 2 and
                 len(before["edges"]) == len(after["edges"]) == 1)
    exit_assertions(result.returncode == 0 and unchanged and counts in result.stdout,
                    "dry run should report create/skip counts and leave destination unchanged", result)
    return True


def case_properties_order():
    dst = "dst-order"
    dump = dump_file("properties-order", [
        {"key": "order-a", "labels": ["Fact"], "properties": {}},
        {"key": "order-b", "labels": ["Fact"], "properties": {}},
    ], [{"src_key": "order-a", "dst_key": "order-b", "type": "R",
         "properties": {"z": 1, "a": 2}}])
    a, b = node(dst, "order-a"), node(dst, "order-b")
    edge(dst, a["id"], b["id"], "R", {"a": 2, "z": 1})
    result = run("load", "--api", api, "--token", token, "--plane", dst, "--in", dump)
    exit_assertions(result.returncode == 0, "load should skip the canonical equivalent edge", result)
    assert len(seed(dst)["edges"]) == 1, "canonical property order produced a duplicate edge"
    return True


def run_case(name, function):
    global ran, passed
    if only and only != name:
        return
    ran += 1
    try:
        function()
    except Exception as error:
        print("FAIL %s: %s: %s" % (name, type(error).__name__, error))
        return
    passed += 1
    print("PASS %s" % name)


if only and only not in cases:
    print("FAIL unknown-only-case: " + only)
    print("PASS 0/1")
    sys.exit(1)
rpc("plane.create", {"name": "src-rerun"})
rpc("plane.create", {"name": "dst-rerun"})
rpc("plane.create", {"name": "src-properties"})
rpc("plane.create", {"name": "dst-properties"})
rpc("plane.create", {"name": "src-truncated"})
rpc("plane.create", {"name": "dst-truncated"})
rpc("plane.create", {"name": "dst-write-failure"})
rpc("plane.create", {"name": "src-dry-run"})
rpc("plane.create", {"name": "dst-dry-run"})
rpc("plane.create", {"name": "dst-order"})
ran = passed = 0
run_case("load-rerun-no-duplicate", case_load_rerun)
run_case("properties-distinguish-edges", case_properties_distinguish)
run_case("dump-truncated", case_dump_truncated)
run_case("load-target-truncated", case_load_target_truncated)
run_case("load-write-failure", case_load_write_failure)
run_case("load-dry-run", case_load_dry_run)
run_case("properties-key-order", case_properties_order)
if ran == 0:
    print("FAIL unknown-only-case: " + (only or "<none>"))
    ran = 1
print("PASS %d/%d" % (passed, ran))
sys.exit(0 if ran and passed == ran else 1)
PY

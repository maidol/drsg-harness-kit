#!/usr/bin/env python3
"""Collapse a duplicated external key down to one node, key index included.

Deleting only the shadow is not enough: the key is left resolving to nothing,
so the next digest run sees it as free and writes a fresh node beside the
survivor — the duplicate grows back. The survivor therefore has to be
recreated under the key and relinked.

Edges come from the plane export (id-based, with type and properties), taken
before anything is deleted. Usage: repair_dupe_key.py <key> <junk_id>
<keep_id> [--apply]

The RPC helper is loaded from ``$DRSG_HOOKS_DIR`` when set, otherwise from
``.claude/hooks`` under the current directory.  ``$DRSG_PROJECT_DIR`` selects
which project's environment supplies the daemon address and token; it defaults
to the current directory.
"""
import json
import os
import sys

PROJECT_DIR = os.environ.get("DRSG_PROJECT_DIR", os.getcwd())
HOOKS_DIR = os.environ.get(
    "DRSG_HOOKS_DIR", os.path.join(PROJECT_DIR, ".claude", "hooks")
)
sys.path.insert(0, HOOKS_DIR)
import user_prompt as u  # noqa: E402

EXPORT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory-export.jsonl")
PLANE = "memory"


def load_export():
    nodes, edges = {}, []
    for line in open(EXPORT, encoding="utf-8"):
        o = json.loads(line)
        if "src" in o and "dst" in o:
            edges.append(o)
        elif "id" in o:
            nodes[o["id"]] = o
    return nodes, edges


def repair(key, junk_id, keep_id, tok, apply=False):
    nodes, edges = load_export()
    keep = nodes[keep_id]
    mine = [e for e in edges if e["src"] == keep_id or e["dst"] == keep_id]
    print(f"{key}: 保留 id={keep_id} labels={keep.get('labels')} 边 {len(mine)} 条; "
          f"删除 id={junk_id}")
    for e in mine:
        print(f"    {e['src']} -{e['type']}-> {e['dst']}")
    if not apply:
        return

    u.rpc("node.delete", {"plane": PLANE, "id": junk_id}, tok)
    u.rpc("node.delete", {"plane": PLANE, "id": keep_id}, tok)
    if u.rpc("node.get", {"plane": PLANE, "key": key}, tok):
        raise SystemExit(f"{key} still resolves after both deletes — stop and look")

    new = u.rpc("node.create", {"plane": PLANE, "key": key,
                                "labels": keep.get("labels", []),
                                "properties": keep.get("properties", {})}, tok)
    nid = new["id"]
    for e in mine:
        src = nid if e["src"] == keep_id else e["src"]
        dst = nid if e["dst"] == keep_id else e["dst"]
        u.rpc("edge.create", {"plane": PLANE, "src": src, "dst": dst,
                              "type": e["type"], "properties": e.get("properties", {})}, tok)
    got = u.rpc("plane.neighbors", {"plane": PLANE, "id": nid}, tok)
    n = len(got.get("edges", got)) if isinstance(got, dict) else len(got)
    print(f"    → 重建为 id={nid}, 重连 {n}/{len(mine)} 条边")


if __name__ == "__main__":
    u.load_env(PROJECT_DIR)
    tok = os.environ.get("DRSG_TOKEN", "")
    apply = "--apply" in sys.argv
    repair(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), tok, apply)

#!/usr/bin/env python3
"""Repair a Project node whose external-key index entry went dangling.

Cause: digest.write bypasses the uniqueness check that node.create enforces, so
writing a second node carrying an existing key can leave the key index dangling.
The original Project is still reachable by its ``path`` property.

Repair: capture the Project and every incident edge before touching anything,
write a complete snapshot, then delete and recreate the Project under the same
key and relink its edges. Without ``--apply`` this is a read-only dry run.

Usage: repair_project_key.py <plane> <project-path> <key> [--apply]
       [--snapshot <path>]

The RPC helper is loaded from ``$DRSG_HOOKS_DIR`` when set, otherwise from
``.claude/hooks`` under the current directory. ``$DRSG_PROJECT_DIR`` selects
which project's ``.drsg/env`` supplies the daemon address and token; it defaults
to the current directory.
"""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import sys
import time

PROJECT_DIR = os.environ.get("DRSG_PROJECT_DIR", os.getcwd())
HOOKS_DIR = os.environ.get(
    "DRSG_HOOKS_DIR", os.path.join(PROJECT_DIR, ".claude", "hooks")
)
sys.path.insert(0, HOOKS_DIR)
import user_prompt as u  # noqa: E402  (reuse its rpc/load_env)

SEED_LIMIT = 100000


def graph_seed(plane, tok):
    return u.rpc("graph.seed", {"plane": plane, "limit": SEED_LIMIT}, tok)


def project_for_path(nodes, path):
    return [node for node in nodes
            if "Project" in (node.get("labels") or [])
            and (node.get("properties") or {}).get("path") == path]


def incident_edges(edges, node_id):
    # graph.seed returns each edge once; this also keeps a self-loop exactly once.
    return [edge for edge in edges
            if edge.get("src") == node_id or edge.get("dst") == node_id]


def snapshot_path(key, requested):
    if requested:
        return Path(requested)
    safe_key = re.sub(r"[^A-Za-z0-9._-]", "_", key)
    return Path.cwd() / ("repair-project-key-%s-%d.json" % (safe_key, int(time.time())))


def write_snapshot(path, node, edges):
    payload = {
        "node": {"id": node.get("id"), "key": node.get("external_key"),
                 "labels": node.get("labels") or [],
                 "properties": node.get("properties") or {}},
        "edges": edges,
    }
    created = False
    try:
        with open(path, "x", encoding="utf-8") as output:
            created = True
            json.dump(payload, output, ensure_ascii=False, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        if created:
            try:
                os.unlink(path)
            except OSError:
                pass
        raise


def edge_params(edge, old_id, new_id, plane):
    return {
        "plane": plane,
        "src": new_id if edge.get("src") == old_id else edge.get("src"),
        "dst": new_id if edge.get("dst") == old_id else edge.get("dst"),
        "type": edge["type"],
        "properties": edge.get("properties") or {},
    }


def edge_signature(edge, project_id):
    src, dst = edge.get("src"), edge.get("dst")
    if src == project_id and dst == project_id:
        direction, other = "self", project_id
    elif dst == project_id:
        direction, other = "in", src
    elif src == project_id:
        direction, other = "out", dst
    else:
        return None
    properties = json.dumps(edge.get("properties") or {}, sort_keys=True,
                            ensure_ascii=False, separators=(",", ":"))
    return (direction, edge.get("type"), other, properties)


def edge_counts(edges, project_id):
    counts = Counter()
    for edge in edges:
        signature = edge_signature(edge, project_id)
        if signature is not None:
            counts[signature] += 1
    return counts


def verify(plane, path, key, tok, old_node, old_edges, old_id, new_id):
    seed = graph_seed(plane, tok)
    if seed.get("truncated"):
        print("verify: graph.seed truncated -> FAIL")
        return False
    nodes = seed.get("nodes", [])
    edges = seed.get("edges", [])
    matches = project_for_path(nodes, path)
    keyed = u.rpc("node.get", {"plane": plane, "key": key}, tok)
    keyed_ok = bool(keyed and keyed.get("id") == new_id)
    metadata_ok = (len(matches) == 1
                   and matches[0].get("id") == new_id
                   and (matches[0].get("labels") or []) == (old_node.get("labels") or [])
                   and (matches[0].get("properties") or {}) ==
                       (old_node.get("properties") or {}))
    expected_edges = [edge_params(edge, old_id, new_id, plane)
                      for edge in old_edges]
    want = edge_counts(expected_edges, new_id)
    got = edge_counts(incident_edges(edges, new_id), new_id)
    ok = keyed_ok and metadata_ok and want == got
    for direction, edge_type in sorted({(sig[0], sig[1]) for sig in want} |
                                       {(sig[0], sig[1]) for sig in got},
                                       key=lambda item: (item[1], item[0])):
        expected_count = sum(n for sig, n in want.items()
                             if sig[0] == direction and sig[1] == edge_type)
        actual_count = sum(n for sig, n in got.items()
                           if sig[0] == direction and sig[1] == edge_type)
        print("%s %s want %d got %d" %
              (edge_type, direction, expected_count, actual_count))
    print("verify: node.get=%s project_nodes=%d labels_properties=%s" %
          ("ok" if keyed_ok else "MISSING", len(matches),
           "same" if metadata_ok else "DIFFERENT"))
    print("PASS" if ok else "FAIL")
    return ok


def repair(plane, path, key, tok, apply=False, requested_snapshot=None):
    seed = graph_seed(plane, tok)
    if seed.get("truncated"):
        print("refused: graph.seed result is truncated; increase its limit before repair",
              file=sys.stderr)
        raise SystemExit(3)
    nodes = seed.get("nodes", [])
    matches = project_for_path(nodes, path)
    if len(matches) != 1:
        print("refused: expected exactly 1 Project with path=%s, found %d" %
              (path, len(matches)), file=sys.stderr)
        raise SystemExit(3)
    old = matches[0]
    old_id = old["id"]
    edges = incident_edges(seed.get("edges", []), old_id)
    plan = {"plane": plane, "key": key, "project_path": path,
            "node": {"id": old_id, "key": old.get("external_key"),
                     "labels": old.get("labels") or [],
                     "properties": old.get("properties") or {}},
            "edges": edges}
    print(json.dumps(plan, ensure_ascii=False, indent=2))
    if not apply:
        print("(dry run — pass --apply to execute)")
        return plan

    snapshot = snapshot_path(key, requested_snapshot)
    try:
        write_snapshot(snapshot, old, edges)
    except Exception as error:
        print("refused: could not write snapshot %s (%s)" %
              (snapshot, error), file=sys.stderr)
        raise SystemExit(3)
    print("snapshot: %s" % snapshot)

    # Delete the orphan first. Creating first and deleting after risks the
    # delete taking the freshly-written index entry down with it — the very
    # failure this whole repair exists to undo.
    deleted = u.rpc("node.delete", {"plane": plane, "id": old_id}, tok)
    if isinstance(deleted, dict) and deleted.get("deleted") is False:
        print("repair stopped after snapshot; node.delete did not delete the old Project: %s" %
              snapshot, file=sys.stderr)
        raise SystemExit(1)
    if u.rpc("node.get", {"plane": plane, "key": key}, tok):
        print("repair stopped after snapshot: key still resolves after deleting the old Project: %s" %
              snapshot, file=sys.stderr)
        raise SystemExit(1)

    try:
        new = u.rpc("node.create", {"plane": plane, "key": key,
                                    "labels": old.get("labels") or [],
                                    "properties": old.get("properties") or {}}, tok)
    except Exception as error:
        print("repair stopped after snapshot: could not recreate Project (%s): %s" %
              (error, snapshot), file=sys.stderr)
        raise SystemExit(2)
    new_id = (new or {}).get("id") if isinstance(new, dict) else None
    if new_id is None:
        print("repair stopped after snapshot: node.create returned no id: %s" % snapshot,
              file=sys.stderr)
        raise SystemExit(2)

    failed = []
    for edge in edges:
        params = edge_params(edge, old_id, new_id, plane)
        try:
            result = u.rpc("edge.create", params, tok)
            if not isinstance(result, dict) or result.get("id") is None:
                failed.append(edge)
        except Exception:
            failed.append(edge)
    if failed:
        for edge in failed:
            print("failed edge: %s" % json.dumps(edge, ensure_ascii=False, sort_keys=True))
        print("repair incomplete; snapshot: %s" % snapshot, file=sys.stderr)
        raise SystemExit(2)

    if not verify(plane, path, key, tok, old, edges, old_id, new_id):
        print("verify failed; snapshot: %s" % snapshot, file=sys.stderr)
        raise SystemExit(1)
    return plan


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plane")
    parser.add_argument("project_path")
    parser.add_argument("key")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--snapshot")
    args = parser.parse_args(argv)
    u.load_env(PROJECT_DIR)
    u.API = os.environ.get("DRSG_API", u.API)
    tok = os.environ.get("DRSG_TOKEN", "")
    repair(args.plane, args.project_path, args.key, tok,
           apply=args.apply, requested_snapshot=args.snapshot)
    return 0


if __name__ == "__main__":
    sys.exit(main())

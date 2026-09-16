#!/usr/bin/env python3
"""Repair a Project node whose external-key index entry went dangling.

Cause: digest.write bypasses the uniqueness check that node.create enforces, so
a distillation run can write a second node carrying an existing key. Deleting
that shadow does NOT restore the index to the original node — the key then
resolves to nothing, and every `WHERE key(p) = ...` read returns empty while the
data itself is untouched (reachable via p.path).

Repair: capture the edges, drop the orphaned node, recreate it under the key,
relink. Edges are captured BEFORE anything is deleted and printed, so a crash
mid-way leaves a recoverable record rather than silent orphans.

Usage: repair_project_key.py <plane> <project-path> <key> [--apply]
Without --apply it only reports what it would do.

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
import user_prompt as u  # noqa: E402  (reuse its rpc/load_env)


def cypher(plane, q, params, tok):
    return u.rpc("plane.cypher", {"plane": plane, "query": q, "params": params}, tok)


def repair(plane, path, key, tok, apply=False):
    # 1. locate the orphaned Project node by a property, not by key
    res = cypher(plane, "MATCH (p:Project) RETURN p", {}, tok)
    olds = [n for n in res.get("nodes", []) if (n.get("properties") or {}).get("path") == path]
    if len(olds) != 1:
        raise SystemExit(f"expected exactly 1 Project with path={path}, found {len(olds)}")
    old = olds[0]
    old_id, props = old["id"], dict(old.get("properties") or {})

    # 2. capture what hangs off it, by key, before touching anything
    facts = [n.get("external_key") for n in cypher(plane,
        "MATCH (p:Project)<-[:ABOUT]-(f:Fact) WHERE p.path = $path RETURN f",
        {"path": path}, tok).get("nodes", []) if n.get("external_key")]
    sessions = [n.get("external_key") for n in cypher(plane,
        "MATCH (p:Project)<-[:BELONGS_TO]-(s:Session) WHERE p.path = $path RETURN s",
        {"path": path}, tok).get("nodes", []) if n.get("external_key")]

    plan = {"plane": plane, "key": key, "old_id": old_id, "props": props,
            "about_edges": facts, "belongs_to_edges": sessions}
    print(json.dumps(plan, ensure_ascii=False, indent=1))
    if not apply:
        print("(dry run — pass --apply to execute)")
        return plan

    # 3. delete the orphan first. Creating first and deleting after risks the
    #    delete taking the freshly-written index entry down with it — the very
    #    failure this whole repair exists to undo.
    u.rpc("node.delete", {"plane": plane, "id": old_id}, tok)
    if u.rpc("node.get", {"plane": plane, "key": key}, tok):
        raise SystemExit("key still resolves after deleting the orphan — stop and look")

    # 4. recreate under the key, then relink
    new = u.rpc("node.create", {"plane": plane, "key": key,
                                "labels": ["Project"], "properties": props}, tok)
    for fk in facts:
        u.rpc("edge.create", {"plane": plane, "src": fk, "dst": key, "type": "ABOUT"}, tok)
    for sk in sessions:
        u.rpc("edge.create", {"plane": plane, "src": sk, "dst": key, "type": "BELONGS_TO"}, tok)
    print(f"recreated {key} as id={new.get('id')}, "
          f"relinked {len(facts)} ABOUT + {len(sessions)} BELONGS_TO")
    return plan


def verify(plane, path, key, tok, want_facts):
    got_key = len(cypher(plane,
        "MATCH (p:Project)<-[:ABOUT]-(f:Fact) WHERE key(p) = $k RETURN f",
        {"k": key}, tok).get("nodes", []))
    got_path = len(cypher(plane,
        "MATCH (p:Project)<-[:ABOUT]-(f:Fact) WHERE p.path = $p RETURN f",
        {"p": path}, tok).get("nodes", []))
    n = u.rpc("node.get", {"plane": plane, "key": key}, tok)
    projects = len([x for x in cypher(plane, "MATCH (p:Project) RETURN p", {}, tok).get("nodes", [])
                    if (x.get("properties") or {}).get("path") == path])
    ok = (got_key == want_facts and got_path == want_facts and n and projects == 1)
    print(f"verify: key()={got_key} path()={got_path} want={want_facts} "
          f"node.get={'ok' if n else 'MISSING'} project_nodes={projects} -> {'PASS' if ok else 'FAIL'}")
    return ok


if __name__ == "__main__":
    plane, path, key = sys.argv[1], sys.argv[2], sys.argv[3]
    apply = "--apply" in sys.argv
    u.load_env(PROJECT_DIR)
    tok = os.environ.get("DRSG_TOKEN", "")
    plan = repair(plane, path, key, tok, apply)
    if apply:
        verify(plane, path, key, tok, len(plan["about_edges"]))

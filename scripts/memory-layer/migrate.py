#!/usr/bin/env python3
"""Migrate a project's memory from one drsg daemon/plane to another.

Designed for the "join the shared 7700 daemon" flow: read all nodes+edges of a
project's memory plane from one daemon, write them into the shared plane on
another daemon, WITHOUT touching anything already there.

Two subcommands (run separately so each phase is verifiable):

  dump  — read src plane fully (graph.seed) and write {nodes, edges} JSON.
          Edges' internal node ids are resolved to external keys so the dump
          is portable between daemons. Read-only on the source.
  load  — write a dump into a dst plane. Per-node existence check via node.get
          (never silently squats an existing key — the key-collision incident
          this guard exists for); edges created by key. Never deletes on dst.

Usage:
  migrate.py dump --api http://127.0.0.1:7701/rpc --token T --plane memory \
                  --out data-safe-memory.json
  migrate.py load --api http://127.0.0.1:7700/rpc --token T --plane memory \
                  --in data-safe-memory.json [--dry-run]
"""
import argparse
import json
import sys
import urllib.request


def rpc(api, token, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = json.load(r)
    if "error" in resp:
        raise RuntimeError("%s: %s" % (method, resp["error"]))
    return resp.get("result")


def cmd_dump(args):
    res = rpc(args.api, args.token, "graph.seed",
              {"plane": args.plane, "limit": 100000})
    nodes, edges = res["nodes"], res["edges"]

    # Resolve edge endpoints (internal ids) to external keys.
    id2key = {n["id"]: n.get("external_key") for n in nodes}
    dump_edges = []
    dropped = 0
    for e in edges:
        sk, dk = id2key.get(e["src"]), id2key.get(e["dst"])
        if sk is None or dk is None:
            dropped += 1  # endpoint without an external key — not portable
            continue
        dump_edges.append({"src_key": sk, "dst_key": dk, "type": e["type"],
                           "properties": e.get("properties", {})})

    # Nodes without an external key can't be created/deduplicated by key.
    keyed = [n for n in nodes if n.get("external_key")]
    unkeyed = [n for n in nodes if not n.get("external_key")]
    for n in unkeyed:
        print("WARN: skipping node without external_key: labels=%s props=%s"
              % (n.get("labels"), list(n.get("properties", {}).keys())),
              file=sys.stderr)

    out = {"source": {"api": args.api, "plane": args.plane},
           "nodes": [{"key": n["external_key"], "labels": n.get("labels", []),
                      "properties": n.get("properties", {})} for n in keyed],
           "edges": dump_edges}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print("dumped %d nodes (%d unkeyed skipped), %d edges (%d dropped) → %s"
          % (len(keyed), len(unkeyed), len(dump_edges), dropped, args.out))
    if not keyed:
        sys.exit("nothing to migrate")
    print("node keys:", sorted(n["key"] for n in out["nodes"]))


def cmd_load(args):
    with open(args.input, encoding="utf-8") as f:
        dump = json.load(f)
    nodes, edges = dump["nodes"], dump["edges"]

    created = skipped = failed = 0
    for n in nodes:
        try:
            existing = rpc(args.api, args.token, "node.get",
                           {"plane": args.plane, "key": n["key"]})
        except RuntimeError as e:
            print("  WARN node.get %s: %s" % (n["key"], e), file=sys.stderr)
            existing = None
        if existing and existing.get("id") is not None:
            skipped += 1  # key already owned on dst — never squat it
            continue
        if args.dry_run:
            print("  would create %s" % n["key"])
            continue
        try:
            rpc(args.api, args.token, "node.create",
                {"plane": args.plane, "key": n["key"], "labels": n["labels"],
                 "properties": n["properties"]})
            created += 1
        except RuntimeError as e:
            failed += 1
            print("  FAIL create %s: %s" % (n["key"], e), file=sys.stderr)

    # Second pass: edges (endpoints must now exist as keys on dst).
    edges_created = edges_skipped = edges_failed = 0
    for e in edges:
        if args.dry_run:
            print("  would create edge %s -[%s]-> %s"
                  % (e["src_key"], e["type"], e["dst_key"]))
            continue
        try:
            rpc(args.api, args.token, "edge.create",
                {"plane": args.plane, "src": e["src_key"], "dst": e["dst_key"],
                 "type": e["type"], "properties": e["properties"]})
            edges_created += 1
        except RuntimeError as err:
            msg = str(err)
            if "already" in msg.lower() or "duplicate" in msg.lower():
                edges_skipped += 1
            else:
                edges_failed += 1
                print("  FAIL edge %s -[%s]-> %s: %s"
                      % (e["src_key"], e["type"], e["dst_key"], err),
                      file=sys.stderr)

    verb = "would" if args.dry_run else "did"
    print("%s %s: nodes created=%d skipped=%d failed=%d; edges created=%d "
          "skipped=%d failed=%d" % (verb, args.plane, created, skipped, failed,
                                    edges_created, edges_skipped, edges_failed))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("dump")
    d.add_argument("--api", required=True, help="source RPC base URL")
    d.add_argument("--token", required=True)
    d.add_argument("--plane", default="memory")
    d.add_argument("--out", required=True, help="output JSON file")
    d.set_defaults(func=cmd_dump)

    l = sub.add_parser("load")
    l.add_argument("--api", required=True, help="destination RPC base URL")
    l.add_argument("--token", required=True)
    l.add_argument("--plane", default="memory")
    l.add_argument("--in", dest="input", required=True, help="dump JSON file")
    l.add_argument("--dry-run", action="store_true")
    l.set_defaults(func=cmd_load)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

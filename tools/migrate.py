#!/usr/bin/env python3
"""Migrate a project's memory from one drsg daemon/plane to another.

Designed for the "join the shared 7700 daemon" flow: read all nodes+edges of a
project's memory plane from one daemon, write them into the shared plane on
another daemon, WITHOUT touching anything already there.

Two subcommands (run separately so each phase is verifiable):

  dump  — read src plane fully (graph.seed) and write {nodes, edges} JSON.
          Edges' internal node ids are resolved to external keys so the dump
          is portable between daemons. Read-only on the source.
  load  — write a dump into a dst plane. Reads the dst plane once (graph.seed)
          before writing and skips node keys and edges already there
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


# urllib sends even 127.0.0.1 through http_proxy unless no_proxy names it, and
# a proxy that cannot reach this machine's loopback fails every call.
_DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _urlopen(req, timeout):
    """urlopen that never proxies a loopback address."""
    host = urllib.parse.urlsplit(req.full_url).hostname or ""
    if host in ("localhost", "::1") or host.startswith("127."):
        return _DIRECT.open(req, timeout=timeout)
    return urllib.request.urlopen(req, timeout=timeout)


def rpc(api, token, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with _urlopen(req, 30) as r:
        resp = json.load(r)
    if "error" in resp:
        raise RuntimeError("%s: %s" % (method, resp["error"]))
    return resp.get("result")


def edge_signature(src_key, dst_key, edge_type, properties):
    props = json.dumps(properties or {}, sort_keys=True, ensure_ascii=False,
                        separators=(",", ":"))
    return src_key, dst_key, edge_type, props


def keyed_edges(seed):
    id2key = {n["id"]: n.get("external_key") for n in seed.get("nodes", [])}
    found = set()
    for edge in seed.get("edges", []):
        src_key = id2key.get(edge.get("src"))
        dst_key = id2key.get(edge.get("dst"))
        if src_key is not None and dst_key is not None:
            found.add(edge_signature(src_key, dst_key, edge.get("type"),
                                     edge.get("properties", {})))
    return found


def cmd_dump(args):
    res = rpc(args.api, args.token, "graph.seed",
              {"plane": args.plane, "limit": args.limit})
    if res.get("truncated"):
        print("graph.seed truncated: source plane exceeds the limit; increase --limit",
              file=sys.stderr)
        return 3
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
        print("nothing to migrate", file=sys.stderr)
        return 1
    print("node keys:", sorted(n["key"] for n in out["nodes"]))
    return 0


def cmd_load(args):
    with open(args.input, encoding="utf-8") as f:
        dump = json.load(f)
    nodes, edges = dump["nodes"], dump["edges"]

    # Read the target before writing anything: a partial seed is unsafe both
    # for deciding which edges already exist and for node-key ownership.
    target = rpc(args.api, args.token, "graph.seed",
                 {"plane": args.plane, "limit": args.limit})
    if target.get("truncated"):
        print("graph.seed truncated: target plane exceeds the limit; increase --limit",
              file=sys.stderr)
        return 3
    existing_nodes = {n.get("external_key") for n in target.get("nodes", [])
                      if n.get("external_key")}
    edge_set = keyed_edges(target)

    nodes_created = nodes_skipped = nodes_failed = 0
    for node in nodes:
        key = node["key"]
        if key in existing_nodes:
            nodes_skipped += 1
            continue
        if args.dry_run:
            nodes_created += 1
            existing_nodes.add(key)
            print("  would create %s" % key)
            continue
        try:
            rpc(args.api, args.token, "node.create",
                {"plane": args.plane, "key": key, "labels": node["labels"],
                 "properties": node["properties"]})
            nodes_created += 1
            existing_nodes.add(key)
        except RuntimeError as error:
            nodes_failed += 1
            print("  FAIL create %s: %s" % (key, error), file=sys.stderr)

    edges_created = edges_skipped = edges_failed = 0
    for edge in edges:
        src_key, dst_key = edge["src_key"], edge["dst_key"]
        signature = edge_signature(src_key, dst_key, edge["type"],
                                   edge.get("properties", {}))
        if signature in edge_set:
            edges_skipped += 1
            continue
        if args.dry_run:
            edges_created += 1
            edge_set.add(signature)
            print("  would create edge %s -[%s]-> %s"
                  % (src_key, edge["type"], dst_key))
            continue
        try:
            rpc(args.api, args.token, "edge.create",
                {"plane": args.plane, "src": src_key, "dst": dst_key,
                 "type": edge["type"], "properties": edge.get("properties", {})})
            edges_created += 1
            edge_set.add(signature)
        except RuntimeError as error:
            edges_failed += 1
            print("  FAIL edge %s -[%s]-> %s: %s" %
                  (src_key, edge["type"], dst_key, error), file=sys.stderr)

    if args.dry_run:
        print("would %s: would create %d nodes / would skip %d; "
              "would create %d edges / would skip %d" %
              (args.plane, nodes_created, nodes_skipped,
               edges_created, edges_skipped))
        return 0

    verification = rpc(args.api, args.token, "graph.seed",
                       {"plane": args.plane, "limit": args.limit})
    if verification.get("truncated"):
        print("verify: target seed truncated -> FAIL")
        print("verify: nodes 0/%d edges 0/%d -> FAIL" %
              (len({n["key"] for n in nodes}), len({
                  edge_signature(e["src_key"], e["dst_key"], e["type"],
                                 e.get("properties", {})) for e in edges})))
        return 1

    target_keys = {n.get("external_key") for n in verification.get("nodes", [])
                   if n.get("external_key")}
    required_nodes = {n["key"] for n in nodes}
    present_nodes = required_nodes & target_keys
    verified_edges = keyed_edges(verification)
    required_edges = {edge_signature(e["src_key"], e["dst_key"], e["type"],
                                     e.get("properties", {})) for e in edges}
    present_edges = required_edges & verified_edges
    missing_nodes = sorted(required_nodes - present_nodes)
    missing_edges = sorted(required_edges - present_edges)
    for key in missing_nodes:
        print("verify missing node: %s" % key, file=sys.stderr)
    for src_key, dst_key, edge_type, properties in missing_edges:
        print("verify missing edge: %s -[%s]-> %s properties=%s" %
              (src_key, edge_type, dst_key, properties), file=sys.stderr)

    verified = not missing_nodes and not missing_edges
    print("verify: nodes %d/%d edges %d/%d -> %s" %
          (len(present_nodes), len(required_nodes), len(present_edges),
           len(required_edges), "PASS" if verified else "FAIL"))
    print("did %s: nodes created=%d skipped=%d failed=%d; edges created=%d "
          "skipped=%d failed=%d" %
          (args.plane, nodes_created, nodes_skipped, nodes_failed,
           edges_created, edges_skipped, edges_failed))
    return 0 if verified and not nodes_failed and not edges_failed else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("dump")
    d.add_argument("--api", required=True, help="source RPC base URL")
    d.add_argument("--token", required=True)
    d.add_argument("--plane", default="memory")
    d.add_argument("--limit", type=int, default=100000,
                   help="graph.seed node limit (default 100000)")
    d.add_argument("--out", required=True, help="output JSON file")
    d.set_defaults(func=cmd_dump)

    l = sub.add_parser("load")
    l.add_argument("--api", required=True, help="destination RPC base URL")
    l.add_argument("--token", required=True)
    l.add_argument("--plane", default="memory")
    l.add_argument("--limit", type=int, default=100000,
                   help="graph.seed node limit (default 100000)")
    l.add_argument("--in", dest="input", required=True, help="dump JSON file")
    l.add_argument("--dry-run", action="store_true")
    l.set_defaults(func=cmd_load)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

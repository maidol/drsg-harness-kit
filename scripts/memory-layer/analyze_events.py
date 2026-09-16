#!/usr/bin/env python3
"""Are cross-agent to-dos carrying code-graph addresses, and do those hold up?

Four things this reads, and one it deliberately does not.

Reads, from the `memory` plane: how many to-dos carry `symbols` at all, how
many of those the sender got to verify, which verb they name, and which plane
they point into. Reads, from disk: the addresses that were REFUSED before
anything was written — those leave no node by design, so the graph cannot be
asked about them and the sender-side `.drsg/events_refused.jsonl` is the only
record. It lands with the SENDER, so this sweeps every install rather than one.

Does not read whether anyone then called the graph. That needs a suppression
arm (P3), and even that would only show the tools being invoked, not the answer
changing — the same limit `codegraph-usage.py` carries. Nothing printed below
is a usefulness rate. Say so whenever you quote one of these numbers.

The cypher subset has no projections or aggregates (`RETURN e.verb` is a syntax
error, `count()` likewise), so whole nodes come back and are folded here. That
is also why this is a script and not a query you can type: 100 Events came to
92,551 characters when this was written.

Usage:
  analyze_events.py [--since YYYY-MM-DD] [--verbose]

Config comes from the CWD's .drsg/env, like the hooks.
"""
import argparse
import json
import os
import sys
import time
import urllib.request
from collections import Counter

API = "http://127.0.0.1:7700/rpc"
PLANE = "memory"
REFUSED = "events_refused.jsonl"
FETCH_CAP = 500


def load_env(proj_dir):
    p = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def rpc(method, params, token):
    body = json.dumps({"jsonrpc": "2.0", "id": 1,
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(API, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=20) as r:
        res = json.load(r)
    if "result" not in res:
        raise RuntimeError((res.get("error") or {}).get("message") or res)
    return res["result"]


def prop(v):
    """Unwrap the daemon's described-property form ({$desc,$value})."""
    return v.get("$value") if isinstance(v, dict) and "$value" in v else v


def projects(token):
    res = rpc("plane.cypher", {"plane": PLANE,
                               "query": "MATCH (p:Project) RETURN p",
                               "params": {}}, token)
    out = []
    for n in res.get("nodes", []):
        path = prop((n.get("properties") or {}).get("path"))
        if path:
            out.append(path)
    return sorted(set(out))


def events(path, token):
    """Every to-do addressed to `path`, reduced to the fields this reports on.

    Reduced here rather than carried around: `summary` and `detail` are the
    bulk, and none of the four distributions needs them."""
    res = rpc("plane.cypher", {"plane": PLANE,
        "query": ("MATCH (p:Project)<-[:NOTIFY]-(e:Event) WHERE p.path = $path "
                  "RETURN e ORDER BY e.created_at DESC LIMIT %d" % FETCH_CAP),
        "params": {"path": path}}, token)
    out = []
    for n in res.get("nodes", []):
        pr = n.get("properties") or {}
        syms = prop(pr.get("symbols"))
        created = prop(pr.get("created_at"))
        out.append({
            "key": n.get("external_key", "?"),
            "to": os.path.basename(os.path.normpath(path)),
            "from": prop(pr.get("from_project")) or "?",
            "status": prop(pr.get("status")) or "?",
            "created_at": created if isinstance(created, int) else None,
            "symbols": syms if isinstance(syms, list) else
                       ([syms] if syms else []),
            "verified": prop(pr.get("symbols_verified")),
            "verb": prop(pr.get("verb")),
            "plane": prop(pr.get("plane")),
        })
    return out


def refusals(paths):
    """Refused addresses, swept from every install's sender-side log.

    A missing file is not a zero and not an error: it means that project has
    never refused one (or was installed before the log existed). Both are
    reported as "no log", because printing 0 for them would put a number where
    there is no observation."""
    rows, swept, missing = [], [], []
    for path in paths:
        p = os.path.join(path, ".drsg", REFUSED)
        if not os.path.exists(p):
            missing.append(path)
            continue
        swept.append(path)
        try:
            for line in open(p, encoding="utf-8"):
                line = line.strip()
                if line:
                    rows.append(json.loads(line))
        except Exception as e:
            print("  ! unreadable %s: %s" % (p, e), file=sys.stderr)
    return rows, swept, missing


def stamp(ts):
    return time.strftime("%Y-%m-%d %H:%M", time.localtime(ts)) if ts else "?"


def histogram(counter, width=40):
    if not counter:
        return ["      (none)"]
    return ["      %-22s %4d" % (k if k is not None else "(unset)", v)
            for k, v in counter.most_common(width)]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--since", help="YYYY-MM-DD; default is when addresses "
                                    "first appeared")
    ap.add_argument("--verbose", action="store_true",
                    help="list the addressed to-dos and the refusals")
    args = ap.parse_args()

    load_env(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    globals()["API"] = os.environ.get("DRSG_API", API)
    globals()["PLANE"] = os.environ.get("DRSG_PLANE", PLANE)
    token = os.environ.get("DRSG_TOKEN", "")
    if not token:
        sys.exit("DRSG_TOKEN missing — run from a project with .drsg/env")

    paths = projects(token)
    evs = []
    for p in paths:
        evs.extend(events(p, token))
    refs, swept, missing = refusals(paths)

    # The window matters more than it looks. `symbols_verified` and the refusal
    # log both arrived with P2, so anything older cannot have carried an
    # address — counting it in the denominator would report a made-up dilution
    # of a feature that did not exist yet.
    if args.since:
        start = int(time.mktime(time.strptime(args.since, "%Y-%m-%d")))
        why = "given"
    else:
        marks = [e["created_at"] for e in evs
                 if e["verified"] is not None and e["created_at"]]
        marks += [r.get("ts") for r in refs if r.get("ts")]
        start = min(marks) if marks else None
        why = "first address-carrying to-do" if marks else "nothing to date"

    if start is None:
        print("No to-do has carried an address yet, and nothing has been "
              "refused. Nothing to measure — that is the honest reading, not "
              "a zero.")
        print("\nprojects known to the memory plane: %d" % len(paths))
        return

    evs = [e for e in evs if (e["created_at"] or 0) >= start]
    refs = [r for r in refs if (r.get("ts") or 0) >= start]
    addressed = [e for e in evs if e["symbols"]]

    print("== window   since %s  (%s), %.1f days"
          % (stamp(start), why, (time.time() - start) / 86400.0))
    print("== to-dos   %d project(s) in the memory plane, %d to-do(s) in window"
          % (len(paths), len(evs)))
    pct = (100.0 * len(addressed) / len(evs)) if evs else 0.0
    print("   carrying an address        %4d   (%.0f%% of %d)"
          % (len(addressed), pct, len(evs)))
    ver = Counter("verified" if e["verified"] else "UNVERIFIED"
                  for e in addressed)
    for k, v in ver.most_common():
        print("     %-24s %4d" % (k, v))
    if ver.get("UNVERIFIED"):
        print("     ^ the graph could not be consulted (plane unregistered, "
              "daemon down) — not a bad address")

    print("\n   verb        (the one to watch: impact staying in single "
          "digits means the old\n               habit moved from the question "
          "to the hand-off, not that it was fixed)")
    for ln in histogram(Counter(e["verb"] for e in addressed)):
        print(ln)
    print("   plane pointed into")
    for ln in histogram(Counter(e["plane"] for e in addressed)):
        print(ln)
    print("   recipient")
    for ln in histogram(Counter(e["to"] for e in addressed)):
        print(ln)

    print("\n== refused before posting   swept %d install(s), no log in %d"
          % (len(swept), len(missing)))
    print("   total                      %4d" % len(refs))
    why_counter, cand_sizes = Counter(), []
    for r in refs:
        for p in r.get("problems") or []:
            why_counter[p.get("why", "?")] += 1
            if p.get("why") == "ambiguous":
                cand_sizes.append(len(p.get("candidates") or []))
    for k, v in why_counter.most_common():
        print("     %-24s %4d" % (k, v))
    if cand_sizes:
        cand_sizes.sort()
        print("     ambiguous ones showed a median of %d candidate(s)"
              % cand_sizes[len(cand_sizes) // 2])
    print("   sender")
    for ln in histogram(Counter(r.get("from") for r in refs)):
        print(ln)

    attempts = len(addressed) + len(refs)
    if attempts:
        print("\n== addresses attempted in window   %d → %d posted, %d refused "
              "(%.0f%% refused)"
              % (attempts, len(addressed), len(refs),
                 100.0 * len(refs) / attempts))
        print("   A high `ambiguous` share is the signal that the "
              "rough-name-plus-auto-complete\n   premise does not hold, and "
              "that senders should `graph_describe` first.")

    if args.verbose:
        print("\n-- addressed to-dos")
        for e in sorted(addressed, key=lambda x: x["created_at"] or 0):
            print("   %s  %-18s %-8s %-8s %s" % (
                stamp(e["created_at"]), e["to"], e["status"],
                e["verb"] or "-", ", ".join(e["symbols"])))
        print("-- refusals")
        for r in sorted(refs, key=lambda x: x.get("ts") or 0):
            for p in r.get("problems") or []:
                print("   %s  %-18s %-10s %s" % (
                    stamp(r.get("ts")), r.get("to", "?").split("/")[-1],
                    p.get("why"), p.get("symbol")))

    print("\nWhat none of this shows: whether the recipient then called the "
          "graph, or whether\nthe answer changed because of it. That is P3, "
          "and P3 only reaches the first half.")


if __name__ == "__main__":
    main()

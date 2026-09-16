#!/usr/bin/env python3
"""Cross-agent coordination events in the memory plane.

A Fact is what an agent *learned*; an Event is what an agent wants another
agent to *do*. Both live in the memory plane, but they are read on different
paths, and deliberately so:

  * Facts go through the briefing and the per-prompt recall — ranked, lossy,
    compressed to ~18 chars. Right for knowledge, wrong for a task: a to-do
    that loses its ranking contest simply never arrives.
  * Events go through a small dedicated block at SessionStart that is bounded,
    uncompressed, and disappears the moment they are closed.

The recipient is the NOTIFY edge's target rather than a property: the graph
already models "who is this for", and the only question we ever ask is "what
is still open for this project?", which the edge answers directly.

A to-do can also carry a code-graph address — `--symbol` / `--verb`. That is
structure, not phrasing: a description written to *sound* like it wants a graph
call does not produce one (skills with an explicit must-invoke instruction fire
in 0.14% of turns here), whereas a symbol and a verb render into an imperative
line the recipient reads before touching any code.

Usage:
  event.py post <recipient-project-dir> <summary> [--kind handoff|notice] [--ref R]
                [--symbol KEY]... [--verb context|impact|trace]
  event.py list [<project-dir>]
  event.py done <event-key>

Config comes from the CWD's .drsg/env (DRSG_API / DRSG_PLANE / DRSG_TOKEN),
the same file the hooks read.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import sys
import time
import urllib.request

API = "http://127.0.0.1:7700/rpc"
PLANE = "memory"
# What a SessionStart is willing to look at. Kept here as well so `list` and
# the hook agree on how much is "too many to still be a to-do list".
LIST_CAP = 20

# The code-graph verbs an Event may point at, and how many symbols each needs.
# Deliberately not the whole tool surface: a to-do says where to start looking,
# and `context` / `impact` / `trace` are the three that answer "what is this",
# "what does changing it break" and "how does A reach B".
VERBS = {"context": (1, 3), "impact": (1, 3), "trace": (2, 2)}
MAX_SYMBOLS = 3
# Same registry codegraph-router.py reads. Only consulted to name the plane;
# a repository missing from it still gets an Event, just without the hint's
# parenthetical.
GRAPHS = os.environ.get("DRSG_GRAPHS") or os.path.expanduser(
    "~/.drsg-memory/graphs")
# How many candidates a rejection quotes back. The graph caps its own list at
# 20 and does not rank it, so quoting all of them invites picking from what
# happens to be visible — the failure that once turned `plugin` into a wrapper
# in the CLI instead of the loader in dr-strange-llm.
CANDIDATE_CAP = 8


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
    req = urllib.request.Request(
        API, data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=5) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def project_id(path, token):
    """The Project node for `path`, by property — never by key.

    Same reason as the hooks: digest.run has written a second node under an
    existing project's key, and every key-filtered read then silently returns
    nothing while the data sits untouched."""
    res = rpc("plane.cypher", {"plane": PLANE,
                               "query": "MATCH (p:Project) RETURN p",
                               "params": {}}, token)
    for n in res.get("nodes", []):
        if (n.get("properties") or {}).get("path") == path:
            return n.get("id")
    return None


def fetch(path, token):
    """Every Event addressed to `path`, newest first. Status is filtered by
    the caller: one predicate on the pattern's first variable is the shape
    every other query in this layer uses and is known to work."""
    res = rpc("plane.cypher", {"plane": PLANE,
        "query": ("MATCH (p:Project)<-[:NOTIFY]-(e:Event) "
                  "WHERE p.path = $path "
                  "RETURN e ORDER BY e.created_at DESC LIMIT %d") % LIST_CAP,
        "params": {"path": path}}, token)
    return res.get("nodes", [])


def plane_for(path):
    """The plane a repository answers on, or "" if it has no graph.

    Only a repository in the registry gets a name, and the name is the one
    codegraph.sh would use (`PLANE=$(basename "$REPO")`, overridable per line),
    so a to-do and the router cannot disagree about one repo.

    Unregistered means "" rather than the basename on purpose: a guessed plane
    name is not a weaker address, it is a wrong one — it sends the recipient to
    `not found: plane`, which reads exactly like a graph that is simply
    missing the symbol."""
    if not path:
        return ""
    path = os.path.abspath(os.path.normpath(path))
    try:
        with open(GRAPHS, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return ""
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split("\t")
        if os.path.abspath(os.path.expanduser(parts[0].strip())) == path:
            if len(parts) > 1 and parts[1].strip():
                return parts[1].strip()
            return os.path.basename(path)
    return ""


def resolve_plane(target, from_path):
    """Which plane the symbols live in, when the sender did not say.

    Usually the recipient's — you hand someone work about their own code. But
    the other direction is just as common here (a repo reporting back to the
    review hub, whose symbols are the repo's), and the hub has no graph of its
    own, so falling back to the sender covers it. Both candidates are real
    registered planes; neither is invented.

    When the symbols belong to neither, the sender passes `plane` — the rule
    above is a default, and the field is what makes it correctable."""
    return plane_for(target) or plane_for(from_path)


def check_symbols(symbols, verb):
    """Reject the two ways this field gets misused, before anything is written.

    A symbol with a space in it is prose — every language the plugins model
    produces keys without spaces (`dr_strange_llm::preprocess::Plugins::load`,
    `github.com/acme/store/internal/vault.FileService.Encrypt`) — and
    prose here means the sender put the description in the wrong field, where
    the recipient's graph call will simply miss.

    Arity is checked because `trace` without both ends is not a weaker trace,
    it is not a call at all."""
    syms = [s.strip() for s in (symbols or []) if s and s.strip()]
    if not syms:
        return [], None
    if len(syms) > MAX_SYMBOLS:
        raise ValueError("at most %d symbols — a to-do pointing at more than "
                         "that is not an address, it is a survey"
                         % MAX_SYMBOLS)
    for s in syms:
        if " " in s:
            raise ValueError("%r is not a symbol key (it has a space) — put "
                             "descriptive text in `summary`; this field is the "
                             "address the recipient's graph call uses" % s)
    verb = (verb or "context").strip()
    if verb not in VERBS:
        raise ValueError("verb must be one of %s" % ", ".join(sorted(VERBS)))
    lo, hi = VERBS[verb]
    if not lo <= len(syms) <= hi:
        raise ValueError("%s takes %s symbol(s), got %d"
                         % (verb, lo if lo == hi else "%d-%d" % (lo, hi),
                            len(syms)))
    return syms, verb


class AddressRejected(ValueError):
    """The graph had an opinion about a symbol and it was no.

    A ValueError so every existing caller keeps handling it as the operator
    error it is; the `problems` list rides along for the telemetry, which wants
    structure rather than the sentence assembled for a human."""

    def __init__(self, message, problems):
        super().__init__(message)
        self.problems = problems


def telemetry(proj_dir, record):
    """Append one JSON line to .drsg/events_refused.jsonl.

    A refusal writes no node — correctly, since nothing was posted — and the
    consequence is that "how often does a rough name miss" is unmeasurable
    from the graph. Without this line, seeing no refusals and there being no
    refusals look the same.

    Best-effort and silent, like the recall telemetry it copies: the refusal
    has already been decided by the time this runs, and a coordination channel
    must not fail because a log file could not be opened."""
    try:
        d = os.path.join(proj_dir, ".drsg")
        os.makedirs(d, exist_ok=True)
        record["ts"] = int(time.time())
        with open(os.path.join(d, "events_refused.jsonl"), "a",
                  encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _router():
    """codegraph-router.py, wherever this copy of the tooling lives.

    Same two-place search the router itself does for codegraph.sh, plus the
    repository layout where the router sits one directory up. Importing it is
    free — it guards its own `main()` — and reusing it means one implementation
    of the MCP transport, the registry and the lazy daemon start rather than a
    second one drifting quietly out of step."""
    here = os.path.dirname(os.path.abspath(__file__))
    for d in (here, os.path.dirname(here),
              os.path.expanduser("~/.drsg-memory/tools")):
        path = os.path.join(d, "codegraph-router.py")
        if os.path.exists(path):
            spec = importlib.util.spec_from_file_location(
                "codegraph_router", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    return None


def _entry_for_plane(router, plane):
    for e in router.load_registry():
        if e["plane"] == plane:
            return e
    return None


def _classify(text, symbol):
    """Read `describe`'s answer. -> (canonical_key, candidates, missing).

    The graph answers in three shapes and only one of them is an address:
    a definition line `KEY  Kind  path:line`, an ambiguity listing candidates,
    or `no symbol matches`. Parsing text is not lovely, but the verbs live only
    in the MCP layer — there is no structured surface underneath to ask
    instead (`/rpc` has 36 methods and none of them is `describe`)."""
    lines = [ln for ln in text.splitlines() if ln.strip()]
    # The router prefixes every answer with `# <repo> · plane <plane>`.
    lines = [ln for ln in lines if not ln.startswith("# ")]
    if not lines:
        return None, [], True
    head = lines[0]
    if head.startswith("no symbol matches"):
        return None, [], True
    if "is ambiguous" in head and symbol in head:
        cands = [ln.split()[0] for ln in lines[1:] if ln.split()]
        # Real keys before `?::path::name` ones. Those are UnresolvedRef nodes
        # — where the parser gave up — so they are in the plane but are not
        # addresses anyone can act on, and letting them eat the cap hides the
        # candidates that are.
        cands.sort(key=lambda c: c.startswith("?::"))
        return None, cands[:CANDIDATE_CAP], False
    return head.split()[0], [], False


def verify_symbols(symbols, plane):
    """Resolve every symbol against the plane it claims to live in.

    The point of doing it HERE rather than leaving it to the recipient: the
    sender is the one who currently knows what it means, and a to-do whose
    address misses turns into `no symbol matches` in someone else's session —
    a sentence indistinguishable from the graph genuinely not modelling it.

    Returns `(canonical_symbols, unverified_reason)`. A reason means the graph
    could not be consulted at all (no such plane registered, daemon will not
    start, tooling absent); the to-do still goes out, because a coordination
    channel that fails closed on the graph's availability is worse than one
    that delivers an unchecked address and says so. A symbol the graph HAS an
    opinion about and rejects raises instead — that is not availability, that
    is a wrong address, and it is cheapest to fix now."""
    if not symbols:
        return symbols, None
    if not plane:
        return symbols, "no plane to check against"
    router = _router()
    if router is None:
        return symbols, "codegraph-router.py not installed"
    entry = _entry_for_plane(router, plane)
    if entry is None:
        return symbols, "plane %r is not in %s" % (plane, GRAPHS)

    canonical, problems = [], []
    for s in symbols:
        try:
            text, err = router.call_upstream(entry, "describe",
                                             {"name": s, "plane": plane})
        except Exception as e:                       # availability, not verdict
            return symbols, "%s: %s" % (type(e).__name__, e)
        if err:
            return symbols, text.strip().splitlines()[-1][:200]
        key, cands, missing = _classify(text, s)
        if key:
            canonical.append(key)
        elif missing:
            problems.append({"symbol": s, "why": "missing", "candidates": []})
        else:
            problems.append({"symbol": s, "why": "ambiguous",
                             "candidates": cands})
    if problems:
        raise AddressRejected(
            "the graph does not recognise this address, so nothing was "
            "posted:\n  " + "\n  ".join(_problem_line(p, plane)
                                        for p in problems)
            + "\nNarrow it (`Type::method` usually lands in one), or drop "
              "`symbols` and describe the work in `summary` — a to-do about "
              "code that does not exist yet has no address to give.",
            problems)
    return canonical, None


def _problem_line(p, plane):
    if p["why"] == "missing":
        return "%s — no symbol matches it in plane %s" % (p["symbol"], plane)
    return "%s — ambiguous in plane %s; candidates: %s" % (
        p["symbol"], plane, ", ".join(p["candidates"]) or "(none shown)")


def graph_hint(symbols, verb, plane, verified=True):
    """The imperative line the recipient sees, rendered from the fields.

    Rendered once here rather than in each hook: there are two renderers
    (SessionStart and UserPromptSubmit) and a to-do that says one thing on a
    fresh session and another on a resumed one is worse than no hint. The
    symbols and verb are stored alongside it, so the structure — not this
    string — is what P2's resolution and any later measurement read.

    Never folded into `summary`: both renderers hard-truncate that to 80
    characters, so a symbol key put there competes with the sentence and
    usually loses its tail, which is the half that identifies it."""
    if not symbols:
        return ""
    quoted = ["`%s`" % s for s in symbols]
    body = " → ".join(quoted) if verb == "trace" else ", ".join(quoted)
    where = " (plane %s)" % plane if plane else ""
    # An address the sender could not check is still worth sending, but the
    # recipient has to be told which kind it is holding: an unchecked one that
    # misses is indistinguishable from the graph not modelling the symbol.
    doubt = "" if verified else " — sender could not verify this address"
    return "↳ graph first: %s %s%s%s" % (verb, body, where, doubt)


def post(target, pid, summary, kind, ref, from_project, token,
         symbols=None, verb=None, plane=None, from_path=None):
    """Create the Event and its NOTIFY edge.

    Returns `{key, symbols, plane, hint, unverified}` — the outcome, not just
    the key, because both callers have to report what the recipient will
    actually see: symbols resolved to their canonical keys, and whether the
    graph got to confirm them. Raises on any step that did not change the
    graph. Shared with mcp_events.py so the CLI and the MCP tool cannot drift
    on what a well-formed to-do is."""
    symbols, verb = check_symbols(symbols, verb)
    unverified = None
    if symbols:
        # Before anything is written: a rejected address must leave no node
        # behind, or the sender fixes the message while a broken to-do sits in
        # the recipient's queue.
        plane = plane or resolve_plane(target, from_path)
        try:
            symbols, unverified = verify_symbols(symbols, plane)
        except AddressRejected as e:
            # Logged here rather than inside verify_symbols: this is where the
            # sender and recipient are known, and the verifier stays a pure
            # question about symbols.
            telemetry(from_path or os.getcwd(),
                      {"event": "refused", "to": target, "from": from_project,
                       "plane": plane, "verb": verb, "symbols": symbols,
                       "problems": e.problems})
            raise
    ts = int(time.time())
    h = hashlib.sha1(summary.encode("utf-8")).hexdigest()[:6]
    key = f"evt-{os.path.basename(target)}-{ts}-{h}"
    props = {"kind": kind, "status": "open", "summary": summary,
             "from_project": from_project,
             "from_session": os.environ.get("CLAUDE_SESSION_ID", ""),
             "created_at": ts}
    if ref:
        props["ref"] = ref
    if symbols:
        props["symbols"] = symbols
        props["verb"] = verb
        if plane:
            props["plane"] = plane
        # Recorded either way. "Checked and it resolves" and "could not check"
        # are different claims, and the recipient is entitled to know which one
        # it is holding — an unchecked address that misses looks exactly like a
        # gap in the graph.
        props["symbols_verified"] = not unverified
        props["graph_hint"] = graph_hint(symbols, verb, plane, not unverified)
    node = rpc("node.create", {"plane": PLANE, "key": key,
                               "labels": ["Event"], "properties": props}, token)
    if not (node or {}).get("id"):
        raise RuntimeError(f"node.create returned no record for {key} — "
                           f"nothing was posted")
    # By id, not key: a dangling key makes edge.create fail outright, and an
    # Event with no NOTIFY edge is invisible exactly like an unlinked Fact.
    edge = rpc("edge.create", {"plane": PLANE, "src": key, "dst": pid,
                               "type": "NOTIFY"}, token)
    if not edge:
        # Say which node is now stranded. An Event without its edge is not a
        # half-posted to-do, it is an invisible one: no read path walks it, so
        # the sender would otherwise believe the message was delivered.
        raise RuntimeError(f"{key} was created but its NOTIFY edge was not — "
                           f"the Event is unreachable; link or delete it "
                           f"before relying on it")
    return {"key": key, "symbols": symbols, "plane": plane,
            "hint": props.get("graph_hint", ""), "unverified": unverified}


def report(res, target):
    """What to print or hand back after a post. One wording for both callers."""
    out = ["posted %s to %s" % (res["key"], target)]
    if res.get("hint"):
        out.append(res["hint"])
        out.append("  (resolved against plane %s)" % res["plane"]
                   if not res["unverified"] else
                   "  ⚠ NOT checked against the graph: %s" % res["unverified"])
    return "\n".join(out)


def cmd_post(args, token):
    target = os.path.abspath(os.path.normpath(args.recipient))
    pid = project_id(target, token)
    if pid is None:
        sys.exit(f"no Project node with path {target} — has a session ever "
                 f"started there with the memory layer installed?")
    here = os.path.abspath(os.getcwd())
    print(report(post(target, pid, args.summary, args.kind, args.ref,
                      os.path.basename(here), token, symbols=args.symbol,
                      verb=args.verb, plane=args.plane, from_path=here),
                 target))


def receipt(pr):
    """How far a to-do actually got: posted → seen → done.

    `seen_at` is written by whichever hook puts the line on someone's terminal,
    so the *sending* project can tell "never delivered" from "delivered and
    ignored". `.drsg/events_seen.json` already knew this, but it is a file in
    the recipient's working copy — the one place the sender cannot look."""
    if pr.get("status") == "done":
        return "done"
    if not pr.get("seen_at"):
        return "unseen"
    age = int(time.time()) - int(pr["seen_at"])
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if age >= n:
            return "seen %d%s ago" % (age // n, unit)
    return "seen just now"


def cmd_list(args, token):
    path = os.path.abspath(os.path.normpath(args.project or os.getcwd()))
    for n in fetch(path, token):
        pr = n.get("properties", {})
        print("%-9s %-8s %-14s %s  %s" % (pr.get("status", "?"), pr.get("kind", "?"),
                                          receipt(pr), n.get("external_key", "?"),
                                          pr.get("summary", "")))
        # The sender's only view of what the recipient is actually shown.
        if pr.get("graph_hint"):
            print("%-9s %s" % ("", pr["graph_hint"]))


def close(key, token):
    """Close an Event, and report what the graph says rather than what the call
    did.

    The two are not the same thing, and the difference is the whole failure mode
    this guards. An unknown key already errors here (`node.update` resolves the
    key server-side), but two neighbouring paths do not:

      * a key can resolve to the *wrong* node — digest.run has twice written a
        second node under an existing key, and `node_by_key` then answers with
        the shadow;
      * closing by hand with `MATCH (e:Event) WHERE e.key = ...` matches nothing
        and still answers `props_set: 0` with no error (use `key(e)`).

    Both leave a to-do open while telling the operator it is closed, which is
    the one report a coordination channel must never get wrong. `node.update`
    hands back the stored record, so the confirmation is already paid for — it
    just has to be read.
    """
    node = rpc("node.update", {"plane": PLANE, "key": key,
                               "set": {"status": "done", "done_at": int(time.time())}},
               token) or {}
    labels = node.get("labels") or []
    status = (node.get("properties") or {}).get("status")
    if "Event" not in labels:
        raise RuntimeError(f"{key} is not an Event (labels: {labels or 'none'}) "
                           f"— a node was patched, but no to-do was closed")
    if status != "done":
        raise RuntimeError(f"{key} still reads status={status!r} after the "
                           f"update — nothing was closed")
    return f"{key} done"


def cmd_done(args, token):
    print(close(args.key, token))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("post", help="leave an event for another project")
    p.add_argument("recipient")
    p.add_argument("summary")
    p.add_argument("--kind", default="handoff", choices=["handoff", "notice"])
    p.add_argument("--ref", default="")
    p.add_argument("--symbol", action="append", default=[], metavar="KEY",
                   help="code-graph symbol key the recipient should start "
                        "from; repeatable, at most %d" % MAX_SYMBOLS)
    p.add_argument("--verb", default=None, choices=sorted(VERBS),
                   help="what to ask the graph (default context)")
    p.add_argument("--plane", default=None,
                   help="plane the symbols live in; defaults to the "
                        "recipient's, then to this project's")
    p.set_defaults(fn=cmd_post)

    p = sub.add_parser("list", help="events addressed to a project")
    p.add_argument("project", nargs="?")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("done", help="close an event by key")
    p.add_argument("key")
    p.set_defaults(fn=cmd_done)

    args = ap.parse_args()
    load_env(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
    global API, PLANE
    API = os.environ.get("DRSG_API", API)
    PLANE = os.environ.get("DRSG_PLANE", PLANE)
    token = os.environ.get("DRSG_TOKEN", "")
    if not token:
        sys.exit("DRSG_TOKEN missing — run from a project with .drsg/env")
    try:
        args.fn(args, token)
    except (RuntimeError, ValueError) as e:
        # A server-side rejection (unknown key, bad plane) or a malformed field
        # is an operator error, not a defect worth a traceback. Still non-zero.
        sys.exit(f"drsg: {e}")


if __name__ == "__main__":
    main()

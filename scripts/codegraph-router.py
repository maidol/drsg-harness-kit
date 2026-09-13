#!/usr/bin/env python3
"""One MCP server that reaches every repository's code graph.

A code graph is per-repository by construction: `serve watch` takes one `--dir`
and one `--plane`, the native backend lets exactly one process open a database,
and `--follow` replicates one-to-many rather than fanning in. So five repos mean
five daemons, and a project that wants to ask about another project's code has
nothing to ask. The review workspace — the one repository whose entire job is
reading other people's code — was the one with no graph reachable at all.

The verbs live only in the MCP layer (`/rpc` has 36 methods and none of them is
`context`, `impact`, `trace`, `snippet` or `grep`), so this proxies MCP to MCP
rather than reimplementing anything.

Why one router instead of registering all five `drsg-watch` servers:

  * a single daemon's `tools/list` measures 22 tools / ~24.5 kB ≈ 6.1k tokens.
    Five of those is ~30k tokens resident in every session, to reach graphs a
    given session usually does not touch. This surface is eight tools.
  * `plane` stops being the model's problem. Every call must name the plane, the
    default plane is an empty one named `startup`, and an empty plane answers
    `no symbol matches` in exactly the words a real miss uses. In one audit six
    of eight empty-handed calls were that mistake. Here the plane comes from the
    registry, so it cannot be typed wrong.

Deliberately NOT one `graph(verb=...)` tool, which would cost ~600 tokens: that
hides the verbs inside an enum. The verbs are already chosen badly — the first
month on this repository ran `context` 46 times, `impact` once and `trace` never
— and a name you cannot see is a name you will not reach for. Tool names are
part of recall.

Per-verb rules live in the schemas, not in prose somewhere upstream: a rule about
`depth` is read at the moment `depth` is being filled in, which is not where a
paragraph of CLAUDE.md 8000 tokens ago is read.

Registry: ~/.drsg-memory/graphs (override with $DRSG_GRAPHS), one repository per
line, optional TAB + plane when the plane is not the directory's own name.
Addresses and tokens are NOT stored here — they are read out of each repo's
`.mcp.json` at call time, the same file the MCP clients read. Copying a token
into a second place only creates a second place for it to rot and to leak.

Transport is stdio JSON-RPC, stdlib only, like the other memory-layer servers.
"""
import json
import os
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROTOCOL = "2025-06-18"
REGISTRY = os.environ.get("DRSG_GRAPHS") or os.path.expanduser(
    "~/.drsg-memory/graphs")
CALL_TIMEOUT = float(os.environ.get("DRSG_ROUTER_TIMEOUT", "60"))
START_TIMEOUT = 180.0

INSTRUCTIONS = (
    "Code graphs for several repositories behind one surface. Name the repo by "
    "its directory name; graph_repos lists them. The plane is filled in from "
    "the registry — you never pass one, and it can never be wrong.\n"
    "Quote the full symbol key the graph returns (`dr_strange_mcp::snippet_"
    "logic`, not a file:line): a key is evidence the graph was asked, a "
    "file:line is what grep prints too.\n"
    "Whatever the graph does not cover, say so — it is a plugin-fed plane, and "
    "cross-language edges are mostly absent. An empty answer is an answer; "
    "filling it in from impression is not."
)


# --------------------------------------------------------------------------
# registry
# --------------------------------------------------------------------------
def load_registry():
    """Read on every call, not once at startup.

    A router that cached this would keep answering "unknown repo" for the rest
    of the session after `codegraph.sh install` added one — and the model has no
    way to tell that from a repository that really has no graph."""
    out = []
    try:
        with open(REGISTRY, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return out
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split("\t")
        path = os.path.abspath(os.path.expanduser(parts[0].strip()))
        plane = parts[1].strip() if len(parts) > 1 and parts[1].strip() else None
        out.append({
            "path": path,
            "name": os.path.basename(path),
            # Matches codegraph.sh's default: PLANE=$(basename "$REPO").
            "plane": plane or os.path.basename(path),
        })
    return out


def resolve_repo(token):
    entries = load_registry()
    if not entries:
        raise ValueError(
            "the graph registry %s is empty or missing — add one repository "
            "path per line, or run `codegraph.sh install --dir <repo>`."
            % REGISTRY)
    if not token:
        raise ValueError("which repo? one of: %s"
                         % ", ".join(e["name"] for e in entries))
    want = token.strip().rstrip("/")
    for e in entries:
        if want in (e["path"], e["name"]):
            return e
    # Path spelled some other way (a symlink, a trailing component) still wins
    # over an error the caller cannot act on.
    full = os.path.abspath(os.path.expanduser(want))
    for e in entries:
        if full == e["path"]:
            return e
    raise ValueError("no graph registered for %r — known: %s"
                     % (token, ", ".join(e["name"] for e in entries)))


def endpoint(entry):
    """Address and token, from the repo's own .mcp.json.

    Same source codegraph.sh reads, and for the same reason: a token minted or
    copied anywhere else silently disagrees with every client config that
    `drsg init` wrote."""
    path = os.path.join(entry["path"], ".mcp.json")
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)["mcpServers"]["drsg-watch"]
        return cfg["url"], cfg["headers"]["Authorization"]
    except (OSError, KeyError, ValueError) as e:
        raise ValueError(
            "%s has no usable drsg-watch entry in .mcp.json (%s) — that repo "
            "has never been digested; run `codegraph.sh install --dir %s`."
            % (entry["name"], type(e).__name__, entry["path"]))


def is_listening(url):
    try:
        u = urllib.parse.urlparse(url)
        with socket.create_connection((u.hostname, u.port), timeout=0.4):
            return True
    except OSError:
        return False


# --------------------------------------------------------------------------
# upstream MCP (streamable HTTP + SSE)
# --------------------------------------------------------------------------
SESSIONS = {}


def _post(url, auth, body, session_id, timeout):
    headers = {
        "Authorization": auth,
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"), headers=headers)
    resp = urllib.request.urlopen(req, timeout=timeout)
    raw = resp.read().decode("utf-8", "replace")
    msg = None
    # The response is an SSE stream whose first `data:` line is empty; taking
    # the first one instead of the last parses as nothing at all.
    for line in raw.splitlines():
        if line.startswith("data:"):
            payload = line[5:].strip()
            if payload:
                msg = json.loads(payload)
    if msg is None and raw.strip():
        msg = json.loads(raw)
    return msg, resp.headers.get("Mcp-Session-Id")


def _handshake(url, auth):
    msg, sid = _post(url, auth, {
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": PROTOCOL, "capabilities": {},
                   "clientInfo": {"name": "codegraph-router",
                                  "version": "1.0.0"}},
    }, None, 15)
    if msg and msg.get("error"):
        raise ValueError("initialize refused: %s" % msg["error"].get("message"))
    if sid:
        _post(url, auth, {"jsonrpc": "2.0", "method": "notifications/initialized",
                          "params": {}}, sid, 10)
    SESSIONS[url] = sid
    return sid


def start_daemon(entry):
    """Lazily bring a repository's daemon up.

    The SessionStart guard only fires when someone opens a session in that
    repository, so a graph queried from elsewhere is routinely down — that is
    normal, not a fault. What must never happen is answering an empty result
    for it: one repository's graph ran empty for three days, and every session
    that hit it quietly degraded to grep."""
    script = os.path.join(HERE, "codegraph.sh")
    if not os.path.exists(script):
        script = os.path.expanduser("~/.drsg-memory/tools/codegraph.sh")
    if not os.path.exists(script):
        return "codegraph.sh not found next to the router (%s)" % HERE
    try:
        p = subprocess.run([script, "start", "--dir", entry["path"]],
                           capture_output=True, text=True, timeout=START_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "codegraph.sh start timed out after %ds" % START_TIMEOUT
    if p.returncode != 0:
        tail = (p.stderr or p.stdout or "").strip().splitlines()
        return tail[-1] if tail else "codegraph.sh start exited %d" % p.returncode
    return None


def call_upstream(entry, tool, args):
    url, auth = endpoint(entry)
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": tool, "arguments": args}}

    def attempt():
        sid = SESSIONS.get(url) or _handshake(url, auth)
        return _post(url, auth, body, sid, CALL_TIMEOUT)[0]

    try:
        msg = attempt()
    except urllib.error.HTTPError as e:
        # A daemon restart invalidates the session id we cached; one silent
        # re-handshake, then the error is real.
        if e.code in (400, 404):
            SESSIONS.pop(url, None)
            msg = attempt()
        else:
            raise ValueError("%s graph returned HTTP %d" % (entry["name"], e.code))
    except (urllib.error.URLError, OSError):
        SESSIONS.pop(url, None)
        why = start_daemon(entry)
        if why:
            raise ValueError(
                "%s's graph is not up and could not be started: %s  "
                "(nothing was queried — this is not an empty result)"
                % (entry["name"], why))
        msg = attempt()

    if msg is None:
        raise ValueError("%s graph sent no parseable response" % entry["name"])
    if msg.get("error"):
        raise ValueError("%s graph: %s"
                         % (entry["name"], msg["error"].get("message")))
    result = msg.get("result") or {}
    text = "\n".join(c.get("text", "") for c in result.get("content") or []
                     if c.get("type") == "text")
    return unwrap_json_string(text), bool(result.get("isError"))


def unwrap_json_string(text):
    """The verbs return their text serialised as a JSON string literal.

    So a 40-line `context` arrives as one line of `"...\\n...\\n..."`, which
    costs tokens for the escapes and is markedly harder to read than the thing
    it encodes. Decoding is loss-free and only ever applied when the payload
    really is a quoted string — anything else is passed through untouched."""
    if len(text) > 1 and text.startswith('"') and text.endswith('"'):
        try:
            decoded = json.loads(text)
        except ValueError:
            return text
        if isinstance(decoded, str):
            return decoded
    return text


# --------------------------------------------------------------------------
# tools
# --------------------------------------------------------------------------
REPO_ARG = {"type": "string", "description":
            "Repository directory name (or absolute path). graph_repos lists them."}

TOOLS = [
    {
        "name": "graph_repos",
        "description": (
            "Which repositories have a code graph here, which plane each one "
            "answers on, and whether its daemon is up right now. A daemon that "
            "is down is normal — it is started on first use, not skipped."),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "graph_describe_plane",
        "description": (
            "What a repository's graph actually contains: size, the labels it "
            "models, the edge types and what they connect, and the commit it "
            "is folded up to. The orientation call for a whole-repository "
            "question — the verbs all need a symbol name first, so a review "
            "with no starting symbol starts here. It is also the ONLY way to "
            "get counts: the cypher subset has no aggregates, so `count()` is "
            "a syntax error."),
        "inputSchema": {
            "type": "object",
            "properties": {"repo": REPO_ARG},
            "required": ["repo"],
        },
    },
    {
        "name": "graph_context",
        "description": (
            "A symbol's whole neighbourhood in one call: definition, signature, "
            "doc comment, callers with call sites, callees, containment. Start "
            "here for what-is / who-calls. It walks ONE hop — it cannot answer "
            "'what does changing this affect', which is graph_impact. Fuzzy "
            "name: exact key, `::name`/`.name` suffix, or substring; a "
            "descriptive phrase only matches if it is a substring of a real "
            "symbol name. Ambiguity returns candidates truncated to 20 and NOT "
            "ranked — with a long list, narrow the name and ask again rather "
            "than picking from what happens to be visible."),
        "inputSchema": {
            "type": "object",
            "properties": {"repo": REPO_ARG, "name": {
                "type": "string",
                "description": "Symbol name — `Type::method` usually resolves "
                               "in one call."}},
            "required": ["repo", "name"],
        },
    },
    {
        "name": "graph_impact",
        "description": (
            "Blast radius: everything that reaches this symbol through incoming "
            "structural edges, grouped by distance with a count per group. This "
            "is the only tool that answers 'what breaks if I change/delete/"
            "rename X' — a caller list from graph_context has no distance "
            "grouping, and offering one in its place is a visible substitution. "
            "It counts recorded edges only and says so in its own output; quote "
            "that lower-bound sentence along with any number you take from it. "
            "Finding nothing past distance 1 is itself the answer."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": REPO_ARG,
                "name": {"type": "string"},
                "depth": {"type": "integer", "description":
                          "Hops to walk (default 3, max 6). RAISE IT UNTIL A "
                          "LEVEL COMES BACK EMPTY: stopping at the default "
                          "yields 'the first three hops', which looks exactly "
                          "like a blast radius. Measured: one symbol reported "
                          "12 at depth 3 and 15 at depth 5, where level 5 was "
                          "empty. Two symbols measured at different depths are "
                          "not comparable."},
            },
            "required": ["repo", "name"],
        },
    },
    {
        "name": "graph_trace",
        "description": (
            "The shortest recorded CALLS path from one symbol to another, one "
            "hop per line; tries the reverse direction and says so. Quote the "
            "path hop by hop when claiming A reaches B. SINGLE REPOSITORY ONLY "
            "— planes are isolated and no cross-repository edges exist, so "
            "`from` and `to` must both live in `repo`."),
        "inputSchema": {
            "type": "object",
            "properties": {"repo": REPO_ARG,
                           "from": {"type": "string"},
                           "to": {"type": "string"}},
            "required": ["repo", "from", "to"],
        },
    },
    {
        "name": "graph_describe",
        "description": (
            "Where a symbol is defined and what its signature is. Use it on 2–10 "
            "ambiguous candidates before committing: a return type pointing into "
            "another crate marks a thin wrapper, and measuring the wrapper gives "
            "a strict subset of the real thing's blast radius."),
        "inputSchema": {
            "type": "object",
            "properties": {"repo": REPO_ARG, "name": {"type": "string"}},
            "required": ["repo", "name"],
        },
    },
    {
        "name": "graph_snippet",
        "description": "The source of a symbol, from the watched working tree.",
        "inputSchema": {
            "type": "object",
            "properties": {"repo": REPO_ARG, "name": {"type": "string"},
                           "lines": {"type": "integer", "description":
                                     "Max lines to return."}},
            "required": ["repo", "name"],
        },
    },
    {
        "name": "graph_grep",
        "description": (
            "Literal search over that repository's watched source tree — for "
            "what the graph does not model: log strings, `//` comments, .md / "
            ".sh / Justfile / CI files no plugin claims, and calls the parser "
            "left unresolved. Reach for it when the graph came back empty AND "
            "say that is what you did; do not let a graph miss turn into an "
            "answer from impression."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "repo": REPO_ARG,
                "pattern": {"type": "string"},
                "ignore_case": {"type": "boolean"},
                "max_results": {"type": "integer"},
            },
            "required": ["repo", "pattern"],
        },
    },
    {
        "name": "graph_cypher",
        "description": (
            "openCypher against that repository's plane, for questions no verb "
            "shapes — counts, label inventories, edge-type breakdowns. The "
            "plane is injected; do not name one in the query."),
        "inputSchema": {
            "type": "object",
            "properties": {"repo": REPO_ARG, "query": {"type": "string"},
                           "params": {"type": "object"}},
            "required": ["repo", "query"],
        },
    },
]

# router tool -> (upstream tool, argument mapping). `plane` is added by
# dispatch for every tool that takes one; upstream `grep` does not.
UPSTREAM = {
    "graph_describe_plane": ("describe_plane", [], True),
    "graph_context": ("context", ["name"], True),
    "graph_impact": ("impact", ["name", "depth"], True),
    "graph_trace": ("trace", ["from", "to"], True),
    "graph_describe": ("describe", ["name"], True),
    "graph_snippet": ("snippet", ["name", "lines"], True),
    "graph_grep": ("grep", ["pattern", "ignore_case", "max_results"], False),
    "graph_cypher": ("cypher", ["query", "params"], True),
}


def tool_repos():
    entries = load_registry()
    if not entries:
        return ("no repositories registered in %s — one path per line, or run "
                "`codegraph.sh install --dir <repo>`." % REGISTRY)
    rows = ["%-14s %-14s %-18s %s" % ("repo", "plane", "address", "path")]
    for e in entries:
        try:
            url, _ = endpoint(e)
            u = urllib.parse.urlparse(url)
            addr = "%s:%s" % (u.hostname, u.port)
            state = "" if is_listening(url) else "  (down — starts on first use)"
        except ValueError:
            addr, state = "-", "  (never digested)"
        rows.append("%-14s %-14s %-18s %s%s"
                    % (e["name"], e["plane"], addr, e["path"], state))
    return "\n".join(rows)


def call_tool(name, args):
    if name == "graph_repos":
        return tool_repos(), False
    if name not in UPSTREAM:
        raise ValueError("unknown tool %r" % name)

    tool, keys, wants_plane = UPSTREAM[name]
    entry = resolve_repo(args.get("repo"))
    payload = {k: args[k] for k in keys if args.get(k) is not None}
    if wants_plane:
        payload["plane"] = entry["plane"]

    text, err = call_upstream(entry, tool, payload)
    # Which graph answered, on the reply itself: a router makes it possible to
    # read one repository's answer as another's, and nothing downstream
    # would catch that.
    head = "# %s · plane %s" % (entry["name"], entry["plane"])
    return "%s\n%s" % (head, text if text.strip() else "(empty result)"), err


# --------------------------------------------------------------------------
# stdio JSON-RPC
# --------------------------------------------------------------------------
def respond(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    msg["error" if error else "result"] = error or result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        method, rid = req.get("method"), req.get("id")
        if rid is None:  # notification
            continue

        if method == "initialize":
            respond(rid, {
                "protocolVersion": (req.get("params") or {}).get(
                    "protocolVersion") or PROTOCOL,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "codegraph-router", "version": "1.0.0"},
                "instructions": INSTRUCTIONS,
            })
        elif method == "ping":
            respond(rid, {})
        elif method == "tools/list":
            respond(rid, {"tools": TOOLS})
        elif method == "tools/call":
            p = req.get("params") or {}
            try:
                text, err = call_tool(p.get("name"), p.get("arguments") or {})
            except Exception as e:
                # A refusal the model can read and act on, not a JSON-RPC error
                # it will only see as a broken tool.
                text, err = "%s: %s" % (type(e).__name__, e), True
            respond(rid, {"content": [{"type": "text", "text": text}],
                          "isError": err})
        else:
            respond(rid, error={"code": -32601,
                                "message": "unknown method %r" % method})


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Cross-agent to-dos as MCP tools — the memory layer's own stdio server.

Posting, listing and closing an `Event` were reachable only through a CLI and a
paragraph of hand-written cypher in every project's CLAUDE.md. An interface you
have to teach with documentation is not an interface: the model had to remember
that the recipient is matched on `p.path`, that the node and its `NOTIFY` edge
must be written in one statement, and that closing needs `key(e)` rather than
`e.key`. Every one of those has silently produced an invisible or unclosed
to-do at least once. Three tools state them once, here.

Deliberately NOT part of `drsg-mcp`. `Event`, `Project` and `NOTIFY` are memory
-layer conventions living on top of a soft-schema graph; the engine does not
know what a Fact is and should not learn what an Event is. Keeping this a
separate process is what lets the database stay a database.

Transport is stdio JSON-RPC, stdlib only, matching the hooks: one more
dependency in the coordination path is one more way for the path to be down
when it is needed.

Usage (install.sh registers this):
  mcp_events.py <project-dir>        # the project this session belongs to
"""
import json
import os
import sys
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
PROTOCOL = "2025-06-18"


def _load_event_module():
    """The CLI's implementation, imported rather than copied.

    `event.py` guards its `main()`, so importing it is free. Sharing the module
    is what keeps `event_done` here and `event.py done` from drifting into two
    different opinions about what "closed" means."""
    spec = importlib.util.spec_from_file_location(
        "drsg_event", os.path.join(HERE, "event.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ev = _load_event_module()

TOOLS = [
    {
        "name": "event_post",
        "description": (
            "Leave a to-do for an agent working in ANOTHER project. Use this "
            "instead of writing a Fact: Facts reach a session by winning a "
            "relevance ranking, so one that loses is never delivered, while an "
            "open Event is injected verbatim and also printed to the "
            "recipient's terminal. The recipient is addressed by its directory "
            "path; the node and its NOTIFY edge are written together, because "
            "an Event without that edge is unreachable by every read path."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "recipient": {"type": "string", "description":
                              "Absolute directory of the receiving project."},
                "summary": {"type": "string", "description":
                            "One line. The first 80 chars reach the terminal."},
                "kind": {"type": "string", "enum": ["handoff", "notice"],
                         "default": "handoff"},
                "ref": {"type": "string", "description":
                        "Optional pointer — a doc path, commit or issue."},
                "symbols": {
                    "type": "array", "items": {"type": "string"},
                    "description":
                        "Code-graph symbol KEYS the recipient should start "
                        "from — at most 3, e.g. "
                        "`dr_strange_llm::preprocess::Plugins::load`. Give "
                        "them whenever the work is about specific code: the "
                        "recipient is shown an imperative graph call instead "
                        "of a sentence that merely hints at one. Keys, not "
                        "prose — anything with a space in it is rejected, and "
                        "a file:line is not an address the graph can use. "
                        "NEVER put them in `summary`, which is truncated to "
                        "80 characters on the way to the terminal. Each key is "
                        "resolved against the recipient's graph before "
                        "anything is written: one that misses or is ambiguous "
                        "REFUSES the post and shows candidates, and one that "
                        "resolves is rewritten to its canonical full key. A "
                        "rough name is therefore fine — `Type::method` usually "
                        "lands in one."},
                "verb": {
                    "type": "string",
                    "enum": ["context", "impact", "trace"],
                    "description":
                        "What the recipient should ask (default context). "
                        "`impact` for what a change breaks — it is the only "
                        "one that groups by distance with counts; `trace` "
                        "needs exactly two symbols, from and to, in that "
                        "order."},
                "plane": {
                    "type": "string",
                    "description":
                        "Plane the symbols live in. Defaults to the "
                        "recipient's repository, then to this one — right for "
                        "work about the recipient's code, and for reporting "
                        "back about yours. Set it when the symbols are in "
                        "neither."},
            },
            "required": ["recipient", "summary"],
        },
    },
    {
        "name": "event_list",
        "description": (
            "To-dos addressed to a project, newest first, with how far each "
            "one got: unseen (posted, never rendered to anyone), seen <age> "
            "ago, or done. Defaults to this project and to open ones."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string", "description":
                            "Absolute directory. Defaults to this session's."},
                "status": {"type": "string", "enum": ["open", "done", "all"],
                           "default": "open"},
            },
        },
    },
    {
        "name": "event_done",
        "description": (
            "Close a to-do by its key, and verify it actually closed. Fails "
            "loudly if the key resolved to something that is not an Event or "
            "if the node did not change — closing by hand with `e.key` matches "
            "nothing, reports props_set: 0, and does not error."),
        "inputSchema": {
            "type": "object",
            "properties": {"key": {"type": "string"}},
            "required": ["key"],
        },
    },
]


def _project_dir():
    return os.path.abspath(os.path.normpath(
        (sys.argv[1] if len(sys.argv) > 1 else None)
        or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()))


def call_tool(name, args, token):
    proj = _project_dir()
    if name == "event_post":
        target = os.path.abspath(os.path.normpath(args["recipient"]))
        # Both of these are refusals, so they travel as tool errors: a message
        # saying nothing was posted is worthless if the call still reads as a
        # success — the same confusion this whole channel keeps being bitten by.
        if target == proj:
            # A to-do addressed to the sender is the one case the block cannot
            # help with: it arrives where the work already is.
            raise ValueError("%s is this project — an Event is for another "
                             "agent; write a Fact to remember something here."
                             % target)
        pid = ev.project_id(target, token)
        if pid is None:
            raise ValueError("no Project node with path %s — the memory layer "
                             "has never run a session there, so nothing can be "
                             "addressed to it yet." % target)
        # The reply echoes the rendered hint and whether the graph confirmed
        # the address: without it a symbol that resolved to something else —
        # or was never checked — reads exactly like a clean post.
        return ev.report(
            ev.post(target, pid, args["summary"],
                    args.get("kind") or "handoff", args.get("ref") or "",
                    os.path.basename(proj), token,
                    symbols=args.get("symbols"), verb=args.get("verb"),
                    plane=args.get("plane"), from_path=proj),
            target)

    if name == "event_list":
        path = os.path.abspath(os.path.normpath(args.get("project") or proj))
        want = args.get("status") or "open"
        rows = []
        for n in ev.fetch(path, token):
            pr = n.get("properties", {})
            if want != "all" and pr.get("status") != want:
                continue
            rows.append("%-6s %-8s %-14s %s  %s" % (
                pr.get("status", "?"), pr.get("kind", "?"), ev.receipt(pr),
                n.get("external_key", "?"), pr.get("summary", "")))
            # The sender's only view of the second line the recipient gets.
            if pr.get("graph_hint"):
                rows.append("%-6s %s" % ("", pr["graph_hint"]))
        return "\n".join(rows) if rows else "no %s events for %s" % (want, path)

    if name == "event_done":
        return ev.close(args["key"], token)

    raise ValueError("unknown tool %r" % name)


def respond(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    msg["error" if error else "result"] = error or result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    proj = _project_dir()
    ev.load_env(proj)
    ev.API = os.environ.get("DRSG_API", ev.API)
    ev.PLANE = os.environ.get("DRSG_PLANE", ev.PLANE)
    token = os.environ.get("DRSG_TOKEN", "")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        method, rid = req.get("method"), req.get("id")
        # Notifications carry no id and must not be answered.
        if rid is None:
            continue

        if method == "initialize":
            respond(rid, {
                # Echo the client's version when it names one: refusing to
                # speak a protocol we are compatible with just to advertise
                # our own is how a working server looks broken.
                "protocolVersion": (req.get("params") or {}).get(
                    "protocolVersion") or PROTOCOL,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "drsg-events", "version": "1.0.0"},
            })
        elif method == "ping":
            respond(rid, {})
        elif method == "tools/list":
            respond(rid, {"tools": TOOLS})
        elif method == "tools/call":
            p = req.get("params") or {}
            if not token:
                respond(rid, {"content": [{"type": "text", "text":
                        "DRSG_TOKEN missing — %s/.drsg/env was not readable"
                        % proj}], "isError": True})
                continue
            try:
                text = call_tool(p.get("name"), p.get("arguments") or {}, token)
                err = False
            except Exception as e:
                # Surfaced as tool output, not as a JSON-RPC error: the model
                # can read this one and fix its call.
                text, err = "%s: %s" % (type(e).__name__, e), True
            respond(rid, {"content": [{"type": "text", "text": text}],
                          "isError": err})
        else:
            respond(rid, error={"code": -32601,
                                "message": "unknown method %r" % method})


if __name__ == "__main__":
    main()

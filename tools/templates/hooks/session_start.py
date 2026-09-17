#!/usr/bin/env python3
"""SessionStart hook: record this session in dr-strange and inject the
project's compressed memory briefing into Claude's context.

Design (see tools/README.md):
  * Dr-strange native backend allows ONE process per database, so hooks never
    open the DB themselves — they talk to the shared `drsg serve` daemon over
    JSON-RPC (POST /rpc), never the CLI.
  * The API requires `Authorization: Bearer $DRSG_TOKEN` for native clients.
  * Any failure is a soft downgrade: if the daemon is down we emit a bare
    hook output (SessionStart stdout at exit 0 is injected as context, and a
    malformed JSON would break the session). We never block.
  * Memory growth vs context: the injected payload is a *briefing* — a rule
    -compressed, per-kind summary of the project's Facts stored in
    Project.briefing — not the full Fact list. The full Facts stay queryable
    via the MCP tools / per-prompt recall (user_prompt.py), so the constant
    startup cost stays ~one short paragraph no matter how many Facts exist.
  * The .drsg/env file (gitignored) holds DRSG_TOKEN/DRSG_API/DRSG_PLANE.
  * Runs on `startup|resume|compact`. A compaction drops the injected briefing
    and protocol out of context while the session continues, so they have to be
    re-injected; only the node bookkeeping differs (see `source == "compact"`).
"""
import json
import os
import socket
import sys
import time

# --- Configuration (overridable via .drsg/env) -----------------------------
# install.sh writes .drsg/env; values here are project-agnostic defaults that
# get re-read from os.environ after load_env in main().
API = "http://127.0.0.1:7700/rpc"
PLANE = "memory"
# How many Facts to consider when building the briefing. Far beyond current
# usage; the briefing itself is compressed regardless of this cap.
BRIEFING_FACT_CAP = 1000

# L2 write-memory protocol: injected with the briefing so the model
# automatically persists valuable conclusions without any user action.
#
# Every clause here is load-bearing on the READ side, and a Fact that violates
# one is not rejected — it is silently unreadable. `path` rather than `key`
# because that is how the readers (all_facts, project_id) address the Project,
# and a key can end up shadowed while path stays ours.
#
# `supersedes` / `valid_to` are written but NOT yet read: the recall and
# briefing filters that consume them are held until the pre-registered baseline
# in docs/memory-layer-observability.md reaches its phase-1 trigger (30 sessions
# in recall.jsonl), because changing the read path now resets that sample. Times
# are integer Unix seconds — every created_at in the plane already is, and an
# Int/Str comparison silently evaluates to false instead of erroring.
def protocol(slug, plane, path):
    return (
        f"[write-memory protocol] Persist this session's durable conclusions, "
        f"gotchas and decisions into the `{plane}` plane yourself (MCP tools "
        f"cypher / write_nodes / write_edges, plane=\"{plane}\"):\n"
        f"- one `Fact` node each, with an idempotent `external_key` (e.g. "
        f"fact-{slug}-<topic>), a `kind` you choose (setup-experience / "
        "decision / gotcha / workflow), `summary` as a ONE-LINE conclusion (only its "
        "first ~18 chars reach the briefing), `detail` for the rest, "
        "`created_at` as the current Unix time (integer seconds);\n"
        f"- linked with an `ABOUT` edge to the Project matched by "
        f"`p.path = \"{path}\"` (by path, not key; a Fact unreachable that "
        "way is invisible);\n"
        "- replacing an older Fact: set `supersedes`=<old key> on the new one "
        "and `valid_to`=<Unix time> on the old one; never edit or delete the "
        "old Fact."
    )


def rpc(method, params, token):
    """POST one JSON-RPC call to the local daemon over a bare socket.

    Not urllib: `import urllib.request` is ~45 ms of this hook's ~90 ms
    interpreter+import floor, because it pulls in http.client and, through
    it, email.parser — a MIME header parser, to read one Content-Type off a
    fixed loopback endpoint that needs no proxy, redirect, TLS or chunked
    decoding. Anything that is not plain http still goes through urllib,
    imported lazily so the common path never pays for it.

    Behaviour is deliberately unchanged: any failure raises (every caller
    wraps this in `except Exception` and degrades), and the timeout keeps
    urlopen's semantics — per socket operation, not a deadline for the call.
    """
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    scheme, _, rest = API.partition("://")
    hostport, _, path = rest.partition("/")
    if scheme != "http" or hostport.startswith("["):
        import urllib.request  # https, or an IPv6 literal: not the local daemon
        req = urllib.request.Request(
            API, data=body,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=3) as r:
            return json.load(r)["result"]
    host, _, port = hostport.partition(":")
    head = (
        f"POST /{path} HTTP/1.1\r\nHost: {hostport}\r\n"
        f"Content-Type: application/json\r\nAuthorization: Bearer {token}\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
    ).encode()
    with socket.create_connection((host, int(port or 80)), timeout=3) as s:
        s.sendall(head + body)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                raise OSError("drsg rpc: closed before headers")
            buf += chunk
        raw, _, payload = buf.partition(b"\r\n\r\n")
        lines = raw.decode("latin-1").split("\r\n")
        if lines[0].split(" ")[1:2] != ["200"]:
            raise OSError(f"drsg rpc: {lines[0]}")
        length = None
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "content-length":
                length = int(value.strip())
        while length is None or len(payload) < length:
            chunk = s.recv(65536)
            if not chunk:
                break
            payload += chunk
    return json.loads(payload)["result"]


def load_env(proj_dir):
    p = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def hook_out(system_message=None, **extra):
    # stdout must contain exactly one JSON object.
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart"}}
    out["hookSpecificOutput"].update(extra)
    # `systemMessage` is top-level, not hook-specific, and it is the only
    # channel that reaches the terminal: additionalContext goes to the model
    # alone. A to-do another project left here was therefore invisible to the
    # person who decides whether it gets done this session.
    if system_message:
        out["systemMessage"] = system_message
    print(json.dumps(out))


def telemetry(proj_dir, record):
    """Append one JSON line to .drsg/recall.jsonl. Same file and same silence
    as user_prompt.py's: one log, so a session's startup cost and its
    per-prompt recalls can be read on one timeline."""
    try:
        d = os.path.join(proj_dir, ".drsg")
        os.makedirs(d, exist_ok=True)
        record["ts"] = int(time.time())
        with open(os.path.join(d, "recall.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


def project_id(proj_dir, token):
    """The Project node for this working directory, addressed by `path`.

    Not by `key(p)`: digest.write bypasses the uniqueness check that
    node.create enforces, so a distillation run can write a second node under
    an existing key and shadow the real one — and deleting that shadow does not
    hand the key back, it just leaves it resolving to nothing. Either way every
    key-filtered read silently returns empty while the data is untouched.
    That has happened, and it took the whole briefing out with it.
    `path` is ours, written here at line ~1 of every session, and no distiller
    invents it. Returns the node id, or None when this project is new."""
    res = rpc("plane.cypher", {"plane": PLANE,
        "query": "MATCH (p:Project) RETURN p", "params": {}}, token)
    for n in res.get("nodes", []):
        if (n.get("properties") or {}).get("path") == proj_dir:
            return n.get("id")
    return None


def all_facts(proj_dir, token):
    """All Facts ABOUT this project, newest first."""
    res = rpc("plane.cypher", {"plane": PLANE,
        "query": ("MATCH (p:Project)<-[:ABOUT]-(f:Fact) "
                  "WHERE p.path = $path "
                  "RETURN f ORDER BY f.created_at DESC LIMIT %d") % BRIEFING_FACT_CAP,
        "params": {"path": proj_dir}}, token)
    return res.get("nodes", [])


def open_events(proj_dir, token, limit=3):
    """Coordination events addressed to this project and still open.

    A hard-bounded block, unlike the briefing: an Event is a to-do, and a
    to-do compressed to 18 chars or losing a ranking contest is worse than
    absent. Costs nothing when there are none — the caller only appends the
    block if this returns something, same rule as Recent sessions.

    `status` is filtered here rather than in the WHERE clause: the volume is a
    handful of nodes, and one predicate on the pattern's first variable is the
    shape every other query in this file uses."""
    try:
        res = rpc("plane.cypher", {"plane": PLANE,
            "query": ("MATCH (p:Project)<-[:NOTIFY]-(e:Event) "
                      "WHERE p.path = $path "
                      "RETURN e ORDER BY e.created_at DESC LIMIT 20"),
            "params": {"path": proj_dir}}, token)
    except Exception as e:
        print(f"[drsg-memory] open events: {e}", file=sys.stderr)
        return []
    out = []
    for n in res.get("nodes", []):
        pr = n.get("properties", {})
        if pr.get("status") != "open":
            continue
        line = "- [%s from %s] %s" % (pr.get("kind", "notice"),
                                      pr.get("from_project", "?"),
                                      (pr.get("summary") or "")[:80])
        if pr.get("ref"):
            line += f"  (ref: {pr['ref']})"
        key = n.get("external_key", "?")
        line = f"{line}  <{key}>"
        # A second line, rendered by event.py at post time from the Event's
        # `symbols`/`verb` — never written by hand, and never folded into
        # `summary`, which is truncated to 80 chars just above where a symbol
        # key would lose the tail that identifies it. Appended verbatim so this
        # renderer and user_prompt.py's cannot say different things about one
        # to-do.
        if pr.get("graph_hint"):
            line += "\n  " + pr["graph_hint"]
        # `fresh` marks a to-do the graph has no receipt for yet, so the ack
        # below records when it was FIRST delivered rather than most recently.
        out.append({"key": key, "line": line,
                    "fresh": not pr.get("seen_at")})
        if len(out) >= limit:
            break
    return out


def ack_events(keys, sid, token):
    """Write the delivery receipt back to the graph.

    `.drsg/events_seen.json` already records this, but it is a file in the
    *recipient's* working copy: the project that posted the to-do cannot read
    it, so "sent" and "seen" look identical from the sending side. The receipt
    belongs where both ends can reach it, which is the node itself.

    One statement for all keys — `key(e) IN [...]` is supported, and the
    change-count comes back so a receipt that wrote nothing is visible instead
    of assumed. Best-effort like every write on this path: a lost receipt costs
    the sender a question, a raised exception would cost the user a session."""
    if not keys:
        return
    try:
        res = rpc("plane.cypher", {"plane": PLANE,
            "query": ("MATCH (e:Event) WHERE key(e) IN $keys "
                      "SET e.seen_at = $ts, e.seen_by = $sid"),
            "params": {"keys": sorted(keys), "ts": int(time.time()), "sid": sid}},
            token)
        if not res.get("props_set"):
            print(f"[drsg-memory] receipt for {len(keys)} Event(s) changed "
                  f"nothing — they stay indistinguishable from undelivered",
                  file=sys.stderr)
    except Exception as e:
        print(f"[drsg-memory] ack events: {e}", file=sys.stderr)


def mark_events_shown(proj_dir, sid, keys):
    """Record which Events this session has already put on the terminal.

    Two hooks show the same block. This one covers a fresh start; user_prompt.py
    covers the two cases this one cannot — a resumed session, whose SessionStart
    output the REPL does not render, and an Event another project posts while
    this session is already open. One file is what keeps them from showing the
    same to-do twice.

    Best-effort like every other write here: losing the file costs one repeated
    line, which is strictly better than losing the to-do."""
    try:
        d = os.path.join(proj_dir, ".drsg")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "events_seen.json"), "w", encoding="utf-8") as f:
            json.dump({"session": sid, "keys": sorted(keys)}, f)
    except Exception:
        pass


def short_tag(s, n=18):
    """One compressed label per Fact summary: prefer the conclusion side of
    an arrow, cut to n chars. Zero-dependency rule compression."""
    s = (s or "").strip()
    for sep in ("→", " -> ", " => "):
        if sep in s:
            s = s.split(sep, 1)[1].strip()
            break
    # First sentence only, either script's full stop.
    s = s.split("\u3002")[0].split(". ")[0]
    return s if len(s) <= n else s[:n - 1] + "…"


def build_briefing(facts):
    """Group Facts by kind, one line each: `• <kind> ×n: tag; tag; ...`."""
    by_kind = {}
    for n in facts:
        pr = n.get("properties", {})
        kind = pr.get("kind") or "general"
        by_kind.setdefault(kind, []).append(short_tag(pr.get("summary", "")))
    lines = []
    for kind in sorted(by_kind):
        tags = by_kind[kind]
        lines.append("• %s ×%d: %s" % (kind, len(tags), "; ".join(t for t in tags if t)))
    return "\n".join(lines)


def ensure_briefing(proj_dir, pid, token):
    """Rebuild Project.briefing when the Fact count changed; else reuse it.
    Returns (briefing text, fact count). Addressed by node id (see project_id).

    The count comes back for the telemetry line: a briefing that stops growing
    is the difference between "nothing worth writing happened" and "the write
    path broke", and the text alone cannot tell those apart."""
    try:
        proj = rpc("node.get", {"plane": PLANE, "id": pid}, token)
        stored = (proj or {}).get("properties", {}).get("briefing_count")
        stale = True
        try:
            facts = all_facts(proj_dir, token)
            if stored == len(facts):
                stale = False
        except Exception:
            facts = None  # read failed — not the same as "no facts"
        if stale:
            brief = build_briefing(facts) if facts else ""
            rpc("node.update", {"plane": PLANE, "id": pid, "set": {
                "briefing": brief, "briefing_count": len(facts or []),
                "briefing_at": int(time.time())}}, token)
        else:
            brief = (proj.get("properties", {}).get("briefing", "") or "")
        return brief, len(facts) if facts is not None else stored
    except Exception as e:
        print(f"[drsg-memory] ensure_briefing failed: {e}", file=sys.stderr)
        return "", None


def heal_text(token):
    """Keep the derived `Fact.text` (summary + detail) current, plane-wide.

    `text` exists because `Fact.summary`'s BM25 index is pinned to the English
    analyzer: `ensure_keyword_index` refuses to change an index's language and
    the API has no drop. A Chinese (jieba) index needs a property of its own,
    and `detail` alone is not it — measured, summary carries most of the
    signal. So `text` is derived and indexed instead.

    It is maintained here, by code, and deliberately absent from the protocol
    above. A field the protocol asks the model to write is a field that gets
    silently omitted — that is where the six empty Fact shells came from. This
    self-heals every session start instead, so an omission cannot degrade
    anything.

    Duplicated on purpose in tools/backfill_text.py, which is
    the standalone repair tool; the hooks are byte-identical copies across
    projects and cannot import from any one repo. Keep `derive` in sync — it is
    two lines.

    Plane-wide, not per-project: every install shares one plane, so whichever
    session starts first heals it for all of them. Returns the repair count.
    """
    res = rpc("plane.cypher", {"plane": PLANE, "query": "MATCH (f:Fact) RETURN f",
                               "params": {}}, token)
    fixed = 0
    for n in res.get("nodes", []):
        props = n.get("properties") or {}
        s = (props.get("summary") or "").strip()
        d = (props.get("detail") or "").strip()
        want = (s + "\n" + d).strip() if d else s
        if not want or props.get("text") == want:
            continue
        rpc("node.update", {"plane": PLANE, "id": n["id"], "set": {"text": want}}, token)
        fixed += 1
    return fixed


def orphan_facts(token):
    """Facts with no ABOUT edge to a Project — permanently invisible to recall.

    Reported, never repaired. Attaching one means deciding which Project it is
    about, and that is a judgement, not a repair: auto-grafting the 286 L3
    nodes onto whichever Project sorted first would have been worse than
    leaving them unreachable, because then they would have been *injected*.

    The reachability test is the recall query's own shape, deliberately. It
    means "reachable by the code that actually reads memory" — an ABOUT edge
    pointing at something that is not a Project does not count, and must not,
    because recall would not follow it either.

    Returns the orphan keys, newest-looking first is not worth the sort — the
    count is the signal and the keys are for the human who investigates.
    """
    def keys(query):
        res = rpc("plane.cypher", {"plane": PLANE, "query": query, "params": {}}, token)
        return {n.get("external_key") for n in res.get("nodes", []) if n.get("external_key")}

    everything = keys("MATCH (f:Fact) RETURN f")
    reachable = keys("MATCH (p:Project)<-[:ABOUT]-(f:Fact) RETURN f")
    return sorted(everything - reachable)


def main():
    ts_start = time.time()
    data = json.load(sys.stdin)
    proj_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    load_env(proj_dir)
    # Re-read config after load_env populated os.environ (install.sh's .drsg/env).
    global API, PLANE
    API = os.environ.get("DRSG_API", API)
    PLANE = os.environ.get("DRSG_PLANE", PLANE)
    token = os.environ.get("DRSG_TOKEN", "")
    if not token:
        hook_out()
        return
    try:
        rpc("db.stats", {}, token)  # liveness probe
    except Exception:
        hook_out()  # daemon down → don't block the session
        return

    sid = data.get("session_id", "")
    slug = os.path.basename(os.path.normpath(proj_dir))
    ts = int(time.time())

    # 1. Idempotently record Project + a fresh Session for this session.
    #    Existence is decided by `path`, not by whether the key is free: after a
    #    key-index accident the key can be unowned while the node is right there
    #    with every Fact still attached, and creating "because the key was free"
    #    is what turns one damaged project into two.
    pid = project_id(proj_dir, token)
    if pid is None:
        try:
            created = rpc("node.create", {"plane": PLANE, "key": slug, "labels": ["Project"],
                                          "properties": {"path": proj_dir}}, token)
            pid = created.get("id")
        except Exception as e:
            print(f"[drsg-memory] project create failed: {e}", file=sys.stderr)
    source = data.get("source", "startup")
    if source == "compact":
        # A compaction keeps the SAME session_id, so the Session node and its
        # BELONGS_TO edge already exist — creating again would only collide.
        # We still run (matcher includes `compact`) because the point of this
        # hook on a compaction is re-injecting the briefing and the protocol,
        # which the compaction summary drops. Stamp the event and move on.
        try:
            rpc("node.update", {"plane": PLANE, "key": sid,
                                "set": {"compacted_at": ts}}, token)
        except Exception as e:
            print(f"[drsg-memory] compact stamp failed: {e}", file=sys.stderr)
    else:
        try:
            rpc("node.create", {"plane": PLANE, "key": sid, "labels": ["Session"],
                "properties": {"started_at": ts,
                               "source": source,
                               "cwd": data.get("cwd", ""),
                               "project": slug}}, token)
            # Link by id (NodeRef is untagged: a number is an id, a string a key).
            # A dangling key makes edge.create fail outright — the session record
            # would be lost for exactly as long as the key stayed broken.
            rpc("edge.create", {"plane": PLANE, "src": sid, "dst": pid,
                                "type": "BELONGS_TO"}, token)
        except Exception as e:
            print(f"[drsg-memory] record failed: {e}", file=sys.stderr)

    # Derived-field upkeep, before the briefing reads anything. Best-effort:
    # a stale `text` only costs the shadow ranker some accuracy, and nothing
    # here is worth failing a session start over.
    try:
        healed = heal_text(token)
    except Exception as e:
        healed = None
        print(f"[drsg-memory] heal_text failed: {e}", file=sys.stderr)

    # An orphan Fact is written, costs storage, and can never be read. Nothing
    # errors when one is created, so the only way it surfaces is a check like
    # this one. Counted every session; the keys go to stderr (visible when a
    # human looks) rather than into the injected context, which is for memory,
    # not for maintenance chores.
    try:
        orphans = orphan_facts(token)
        if orphans:
            print(f"[drsg-memory] {len(orphans)} Fact(s) with no ABOUT edge to a "
                  f"Project — unreachable by recall: {', '.join(orphans[:5])}"
                  + (" …" if len(orphans) > 5 else ""), file=sys.stderr)
    except Exception as e:
        orphans = None
        print(f"[drsg-memory] orphan_facts failed: {e}", file=sys.stderr)

    # 2. Inject: the compressed briefing + recent sessions (NOT full Facts).
    parts = []
    brief, n_facts = ensure_briefing(proj_dir, pid, token) if pid else ("", None)
    if brief:
        parts.append("Briefing:\n" + brief)
    try:
        res = rpc("plane.cypher", {"plane": PLANE,
            "query": ("MATCH (p:Project)<-[:BELONGS_TO]-(s:Session) "
                      "WHERE p.path = $path "
                      "RETURN s ORDER BY s.started_at DESC LIMIT 3"),
            "params": {"path": proj_dir}}, token)
        # Only sessions that actually say something. Nothing writes
        # Session.summary today, so listing every recent session spent ~10% of
        # the startup injection on three lines of bare timestamps — context the
        # model cannot act on. When a summary does get written the line earns
        # its place again, and the block comes back on its own.
        sess_lines = []
        for n in res.get("nodes", []):
            pr = n.get("properties", {})
            if not pr.get("summary"):
                continue
            sess_lines.append(f"- session {pr.get('started_at')} "
                              f"[{pr.get('source', '?')}]: {pr['summary']}")
        if sess_lines:
            parts.append("Recent sessions:\n" + "\n".join(sess_lines))
    except Exception as e:
        print(f"[drsg-memory] recall sessions: {e}", file=sys.stderr)

    # Coordination events left for this project by another agent. Bounded and
    # self-clearing: once the Event is closed the block is gone. Closing is
    # described in-line because not every install has the helper script — the
    # MCP tools are the one interface every session has.
    events = open_events(proj_dir, token)
    ev_block = ""
    user_msg = None
    if events:
        ev_lines = [e["line"] for e in events]
        ev_block = ("⏳ Open for you (set the Event node's `status` to \"done\" "
                    "once handled):\n" + "\n".join(ev_lines))
        parts.append(ev_block)
        # Same list, second audience. Only Events get a terminal line: the
        # briefing and the protocol are standing context, while a to-do is a
        # decision someone has to make now, and it is the user who decides
        # whether this session is the one that takes it.
        user_msg = ("⏳ drsg memory — open for this project:\n"
                    + "\n".join(ev_lines))
        # Only claim it was shown where the REPL actually renders it. On a
        # resume the message above goes nowhere, and marking it seen would
        # make user_prompt.py stay quiet too — the one path left that can
        # still reach the person. Over-reporting costs a repeated line on a
        # fork; under-reporting loses the to-do entirely.
        if source == "startup":
            mark_events_shown(proj_dir, sid, [e["key"] for e in events])
            # Same predicate, for the same reason: the receipt must mean "a
            # person saw this", and on a resume nothing rendered. Only the
            # ones with no receipt yet, so seen_at stays the FIRST delivery.
            ack_events([e["key"] for e in events if e["fresh"]], sid, token)

    # L2: the write-memory protocol — makes the model the value-judge for what
    # deserves persisting, every turn, automatically (no user action needed).
    proto = protocol(slug, PLANE, proj_dir)
    parts.append(proto)
    ctx = "# dr-strange memory (%s)\n%s" % (slug, "\n\n".join(parts))
    # Split the cost the way it is spent. The protocol is a fixed instruction,
    # not memory: counted together with the briefing it hides that most of the
    # startup budget buys no recall at all.
    # `source` distinguishes the startup injection from a re-injection after a
    # compaction — without it one session's two briefing lines are unreadable.
    telemetry(proj_dir, {"event": "briefing", "session": sid, "project": slug,
                         "source": source, "facts": n_facts,
                         "brief_chars": len(brief), "proto_chars": len(proto),
                         "events": len(events), "event_chars": len(ev_block),
                         "total_chars": len(ctx),
                         # None = the repair pass itself failed, 0 = nothing to
                         # repair. A number that stays >0 every session means
                         # something is rewriting summaries behind us.
                         "text_healed": healed,
                         # None = the check itself failed, 0 = none orphaned.
                         # A number that grows means something is writing Facts
                         # without the ABOUT edge again.
                         "orphan_facts": None if orphans is None else len(orphans),
                         "ms": int((time.time() - ts_start) * 1000)})
    hook_out(system_message=user_msg, additionalContext=ctx)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""UserPromptSubmit hook: task-level memory recall.

SessionStart injects a compressed *briefing* (always relevant, bounded). This
hook is the L2 layer: for each user prompt, pull the Facts most relevant to
what they're about to work on and inject only those (max 3) as context.

Cross-project: recall spans ALL projects' Facts — the n-gram+IDF scoring is
prompt-driven, so a prompt in one project naturally pulls in facts from another
when they are genuinely relevant, while irrelevant ones score ~0 and stay out.
The SessionStart briefing stays per-project.

Two things that a single unfiltered query got wrong, both silent:
  * A foreign fact injected bare reads exactly like a local one. "本项目的 X
    必须配成 Y" from another repo would be applied here without a hint that it
    came from somewhere else. Facts from other projects are now labelled with
    their origin; local ones stay bare (absence of a label *is* the signal).
  * `ORDER BY created_at DESC LIMIT n` over the union means one busy project
    can push another project's older facts out of the candidate pool entirely,
    and nothing shows that it happened. The cap is now applied per project,
    so each project always gets its own newest n into the ranking.
Cost: one query per project instead of one total (2 projects today, local
daemon, ~ms each) — well inside the hook's budget.

Matching strategy — character n-gram reverse match (CJK-friendly, zero-dep):
  * A server-side substring search (`plane.find`) requires the *query* to be a
    substring of the text, so a whole-sentence Chinese prompt never matches
    (verified).
  * Instead we load the project's Facts once and score each against the
    prompt's 2–4 char windows, weighting by inverse document frequency — a
    rare gram like "环境变量" that appears in one Fact strongly pulls it up,
    while filler grams ("这个","问题") spread evenly and contribute little.
  * The core shipped a Chinese (jieba) BM25 analyzer in 2f175ee, after this
    hook was written, so the premise above ("BM25 can't do Chinese") no longer
    holds. Replacing the ranker is a read-path change and the observability
    plan froze those until its phase-1 gate, so BM25 runs here in *shadow*:
    scored and logged every prompt, never injected. See `shadow_bm25`.
  * The gate opened at 49 sessions and the shadow lost, decisively: over 355
    prompts where both rankers were logged, BM25's top-3 cleared the usage bar
    30% of the time against this ranker's 48%, and on the picks where the two
    disagreed, 23% against 45% — barely above the 16% chance floor. The two
    agree on nothing (54% of prompts share zero of top-3), so that is a real
    difference and not a tie. The ranker therefore stays. The shadow keeps
    running because the corpus keeps growing and the comparison costs one RPC.

Phase 2 (control arm): a fixed share of prompts have their recall computed and
logged but withheld — see `arm`. The utilization proxy cannot judge the effect
of injection (it scores rank 4 as highly as rank 3, so it is blind to the
treatment); tool outcomes joined per prompt by session_end.py can.

Design rules (same as session_start.py):
  * Talk to the shared daemon over /rpc, never open the DB directly.
  * Any failure → bare output, never block the prompt.
  * Cheap: one read RPC + local scoring, silent when nothing matches.
"""
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.request

# --- Configuration (overridable via .drsg/env) -----------------------------
API = "http://127.0.0.1:7700/rpc"
PLANE = "memory"
# 3 until 2026-09-07. LOG_RANK is what made the change measurable rather than a
# guess: over the 2026-08-08..09-07 window ten facts were ranked but never
# injected, and four of them peaked at exactly rank 4 — losing to the cut, not
# to the ranker. Widening by one reaches those without touching scoring. The
# cost is one more line per prompt (~104 chars, ~a third of the current 312).
# Revisit against the same report: if the newly reachable rank-4 slot does not
# clear the usage bar the way ranks 1-3 do, put it back.
MAX = 4
FACT_CAP = 200  # per project, not total — see the module docstring
# Ranked facts recorded per prompt, injected or not. The ones just below the
# cut are the whole point: tuning MAX or adding a score threshold is guesswork
# without knowing what was almost injected. Keep this strictly above MAX, or
# the next tuning round is blind in exactly the way this one was not.
LOG_RANK = 5
# Terminal to-do lines per prompt. Same bound session_start.py uses: a to-do
# is worth interrupting for, a wall of them is not.
MAX_EVENTS = 3
# Share of prompts held back as the control arm. Small on purpose: the cost of
# the arm is paid by the user, one degraded prompt at a time, and the gain is
# statistical. 15% over a session of ~35 prompts is about five, while both arms
# still accrue inside every session — which is what lets the comparison cancel
# the 5x spread in failure rate between sessions.
SUPPRESS_PCT = 15


def telemetry(proj_dir, record):
    """Append one JSON line to .drsg/recall.jsonl.

    Best-effort and silent by construction: this is the read path, and a
    session must never degrade because a log write failed. The recall
    decision is already made by the time this runs.
    """
    try:
        d = os.path.join(proj_dir, ".drsg")
        os.makedirs(d, exist_ok=True)
        record["ts"] = int(time.time())
        with open(os.path.join(d, "recall.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


def prompt_id(prompt):
    """A stable handle for a prompt that is not the prompt.

    The analyzer needs to find the same turn in the transcript; the log must
    not become a second copy of everything the user typed, secrets included.
    A digest satisfies both."""
    return hashlib.sha1(prompt.encode("utf-8", "replace")).hexdigest()[:16]


def arm(session_id, pid):
    """"treated" or "suppressed" for this prompt. Pure: no I/O, no RNG.

    Deterministic rather than random so the assignment can be reproduced from
    the log alone, survives the hook running twice on the same prompt, and does
    not depend on process state. The session id is hashed in so that the same
    question asked in two sessions can land on either side — otherwise a prompt
    someone repeats often would be permanently stuck in one arm."""
    h = hashlib.sha1(f"{session_id}:{pid}".encode()).hexdigest()
    return "suppressed" if int(h[:8], 16) % 100 < SUPPRESS_PCT else "treated"


def rpc(method, params, token):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        API, data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=3) as r:
        return json.load(r)["result"]


def load_env(proj_dir):
    p = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


# The to-do lines this prompt should put on the terminal, set once in main().
# A module global rather than an argument because hook_out() has five call
# sites, four of them early returns (no token, no facts, no match, daemon
# down) — and a to-do must survive all of them. An unrelated failure is
# exactly when the reminder matters most.
NOTICE = None


def hook_out(**extra):
    out = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit"}}
    out["hookSpecificOutput"].update(extra)
    # `systemMessage` is top-level and goes to the terminal alone, the mirror
    # of additionalContext. Nothing here reaches the model.
    if NOTICE:
        out["systemMessage"] = NOTICE
    print(json.dumps(out))


def mark_events_shown(proj_dir, sid, keys):
    """Record which Events this session has already put on the terminal.

    Deliberately duplicated from session_start.py — the two hooks are separate
    files with no shared module, and this file is what keeps a fresh session
    from being shown the same to-do twice, once by each hook."""
    try:
        d = os.path.join(proj_dir, ".drsg")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "events_seen.json"), "w", encoding="utf-8") as f:
            json.dump({"session": sid, "keys": sorted(keys)}, f)
    except Exception:
        pass


def events_shown(proj_dir, sid):
    """Event keys already shown *in this session*. A different session id means
    an empty set: on a resume the to-do has to be said again, because the REPL
    never rendered what SessionStart said."""
    try:
        with open(os.path.join(proj_dir, ".drsg", "events_seen.json"),
                  encoding="utf-8") as f:
            d = json.load(f)
        return set(d.get("keys") or []) if d.get("session") == sid else set()
    except Exception:
        return set()


def event_notice(proj_dir, sid, token):
    """Open to-dos for this project that this session has not shown yet.

    SessionStart shows them too, but only where the REPL renders its output —
    a fresh start. Asking again here reaches the two cases it cannot: a resumed
    session, and an Event another project posts while this session is already
    open (the cross-agent hand-off that today waits for the next startup).

    Costs one small cypher per prompt. Nothing about recall changes: the block
    leaves over `systemMessage`, `additionalContext` is untouched, and no Fact
    is filtered, ranked or injected differently — the same line shadow_bm25
    stays behind."""
    seen = events_shown(proj_dir, sid)
    res = rpc("plane.cypher", {"plane": PLANE,
        "query": ("MATCH (p:Project)<-[:NOTIFY]-(e:Event) "
                  "WHERE p.path = $path "
                  "RETURN e ORDER BY e.created_at DESC LIMIT 20"),
        "params": {"path": proj_dir}}, token)
    lines, keys, fresh = [], [], []
    for n in res.get("nodes", []):
        pr = n.get("properties", {})
        if pr.get("status") != "open":
            continue
        key = n.get("external_key", "?")
        # Every open key is remembered, not just the newly shown ones, so the
        # file stays a complete record of what this session has been told.
        keys.append(key)
        if key in seen or len(lines) >= MAX_EVENTS:
            continue
        line = "- [%s from %s] %s" % (pr.get("kind", "notice"),
                                      pr.get("from_project", "?"),
                                      (pr.get("summary") or "")[:80])
        if pr.get("ref"):
            line += f"  (ref: {pr['ref']})"
        line = f"{line}  <{key}>"
        # Rendered by event.py at post time from the Event's `symbols`/`verb`;
        # appended verbatim, exactly as session_start.py does it, so a to-do
        # cannot read one way on a fresh session and another on a resumed one.
        if pr.get("graph_hint"):
            line += "\n  " + pr["graph_hint"]
        lines.append(line)
        # Only what this prompt actually puts on screen, and only if the graph
        # has no receipt yet — this hook is the delivery path for resumed
        # sessions, so it is usually the one that writes the first receipt.
        if not pr.get("seen_at"):
            fresh.append(key)
    if lines:
        mark_events_shown(proj_dir, sid, keys)
        ack_events(fresh, sid, token)
    return lines


def ack_events(keys, sid, token):
    """Write the delivery receipt back to the graph — see session_start.py.

    Duplicated rather than shared for the same reason mark_events_shown is: the
    hooks are installed as independent files with no import path between them.

    Swallowed on failure, and deliberately quiet on stderr too: this hook runs
    on every prompt, and a daemon hiccup must not print into the user's typing."""
    if not keys:
        return
    try:
        rpc("plane.cypher", {"plane": PLANE,
            "query": ("MATCH (e:Event) WHERE key(e) IN $keys "
                      "SET e.seen_at = $ts, e.seen_by = $sid"),
            "params": {"keys": sorted(keys), "ts": int(time.time()), "sid": sid}},
            token)
    except Exception:
        pass


def clean(s):
    # keep CJK + alnum, lower; drop spaces/punctuation so grams cross the
    # "配置构建" boundary the way a reader would.
    return re.sub(r"[^\w一-鿿]+", "", (s or "").lower())


def grams(s, lo=2, hi=4):
    out = []
    for n in range(lo, hi + 1):
        for i in range(len(s) - n + 1):
            out.append(s[i:i + n])
    return out


def rank_facts(prompt, facts):
    """Rank facts by n-gram+IDF match against the prompt. Returns (score, fact)
    pairs, best first, positives only. Pure: no I/O.

    IDF is computed over the whole cross-project corpus on purpose: a gram that
    is rare *everywhere* is the one worth ranking on."""
    pgrams = set(grams(clean(prompt)))
    df = {}
    for f in facts:
        for g in set(grams(f["clean"])):
            df[g] = df.get(g, 0) + 1
    n = len(facts)
    scored = []
    for f in facts:
        sc = sum(math.log(1.0 + n / df.get(g, n)) for g in pgrams if g in f["clean"])
        if sc > 0:
            scored.append((sc, f))
    # Sort on the score alone — tuples carrying dicts blow up on a tie.
    scored.sort(key=lambda t: -t[0])
    return scored


def shadow_bm25(prompt, facts, token):
    """The BM25-over-`Fact.text` ranking for this prompt — logged, never used.

    Waiting for the phase-1 gate with the read path frozen produces no evidence
    about what would replace it. Running the candidate ranker beside the live
    one costs one RPC (~2ms measured) and means the A/B is already collected
    when the gate opens rather than starting from zero then.

    `Fact.text` is a derived summary+detail property maintained by
    tools/backfill_text.py — `Fact.summary`'s own index is
    pinned to the English analyzer and cannot be changed in place.

    The prompt travels as an RPC *parameter*, never interpolated into a query
    string: prompts carry quotes and backslashes, and `SEARCH ... MATCHING
    "<user text>"` would be a parse error at best.
    """
    origins = {f["key"]: f["origin"] for f in facts}
    res = rpc("plane.hybrid", {
        "plane": PLANE, "q": prompt, "label": "Fact", "keyword_prop": "text",
        "k": LOG_RANK, "w_keyword": 1.0, "w_vector": 0.0, "w_graph": 0.0,
    }, token)
    out = []
    for h in res.get("results", []):
        key = h.get("external_key", "?")
        out.append({
            "key": key,
            # A Fact with no ABOUT edge can place here but never in production:
            # this scans the label, recall walks the edges. "?" marks that gap.
            "origin": origins.get(key, "?"),
            "score": round((h.get("channels") or {}).get("keyword") or 0.0, 2),
        })
    return out


def score_facts(prompt, facts, maxhits=MAX):
    """The facts that win, best first, capped at maxhits. The shape callers
    outside this hook already read (benchmark/bench_lib.py)."""
    return [f for _, f in rank_facts(prompt, facts)[:maxhits]]


def fetch_facts(token):
    """Every project's Facts, newest-first *per project*, each carrying the
    project it belongs to.

    One query per project rather than one over the union: the query language
    requires RETURN to name the pattern's last variable, so a single
    `(p)<-[:ABOUT]-(f)` cannot hand back both the fact and its project — and
    the origin is exactly what we need to label with.

    Projects are matched on `p.path`, NOT on `key(p)`. The external-key index
    is not trustworthy here: digest.run has twice written a second node with an
    existing project's key (see the `fact-key-collision-incident` Fact), and
    once that happens `key(p) = "data-safe"` resolves to the shadowing node —
    which has no ABOUT edges, so every key-filtered query silently returns
    nothing. Filtering on a property walks the real nodes instead, and the
    junk duplicates drop out for free: only session_start.py sets `path`."""
    res = rpc("plane.cypher", {"plane": PLANE, "query": "MATCH (p:Project) RETURN p",
                               "params": {}}, token)
    paths = []
    for n in res.get("nodes", []):
        path = (n.get("properties") or {}).get("path")
        if path and path not in paths:
            paths.append(path)

    facts, seen = [], set()
    for path in paths:
        pk = os.path.basename(os.path.normpath(path))
        res = rpc("plane.cypher", {"plane": PLANE,
            "query": ("MATCH (p:Project)<-[:ABOUT]-(f:Fact) "
                      "WHERE p.path = $path "
                      "RETURN f ORDER BY f.created_at DESC LIMIT %d") % FACT_CAP,
            "params": {"path": path}}, token)
        for n in res.get("nodes", []):
            pr = n.get("properties", {})
            key = n.get("external_key", "?")
            # A Fact ABOUT two projects would otherwise be ranked twice.
            if not pr.get("summary") or key in seen:
                continue
            seen.add(key)
            facts.append({
                "key": key,
                "origin": pk,
                "clean": clean(pr["summary"]),
                "tag": (pr["summary"].split("→")[-1].split("。")[0].strip() or pr["summary"])[:60],
            })
    return facts


def main():
    t0 = time.time()
    data = json.load(sys.stdin)
    prompt = (data.get("prompt") or "").strip()
    if len(prompt) < 2:
        hook_out()
        return
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

    # The project this session is in — same derivation as session_start.py, so
    # a fact from here stays bare and everything else gets named.
    home = os.path.basename(os.path.normpath(proj_dir))

    # Every outcome is logged, including the ones that inject nothing. A recall
    # rate needs its denominator, and "the daemon was down for a week" is a
    # conclusion the analyzer can only reach from records that say so.
    rec = {"event": "recall", "session": data.get("session_id", ""),
           "project": home, "prompt": prompt_id(prompt), "prompt_len": len(prompt)}
    # Assigned for every prompt, including the ones that end up with nothing to
    # inject: the arm is a property of the prompt, not of the outcome, and the
    # split is only verifiable if the misses are logged too. The analyzer counts
    # the arm only where an injection was actually on the table.
    rec["arm"] = arm(rec["session"], rec["prompt"])

    # Before any early return: whether recall finds anything is unrelated to
    # whether someone left a to-do here, and the failure paths below must not
    # swallow it. Swallowed whole on error for the same reason shadow_bm25 is —
    # a coordination extra must never cost the user a prompt.
    global NOTICE
    try:
        ev_lines = event_notice(proj_dir, rec["session"], token)
        if ev_lines:
            NOTICE = ("⏳ drsg memory — open for this project:\n"
                      + "\n".join(ev_lines))
            rec["events_shown"] = len(ev_lines)
    except Exception as e:
        rec["events_error"] = type(e).__name__

    def done(status, **extra):
        rec["status"] = status
        rec.update(extra)
        rec["ms"] = int((time.time() - t0) * 1000)
        telemetry(proj_dir, rec)

    try:
        facts = fetch_facts(token)
    except Exception as e:
        done("error", error=type(e).__name__)
        hook_out()  # daemon down / error → don't touch the prompt
        return
    if not facts:
        done("no_facts")
        hook_out()
        return

    ranked = rank_facts(prompt, facts)
    # Scores are rounded, not raw: the analyzer compares them, it does not
    # reproduce the arithmetic, and full floats trebled the line length.
    rec["ranked"] = [{"key": f["key"], "origin": f["origin"], "score": round(s, 2)}
                     for s, f in ranked[:LOG_RANK]]
    rec["n_candidates"] = len(facts)
    # Shadow only. Nothing below reads it, and its failure must never cost the
    # user a prompt — so it is swallowed whole and recorded as a bare name.
    try:
        rec["shadow_bm25"] = shadow_bm25(prompt, facts, token)
    except Exception as e:
        rec["shadow_bm25_error"] = type(e).__name__
    hits = [f for _, f in ranked[:MAX]]
    if not hits:
        done("no_match")
        hook_out()
        return

    lines = []
    for f in hits:
        origin = "" if f["origin"] == home else f" [from {f['origin']}]"
        lines.append(f"- ({f['key']}){origin} {f['tag']}")
    block = "# Relevant memory\n" + "\n".join(lines)
    if rec["arm"] == "suppressed":
        # The control side. Everything above ran and is logged identically —
        # what was withheld is recorded by key, so the two arms differ in one
        # thing and the analyzer can still say what this prompt gave up.
        done("suppressed", withheld=[f["key"] for f in hits], chars=len(block))
        hook_out()
        return
    done("injected", injected=[f["key"] for f in hits], chars=len(block))
    hook_out(additionalContext=block)


if __name__ == "__main__":
    main()

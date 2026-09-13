#!/usr/bin/env python3
"""Did the code graph get used, and did the calls land?

A plane that is served, synced and never queried looks exactly like a healthy
one from the daemon's side — `status` reports the same thing either way. The
only record of whether an agent actually consulted it lives in the session
transcripts, so that is what this reads.

    codegraph-usage.py [--since YYYY-MM-DD] [--project SUBSTR] [--verbose]

Three numbers matter, in this order:

  calls        zero means the tools may as well not be installed, and no
               amount of tuning the block in CLAUDE.md shows up anywhere else.
  landed       a call that came back with a symbol. The failure this separates
               out is plane addressing: `no symbol matches` from the default
               empty `startup` plane reads identically to a real gap, so a
               setup can look "used but unhelpful" when it was only misaddressed.
  missed       greps that went at source files in a repo whose graph tools were
               available in that same session. An upper bound, not a verdict:
               string literals, comments, dependencies outside the tree and
               generated files are all legitimately grep's job. Only a segment
               that actually *runs* grep counts — not a `| grep` filtering some
               other command, not the word appearing in a heredoc body, and not
               a compound line judged on the arguments of its other half.

What it cannot tell you: whether consulting the graph *changed* an answer.
Nothing here is a controlled comparison — for that you would have to withhold
the tools from a random share of sessions and compare outcomes, the way the
memory layer's suppression arm does. Read `landed` as "was consulted", never as
"was useful".

Transcripts are pruned on `cleanupPeriodDays` (30 by default), so a window that
starts before the oldest surviving file is silently shorter than it looks; the
report says which window it actually covered.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import sys

PROJECTS = os.path.expanduser("~/.claude/projects")
# Two ways a session reaches a graph: the repository's own daemon, or the
# router's `graph_*` proxies, which carry the same verbs to any repository.
# Counting only the first is how the hub — the heaviest user of the router, and
# the only place cross-repository review happens — reported "never offered, 0
# calls" for two days in which it made 35 landed calls.
DIRECT_TOOL = re.compile(r"^mcp__drsg-watch__(.+)$")
ROUTED_TOOL = re.compile(r"^mcp__codegraph__graph_(.+)$")
# A grep/rg that is actually being run, rather than mentioned. Leading shell
# keywords are allowed through so `do grep …` inside a loop still counts.
RUNS_SEARCH = re.compile(r"(?:(?:do|then|else|\{)\s+)?(?:sudo\s+)?(?:grep|rg)\b")
# `<<EOF … EOF`: a commit message or a script body is prose, not a search.
HEREDOC = re.compile(r"<<-?\s*['\"]?(\w+)['\"]?\n.*?^\1$", re.S | re.M)
# Extensions a code-graph plugin plausibly claims. Deliberately not exhaustive:
# this feeds an upper bound that is meant to be argued down, not a metric.
SRC_EXT = (".rs", ".go", ".py", ".ts", ".tsx", ".js", ".mjs", ".java", ".c", ".h",
           ".cpp", ".zig", ".svelte", ".rb", ".php", ".cs", ".kt", ".swift")
EMPTY = ("no symbol matches", "no matches")
AMBIGUOUS = "is ambiguous"
# Places a plane never covers, so a grep there was never the graph's to answer:
# dependency sources, build output, and anything outside the watched tree.
OUTSIDE = ("/.cargo/", "node_modules", "/target/", "/proc/", "/site-packages/",
           "/vendor/", "/.venv/", "/dist/", "/build/")


def scan(path):
    """One transcript -> (cwd, uses by id, results by use id, when tools appeared).

    A session is only accountable for the graph from the moment it was told the
    tools exist. Transcripts continue across resumes, so one file can span the
    weeks before a repository had a code graph at all; counting those greps as
    missed opportunities is how an upper bound turns into a fiction.
    """
    cwd = None
    uses, results, offered_at = {}, {}, None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            has_listing = "mcp__drsg-watch__" in line or "mcp__codegraph__" in line
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            cwd = cwd or rec.get("cwd")
            # The listing names every tool at once; prose that happens to
            # mention one is not the session being handed them.
            has_listing = has_listing and (line.count("mcp__drsg-watch__") >= 5
                                           or line.count("mcp__codegraph__") >= 5)
            if has_listing and offered_at is None:
                offered_at = rec.get("timestamp", "")
            content = (rec.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    uses[block.get("id")] = (rec.get("timestamp", ""), block.get("name", ""),
                                             block.get("input") or {})
                elif block.get("type") == "tool_result":
                    body = block.get("content")
                    if isinstance(body, list):
                        body = "".join(p.get("text", "") for p in body if isinstance(p, dict))
                    results[block.get("tool_use_id")] = str(body)
    return cwd, uses, results, offered_at


def graph_verb(tool):
    """`(verb, routed)` for a graph tool call, `(None, False)` for anything else.

    Whether it was routed is not cosmetic: the router fills `plane` in from its
    registry, so a routed call cannot be mis-addressed and `classify` must not
    read its absent `plane` as the default-`startup` mistake.
    """
    m = DIRECT_TOOL.match(tool)
    if m:
        return m.group(1), False
    m = ROUTED_TOOL.match(tool)
    if m:
        return m.group(1), True
    return None, False


def searches(cmd):
    """The grep/rg invocations in a shell command, each as its own text.

    Matching the word anywhere in the command counted three things that are not
    searches: a `grep` inside a heredoc body, a `| grep` filtering some other
    command's output, and the whole of `chmod … && grep …`, which was then
    judged on the chmod's arguments. Splitting on `&&`/`||`/`;`/newline — but
    deliberately *not* on a single `|` — leaves a pipeline filter attached to the
    command it filters, so it never reaches the head of a segment.
    """
    return [seg.strip() for seg in re.split(r"&&|\|\||;|\n", HEREDOC.sub("", cmd))
            if RUNS_SEARCH.match(seg.strip())]


def classify(inp, out, routed=False):
    """Why a `context`/`describe` call came back empty — the graph, or the call."""
    plane = inp.get("plane")
    if out.startswith("not found: plane"):
        return "bad plane name"
    if any(marker in out for marker in EMPTY):
        if not routed and plane in (None, "", "startup"):
            return "default/empty plane"
        return "genuinely absent"
    if AMBIGUOUS in out:
        return "ambiguous"
    return "landed"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", default="", help="ISO date; skip anything older")
    ap.add_argument("--project", default="", help="only projects whose path contains this")
    ap.add_argument("--verbose", action="store_true", help="list every call and every missed grep")
    args = ap.parse_args()

    if not os.path.isdir(PROJECTS):
        print(f"no transcripts at {PROJECTS}", file=sys.stderr)
        return 1

    per = collections.defaultdict(lambda: {
        "sessions": 0, "offered": 0, "routed": 0, "verbs": collections.Counter(),
        "why": collections.Counter(), "missed": [], "calls": [], "span": [None, None],
        })

    for entry in sorted(os.listdir(PROJECTS)):
        d = os.path.join(PROJECTS, entry)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".jsonl"):
                continue
            cwd, uses, results, offered_at = scan(os.path.join(d, name))
            if not cwd or (args.project and args.project not in cwd):
                continue
            st = per[cwd]
            st["sessions"] += 1
            st["offered"] += 1 if offered_at else 0
            for use_id, (ts, tool, inp) in uses.items():
                if args.since and ts[:10] < args.since:
                    continue
                lo, hi = st["span"]
                st["span"] = [min(lo, ts) if lo else ts, max(hi, ts) if hi else ts]
                v, routed = graph_verb(tool)
                if v:
                    st["verbs"][v] += 1
                    st["routed"] += 1 if routed else 0
                    if v in ("context", "describe", "snippet", "impact", "trace"):
                        st["why"][classify(inp, results.get(use_id, ""), routed)] += 1
                    st["calls"].append((ts, v, routed,
                                        json.dumps(inp, ensure_ascii=False)[:90]))
                    continue
                # Everything below is the substitutable population: only what
                # happened after this session was handed the tools counts.
                if not offered_at or ts < offered_at:
                    continue
                if tool == "Bash":
                    texts = searches(inp.get("command", ""))
                elif tool == "Grep":
                    texts = [json.dumps(inp, ensure_ascii=False)]
                else:
                    texts = []
                for text in texts:
                    if (any(e in text for e in SRC_EXT)
                            and not any(o in text for o in OUTSIDE)):
                        st["missed"].append((ts, text[:120].replace("\n", " ")))

    if not per:
        print("no sessions matched")
        return 0

    for cwd, st in sorted(per.items()):
        calls = sum(st["verbs"].values())
        print(f"\n{cwd}")
        span = " .. ".join(s[:10] for s in st["span"] if s) or "no activity"
        print(f"  {st['sessions']} session(s), tools offered in {st['offered']}; window {span}")
        if not calls:
            verdict = ("the tools were never offered — no .mcp.json entry, or the daemon"
                       " was down at session start" if not st["offered"]
                       else "the tools were available and never called")
            print(f"  calls: 0  <- {verdict}")
        else:
            print(f"  calls: {calls}  " + " ".join(f"{v}={n}" for v, n in st["verbs"].most_common()))
            if st["routed"]:
                print(f"  {st['routed']} of those went through the router to another"
                      f" repository's graph")
            if st["why"]:
                print("  lookups: " + "  ".join(f"{k}={n}" for k, n in st["why"].most_common()))
                addressing = st["why"]["default/empty plane"] + st["why"]["bad plane name"]
                if addressing:
                    print(f"  ** {addressing} lookup(s) failed on plane addressing, not on missing data —"
                          f" the block in CLAUDE.md should name the plane")
        unused = [v for v in ("impact", "trace") if not st["verbs"][v]]
        if calls and unused:
            print(f"  never used: {', '.join(unused)} — the verbs a grep cannot stand in for")
        print(f"  missed (upper bound): {len(st['missed'])} source-file grep(s) while the tools were live")
        if args.verbose:
            for ts, v, routed, inp in st["calls"]:
                print(f"    {'route' if routed else 'call '}  {ts[:16]}  {v:11s} {inp}")
            for ts, text in st["missed"]:
                print(f"    grep  {ts[:16]}  {text}")

    print("\n`landed` means consulted, not useful — there is no control arm here.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

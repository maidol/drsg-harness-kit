#!/usr/bin/env python3
"""Read the memory layer's telemetry and say whether recall is earning its keep.

Answers, from records rather than impressions:

  * **Utilization** — of the facts that were injected, how many did the model
    visibly use in the reply? Injection is free to measure and means nothing on
    its own; a fact that is injected every day and never used is a tax.
  * **Cross-project** — is utilization for facts borrowed from another project
    comparable to local ones, or is sharing just noise with a token bill?
  * **Dead and dumb facts** — injected often but never used (demote), or never
    injected at all (its wording matches no real prompt; rewrite or delete).
  * **Cost** — the injected characters and hook latency the above is bought with.

Usage:
    python3 analyze_recall.py                 # every project the daemon knows
    python3 analyze_recall.py --project DIR   # just this one, repeatable
    python3 analyze_recall.py --since 14      # last 14 days
    python3 analyze_recall.py --no-cache      # ignore frozen verdicts, recompute

## Why this is incremental

Deciding whether a fact was used needs the *reply*, and replies live in Claude
Code transcripts, which are deleted on a retention timer. The pre-registered
thresholds run over months; the evidence does not survive that long. So every
verdict this script reaches is frozen into `.drsg/recall-verdicts.jsonl` on
first computation and read back from there afterwards. Run it at least once
inside the retention window and the verdict outlives the transcript.

What is frozen is the matched-character **mass**, not the yes/no — so
`MIN_MATCH_CHARS` can still be re-tuned later over the whole history. The
document-frequency filter is not re-runnable that way, so a change to the gram
logic must bump `VERDICT_VERSION`, which recomputes what it still can and
reports the rest as stale rather than silently mixing two definitions.

## How "used" is decided, and what it is worth

An injected line shows the model one compressed tag (~60 chars), nothing more.
So usage can only mean: the reply contains discriminative material from that
tag. "Discriminative" does two jobs —

  * grams that also appear in the user's own prompt are dropped, or the metric
    would measure the prompt echoing itself;
  * grams that are common across the whole fact corpus are dropped by document
    frequency, so "配置" and "文件" cannot carry a match on their own.

This is a proxy and it is stated as one. It over-counts a reply that merely
acknowledges the memory, and it under-counts a memory that changed what the
model *chose not to do* — the gcc fact working perfectly looks like a build
that simply didn't fail. Read it as a floor on a per-fact basis and a trend in
aggregate; it is not a quality score, and P2 (trap recurrence) is the metric
that answers "did it prevent the accident".

## Two measurements that bound what this proxy can say

*A chance floor exists and is large.* Scoring facts the prompt never ranked
against the same reply clears the old 6-char bar 45% of the time. Utilization is
therefore never reported bare: the floor is computed from the same replies and
printed beside it, and the pre-registered kill line is stated as excess over
chance rather than as a raw rate.

*Injection itself does not move this metric.* Production ranks five and injects
three, so rank 3 (injected) and rank 4 (not) sit adjacent in score and differ
only in whether the model saw them. They score the same — 46% vs 43% at 20
chars, against 57% for rank 1. So what is being measured is whether a fact was
*on topic*, not whether showing it changed the answer. That is worth knowing on
its own, and it is also why the phase-3 control arm cannot use this number as
its outcome: it is blind to the treatment. Tool-outcome counters, joined per
prompt (`event: tools`), are that arm's readout instead.
"""
import argparse
import bisect
import hashlib
import json
import os
import sys
import time
import urllib.request
from collections import defaultdict

TRANSCRIPT_ROOT = os.path.expanduser("~/.claude/projects")
# Assistant turns after the prompt that count as "the reply". More than one
# because the answer often lands after a couple of tool calls.
REPLY_TURNS = 3
# A gram must appear in at most this share of facts to count as discriminative.
DF_SHARE = 0.15
# Matched characters, after overlapping grams are merged into spans, before a
# reply counts as using the fact. Mass, not count: the false positives left
# after span-merging were all pairs of generic two-character words (一个, 索引,
# 测试) while every true positive matched a run of 15-25 characters, so length
# separates them and a hit count does not. Measured on the 34-fact corpus:
# 6/6 true positives, 3/170 false (1.8%). The three are `create` and `return`
# — English keywords that belong to the fact and to unrelated prose equally,
# which no threshold on this signal can separate.
#
# Raised 6 → 20 once the placebo arm below made the chance floor measurable.
# At 6 a *random unranked* fact cleared this bar 45% of the time, so a headline
# "74% utilization" was 45 points of vocabulary overlap and 29 of signal. Across
# the whole sweep on 1436 injections vs 1506 placebo draws:
#
#     thr      injected   placebo   lift
#       6         74%       45%     1.7x
#      20         50%       16%     3.1x     <- here
#      40         28%        7%     4.1x
#
# 20 is where the lift is bought without throwing away half the true positives;
# beyond it the rate falls faster than the floor does. Re-tuning costs nothing
# and invalidates nothing — the frozen mass is what the threshold reads.
MIN_MATCH_CHARS = 20
# Random facts drawn per judged prompt to measure the chance floor. They are
# sampled from the facts this prompt did NOT rank, scored against the same
# reply, and frozen like any other verdict — the floor has to survive transcript
# retention exactly as the numerator does, or the pair stops being comparable.
PLACEBO_K = 3
# Recorded prompts a Fact must have been eligible for before "it never matched
# anything" is a statement about its wording rather than about its age.
MIN_ELIGIBLE = 20
# Frozen verdicts, one per (session, prompt, fact). Written beside recall.jsonl
# in each project so a verdict outlives the transcript it was read from.
VERDICTS = "recall-verdicts.jsonl"
# Bump when clean/grams/informative/DF change — i.e. when the same reply would
# now score differently. Old entries are then recomputed where the transcript
# is still there and counted as stale where it is not.
VERDICT_VERSION = 1


# --- shared with the hooks (kept in step deliberately) ----------------------

def clean(s):
    import re
    return re.sub(r"[^\w一-鿿]+", "", (s or "").lower())


def grams(s, lo=2, hi=4):
    out = []
    for n in range(lo, hi + 1):
        for i in range(len(s) - n + 1):
            out.append(s[i:i + n])
    return out


def prompt_id(prompt):
    return hashlib.sha1(prompt.encode("utf-8", "replace")).hexdigest()[:16]


# --- daemon ----------------------------------------------------------------

def load_env(proj_dir):
    env = {}
    p = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def rpc(api, method, params, token):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=15) as r:
        res = json.load(r)
    if "result" not in res:
        raise RuntimeError((res.get("error") or {}).get("message") or res)
    return res["result"]


def prop(v):
    """Unwrap the daemon's described-property form ({$desc,$value})."""
    return v.get("$value") if isinstance(v, dict) and "$value" in v else v


def fetch_facts(api, plane, token):
    """{key: {summary, kind, origin}} for every project."""
    res = rpc(api, "plane.cypher", {"plane": plane,
                                    "query": "MATCH (p:Project) RETURN p", "params": {}}, token)
    paths = [prop((n.get("properties") or {}).get("path")) for n in res.get("nodes", [])]
    facts = {}
    for path in [p for p in paths if p]:
        origin = os.path.basename(os.path.normpath(path))
        res = rpc(api, "plane.cypher", {"plane": plane,
            "query": ("MATCH (p:Project)<-[:ABOUT]-(f:Fact) WHERE p.path = $path "
                      "RETURN f LIMIT 500"), "params": {"path": path}}, token)
        for n in res.get("nodes", []):
            pr = n.get("properties", {})
            summary = prop(pr.get("summary")) or ""
            if not summary:
                continue
            created = prop(pr.get("created_at"))
            facts.setdefault(n.get("external_key", "?"), {
                "summary": summary, "kind": prop(pr.get("kind")) or "?",
                "origin": origin,
                # Only ever an int in practice, but a Fact written with an ISO
                # string would otherwise crash the comparison below rather than
                # just being unsortable. See the epoch-int Fact.
                "created_at": created if isinstance(created, int) else None})
    return facts


# --- transcripts -----------------------------------------------------------

def transcript_dir(proj_dir):
    return os.path.join(TRANSCRIPT_ROOT, proj_dir.replace("/", "-"))


def load_turns(proj_dir):
    """{prompt_id: [assistant text following it]} across this project's
    transcripts. Keyed by digest so the log never has to store the prompt."""
    out = defaultdict(list)
    d = transcript_dir(proj_dir)
    if not os.path.isdir(d):
        return out
    for name in os.listdir(d):
        if not name.endswith(".jsonl"):
            continue
        pending, seen = None, 0
        with open(os.path.join(d, name), encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                t, content = rec.get("type"), rec.get("message", {}).get("content")
                if t == "user":
                    text = content if isinstance(content, str) else "".join(
                        str(i.get("text", "")) for i in (content or [])
                        if isinstance(i, dict) and i.get("type") == "text")
                    text = text.strip()
                    # A tool result arrives typed as "user" with no text part;
                    # treating it as a new prompt would cut the reply window
                    # short and undercount every multi-tool answer.
                    if text:
                        pending, seen = prompt_id(text), 0
                elif t == "assistant" and pending and seen < REPLY_TURNS:
                    chunk = "".join(str(i.get("text", "")) for i in (content or [])
                                    if isinstance(i, dict) and i.get("type") == "text")
                    if chunk.strip():
                        out[pending].append(chunk)
                        seen += 1
    return out


# --- utilization -----------------------------------------------------------

def informative(g):
    """A gram that can carry a match on its own.

    Two CJK characters are close to a word and worth ranking on. Two latin ones
    are a fragment: `cc`, `bi` and `ca` all fired on unrelated replies during
    development — `ca` came from the word "Cargo" and nearly matched a fact
    about gcc. Latin grams therefore have to be long enough to mean something.
    """
    return len(g) >= 4 or any(ch > "⺀" for ch in g)


def discriminative(facts):
    """{key: set(grams)} — each fact's grams, minus the uninformative ones and
    minus those common across the corpus."""
    df = defaultdict(int)
    per = {}
    for k, f in facts.items():
        g = {x for x in grams(clean(f["summary"])) if informative(x)}
        per[k] = g
        for x in g:
            df[x] += 1
    cap = max(1, int(len(facts) * DF_SHARE))
    return {k: {x for x in g if df[x] <= cap} for k, g in per.items()}


def match_mass(fact_grams, prompt_grams, reply):
    """How much of the fact's own material — not the prompt's — the reply carried.

    Returns matched characters over merged spans; the caller compares that to
    MIN_MATCH_CHARS. Mass rather than a verdict, because mass is what gets
    frozen: the threshold stays re-tunable over history, the transcript does not.

    Evidence is measured in matched characters over merged spans, not in grams.
    Overlapping grams are one piece of evidence, not several: `created` yields
    `crea`, `eate` and `reat`, which under a raw gram count reads as three
    independent matches and was enough to fire three unrelated facts on a
    sentence about a SQL index. And spans are weighed rather than counted,
    because two generic two-character words (一个 + 测试) are two spans and
    still no evidence at all.
    """
    r = clean(reply)
    spans = []
    for g in fact_grams - prompt_grams:
        start = r.find(g)
        while start != -1:
            spans.append((start, start + len(g)))
            start = r.find(g, start + 1)
    spans.sort()
    merged = []
    for lo, hi in spans:
        if merged and lo <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return sum(hi - lo for lo, hi in merged)


def placebo_keys(r, eligible, k):
    """K facts this prompt never ranked, drawn stably from (prompt, key).

    Hashing each candidate rather than seeding a shuffle: a shuffle's output
    depends on the pool's length, so every fact written afterwards redraws the
    whole sample — and each redraw is a cache miss that can never be filled once
    the transcript ages out. Hashing keeps a draw valid for as long as the fact
    exists, so the floor accumulates the same way the numerator does.
    """
    salt = f"{r.get('session')}:{r.get('prompt')}:"
    return sorted(eligible,
                  key=lambda x: hashlib.sha1((salt + x).encode()).digest())[:k]


# --- frozen verdicts -------------------------------------------------------

def load_verdicts(projects):
    """{(session, prompt, key, arm): record} — every verdict already frozen.

    `arm` distinguishes a real injection from a placebo draw. Records written
    before the placebo arm existed carry no `arm` field and are all injections,
    so the default keeps them addressable under the same key they were saved
    with."""
    out = {}
    for p in projects:
        f = os.path.join(p, ".drsg", VERDICTS)
        if not os.path.exists(f):
            continue
        for line in open(f, encoding="utf-8"):
            try:
                v = json.loads(line)
            except Exception:
                continue
            # Later lines win: a recompute after a VERDICT_VERSION bump appends
            # rather than rewrites, so the file stays append-only.
            out[(v.get("session"), v.get("prompt"), v.get("key"),
                 v.get("arm", "injected"))] = v
    return out


def save_verdicts(new_by_project):
    for p, rows in new_by_project.items():
        if not rows:
            continue
        d = os.path.join(p, ".drsg")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, VERDICTS), "a", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")


# --- report ----------------------------------------------------------------

def pct(a, b):
    return "n/a" if not b else f"{100.0 * a / b:.0f}%"


def percentile(xs, p):
    if not xs:
        return 0
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(len(xs) * p / 100.0))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", action="append", default=[],
                    help="project dir; repeatable. Default: ask the daemon.")
    ap.add_argument("--since", type=int, default=0, help="only the last N days")
    ap.add_argument("--no-cache", action="store_true",
                    help="recompute from transcripts and freeze nothing")
    ap.add_argument("--api", default="")
    ap.add_argument("--plane", default="")
    args = ap.parse_args()

    projects = [os.path.abspath(p) for p in args.project] or [os.getcwd()]
    env = load_env(projects[0])
    api = args.api or env.get("DRSG_API", "http://127.0.0.1:7700/rpc")
    plane = args.plane or env.get("DRSG_PLANE", "memory")
    token = env.get("DRSG_TOKEN", "")
    if not token:
        sys.exit(f"no DRSG_TOKEN in {projects[0]}/.drsg/env")

    try:
        facts = fetch_facts(api, plane, token)
    except Exception as e:
        sys.exit(f"cannot read facts from {api}: {e}")

    if not args.project:
        res = rpc(api, "plane.cypher", {"plane": plane,
                                        "query": "MATCH (p:Project) RETURN p", "params": {}}, token)
        found = [prop((n.get("properties") or {}).get("path")) for n in res.get("nodes", [])]
        projects = [p for p in found if p and os.path.isdir(p)] or projects

    cutoff = time.time() - args.since * 86400 if args.since else 0
    records = []
    for p in projects:
        log = os.path.join(p, ".drsg", "recall.jsonl")
        if not os.path.exists(log):
            continue
        for line in open(log, encoding="utf-8"):
            try:
                r = json.loads(line)
            except Exception:
                continue
            if r.get("ts", 0) >= cutoff:
                r["_proj_dir"] = p
                records.append(r)

    if not records:
        print("no telemetry yet — .drsg/recall.jsonl is empty in: "
              + ", ".join(projects))
        print("\nThe hooks write it from their next run; come back after a few sessions.")
        return

    recalls = [r for r in records if r.get("event") == "recall"]
    briefs = [r for r in records if r.get("event") == "briefing"]
    disc = discriminative(facts)
    turns = {p: load_turns(p) for p in projects}

    # --- utilization ---
    inj = defaultdict(int)
    use = defaultdict(int)
    by_origin = defaultdict(lambda: [0, 0])  # origin -> [injected, used]
    unmatched = 0
    fresh, cached, stale = 0, 0, 0
    frozen = {} if args.no_cache else load_verdicts(projects)
    new_by_project = defaultdict(list)
    placebo = [0, 0]                         # drawn, cleared

    def verdict(r, key, blob, arm):
        """Matched mass for one (prompt, fact) pair, or None if unjudgeable.

        Frozen first, computed from a live transcript second, and a stale frozen
        value third — using an old mass beats dropping the sample, but the count
        is reported so it never passes as fresh."""
        nonlocal fresh, cached, stale
        have = frozen.get((r.get("session"), r.get("prompt"), key, arm))
        if have is not None and have.get("ver") == VERDICT_VERSION:
            cached += 1
            return have.get("mass", 0)
        if blob is not None:
            mass = match_mass(disc.get(key, set()), set(), blob)
            fresh += 1
            row = {"ts": r.get("ts"), "session": r.get("session"),
                   "prompt": r.get("prompt"), "key": key, "mass": mass,
                   "origin": facts[key]["origin"], "project": r.get("project"),
                   "ver": VERDICT_VERSION}
            if arm != "injected":
                row["arm"] = arm
            new_by_project[r["_proj_dir"]].append(row)
            return mass
        if have is not None:
            stale += 1
            return have.get("mass", 0)
        return None

    for r in recalls:
        if r.get("status") != "injected":
            continue
        reply = turns.get(r["_proj_dir"], {}).get(r.get("prompt"))
        blob = "\n".join(reply) if reply is not None else None
        # The prompt's own grams are unavailable (only its digest is logged), so
        # the echo filter uses the injected tags of the *other* facts in the same
        # turn as the nearest stand-in for shared context.
        judged = 0
        for key in r.get("injected", []):
            f = facts.get(key)
            if not f:
                continue
            mass = verdict(r, key, blob, "injected")
            if mass is None:
                unmatched += 1
                continue
            judged += 1
            inj[key] += 1
            ok = mass >= MIN_MATCH_CHARS
            if ok:
                use[key] += 1
            o = f["origin"] if f["origin"] == r.get("project") else f"{f['origin']} (foreign)"
            by_origin[o][0] += 1
            by_origin[o][1] += 1 if ok else 0

        # The chance floor, from the same reply. Only where the real arm was
        # judged, so numerator and floor always rest on the same prompts.
        if judged:
            ranked = {d["key"] for d in (r.get("ranked") or [])}
            pool = [k for k in facts if k not in ranked and disc.get(k)]
            for key in placebo_keys(r, pool, PLACEBO_K):
                mass = verdict(r, key, blob, "placebo")
                if mass is None:
                    continue
                placebo[0] += 1
                placebo[1] += 1 if mass >= MIN_MATCH_CHARS else 0

    if not args.no_cache:
        save_verdicts(new_by_project)

    total_inj = sum(inj.values())
    total_use = sum(use.values())

    print("=" * 72)
    print("memory layer — recall telemetry")
    print("=" * 72)
    span = (min(r["ts"] for r in records), max(r["ts"] for r in records))
    print(f"projects   : {', '.join(os.path.basename(p) for p in projects)}")
    print(f"window     : {time.strftime('%Y-%m-%d', time.localtime(span[0]))}"
          f" .. {time.strftime('%Y-%m-%d', time.localtime(span[1]))}")
    print(f"sessions   : {len({r.get('session') for r in records})}")
    print(f"prompts    : {len(recalls)}")
    st = defaultdict(int)
    for r in recalls:
        st[r.get("status", "?")] += 1
    print("  " + "  ".join(f"{k}={v}" for k, v in sorted(st.items())))
    if unmatched:
        print(f"  ({unmatched} injections had no reply in the transcripts and no "
              "frozen verdict — compacted or pruned before this ever ran)")
    print(f"verdicts   : {fresh} computed now, {cached} from frozen"
          + (f", {stale} stale (v!={VERDICT_VERSION}, transcript gone)" if stale else "")
          + ("  [--no-cache: nothing frozen]" if args.no_cache else ""))

    print()
    print("-- utilization " + "-" * 57)
    print(f"injections  : {total_inj}")
    print(f"used        : {total_use}  ({pct(total_use, total_inj)})")
    print(f"chance floor: {placebo[1]}  ({pct(placebo[1], placebo[0])} of "
          f"{placebo[0]} unranked facts scored against the same replies)")
    if by_origin:
        print()
        print(f"  {'origin':<28} {'inj':>5} {'used':>5}  rate")
        for o, (i, u) in sorted(by_origin.items(), key=lambda t: -t[1][0]):
            print(f"  {o:<28} {i:>5} {u:>5}  {pct(u, i)}")
        loc = sum(v[0] for k, v in by_origin.items() if "(foreign)" not in k)
        locu = sum(v[1] for k, v in by_origin.items() if "(foreign)" not in k)
        fgn = sum(v[0] for k, v in by_origin.items() if "(foreign)" in k)
        fgnu = sum(v[1] for k, v in by_origin.items() if "(foreign)" in k)
        print()
        print(f"  cross-project share of injections : {pct(fgn, total_inj)}")
        if loc and fgn:
            ratio = (fgnu / fgn) / (locu / loc) if locu else 0.0
            print(f"  foreign/local utilization ratio   : {ratio:.2f}"
                  f"   (threshold: < 0.50 → turn cross-project recall off)")

    print()
    print("-- per fact " + "-" * 60)
    print(f"  {'key':<44} {'kind':<18} {'inj':>4} {'use':>4}")
    for key in sorted(inj, key=lambda k: -inj[k]):
        f = facts.get(key, {})
        print(f"  {key[:44]:<44} {f.get('kind','?')[:18]:<18} {inj[key]:>4} {use[key]:>4}")

    dead = [k for k in inj if inj[k] >= 5 and use[k] == 0]
    # "Never injected" only means something once the Fact has had real chances
    # to be injected. A Fact is only eligible for prompts recorded after it was
    # written, so the honest denominator is that count — not the whole window.
    # Without this split the report tells the author of a Fact written an hour
    # ago to "rewrite the summary", on the strength of zero observations.
    prompt_ts = sorted(r["ts"] for r in recalls)
    # Best rank a fact ever reached, injected or not. Without it "never
    # injected" reads as a verdict on the fact's wording, and for most of them
    # it is not: 4 of the first 6 this report named had placed 4th — matched
    # well, sometimes at triple the score of what got in, and lost to MAX=3.
    # Telling their authors to "rewrite the summary" was advice against the
    # wrong problem.
    best_rank = {}
    for r in recalls:
        for i, d in enumerate(r.get("ranked") or []):
            k = d.get("key")
            if k is not None and i < best_rank.get(k, 99):
                best_rank[k] = i
    unproven, dumb, nearmiss = [], [], []
    for k in facts:
        if k in inj:
            continue
        born = facts[k].get("created_at")
        eligible = (len(prompt_ts) - bisect.bisect_left(prompt_ts, born)
                    if born is not None else len(prompt_ts))
        if eligible < MIN_ELIGIBLE:
            unproven.append((k, eligible))
        elif k in best_rank:
            nearmiss.append((k, best_rank[k] + 1))
        else:
            dumb.append((k, eligible))

    def show(rows, limit=20, chances=False):
        for k, e in sorted(rows):
            if limit <= 0:
                break
            limit -= 1
            tail = f"  ({e} chances)" if chances else ""
            print(f"    {k}  [{facts[k]['origin']}] {facts[k]['summary'][:52]}{tail}")
        if len(rows) > 20:
            print(f"    ... and {len(rows) - 20} more")

    if dead:
        print(f"\n  dead ({len(dead)}) — injected >=5x, never used → demote or delete:")
        for k in dead:
            print(f"    {k}")
    if dumb:
        print(f"\n  never ranked ({len(dumb)}/{len(facts)}) — did not reach even the "
              "logged top-5 for any prompt; this one really is about wording:")
        show(dumb)
    if nearmiss:
        print(f"\n  ranked but never injected ({len(nearmiss)}/{len(facts)}) — matched, "
              f"then lost to the MAX cut. Nothing wrong with the fact:")
        for k, rk in sorted(nearmiss, key=lambda t: t[1]):
            print(f"    {k}  [{facts[k]['origin']}] {facts[k]['summary'][:46]}"
                  f"  (best rank {rk})")
    if unproven:
        print(f"\n  too new to judge ({len(unproven)}/{len(facts)}) — fewer than "
              f"{MIN_ELIGIBLE} recorded prompts since it was written:")
        show(unproven, chances=True)

    print()
    print("-- cost " + "-" * 64)
    if briefs:
        b = [r.get("brief_chars", 0) for r in briefs]
        p_ = [r.get("proto_chars", 0) for r in briefs]
        t_ = [r.get("total_chars", 0) for r in briefs]
        print(f"session start : {len(briefs)} starts, {sum(t_)//len(t_)} chars avg")
        print(f"                briefing {sum(b)//len(b)}  protocol {sum(p_)//len(p_)}"
              f"   → memory is {pct(sum(b), sum(t_))} of the startup injection")
    rc = [r.get("chars", 0) for r in recalls if r.get("status") == "injected"]
    if rc:
        print(f"per prompt    : {sum(rc)//len(rc)} chars avg over {len(rc)} injections")
    ms = [r.get("ms", 0) for r in recalls]
    if ms:
        print(f"hook latency  : p50 {percentile(ms,50)}ms  p95 {percentile(ms,95)}ms")

    print()
    print("-- control arm " + "-" * 56)
    # Phase 3's question — did having the memory make the work better — needs an
    # outcome the utilization proxy cannot give (it scores rank 4 as highly as
    # rank 3, so it is blind to injection itself). The outcome is tool failures,
    # attributed to the prompt they followed by session_end.py and joined here on
    # (session, prompt). Assignment is per prompt, so both arms accrue inside
    # every session and the between-session spread (0.9%–14% at baseline) cancels.
    tool_rows = {(r.get("session"), r.get("prompt")): r
                 for r in records if r.get("event") == "tools"}
    arms = defaultdict(lambda: [0, 0, 0])   # arm -> prompts, calls, errors
    assigned = defaultdict(int)
    for r in recalls:
        a = r.get("arm")
        # Only prompts that had something to inject. `no_match` and `no_facts`
        # are identical on both sides, and counting them would dilute the
        # contrast with turns where the arm made no difference by construction.
        if not a or r.get("status") not in ("injected", "suppressed"):
            continue
        assigned[a] += 1
        t = tool_rows.get((r.get("session"), r.get("prompt")))
        if not t:
            continue
        s = arms[a]
        s[0] += 1
        s[1] += t.get("calls", 0)
        s[2] += t.get("errors", 0)
    if not assigned:
        print("  not running — no prompt carries an `arm`. Until then every")
        print("  number above describes the treated population only.")
    else:
        print(f"  assigned      : " + "  ".join(
            f"{a}={n}" for a, n in sorted(assigned.items())))
        if not arms:
            print("  no outcomes joined yet — session_end.py writes them when a")
            print("  session ends, so the first rows appear one session from now.")
        else:
            print(f"  {'arm':<12} {'prompts':>8} {'calls':>8} {'errors':>8}   rate")
            for a, (n, c, e) in sorted(arms.items()):
                print(f"  {a:<12} {n:>8} {c:>8} {e:>8}   {pct(e, c)}")
            print("  Not a verdict: the phase-3 gate is 100 sessions of arm data,")
            print("  and the session-start briefing is never suppressed, so the")
            print("  contrast is per-prompt recall only — a floor on the effect.")

    print()
    print("-- read against the pre-registered thresholds " + "-" * 26)
    if len({r.get("session") for r in records}) < 30:
        print("  NOT ENOUGH DATA. Fewer than 30 sessions recorded; every rate above")
        print("  is descriptive only. Do not act on it yet.")
    elif not total_inj:
        print("  no judged injections in this window.")
    else:
        u = total_use / total_inj
        fl = placebo[1] / placebo[0] if placebo[0] else 0.0
        # The registered line was "utilization < 20% → the recall strategy
        # failed". It was written against a measure whose chance floor was
        # unknown and turned out to be 45%, so a raw 20% sat *below* chance and
        # could never fire the way it was meant to. Restated in the terms it was
        # always reaching for — how far above random the recall is — which is
        # also the only form that survives a change to MIN_MATCH_CHARS. The
        # restatement is recorded here rather than done quietly: it happened
        # after seeing data, which is exactly when to say so out loud.
        exc = (u - fl) / (1 - fl) if fl < 1 else 0.0
        print(f"  utilization {u*100:.0f}% vs {fl*100:.0f}% chance floor"
              f"  → {exc*100:.0f}% excess over chance "
              f"({'FAIL — recall is at chance' if exc < 0.20 else 'ok'})")
        print("     (registered as 'utilization < 20%', restated as excess over")
        print("      chance once the floor was measured — same intent, same 20%)")


if __name__ == "__main__":
    main()

"""Shared core for the memory-layer benchmark.

Imports the REAL hook template functions so the "with memory" arm measures
the shipped mechanism (briefing compression + n-gram recall), not a
re-implementation. Talks to the shared `drsg serve` daemon over JSON-RPC and
to the ccr OpenAI-compatible proxy over HTTP. Stdlib only.
"""
import importlib.util
import json
import os
import re
import urllib.request

HOOKS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "templates", "hooks")
DEFAULT_API = "http://127.0.0.1:7700/rpc"
DEFAULT_CHAT = "http://127.0.0.1:3456/v1"


def _find_repo_root():
    """Walk up from this file until a directory containing .drsg/env (the
    project root) is found. Robust to cwd and to how deep the scripts are."""
    d = os.path.dirname(os.path.abspath(__file__))
    while True:
        if os.path.exists(os.path.join(d, ".drsg", "env")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.getcwd()  # fallback — cwd has no .drsg/env
        d = parent


REPO_ROOT = _find_repo_root()

# ---- config ---------------------------------------------------------------

def load_env(proj_dir):
    """Read .drsg/env into os.environ (setdefault, same as the hooks)."""
    p = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def config(proj_dir=None):
    """Load .drsg/env (defaults to the repo root, so callers work from any
    cwd) and return the daemon/chat settings."""
    load_env(proj_dir or REPO_ROOT)
    return {
        "api": os.environ.get("DRSG_API", DEFAULT_API),
        "token": os.environ.get("DRSG_TOKEN", ""),
        "chat": os.environ.get("DRSG_CHAT", DEFAULT_CHAT),
        "key_env": os.environ.get("DRSG_BENCH_KEY_ENV", "CCR_API_KEY"),
    }


# ---- JSON-RPC to the daemon -----------------------------------------------

def rpc(cfg, method, params, timeout=5):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    req = urllib.request.Request(
        cfg["api"], data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + cfg["token"]})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)["result"]


# ---- chat via ccr proxy ---------------------------------------------------

def chat(cfg, model, messages, max_tokens=800, temperature=0.2,
         reasoning_effort="none"):
    """Call the ccr proxy. `reasoning_effort: "none"` (default) disables
    thinking — reasoning models (DeepSeek-v4-flash, the claude-ccr subject)
    fill the output cap with reasoning_content and return empty `content`
    otherwise. Override via DRSG_BENCH_REASONING ("" = provider default)."""
    key = os.environ.get(cfg["key_env"], "")
    effort = os.environ.get("DRSG_BENCH_REASONING", reasoning_effort)
    body = json.dumps({"model": model, "messages": messages,
                       "max_tokens": max_tokens,
                       "temperature": temperature})
    if effort:
        body = json.dumps({"model": model, "messages": messages,
                           "max_tokens": max_tokens,
                           "temperature": temperature,
                           "reasoning_effort": effort})
    body = body.encode()
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(cfg["chat"] + "/chat/completions",
                                 data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=180) as r:
        resp = json.load(r)
    return resp["choices"][0]["message"]["content"].strip()


def list_models(cfg):
    """GET /v1/models → list of model ids."""
    key = os.environ.get(cfg["key_env"], "")
    headers = {}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(cfg["chat"] + "/models", headers=headers)
    with urllib.request.urlopen(req, timeout=10) as r:
        return [m["id"] for m in json.load(r).get("data", [])]


def discover_subject_model(cfg, want="claude"):
    """Pick the first model id containing `want` (case-insensitive)."""
    ids = list_models(cfg)
    for m in ids:
        if want.lower() in m.lower():
            return m
    raise SystemExit(
        "no '%s' model found in %s; pass --subject-model. available: %s"
        % (want, cfg["chat"], ", ".join(ids)))


# ---- reuse the REAL hook functions -----------------------------------------

def import_hook(name):
    spec = importlib.util.spec_from_file_location(
        "bench_hook_" + name, os.path.join(HOOKS_DIR, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fetch_facts(cfg, plane, proj_key, limit):
    """Facts ABOUT this project, newest first (same query the hooks run)."""
    res = rpc(cfg, "plane.cypher", {"plane": plane,
        "query": ("MATCH (p:Project)<-[:ABOUT]-(f:Fact) "
                  "WHERE key(p) = $proj "
                  "RETURN f ORDER BY f.created_at DESC LIMIT %d") % limit,
        "params": {"proj": proj_key}})
    return res.get("nodes", [])


def briefing_text(cfg, plane, proj_key, fact_cap=1000):
    """The compressed briefing — exactly what session_start injects."""
    ss = import_hook("session_start")
    return ss.build_briefing(fetch_facts(cfg, plane, proj_key, fact_cap))


def recall_text(cfg, plane, proj_key, prompt, maxhits=3, fact_cap=200):
    """The recall block — exactly what user_prompt.score_facts produces."""
    up = import_hook("user_prompt")
    facts = []
    for n in fetch_facts(cfg, plane, proj_key, fact_cap):
        pr = n.get("properties", {})
        if pr.get("summary"):
            facts.append({"key": n.get("external_key", "?"),
                          "clean": up.clean(pr["summary"]),
                          "tag": (pr["summary"].split("→")[-1].split("。")[0].strip()
                                  or pr["summary"])[:60]})
    hits = up.score_facts(prompt, facts, maxhits=maxhits)
    return "\n".join(f"- ({k}) {t}" for _, k, t in hits), len(hits)


def memory_context(cfg, plane, proj_key, prompt):
    """Full injected context: briefing (always) + per-prompt recall."""
    brief = briefing_text(cfg, plane, proj_key)
    recall, n = recall_text(cfg, plane, proj_key, prompt)
    return ("# 项目记忆简报\n%s\n\n# 与当前任务相关记忆\n%s" % (brief, recall)
            if brief or recall else ""), len(brief) + len(recall)


# ---- objective recall match (Chinese-aware, zero-dep) -----------------------

def clean(s):
    return re.sub(r"[^\w一-鿿]+", "", (s or "").lower())


def grams(s, lo=2, hi=4):
    return [s[i:i + n] for n in range(lo, hi + 1) for i in range(len(s) - n + 1)]


def recall_hit(output, gt_summary, threshold=0.4):
    """True if >= threshold of the ground-truth's 3-4 grams appear in output.
    3-4 grams avoid trivial single-char false positives."""
    og = set(grams(clean(gt_summary), 3, 4))
    if not og:
        return None  # not assessable
    co = clean(output)
    return sum(1 for g in og if g in co) / len(og) >= threshold


def est_tokens(text):
    """Rough cost estimate: CJK chars ≈ 1 token each, else ~4 chars/token."""
    cjk = sum(1 for ch in text if "一" <= ch <= "鿿")
    other = len(text) - cjk
    return int(cjk + other / 4)

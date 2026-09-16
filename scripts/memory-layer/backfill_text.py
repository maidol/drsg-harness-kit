#!/usr/bin/env python3
"""Keep `Fact.text` (= summary + detail) in sync, and declare its BM25 index.

`text` is a *derived* property: the write-memory protocol never mentions it and
models never write it. That is the point. A field the protocol asks for is a
field that gets silently omitted — six empty Fact shells came from exactly that
failure mode — so this field is maintained by code and self-heals instead.

Why it exists at all: the Chinese (jieba) analyzer landed after the plane was
created, and `ensure_keyword_index` refuses to change the language of an
existing index while the API offers no way to drop one. `Fact.summary` is
therefore permanently pinned to the English analyzer, which tokenizes a Chinese
clause as one term. Indexing a derived property is the only way to get a
Chinese index over the summary text without rewriting what `summary` means.

Idempotent: run it as often as you like. Reports what it changed.
"""
import json
import os
import sys
import urllib.request

API = os.environ.get("DRSG_API", "http://127.0.0.1:7700/rpc")
PLANE = os.environ.get("DRSG_PLANE", "memory")


def load_token(proj_dir):
    tok = os.environ.get("DRSG_TOKEN", "")
    if tok:
        return tok
    p = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line.startswith("DRSG_TOKEN="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def rpc(method, params, token):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}).encode()
    req = urllib.request.Request(
        API, data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]


def derive(props):
    """The indexed text of a Fact. Summary first — it is the densest line, and
    the one the briefing and the injected block both show."""
    s = (props.get("summary") or "").strip()
    d = (props.get("detail") or "").strip()
    return (s + "\n" + d).strip() if d else s


def sync(token, verbose=True):
    """Declare the index, then repair every Fact whose `text` is stale.

    Returns (declared, updated, skipped). Safe to call from a hook: it only
    writes the Facts that are actually wrong, so the steady-state cost is one
    read query.
    """
    declared = False
    have = rpc("plane.indexes", {"plane": PLANE}, token)
    if not any(i["label"] == "Fact" and i["property"] == "text"
               for i in have.get("keyword", [])):
        rpc("index.ensure", {"plane": PLANE, "label": "Fact", "property": "text",
                             "kind": "keyword", "language": "chinese"}, token)
        declared = True

    res = rpc("plane.cypher", {"plane": PLANE,
                               "query": "MATCH (f:Fact) RETURN f",
                               "params": {}}, token)
    updated, skipped = [], 0
    for n in res.get("nodes", []):
        props = n.get("properties") or {}
        want = derive(props)
        if not want:
            skipped += 1  # a Fact with no summary is invisible to recall anyway
            continue
        if props.get("text") == want:
            continue
        rpc("node.update", {"plane": PLANE, "id": n["id"], "set": {"text": want}}, token)
        updated.append(n.get("external_key", n["id"]))
    if verbose:
        print(f"index declared={declared}  updated={len(updated)}  "
              f"already-current={len(res.get('nodes', [])) - len(updated) - skipped}  "
              f"no-summary={skipped}")
        for k in updated[:10]:
            print("  +", k)
        if len(updated) > 10:
            print(f"  … and {len(updated) - 10} more")
    return declared, updated, skipped


if __name__ == "__main__":
    proj = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    tok = load_token(proj)
    if not tok:
        sys.exit("no DRSG_TOKEN (env or .drsg/env)")
    sync(tok)

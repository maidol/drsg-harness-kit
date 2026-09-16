#!/usr/bin/env python3
"""L3 memory distillation (see docs/memory-layer-setup.md §3.8).

Reads the tail of a session transcript and, via the shared daemon's
`digest.run` + `digest.write`, distills it into graph entities in the memory
plane. Runs detached (spawned by session_end.py) so session end is never
blocked on the LLM call.

Disabled unless `DRSG_L3_CHAT` names a chat provider: one of `digest.run`'s
preset names (openai / deepseek / qwen / ollama), or — on a daemon whose
`digest.run` accepts one — a raw OpenAI-compatible base URL. Provider keys
live server-side: this script only talks to /rpc, and the daemon reads the
key from its own environment. Nothing here ever carries a key.

Usage: l3_digest.py <session_id> <transcript_path>
"""
import json
import os
import sys
import time
import urllib.request

# --- Configuration --------------------------------------------------------
# All values are read from the environment (populated from .drsg/env by
# load_env) with project-agnostic defaults. install.sh writes .drsg/env.
API = os.environ.get("DRSG_API", "http://127.0.0.1:7700/rpc")
PLANE = os.environ.get("DRSG_PLANE", "memory")
# L3 is opt-in: empty CHAT disables it, and that is the default. Each of the
# three settings below is sent only when set, so an unset one leaves the
# provider's own default in place rather than overriding it with nothing.
CHAT = os.environ.get("DRSG_L3_CHAT", "")
# Env var name the *daemon* reads the key from. Unset → the preset's own
# (OPENAI_API_KEY for `openai`, and so on); required for a raw base URL.
KEY_ENV = os.environ.get("DRSG_L3_KEY_ENV", "")
MODEL = os.environ.get("DRSG_L3_MODEL", "")
# Reasoning models can fill the output cap with thinking tokens and truncate
# the JSON digest.run has to parse; "none" turns reasoning off where the
# provider understands it. Unset → provider default.
REASONING_EFFORT = os.environ.get("DRSG_L3_REASONING", "")
# Enough conversation tail to distill something meaningful, without spending
# provider credits on trivia.
TAIL_CHARS = 4000
MIN_CHARS = 300
RPC_TIMEOUT = 180  # digest.run is an LLM call; detached, so budget is loose


# Project root = <proj>/.claude/hooks → up three levels.
DRSG_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), ".drsg")


def log(msg):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    os.makedirs(DRSG_DIR, exist_ok=True)
    with open(os.path.join(DRSG_DIR, "l3.log"), "a", encoding="utf-8") as f:
        f.write(f"{stamp} {msg}\n")


def load_env(proj_dir):
    p = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())


def rpc(method, params, token):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        API, data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=RPC_TIMEOUT) as r:
        return json.load(r)["result"]


def node_key(n):
    """The external key of a proposed node. `key` is what digest.run emits;
    `external_key` is accepted too so a hand-built payload still works."""
    return n.get("key") or n.get("external_key")


def node_labels(n):
    """The labels of a proposed node. digest.run emits a single `label`;
    `labels` is accepted too so a hand-built payload still works."""
    ls = n.get("labels") or ([n["label"]] if n.get("label") else [])
    return [str(x) for x in ls]


# The memory layer's own structural labels. The distiller reads prose, so a
# transcript saying "the current project" comes back as a Project node — with
# no `path`, indistinguishable from a real one to `MATCH (p:Project)`, and
# impossible to attribute afterwards. These two labels are the layer's to
# write; entities extracted from a conversation get any other label they like.
RESERVED_LABELS = {"Project", "Session"}


def collision_guard(nodes, edges, token):
    """Never write a node whose external_key already exists in the plane.

    digest.run with link:false proposes EVERY entity as new, so a proposed key
    can collide with the Project node or a previous digest run — that is how a
    `Key` node with external_key "dr-strange" shadowed the Project node and
    silently broke every hooks' `WHERE key(p) = $proj` query. Drop colliding
    keys (and dedupe within the proposal), plus any edges whose endpoints were
    dropped. Returns (kept_nodes, kept_edges).

    The key field is `key`, NOT `external_key`: digest.run returns DigestNode
    { key, label, props } (dr-strange crates/dr-strange-llm/src/digest.rs:171).
    Reading the wrong field is not a near miss — every node yields None, the
    guard checks nothing, finds no collisions, logs nothing, and passes the
    entire proposal through. It did exactly that from the day it was written
    until 2026-08-06, when run web-1786035246 wrote five duplicate keys, two of
    them Project nodes; that shadowed the real ones and silently killed both
    the SessionStart briefing and every key-filtered recall. A guard that
    scans nothing reports "all clear", so `no keys at all` is now a hard stop
    rather than a pass.
    """
    # 1) dedupe within the proposal (first occurrence wins)
    seen, uniq = set(), []
    for n in nodes:
        k = node_key(n)
        if k:
            if k in seen:
                continue
            seen.add(k)
        uniq.append(n)
    nodes = uniq
    # Reverse assertion: a proposal with nodes but no keys means the payload
    # shape changed under us. Refuse rather than wave everything through —
    # waving through is what cost us the two Project nodes.
    if nodes and not seen:
        raise ValueError(
            f"collision guard read no key from any of {len(nodes)} proposed nodes "
            f"(fields seen: {sorted({k for n in nodes for k in n})[:8]}) — "
            "digest.run's payload shape changed; refusing to write unchecked")
    # 1b) drop anything claiming one of the layer's own structural labels.
    # A key collision is not required for this to hurt: a *new* key carrying
    # the Project label is enough to pollute every `MATCH (p:Project)`.
    reserved = [n for n in nodes if RESERVED_LABELS.intersection(node_labels(n))]
    if reserved:
        log(f"collision guard: dropping {len(reserved)} proposed node(s) claiming "
            f"a reserved label: "
            f"{', '.join(sorted(str(node_key(n)) for n in reserved)[:8])}")
        nodes = [n for n in nodes
                 if not RESERVED_LABELS.intersection(node_labels(n))]
    # 2) drop keys that already exist in the plane. node.get returns result=null
    # for a missing key (success, not an error) — so a node is "present" only
    # when result carries a node id.
    exists = set()
    for k in seen:
        try:
            res = rpc("node.get", {"plane": PLANE, "key": k}, token)
            if res and res.get("id") is not None:
                exists.add(k)
        except Exception:
            pass  # RPC error → assume the key is free
    if exists:
        log(f"collision guard: skipping {len(exists)} proposed node(s) with "
            f"existing keys: {', '.join(sorted(exists)[:8])}")
    kept = [n for n in nodes if node_key(n) not in exists]
    # 3) drop edges whose endpoints were dropped (endpoints are keys or ids)
    kept_refs = ({node_key(n) for n in kept if node_key(n)}
                 | {n.get("id") for n in kept if n.get("id")})
    kept_edges = [e for e in edges
                  if (e.get("src") in kept_refs and e.get("dst") in kept_refs)]
    return kept, kept_edges


def extract_tail(transcript_path):
    """Last meaningful conversation text: user prompts + assistant text replies,
    tool noise dropped."""
    msgs = []
    if not transcript_path or not os.path.exists(transcript_path):
        return ""
    with open(transcript_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            t = d.get("type")
            content = d.get("message", {}).get("content")
            if t == "user":
                if isinstance(content, str):
                    msgs.append("USER: " + content.strip())
                elif isinstance(content, list):
                    for item in content:
                        if isinstance(item, dict) and item.get("type") == "text":
                            msgs.append("USER: " + str(item.get("text", "")).strip())
            elif t == "assistant":
                for item in content or []:
                    if isinstance(item, dict) and item.get("type") == "text":
                        msgs.append("ASSISTANT: " + str(item.get("text", "")).strip())
    return "\n".join(msgs)[-TAIL_CHARS:]


def main():
    if len(sys.argv) < 3:
        log("usage: l3_digest.py <session_id> <transcript_path>")
        sys.exit(0)
    sid, transcript_path = sys.argv[1], sys.argv[2]
    # Proj dir = two levels up from this hook (hooks live in <proj>/.claude/hooks).
    proj_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    load_env(proj_dir)
    # Re-read config after load_env populated os.environ (install.sh's .drsg/env).
    global API, PLANE, CHAT, KEY_ENV, MODEL, REASONING_EFFORT
    API = os.environ.get("DRSG_API", API)
    PLANE = os.environ.get("DRSG_PLANE", PLANE)
    CHAT = os.environ.get("DRSG_L3_CHAT", CHAT)
    KEY_ENV = os.environ.get("DRSG_L3_KEY_ENV", KEY_ENV)
    MODEL = os.environ.get("DRSG_L3_MODEL", MODEL)
    REASONING_EFFORT = os.environ.get("DRSG_L3_REASONING", REASONING_EFFORT)

    token = os.environ.get("DRSG_TOKEN", "")
    if not token:
        log("no DRSG_TOKEN; abort")
        sys.exit(0)
    if not CHAT:
        log("L3 disabled (no DRSG_L3_CHAT); abort")
        sys.exit(0)
    # No local key check: digest.run passes only the key NAME (key_env) and the
    # daemon reads the key VALUE from ITS OWN env. A missing key surfaces as a
    # visible digest.run error in l3.log rather than a silent pre-abort.

    text = extract_tail(transcript_path)
    if len(text) < MIN_CHARS:
        log(f"transcript tail too short ({len(text)} chars); skip")
        sys.exit(0)

    log(f"distilling {sid} tail ({len(text)} chars) via {CHAT} {MODEL}".rstrip())
    params = {"plane": PLANE, "text": text, "chat": CHAT,
              "no_embed": True, "link": False,
              "source": f"session:{sid}", "mode": "coarse"}
    # Send only what was configured. An empty `model`/`key_env` would override
    # the provider preset's own defaults with nothing, and `reasoning_effort`
    # is understood only by a daemon whose digest.run takes it (see the README's
    # prerequisites) — omitted, it costs nothing on either.
    for name, value in (("model", MODEL), ("key_env", KEY_ENV),
                        ("reasoning_effort", REASONING_EFFORT)):
        if value:
            params[name] = value
    try:
        prop = rpc("digest.run", params, token)
    except Exception as e:
        log(f"digest.run failed: {e}")
        sys.exit(0)

    nodes = prop.get("nodes", [])
    edges = prop.get("edges", [])
    report = prop.get("report", {})
    log(f"digest.run → {len(nodes)} nodes, {len(edges)} edges "
        f"(chat_requests={report.get('chat_requests')}, in={report.get('input_tokens')}, out={report.get('output_tokens')})")
    if not nodes:
        log("no nodes extracted; skip write")
        sys.exit(0)

    # Collision guard: digest.run with link:false proposes everything as new,
    # which can collide with existing keys (see collision_guard docstring).
    try:
        nodes, edges = collision_guard(nodes, edges, token)
    except Exception as e:
        log(f"collision guard failed: {e}")
        sys.exit(0)
    if not nodes:
        log("collision guard dropped all nodes; skip write")
        sys.exit(0)

    try:
        w = rpc("digest.write", {"plane": PLANE, "nodes": nodes, "edges": edges}, token)
        log(f"digest.write done: {w}")
    except Exception as e:
        log(f"digest.write failed: {e}")
        sys.exit(0)


if __name__ == "__main__":
    main()

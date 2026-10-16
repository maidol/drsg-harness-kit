#!/usr/bin/env bash
# Hook upkeep that fails without an error: l3_digest reading the wrong
# project's env, commands_run keeping raw whitespace, a briefing blanked by one
# failed read, and heal_text pulling every Fact on every session start.
set -u
unset DRSG_EVENT_LANES DRSG_L3_MODEL
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOKS="$REPO/tools/templates/hooks"
T="$(mktemp -d)"
DAEMON=""
trap '[ -n "$DAEMON" ] && { kill "$DAEMON" 2>/dev/null; wait "$DAEMON" 2>/dev/null; }; rm -rf "$T"' EXIT

BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
[ -x "$BIN" ] || BIN="$(command -v drsg || true)"
API=""
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
  PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  # exec: $! must be drsg itself, or the trap's kill reaches only the subshell
  # and drsg outlives the suite.
  (cd "$T" && DRSG_TOKEN=test-upkeep exec "$BIN" --db "$T/m.drsg" serve --addr "127.0.0.1:$PORT" >"$T/daemon.log" 2>&1) &
  DAEMON=$!
  for _ in $(seq 1 50); do
    curl -sf -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { API="http://127.0.0.1:$PORT/rpc"; break; }
    sleep 0.2
  done
fi

NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
python3 - "$HOOKS" "$T" "$API" <<'PY'
import importlib.util, json, os, shutil, sys

hooks, tmp, api = sys.argv[1], sys.argv[2], sys.argv[3]
ran = ok = 0


def check(name, cond, got=None):
    global ran, ok
    ran += 1
    ok += bool(cond)
    print("%s %s%s" % ("ok  " if cond else "FAIL", name, "" if cond else ": %r" % (got,)))


def load(name, path):
    sys.path.insert(0, os.path.dirname(path))
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    sys.path.pop(0)
    return mod


# 1. l3_digest reads <project>/.drsg/env, three levels above the hook.
proj = os.path.join(tmp, "proj")
hook_dir = os.path.join(proj, ".claude", "hooks")
os.makedirs(hook_dir)
os.makedirs(os.path.join(proj, ".drsg"))
for name in ("l3_digest.py", "secret_redact.py", "drsg_hook_common.py"):
    shutil.copy(os.path.join(hooks, name), hook_dir)
with open(os.path.join(proj, ".drsg", "env"), "w") as f:
    f.write("DRSG_L3_MODEL=from-project-env\n")
l3 = load("l3_under_test", os.path.join(hook_dir, "l3_digest.py"))
sys.argv = ["l3_digest.py", "sid", os.path.join(tmp, "no-transcript.jsonl")]
try:
    l3.main()
except SystemExit:
    pass
check("l3_digest loads <project>/.drsg/env", os.environ.get("DRSG_L3_MODEL") == "from-project-env",
      os.environ.get("DRSG_L3_MODEL"))

# 2. session_end folds whitespace runs in commands_run.
tr = os.path.join(tmp, "se.jsonl")
with open(tr, "w") as f:
    f.write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Bash",
         "input": {"command": "ls   -la\tsrc\nfoo"}}]}}) + "\n")
se = load("se_under_test", os.path.join(hooks, "session_end.py"))
cmds = list(se.mine(tr)[1])
check("session_end folds whitespace in commands_run", cmds == ["ls -la src foo"], cmds)

# 3. ensure_briefing keeps the stored briefing when the Fact read fails.
ss = load("ss_under_test", os.path.join(hooks, "session_start.py"))
updates = []


def brief_rpc(method, params, token):
    if method == "node.get":
        return {"properties": {"briefing": "KEEP", "briefing_count": 3, "briefing_sig": "x"}}
    if method == "node.update":
        updates.append(params)
        return {}
    raise RuntimeError("daemon hiccup")


ss.rpc = brief_rpc
got = ss.ensure_briefing("/p/a", 1, "t")
check("ensure_briefing keeps stored briefing on read failure", got == ("KEEP", 3), got)
check("ensure_briefing writes nothing on read failure", updates == [], updates)

# 3b. BUG-07: the briefing keeps the newest Facts within DRSG_BRIEFING_MAX_CHARS
# (default 2000; 0 = no limit) and counts the older ones it left out.
ssb = load("ss_brief", os.path.join(hooks, "session_start.py"))
facts = [{"external_key": "k%03d" % i,
          "properties": {"kind": "gotcha" if i % 3 else "decision",
                         "summary": "第%03d条结论用于测试简报上限的足够长摘要" % i}}
         for i in range(120)]                      # newest first, as all_facts returns
check("briefing default cap is 2000", ssb.BRIEFING_MAX_CHARS == 2000, ssb.BRIEFING_MAX_CHARS)
capped = ssb.build_briefing(facts, 2000)
check("capped briefing fits 2000 chars", len(capped) <= 2000, len(capped))
last = capped.splitlines()[-1]
check("capped briefing names how many older Facts were left out",
      last.startswith("（另有 ") and last.endswith(" 条较早的 Fact 未列出）"), last)
shown = sum(int(n) for n in __import__("re").findall(r"×(\d+):", capped))
check("left-out count matches", ("另有 %d 条" % (120 - shown)) in last, (shown, last))
check("capped briefing keeps the newest and drops the oldest",
      "第000条" in capped and "第119条" not in capped)
full = ssb.build_briefing(facts, 0)
check("cap 0 means no limit", "第119条" in full and "未列出" not in full and len(full) > 2000, len(full))
small = facts[:10]
check("under the cap the briefing is unchanged",
      ssb.build_briefing(small, 2000) == ssb.build_briefing(small, 0))

stored_updates = []


def cap_rpc(method, params, token):
    if method == "node.get":
        return {"properties": {"briefing": "OLD", "briefing_count": 10,
                               "briefing_sig": ssb.fact_sig(small), "briefing_cap": 0}}
    if method == "node.update":
        stored_updates.append(params["set"])
        return {}
    raise AssertionError(method)


ssb.rpc = cap_rpc
ssb.all_facts = lambda proj, token: small
ssb.BRIEFING_MAX_CHARS = 2000
got = ssb.ensure_briefing("/p/a", 1, "t")
check("a changed cap rebuilds a briefing whose Facts did not change",
      len(stored_updates) == 1 and stored_updates[0].get("briefing_cap") == 2000 and got[0] != "OLD",
      stored_updates)

# 4. heal_text fetches only Facts lacking `text` (real daemon decides IS NULL).
if not api:
    print("SKIP heal_text: no drsg binary (set DRSG_MEM_BIN)")
else:
    ss = load("ss_heal", os.path.join(hooks, "session_start.py"))
    os.environ["DRSG_API"] = api
    ss.API, ss.PLANE = api, "memory"
    tok = "test-upkeep"
    ss.rpc("plane.create", {"name": "memory"}, tok)
    for key, props in [("f-ok", {"summary": "a", "text": "a"}),
                       ("f-missing", {"summary": "b", "detail": "d"}),
                       ("f-ok2", {"summary": "c", "detail": "e", "text": "c\ne"})]:
        ss.rpc("node.create", {"plane": "memory", "key": key, "labels": ["Fact"],
                               "properties": props}, tok)
    fetched = []
    real = ss.rpc

    def counting(method, params, token):
        res = real(method, params, token)
        if method == "plane.cypher":
            fetched.append(len(res.get("nodes", [])))
        return res

    ss.rpc = counting
    healed = ss.heal_text(tok)
    ss.rpc = real
    res = real("plane.cypher", {"plane": "memory",
               "query": "MATCH (f:Fact) WHERE key(f) = 'f-missing' RETURN f", "params": {}}, tok)
    text = (res["nodes"][0].get("properties") or {}).get("text")
    check("heal_text repairs the Fact lacking text", healed == 1 and text == "b\nd", (healed, text))
    check("heal_text fetches only Facts lacking text", fetched == [1], fetched)
    check("heal_text second run finds nothing", ss.heal_text(tok) == 0)

print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ok == ran else 1)
PY

#!/usr/bin/env bash
# Synthetic contract tests for four recall/dispatch fixes (2026-10-07):
#   R1 analyze_recall.py reads the control arm with a within-session permutation test
#   R2 both read hooks drop Facts whose valid_to has passed; the briefing notices a swap
#   R3 user_prompt.py injects at most 2 Facts per prompt
#   R4 event.py advises verb=impact on a handoff that changes a judgment
# No daemon, transcript or real Fact is touched; every RPC is stubbed below.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
export REPO

RAN=0
OK=0
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
  fi
}

# --- R1: control arm -------------------------------------------------------
# 20 prompts per session, 3 of them suppressed (15%). "null": 150 sessions,
# 4 calls per prompt, both arms fail 4% of calls - no effect, but the small arm
# shows a 0% rate far more often, which is what fooled the old sign test
# (p=0.0007 on this exact fixture). "effect": 60 sessions, 10 calls per prompt,
# treated fails 12%, suppressed 2%.
arm_out() {
  python3 - "$1" <<'PY' 2>&1
import importlib.util, os, random, sys
spec = importlib.util.spec_from_file_location("ar", os.path.join(os.environ["REPO"], "tools", "analyze_recall.py"))
ar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ar)
mode = sys.argv[1]
rng = random.Random(11)
records, recalls = [], []
sessions, calls = (150, 4) if mode == "null" else (60, 10)
for s in range(sessions):
    for i in range(20):
        arm = "suppressed" if i % 7 == 3 else "treated"
        p = 0.04 if mode == "null" else (0.12 if arm == "treated" else 0.02)
        err = sum(rng.random() < p for _ in range(calls))
        sid, pid = "s%d" % s, "p%d" % i
        recalls.append({"event": "recall", "session": sid, "prompt": pid, "arm": arm,
                        "status": "suppressed" if arm == "suppressed" else "injected"})
        records.append({"event": "tools", "session": sid, "prompt": pid,
                        "calls": calls, "errors": err, "infra": 0})
ar.control_arm(records, recalls)
PY
}
p_of() { echo "$1" | grep 'paired all errors' | grep -o 'permutation p=[0-9.]*' | cut -d= -f2; }
NULL_OUT="$(arm_out null)"
EFF_OUT="$(arm_out effect)"
# Fixture sanity, green before and after the fix: the null really is skewed.
check r1_null_fixture_skewed "$(echo "$NULL_OUT" | grep 'paired all errors' | python3 -c "import re,sys; m=re.search(r'worse in (\d+), better in (\d+)', sys.stdin.read()); print('yes' if m and int(m.group(1)) - int(m.group(2)) >= 30 else 'no')")" yes
check r1_reports_permutation_p "$(echo "$NULL_OUT" | grep -c 'paired all errors.*permutation p=')" 1
check r1_no_sign_test_left "$(echo "$NULL_OUT" | grep -c 'sign test')" 0
check r1_null_not_significant "$(python3 -c "import sys; print('yes' if sys.argv[1] and float(sys.argv[1]) >= 0.05 else 'no')" "$(p_of "$NULL_OUT")")" yes
check r1_effect_significant "$(python3 -c "import sys; print('yes' if sys.argv[1] and float(sys.argv[1]) < 0.05 else 'no')" "$(p_of "$EFF_OUT")")" yes

# --- R2: retired Facts -----------------------------------------------------
R2="$(python3 - <<'PY' 2>&1
import importlib.util, os, time
def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(os.environ["REPO"], "tools", "templates", "hooks", name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
now = int(time.time())
facts = [("k-live", None), ("k-future", now + 3600), ("k-retired", now - 10), ("k-junk", "not-a-time")]

up = load("user_prompt")
def up_rpc(method, params, token):
    q = params.get("query", "")
    if "RETURN p\"" in q or q.endswith("RETURN p"):
        return {"nodes": [{"properties": {"path": "/p/a"}}]}
    cols = ["p.path", "key(f)", "f.summary", "f.created_at"] + (["f.valid_to"] if "valid_to" in q else [])
    rows = []
    for i, (k, vt) in enumerate(facts):
        row = ["/p/a", k, "summary of " + k, now - i, vt]
        rows.append(row[:len(cols)])
    return {"columns": cols, "rows": rows}
up.rpc = up_rpc
print("up_keys=" + ",".join(sorted(f["key"] for f in up.fetch_facts("t"))))

ss = load("session_start")
def ss_rpc(method, params, token):
    return {"nodes": [{"external_key": k, "properties": {"summary": k, "valid_to": vt}} for k, vt in facts]}
ss.rpc = ss_rpc
print("ss_keys=" + ",".join(sorted(n["external_key"] for n in ss.all_facts("/p/a", "t"))))

# Briefing built from {k-live, k-old}; now k-old is retired and k-future is
# new — same count, different Facts. The briefing must be rebuilt.
updates = []
live = [{"external_key": "k-live", "properties": {"summary": "a"}},
        {"external_key": "k-future", "properties": {"summary": "b"}}]
old = [{"external_key": "k-live"}, {"external_key": "k-old"}]
sig = ss.fact_sig(old) if hasattr(ss, "fact_sig") else ""
def brief_rpc(method, params, token):
    if method == "node.get":
        return {"properties": {"briefing_count": 2, "briefing_sig": sig, "briefing": "STALE"}}
    if method == "node.update":
        updates.append(params["set"])
        return {}
    return {"nodes": live}
ss.rpc = brief_rpc
brief, n = ss.ensure_briefing("/p/a", 1, "t")
print("rebuilt=" + ("yes" if updates and "STALE" not in brief else "no"))
PY
)"
check r2_user_prompt_drops_retired "$(echo "$R2" | grep '^up_keys=' | cut -d= -f2)" "k-future,k-junk,k-live"
check r2_session_start_drops_retired "$(echo "$R2" | grep '^ss_keys=' | cut -d= -f2)" "k-future,k-junk,k-live"
check r2_briefing_rebuilt_on_swap "$(echo "$R2" | grep '^rebuilt=' | cut -d= -f2)" yes

# --- R3: at most 2 injected ------------------------------------------------
R3="$(python3 - <<'PY' 2>&1
import importlib.util, os
spec = importlib.util.spec_from_file_location("up", os.path.join(os.environ["REPO"], "tools", "templates", "hooks", "user_prompt.py"))
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)
facts = [{"key": "k%d" % i, "origin": "a", "clean": up.clean("代理判断粘性取号 %d" % i), "tag": "t"} for i in range(5)]
print("hits=%d log_rank_above=%s" % (len(up.score_facts("粘性取号缺代理判断", facts)), up.LOG_RANK > up.MAX))
PY
)"
check r3_two_hits "$(echo "$R3" | grep -o 'hits=[0-9]*')" hits=2
check r3_log_rank_still_above "$(echo "$R3" | grep -o 'log_rank_above=[A-Za-z]*')" log_rank_above=True
check r3_guides_say_two "$(cat "$REPO/docs/en/src/drsg-harness-kit-guide.md" "$REPO/docs/zh/src/drsg-harness-kit-guide.md" "$REPO/docs/en/src/images/memory-sharing-flow.svg" "$REPO/docs/zh/src/images/memory-sharing-flow.svg" | grep -c '≤4')" 0

# --- R4: verb advice -------------------------------------------------------
R4="$(python3 - <<'PY' 2>&1
import importlib.util, os
spec = importlib.util.spec_from_file_location("ev", os.path.join(os.environ["REPO"], "tools", "event.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)
adv = getattr(ev, "verb_advice", lambda *a: "MISSING")
print("ctx=" + ("impact" if "verb=impact" in adv("handoff", "粘性取号缺代理判断", ["x.y"], "context") else "none"))
print("nosym=" + ("impact" if "verb=impact" in adv("handoff", "Pause 期间探测要被丢弃", [], None) else "none"))
print("impact=" + repr(adv("handoff", "粘性取号缺代理判断", ["x.y"], "impact")))
print("notice=" + repr(adv("notice", "验收通过：守卫逻辑正确", ["x.y"], "context")))
print("plain=" + repr(adv("handoff", "README 补两行用法", ["x.y"], "context")))
out = ev.report({"key": "evt-x", "hint": "", "plane": None, "unverified": None,
                 "advice": "advice: use verb=impact"}, "/p/b")
print("report=" + ("yes" if out.splitlines()[-1] == "advice: use verb=impact" else "no"))
# post() must hand the advice to report(); no daemon, the two writes are stubbed.
ev.rpc = lambda method, params, token: {"id": 1} if method == "node.create" else {"ok": True}
try:
    res = ev.post("/p/b", 1, "Pause 期间探测要被丢弃", "handoff", "", "a", "t")
    print("post=" + ("impact" if "verb=impact" in (res.get("advice") or "") else "none"))
except Exception as e:
    print("post=error:" + type(e).__name__)
PY
)"
check r4_context_gets_advice "$(echo "$R4" | grep '^ctx=' | cut -d= -f2)" impact
check r4_no_symbols_gets_advice "$(echo "$R4" | grep '^nosym=' | cut -d= -f2)" impact
check r4_impact_is_quiet "$(echo "$R4" | grep '^impact=' | cut -d= -f2)" "''"
check r4_notice_is_quiet "$(echo "$R4" | grep '^notice=' | cut -d= -f2)" "''"
check r4_unrelated_is_quiet "$(echo "$R4" | grep '^plain=' | cut -d= -f2)" "''"
check r4_report_prints_advice "$(echo "$R4" | grep '^report=' | cut -d= -f2)" yes
check r4_post_carries_advice "$(echo "$R4" | grep '^post=' | cut -d= -f2)" impact

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

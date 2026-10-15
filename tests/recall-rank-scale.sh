#!/usr/bin/env bash
# rank_facts cost must not grow with the prompt: a long pasted prompt used to
# walk every prompt gram against every Fact and blow the hook's 10 s timeout,
# which drops recall for that prompt without a word. The ranking itself must
# not change: scores are checked against the original formula.
# No daemon is touched; rank_facts is pure.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOOK="${USER_PROMPT_HOOK:-$HERE/../tools/templates/hooks/user_prompt.py}"
pass=0; fail=0
check() {
  if [ "$1" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $2"; fi
}

# 1. Same scores as the original formula, on a mixed CJK/ASCII corpus.
out="$(python3 - <<'PY' 2>&1
import importlib.util, math, os, random
spec = importlib.util.spec_from_file_location("up", os.environ["HOOK"])
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)
rng = random.Random(7)
alpha = [chr(c) for c in range(0x4e00, 0x4e00 + 40)] + list("abcdefghij")
def text(n):
    return "".join(rng.choice(alpha) for _ in range(n))
facts = [{"key": "k%d" % i, "clean": up.clean(text(rng.randint(5, 120)))} for i in range(60)]
def reference(prompt):
    pgrams = set(up.grams(up.clean(prompt)))
    df = {}
    for f in facts:
        for g in set(up.grams(f["clean"])):
            df[g] = df.get(g, 0) + 1
    n = len(facts)
    out = {}
    for f in facts:
        sc = sum(math.log(1.0 + n / df.get(g, n)) for g in pgrams if g in f["clean"])
        if sc > 0:
            out[f["key"]] = sc
    return out
bad = 0
for _ in range(30):
    prompt = text(rng.randint(2, 300))
    want = reference(prompt)
    got = {f["key"]: sc for sc, f in up.rank_facts(prompt, facts)}
    if set(got) != set(want) or any(abs(got[k] - want[k]) > 1e-9 for k in want):
        bad += 1
    scores = [sc for sc, _ in up.rank_facts(prompt, facts)]
    if scores != sorted(scores, reverse=True):
        bad += 1
print("mismatches=%d" % bad)
PY
)"
[ "$out" = "mismatches=0" ] && check ok "" || check bad "rank_facts differs from the original formula: $out"

# 2. A 40 000-character prompt over 378 Facts (the size of the shared memory
# plane on 2026-10-15) ranks in under 3 s. The original loop took about 11 s.
out="$(timeout 30 python3 - <<'PY' 2>&1
import importlib.util, os, random, time
spec = importlib.util.spec_from_file_location("up", os.environ["HOOK"])
up = importlib.util.module_from_spec(spec)
spec.loader.exec_module(up)
rng = random.Random(1)
alpha = [chr(c) for c in range(0x4e00, 0x4e00 + 3000)] + list("abcdefghijklmnopqrstuvwxyz0123456789")
def text(n):
    return "".join(rng.choice(alpha) for _ in range(n))
facts = [{"key": "k%d" % i, "clean": up.clean(text(150))} for i in range(378)]
prompt = text(40000)
t = time.monotonic()
up.rank_facts(prompt, facts)
print("elapsed=%.2f" % (time.monotonic() - t))
PY
)"; rc=$?
elapsed="${out#elapsed=}"
if [ "$rc" -eq 0 ] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3.0 else 1)' "$elapsed" 2>/dev/null; then
  check ok ""
else
  check bad "40 000-character prompt took too long (rc=$rc): $out"
fi

echo "PASS $pass/$((pass + fail))"
[ "$fail" -eq 0 ]

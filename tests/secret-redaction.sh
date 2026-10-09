#!/usr/bin/env bash
# Contract tests for tools/templates/hooks/secret_redact.py and the three exits
# that use it: l3_digest (text sent to an LLM provider), session_end
# (commands_run on the Session node) and event.py post (summary/ref of a to-do).
# Every secret below is fake and assembled at run time, so this file itself
# never carries a secret-shaped literal for the path & token gate to flag.
# The last line is "PASS n/n" only when every check ran.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HOOKS="$REPO/tools/templates/hooks"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

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

# One python run per group; each prints "name=value" lines that check() reads.
pyrun() {  # $1 = file to exec with REPO/HOOKS/T in the environment
  REPO="$REPO" HOOKS="$HOOKS" T="$T" python3 "$1" 2>&1
}
val() {  # $1 = output, $2 = name
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}

# Fake values. Built from pieces so no line of this file matches a secret shape.
cat > "$T/fakes.py" <<'PY'
A = "A1b2C3d4"
FAKES = {
    "openai":    "s" + "k-" + "proj-" + A * 3,
    "anthropic": "s" + "k-" + "ant-api03-" + A * 3,
    "github":    "gh" + "p_" + A * 4,
    "aws":       "AK" + "IA" + "QWERTYUIOPASDFGH",
    "jwt":       "ey" + "JhbGciOiJIUzI1NiJ9." + "ey" + "JzdWIiOiJmYWtlIn0." + "c2lnbmF0dXJlZmFrZQ",
}
PEM = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\n" + A * 4 + "\n-----END OPENSSH " + "PRIVATE KEY-----"
PW = "hunter2" + A
PY

# ---- 1. the redactor itself ------------------------------------------------
cat > "$T/t1.py" <<'PY'
import importlib.util, os, sys
sys.path.insert(0, os.environ["T"])
from fakes import FAKES, PEM, PW
spec = importlib.util.spec_from_file_location("secret_redact", os.path.join(os.environ["HOOKS"], "secret_redact.py"))
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)
for name, v in FAKES.items():
    out, kinds = sr.redact("export X=" + v + " done")
    print("%s=%s" % (name, "masked" if v not in out and "<hidden>" in out and kinds else "LEAKED"))
out, _ = sr.redact("key:\n" + PEM + "\nafter")
print("pem=%s" % ("masked" if "PRIVATE KEY" not in out and "after" in out else "LEAKED"))
out, _ = sr.redact("DB_PASSWORD=" + PW)
print("password=%s" % ("masked" if PW not in out and out.startswith("DB_PASSWORD=") else "LEAKED"))
out, _ = sr.redact("postgres://admin:" + PW + "@db.example.com:5432/app")
print("url=%s" % ("masked" if PW not in out and "admin:" in out and "@db.example.com" in out else "LEAKED"))
tok = "Q" * 24
out, _ = sr.redact("Authorization: Bearer " + tok)
print("bearer=%s" % ("masked" if tok not in out else "LEAKED"))
keep = ["Authorization: Bearer <token>", "DRSG_TOKEN=$TOKEN", "OPENAI_API_KEY=$KEY_2", "max_tokens: 1024",
        "input_tokens=123456", "token=<hidden>", "commit " + "0123456789abcdef" * 2 + "01234567",
        "task-orchestrator-for-everything"]
print("placeholders=%s" % ("kept" if all(sr.redact(k) == (k, []) for k in keep) else "CHANGED"))
PY
O="$(pyrun "$T/t1.py")"
for n in openai anthropic github aws jwt pem password url bearer; do
  check "redact masks $n" "$(val "$O" $n)" masked
done
check "redact leaves placeholders, SHAs and token counts alone" "$(val "$O" placeholders)" kept

# ---- 2. l3_digest: what leaves for the LLM provider ------------------------
cat > "$T/t2.py" <<'PY'
import importlib.util, json, os, shutil, sys
sys.path.insert(0, os.environ["T"])
from fakes import FAKES
T = os.environ["T"]
v = FAKES["openai"]
tr = os.path.join(T, "l3.jsonl")
with open(tr, "w") as f:
    f.write(json.dumps({"type": "user", "message": {"content": "my key is " + v}}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "noted"}]}}) + "\n")
def load(path):
    sys.path.insert(0, os.path.dirname(path))
    spec = importlib.util.spec_from_file_location("l3_%d" % len(sys.path), path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    sys.path.pop(0)
    return m
m = load(os.path.join(os.environ["HOOKS"], "l3_digest.py"))
out = m.extract_tail(tr)
print("tail=%s" % ("masked" if v not in out and "<hidden>" in out and "noted" in out else "LEAKED"))
# Fail closed: a deployment missing secret_redact.py sends nothing at all.
# Laid out like a project (<proj>/.claude/hooks) because l3.log is written
# three directories up from the hook, into <proj>/.drsg/.
lone = os.path.join(T, "proj", ".claude", "hooks")
os.makedirs(lone)
shutil.copy(os.path.join(os.environ["HOOKS"], "l3_digest.py"), lone)
sys.modules.pop("secret_redact", None)
m2 = load(os.path.join(lone, "l3_digest.py"))
print("lone=%s" % ("empty" if m2.extract_tail(tr) == "" else "SENT"))
logf = os.path.join(T, "proj", ".drsg", "l3.log")
print("logged=%s" % ("yes" if os.path.exists(logf) and "refusing" in open(logf).read() else "no"))
PY
O="$(pyrun "$T/t2.py")"
check "l3 tail masks a key typed in the conversation" "$(val "$O" tail)" masked
check "l3 without secret_redact.py sends nothing"     "$(val "$O" lone)" empty
check "l3 says why it sent nothing"                   "$(val "$O" logged)" yes

# ---- 3. session_end: commands_run on the Session node ----------------------
cat > "$T/t3.py" <<'PY'
import importlib.util, json, os, shutil, sys
sys.path.insert(0, os.environ["T"])
from fakes import FAKES
T = os.environ["T"]
v = FAKES["openai"]
# 31 characters precede the token, so a 40-character cut taken BEFORE masking
# would leave 9 of its characters, too few for any rule to recognise.
tok = "Q1w2E3r4T5y6U7i8O9p0"
tr = os.path.join(T, "se.jsonl")
with open(tr, "w") as f:
    f.write(json.dumps({"type": "user", "message": {"content": "go"}}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "export OPENAI_API_KEY=" + v}},
        {"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": 'curl -H "Authorization: Bearer ' + tok + '"'}}]}}) + "\n")
def load(path):
    sys.path.insert(0, os.path.dirname(path))
    spec = importlib.util.spec_from_file_location("se_%d" % len(sys.path), path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    sys.path.pop(0)
    return m
m = load(os.path.join(os.environ["HOOKS"], "session_end.py"))
commands = m.mine(tr)[1]
keys = " ".join(commands)
print("prefix=%s" % ("masked" if v[:12] not in keys and tok[:6] not in keys else "LEAKED"))
print("kept=%s" % ("yes" if "export OPENAI_API_KEY=<hidden>" in keys else "no:" + keys))
lone = os.path.join(T, "lone_se")
os.makedirs(lone)
shutil.copy(os.path.join(os.environ["HOOKS"], "session_end.py"), lone)
sys.modules.pop("secret_redact", None)
m2 = load(os.path.join(lone, "session_end.py"))
print("lone=%s" % ("dropped" if not m2.mine(tr)[1] else "STORED"))
PY
O="$(pyrun "$T/t3.py")"
check "commands_run keeps no key prefix"              "$(val "$O" prefix)" masked
check "commands_run still records the masked command" "$(val "$O" kept)" yes
check "session_end without secret_redact.py drops commands" "$(val "$O" lone)" dropped

# ---- 4. event.py post: a to-do carrying a secret is refused -----------------
cat > "$T/t4.py" <<'PY'
import importlib.util, os, shutil, sys
sys.path.insert(0, os.environ["T"])
from fakes import FAKES
T = os.environ["T"]
v = FAKES["github"]
def load(path):
    spec = importlib.util.spec_from_file_location("ev_%s" % abs(hash(path)), path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m
def reached(*a, **k):
    raise RuntimeError("reached-rpc")
def attempt(ev, summary, ref=""):
    ev.rpc = reached
    try:
        ev.post("/tmp/x", 1, summary, "notice", ref, "test", "")
    except ValueError as e:
        return "refused" if "secret" in str(e) else "value-error:" + str(e)
    except RuntimeError as e:
        return "posted" if "reached-rpc" in str(e) else "runtime:" + str(e)
    return "posted"
ev = load(os.path.join(os.environ["REPO"], "tools", "event.py"))
print("summary=%s" % attempt(ev, "use token " + v))
print("ref=%s" % attempt(ev, "clean summary", "see DB_PASSWORD=" + FAKES["openai"]))
print("clean=%s" % attempt(ev, "token=<hidden> stays out of the summary"))
lone = os.path.join(T, "lone_ev")
os.makedirs(lone)
shutil.copy(os.path.join(os.environ["REPO"], "tools", "event.py"), lone)
ev2 = load(os.path.join(lone, "event.py"))
print("lone=%s" % attempt(ev2, "clean summary"))
PY
O="$(pyrun "$T/t4.py")"
check "event post refuses a secret in summary" "$(val "$O" summary)" refused
check "event post refuses a secret in ref"     "$(val "$O" ref)" refused
check "event post lets a placeholder through"  "$(val "$O" clean)" posted
check "event.py without secret_redact.py refuses" "$(val "$O" lone)" refused
check "install parks secret_redact.py with event.py" \
  "$(grep -c 'templates/hooks/secret_redact.py' "$REPO/tools/install.sh")" 1

# ---- 5. the path & token gate now knows secret shapes ----------------------
cat > "$T/t5.py" <<'PY'
import os, sys
sys.path.insert(0, os.environ["T"])
from fakes import FAKES
with open(os.path.join(os.environ["T"], "leak.txt"), "w") as f:
    f.write("OPENAI_API_KEY=" + FAKES["openai"] + "\n")
PY
pyrun "$T/t5.py" >/dev/null
python3 "$REPO/tools/check-no-machine-paths.py" "$T/leak.txt" >/dev/null 2>&1
check "path & token gate flags an API key" "$?" 1

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$RAN" -eq 22 ] && [ "$OK" -eq "$RAN" ]

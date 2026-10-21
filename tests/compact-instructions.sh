#!/usr/bin/env bash
# Managed per-project Compact instructions install, opt-out and preservation.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALL="${COMPACT_INSTALL_SOURCE:-$REPO/tools/install.sh}"
ONLY="${ONLY:-}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PROJECT="$T/project"
mkdir -p "$PROJECT"
export HOME="$T/home" XDG_CONFIG_HOME="$T/config" DRSG_MEM_DIR="$T/memory"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf 'Project-owned intro.\n\nKeep this text.\n' > "$PROJECT/CLAUDE.md"

RAN=0
OK=0
check() {
  if [ -n "$ONLY" ] && [ "$ONLY" != "$1" ]; then return; fi
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got <%s> want <%s>\n' "$1" "$2" "$3"
  fi
}
run_setup() {
  bash "$REPO/setup.sh" "$@" > "$T/setup.out" 2>&1
}

run_setup --compact-instructions "$PROJECT"
check "untracked project setup has no Git warning" "$(grep -c 'git diff' "$T/setup.out" || true)" 0
check "setup enables the managed block" "$(grep -c 'BEGIN DRSG COMPACT INSTRUCTIONS' "$PROJECT/CLAUDE.md")" 1
check "template installed verbatim and surrounding project text preserved" "$(python3 - "$PROJECT/CLAUDE.md" "$REPO/tools/templates/compact-instructions.md" <<'PY'
import sys
page, template = (open(path, "rb").read() for path in sys.argv[1:])
begin = b"<!-- BEGIN DRSG COMPACT INSTRUCTIONS -->"
end = b"<!-- END DRSG COMPACT INSTRUCTIONS -->"
start = page.find(begin)
finish = page.find(end, start + len(begin))
block = page[start + len(begin):finish]
expected = b"\n" + template.rstrip(bytes((10, 13))) + b"\n"
print("yes" if start >= 0 and finish >= 0 and block == expected and
      page.startswith(b"Project-owned intro.\n\nKeep this text.\n") else "no")
PY
)" yes
cp "$PROJECT/CLAUDE.md" "$T/first.md"
run_setup --compact-instructions "$PROJECT"
cmp -s "$PROJECT/CLAUDE.md" "$T/first.md"
check "repeated setup is idempotent" "$?" 0

run_setup --no-compact-instructions "$PROJECT"
cmp -s "$PROJECT/CLAUDE.md" "$T/first.md"
check "opt-out does not read or modify CLAUDE.md" "$?" 0
check "opt-out is keyed by realpath hash and private mode" "$(python3 - "$XDG_CONFIG_HOME" "$PROJECT" <<'PY'
import hashlib, os, stat, sys
root, project = sys.argv[1:]
marker = os.path.join(root, "drsg", "compact-instructions-opt-outs",
                      hashlib.sha256(os.path.realpath(project).encode()).hexdigest())
print("yes" if os.path.isfile(marker) and stat.S_IMODE(os.stat(marker).st_mode) == 0o600 else "no")
PY
)" yes

run_setup --compact-instructions "$PROJECT"
check "enable clears opt-out and restores one block" "$(grep -c 'BEGIN DRSG COMPACT INSTRUCTIONS' "$PROJECT/CLAUDE.md")/$(find "$XDG_CONFIG_HOME/drsg/compact-instructions-opt-outs" -type f | wc -l | tr -d ' ')" 1/0
python3 - "$PROJECT/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
needle = "逐项写".encode()
assert needle in data
open(p, "wb").write(data.replace(needle, "手动改写".encode(), 1))
PY
run_setup --compact-instructions "$PROJECT"
check "enable refreshes drifted managed body" "$(grep -c '逐项写' "$PROJECT/CLAUDE.md")" 1
git -C "$PROJECT" init -q
git -C "$PROJECT" add CLAUDE.md
bash "$INSTALL" --compact-instructions "$PROJECT" > "$T/setup.out" 2>&1
check "tracked CLAUDE.md setup warns and still succeeds" "$(grep -Fc '这一段会出现在 git diff 里，需要你自己决定要不要提交。' "$T/setup.out" || true)" 1

# Malformed/repeated markers fail closed without clobbering surrounding content.
python3 - "$PROJECT/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
needle = b"<!-- END DRSG COMPACT INSTRUCTIONS -->"
open(p, "wb").write(data.replace(needle, b"", 1))
PY
cp "$PROJECT/CLAUDE.md" "$T/malformed.md"
bash "$INSTALL" --compact-instructions "$PROJECT" > "$T/install.out" 2>&1
cmp -s "$PROJECT/CLAUDE.md" "$T/malformed.md"
check "malformed markers are reported and left untouched" "$?" 0
check "malformed marker warning is explicit" "$(grep -c 'markers are malformed or repeated' "$T/install.out")" 1

if XDG_CONFIG_HOME="$PROJECT/.config" bash "$INSTALL" --no-compact-instructions "$PROJECT" > "$T/inside.out" 2>&1; then
  inside_status=0
else
  inside_status=$?
fi
check "opt-out path inside project is rejected" "$inside_status" 1
check "inside-project rejection names the reason" "$(grep -c 'inside the project' "$T/inside.out")" 1
if [ -n "$ONLY" ] && [ "$RAN" -eq 0 ]; then
  echo "FAIL requested assertion was not run: $ONLY"
  exit 2
fi
printf 'PASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

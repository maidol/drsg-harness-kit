#!/usr/bin/env bash
# Checks for tools/claude-model-picker.sh: a fake `claude` on PATH prints the
# arguments it was started with, so no Claude Code is needed. The last line is
# "PASS n/n" only when every check ran and passed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PICKER="${PICKER:-$HERE/../tools/claude-model-picker.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'SH'
#!/usr/bin/env bash
echo "ARGS:$*"
exit "${FAKE_RC:-0}"
SH
chmod +x "$T/bin/claude"
RAN=0; OK=0
check() { RAN=$((RAN+1)); if [ "$2" = "$3" ]; then OK=$((OK+1)); echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fi; }
# $1 = what to type at the menu (printf format), rest = claude's arguments; prints the ARGS line
# (or "none" when the real claude was not started), then the function's exit code.
pick() {
  local input="$1"; shift
  local out rc
  out="$(printf "$input" | PATH="$T/bin:$PATH" CLAUDE_PICK_FORCE_TTY="${TTY:-1}" \
    bash -c '. "$1"; shift; claude "$@"' _ "$PICKER" "$@" 2>/dev/null)"
  rc=$?
  echo "${out:-none} rc=$rc"
}

# 1. the menu: a number picks from the list, put in front of the caller's own arguments
check "number picks a model"            "$(pick '2\n')"                       "ARGS:--model sonnet rc=0"
check "own arguments kept, after --model" "$(pick '1\n' --resume abc)"        "ARGS:--model opus --resume abc rc=0"
check "a prompt argument still gets the menu" "$(pick '3\n' 'fix the bug')"   "ARGS:--model haiku fix the bug rc=0"
check "Enter alone: settings default, no --model" "$(pick '\n' -c)"           "ARGS:-c rc=0"
check "a typed name goes through as is" "$(pick 'claude-opus-5-5\n')"         "ARGS:--model claude-opus-5-5 rc=0"
check "Ctrl+D starts nothing"           "$(pick '')"                          "none rc=130"
check "CLAUDE_PICK_MODELS replaces the menu" "$(CLAUDE_PICK_MODELS='fable haiku' pick '1\n')" "ARGS:--model fable rc=0"
check "claude's exit code comes back"   "$(FAKE_RC=3 pick '1\n')"             "ARGS:--model opus rc=3"

# 2. no menu: the real claude runs with the arguments unchanged (input '9\n' would show up as --model 9)
check "not a terminal"                  "$(TTY=0 pick '9\n' --resume abc)"    "ARGS:--resume abc rc=0"
check "CLAUDE_PICK_MODEL=0"             "$(CLAUDE_PICK_MODEL=0 pick '9\n')"   "ARGS: rc=0"
check "--model already given"           "$(pick '9\n' --model haiku)"         "ARGS:--model haiku rc=0"
check "--model=... already given"       "$(pick '9\n' --model=haiku -c)"      "ARGS:--model=haiku -c rc=0"
check "-p (print mode)"                 "$(pick '9\n' -p hi)"                 "ARGS:-p hi rc=0"
check "--version"                       "$(pick '9\n' --version)"             "ARGS:--version rc=0"
check "a subcommand (mcp)"              "$(pick '9\n' mcp list)"              "ARGS:mcp list rc=0"
check "a subcommand (attach)"           "$(pick '9\n' attach 1a2b)"           "ARGS:attach 1a2b rc=0"

# 3. setup.sh --model-picker adds the source line to ~/.bashrc exactly once
mkdir -p "$T/home"
for _ in 1 2; do
  HOME="$T/home" DRSG_MEM_DIR="$T/mem" CLAUDE_CONFIG_DIR="$T/claude" \
    bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint --model-picker >/dev/null 2>&1
done
check "setup adds the source line once" "$(grep -c 'claude-model-picker.sh' "$T/home/.bashrc" 2>/dev/null)" 1
check "the line sources the runtime copy" \
  "$(HOME="$T/home" PATH="$T/bin:$PATH" bash -c '. "$HOME/.bashrc"; type -t claude' 2>/dev/null)" function
mkdir -p "$T/home2"
HOME="$T/home2" DRSG_MEM_DIR="$T/mem2" CLAUDE_CONFIG_DIR="$T/claude2" \
  bash "$HERE/../setup.sh" --no-skills --no-event-poller --no-streak-hint >/dev/null 2>&1
check "without the flag ~/.bashrc is left alone" "$([ -e "$T/home2/.bashrc" ] && echo touched || echo untouched)" untouched

echo "PASS $OK/$RAN"
[ "$RAN" -eq 19 ] && [ "$OK" -eq "$RAN" ]

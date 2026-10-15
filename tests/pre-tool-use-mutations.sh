#!/usr/bin/env bash
# Targeted mutations for command segmentation, wrappers, and fail-closed behavior.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SOURCE="$REPO/tools/templates/hooks/pre_tool_use.py"
TEST="$HERE/pre-tool-use-parsing.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0

run_mutation() {
  local name="$1" only="$2" variant="$3" copy="$T/$1.py"
  if ! python3 - "$SOURCE" "$copy" "$variant" <<'PY'
import sys
source_path, output_path, variant = sys.argv[1:]
text = open(source_path, encoding="utf-8").read()
mutations = {
    "global-help": (
        '    if executable != "event.py":\n        return False, False\n',
        '    if executable != "event.py":\n        return False, False\n'
        '    if "-h" in segment or "--help" in segment:\n'
        '        return False, False\n'),
    "no-python-options": (
        '            elif option in ("-u", "-B", "-E", "-I", "-O", "-OO", "-s", "-S",\n'
        '                            "-b", "-bb", "-q", "-v", "-d", "-P", "-R"):\n'
        '                continue\n',
        '            elif option in ("-B", "-E", "-I", "-O", "-OO", "-s", "-S",\n'
        '                            "-b", "-bb", "-q", "-v", "-d", "-P", "-R"):\n'
        '                continue\n'),
    "no-bash-c": (
        '        return _analyze(shell_script, depth + 1, shell_c_depth + 1)\n',
        '        return False, False\n'),
    "no-executable-check": (
        '    if executable != "event.py":\n        return False, False\n',
        '    if "event.py" in segment and "post" in segment:\n'
        '        return False, True\n'
        '    if executable != "event.py":\n        return False, False\n'),
    "no-target-gate": (
        '        if TARGET_TEXT.search(cmd):\n            _denial(False)\n',
        '        _denial(False)\n'),
    "no-brace-group": (
        '        elif char == "{":\n',
        '        elif char == "{" and False:\n'),
    "no-bang-negation": (
        '        elif char == "!" and not "".join(current).strip() and i + 1 < len(text) and text[i + 1].isspace():\n',
        '        elif False:\n'),
    "no-process-substitution": [
        ('            if text.startswith(("<(", ">("), i):\n',
         '            if False:\n'),
        ('        elif text.startswith(("<(", ">("), i):\n',
         '        elif False:\n'),
    ],
    "no-python-optimize": (
        '            elif option in ("-u", "-B", "-E", "-I", "-O", "-OO", "-s", "-S",\n'
        '                            "-b", "-bb", "-q", "-v", "-d", "-P", "-R"):\n'
        '                continue\n',
        '            elif option in ("-u", "-B", "-E", "-I"):\n'
        '                continue\n'),
    "no-sudo-wrapper": (
        '        if name == "sudo":\n',
        '        if False:\n'),
    "no-op": (
        '"""PreToolUse guard for event CLI and user-only lease transfer commands."""',
        '"""PreToolUse guard for event CLI and user-only lease transfer commands. """'),
}
if variant not in mutations:
    raise SystemExit("unknown mutation")
edits = mutations[variant]
if isinstance(edits, tuple):
    edits = [edits]
for old, new in edits:
    if text.count(old) != 1:
        raise SystemExit("mutation target not unique: " + variant)
    text = text.replace(old, new, 1)
with open(output_path, "w", encoding="utf-8") as out:
    out.write(text)
PY
  then
    printf 'NOT RUN %s (mutation setup failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  printf '\n== %s: ONLY=%s ==\n' "$name" "$only"
  if ONLY="$only" HOOK="$copy" bash "$TEST"; then
    printf 'SURVIVED %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  else
    printf 'killed %s\n' "$name"
    KILLED=$((KILLED + 1))
  fi
}

run_mutation global-help help-in-summary global-help
run_mutation interpreter-options python-unbuffered no-python-options
run_mutation bash-c-recursion bash-c no-bash-c
run_mutation actual-executable git-commit-mention no-executable-check
run_mutation parse-target-gate heredoc-apostrophe no-target-gate
run_mutation no-brace-group brace-group no-brace-group
run_mutation no-bang-negation bang-negation no-bang-negation
run_mutation no-process-substitution process-substitution no-process-substitution
run_mutation no-python-optimize python-optimize no-python-optimize
run_mutation no-sudo-wrapper sudo no-sudo-wrapper
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop help-in-summary no-op
fi

if [ "$NOT_RUN" -gt 0 ]; then
  printf 'MUTATION NOT RUN (%d)\n' "$NOT_RUN"
  exit 1
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
printf 'ALL MUTATIONS KILLED (%d)\n' "$KILLED"

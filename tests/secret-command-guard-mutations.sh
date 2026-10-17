#!/usr/bin/env bash
# Targeted mutations for the secret command guard and the settings warning.
# Each mutant runs only its paired case in secret-command-guard.sh, first on an
# unmutated copy of the hooks directory (NOT RUN unless that passes).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SOURCE="$REPO/tools/templates/hooks"
TEST="$HERE/secret-command-guard.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0
EXPECTED=5

fresh_copy() {
  rm -rf "$1" && cp -r "$SOURCE" "$1"
}

run_mutation() {
  local name="$1" only="$2" file="$3" variant="$4" copy="$T/$1"
  if ! fresh_copy "$copy"; then
    printf 'NOT RUN %s (source copy failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  local control="$T/$name.control.out" control_rc=0
  ONLY="$only" SECRET_GUARD_HOOKS="$copy" bash "$TEST" >"$control" 2>&1 || control_rc=$?
  if [ "$control_rc" -ne 0 ] ||
     grep -Eq '^(SKIP|FAIL )|No module named|Traceback' "$control"; then
    printf 'NOT RUN %s (unmutated paired case did not pass; exit %s)\n' "$name" "$control_rc"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! fresh_copy "$copy" || ! python3 - "$copy/$file" "$variant" <<'PY'
import sys
path, variant = sys.argv[1:]
text = open(path, encoding="utf-8").read()
if variant == "no-secret-check":
    old, new = "    kinds = _secret_kinds(cmd)\n", "    kinds = []\n"
elif variant == "denial-shows-command":
    old, new = "        _secret_denial(kinds)\n", "        _secret_denial([cmd])\n"
elif variant == "drop-url-signature":
    old, new = "(?:Signature|X-Amz-Signature)", "(?:NoSuchParam)"
elif variant == "env-ignores-dollar":
    old, new = ' and not v.startswith("$")', ""
elif variant == "warning-not-wired":
    old, new = "                                  settings_secret_message(proj_dir))\n", '                                  "")\n'
elif variant == "no-op":
    old, new = "def _secret_kinds(cmd):\n", "def _secret_kinds(cmd):  # no-op\n"
else:
    raise SystemExit("unknown mutation")
if text.count(old) != 1:
    raise SystemExit("mutation target not unique")
with open(path, "w", encoding="utf-8") as out:
    out.write(text.replace(old, new))
PY
  then
    printf 'NOT RUN %s (mutation setup failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi

  printf '\n== %s: ONLY=%s ==\n' "$name" "$only"
  if ONLY="$only" SECRET_GUARD_HOOKS="$copy" bash "$TEST"; then
    printf 'SURVIVED %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  else
    printf 'killed %s\n' "$name"
    KILLED=$((KILLED + 1))
  fi
}

run_mutation no-secret-check "inline bearer is denied" pre_tool_use.py no-secret-check
run_mutation denial-shows-command "denial names the kind, not the value" pre_tool_use.py denial-shows-command
run_mutation drop-url-signature "url signature is denied" secret_redact.py drop-url-signature
run_mutation env-ignores-dollar "variable references give no warning" session_start.py env-ignores-dollar
run_mutation warning-not-wired "session start shows the warning" session_start.py warning-not-wired
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop "inline bearer is denied" pre_tool_use.py no-op
fi

if [ "$NOT_RUN" -gt 0 ] || [ "$((KILLED + SURVIVED))" -lt "$EXPECTED" ]; then
  printf 'MUTATION RESULT: NOT RUN (%d; killed %d/%d)\n' "$NOT_RUN" "$KILLED" "$EXPECTED"
  exit 2
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
printf 'MUTATION RESULT: ALL KILLED (%d)\n' "$KILLED"

#!/usr/bin/env bash
# Targeted mutations for tools/sensitive-file-read-guard.py. Each mutant runs
# only its paired case in sensitive-file-read-guard.sh, first on an unmutated
# copy (NOT RUN unless that passes), then on the mutant (must turn red).
# MUTATION_SELF_TEST=1 adds a no-op mutant that must be reported as SURVIVED.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/../tools/sensitive-file-read-guard.py"
TEST="$HERE/sensitive-file-read-guard.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0
EXPECTED=14

run_mutation() {
  local name="$1" only="$2" variant="$3" copy="$T/$1.py"
  local control="$T/$name.control.out" control_rc=0
  cp "$SOURCE" "$copy"
  ONLY="$only" SENSITIVE_GUARD="$copy" bash "$TEST" >"$control" 2>&1 || control_rc=$?
  if [ "$control_rc" -ne 0 ] || ! grep -q '^ok ' "$control"; then
    printf 'NOT RUN %s (unmutated paired case did not pass; exit %s)\n' "$name" "$control_rc"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! python3 - "$copy" "$variant" <<'PY'
import sys
path, variant = sys.argv[1:]
text = open(path, encoding="utf-8").read()
pairs = {
    "no-mcp-json": ('    if base == ".mcp.json":\n        return "mcp-config"\n', ""),
    "no-example-allow": ('{"example", "sample", "template"} & set(parts[1:])', "False"),
    "no-grep-quiet": ("def _grep_quiet(args):\n", "def _grep_quiet(args):\n    return False\n"),
    "no-pipe-split": ('"|&", "|", ";"', '"|&", ";"'),
    "no-subst": ("            out.extend(segments(text[i + 2:end], depth + 1))\n", ""),
    "read-allows": ('        return category(inp.get("file_path"))\n', "        return None\n"),
    "switch-ignored": ('    if os.environ.get("DRSG_SENSITIVE_READ_GUARD_DISABLED") == "1":\n        return\n', ""),
    "grep-pattern-as-file": ("            positional = positional[1:]  # the first one is the pattern\n", "            pass\n"),
    "redirect-target-read": ('        elif re.fullmatch(r"\\d*>>?", a):  # `> file`: written, not read\n            skip = True\n', ""),
    "jq-keys-denied": ('JQ_STRUCTURE = {"keys", "keys_unsorted", "length", "type"}', "JQ_STRUCTURE = set()"),
    "jq-path-any-field": ("        return bool(fields) and fields[-1] in JQ_SAFE_FIELDS\n", "        return bool(fields)\n"),
    "jq-path-not-allowed": ("    if JQ_PATH.fullmatch(last):\n", "    if False:\n"),
    "heredoc-body-parsed": ("                i = _skip_heredocs(text, i, heredocs)\n", "                heredocs.clear()\n"),
    "heredoc-never-ends": ("            if (line.lstrip(\"\\t\") if strip else line) == word:\n", "            if False:\n"),
    "no-op": ("def category(path):\n", "def category(path):  # no-op\n"),
}
old, new = pairs[variant]
if text.count(old) != 1:
    raise SystemExit("mutation target not unique: " + variant)
with open(path, "w", encoding="utf-8") as out:
    out.write(text.replace(old, new))
PY
  then
    printf 'NOT RUN %s (mutation setup failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ONLY="$only" SENSITIVE_GUARD="$copy" bash "$TEST" >"$T/$name.out" 2>&1; then
    printf 'SURVIVED %s (%s)\n' "$name" "$only"
    SURVIVED=$((SURVIVED + 1))
  else
    printf 'killed %s (%s)\n' "$name" "$only"
    KILLED=$((KILLED + 1))
  fi
}

run_mutation no-mcp-json "incident 10-19: cat .mcp.json || true" no-mcp-json
run_mutation no-example-allow "example env" no-example-allow
run_mutation no-grep-quiet "grep -c" no-grep-quiet
run_mutation no-pipe-split "reader after a pipe" no-pipe-split
run_mutation no-subst "echo \$(cat .mcp.json)" no-subst
run_mutation read-allows "Read .mcp.json" read-allows
run_mutation switch-ignored "disabled switch" switch-ignored
run_mutation grep-pattern-as-file "grep pattern that looks like a file" grep-pattern-as-file
run_mutation redirect-target-read "writing an env file with a heredoc" redirect-target-read
run_mutation jq-keys-denied "jq keys" jq-keys-denied
run_mutation jq-path-any-field "jq path to a header value" jq-path-any-field
run_mutation jq-path-not-allowed "jq path to server url" jq-path-not-allowed
run_mutation heredoc-body-parsed "heredoc body is data" heredoc-body-parsed
run_mutation heredoc-never-ends "command after the heredoc terminator" heredoc-never-ends
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  EXPECTED=$((EXPECTED + 1))
  run_mutation self-test-noop "incident 10-19: cat .mcp.json || true" no-op
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

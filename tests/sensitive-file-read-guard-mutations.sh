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
EXPECTED=38

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
    "jq-path-any-field": ("    return bool(named) and named[-1] in JQ_SAFE_FIELDS\n", "    return bool(named)\n"),
    "jq-path-not-allowed": ("            return _jq_path_safe(path), path\n", "            return False, path\n"),
    "jq-known-path-inherits": ("        if known:\n", "        if False:\n"),
    "jq-hooks-root": ('    if path[:1] == ("hooks",):\n', "    if False:\n"),
    "jq-hook-fields-any": ("        if all(p in JQ_HOOK_FIELDS for p in path[2:] if isinstance(p, str)):\n", "        if True:\n"),
    "jq-comma-any": ("            s, _ = self.alt(ctx)\n            safe, path = safe and s, None\n", "            s, _ = self.alt(ctx)\n            safe, path = safe or s, None\n"),
    "jq-compare-passes": ("            self.arith(ctx)\n            result = (True, None)\n", "            s, _ = self.arith(ctx)\n            result = (result[0] and s, None)\n"),
    "jq-unknown-fn-safe": ("            return ctx[0] and all(s for s, _ in args), None\n        raise _JqUnsafe()\n", "            return ctx[0] and all(s for s, _ in args), None\n        return True, None\n"),
    "jq-interp-safe": ('"interp" if "\\\\(" in lit else "str"', '"str"'),
    "heredoc-body-parsed": ("                i = _skip_heredocs(text, i, heredocs)\n", "                heredocs.clear()\n"),
    "heredoc-never-ends": ("            if (line.lstrip(\"\\t\") if strip else line) == word:\n", "            if False:\n"),
    "jq-arg-values-as-files": ("        if a in JQ_ARG2:\n", "        if False:\n"),
    "jq-undefined-var-safe": ("            if value in self.vars:\n", "            if True:\n"),
    "jq-rawfile-ignored": ("                files.extend(args[i + 2:i + 3])  # its variable stays unknown\n", "                pass\n"),
    "jq-interp-bodies-ignored": ('                safe = safe and s\n            return safe, None\n        if kind == "var":', '                pass\n            return safe, None\n        if kind == "var":'),
    "jq-entries-any-field": ('            if name == "key":\n', "            if True:\n"),
    "jq-redirect-file-ignored": ("            if stdout_target and category(a):\n                to_file = True\n", "            if stdout_target and category(a):\n                pass\n"),
    "jq-redirect-any-target": ("            if stdout_target and category(a):\n", "            if stdout_target:\n"),
    "copy-suffix-ignored": ('COPY_SUFFIX = re.compile(r"\\.(?:new|tmp|bak|orig|old|save)(?:[-.][\\w.-]*)?$")', 'COPY_SUFFIX = re.compile(r"(?!)")'),
    "jq-empty-unsafe": ('        if name in ("true", "false", "null", "empty"):\n', '        if name in ("true", "false", "null"):\n'),
    "jq-slice-end-required": ('                            if not self.peek("]"):\n                                self.pipe(ctx)\n', '                            self.pipe(ctx)\n'),
    "jq-slice-start-required": ('                        if not self.peek(":"):\n                            self.pipe(ctx)\n', '                        self.pipe(ctx)\n'),
    "jq-hook-asyncrewake-missing": ('"statusMessage", "asyncRewake"}', '"statusMessage"}'),
    "jq-section-permissions-off": ('JQ_SETTINGS_SECTIONS = {"permissions", "autoMode", "statusLine"}', 'JQ_SETTINGS_SECTIONS = {"autoMode", "statusLine"}'),
    "jq-section-automode-off": ('JQ_SETTINGS_SECTIONS = {"permissions", "autoMode", "statusLine"}', 'JQ_SETTINGS_SECTIONS = {"permissions", "statusLine"}'),
    "jq-section-statusline-off": ('JQ_SETTINGS_SECTIONS = {"permissions", "autoMode", "statusLine"}', 'JQ_SETTINGS_SECTIONS = {"permissions", "autoMode"}'),
    "jq-section-any-depth": ('        if known and path[0] in self.sections:\n', '        if known and any(p in self.sections for p in path):\n'),
    "jq-section-any-file": ('all(c == "claude-config" for c in hits)', 'True'),
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
run_mutation jq-known-path-inherits "jq string built from fields" jq-known-path-inherits
run_mutation jq-hooks-root "jq hook objects" jq-hooks-root
run_mutation jq-hook-fields-any "jq string built from fields" jq-hook-fields-any
run_mutation jq-comma-any "jq comma with an unsafe side" jq-comma-any
run_mutation jq-compare-passes "jq comparison prints only a boolean" jq-compare-passes
run_mutation jq-unknown-fn-safe "jq unknown function" jq-unknown-fn-safe
run_mutation jq-interp-safe "jq string interpolation" jq-interp-safe
run_mutation heredoc-body-parsed "heredoc body is data" heredoc-body-parsed
run_mutation heredoc-never-ends "command after the heredoc terminator" heredoc-never-ends
run_mutation jq-arg-values-as-files "jq --arg index (10-22 02:21)" jq-arg-values-as-files
run_mutation jq-undefined-var-safe "jq --rawfile variable" jq-undefined-var-safe
run_mutation jq-rawfile-ignored "jq --rawfile variable" jq-rawfile-ignored
run_mutation jq-interp-bodies-ignored "jq interpolation with an unsafe part" jq-interp-bodies-ignored
run_mutation jq-entries-any-field "jq to_entries value" jq-entries-any-field
run_mutation jq-redirect-file-ignored "jq edit written to a new file (10-22 08:01)" jq-redirect-file-ignored
run_mutation jq-redirect-any-target "jq output copied to a plain file" jq-redirect-any-target
run_mutation copy-suffix-ignored "cat a dated backup" copy-suffix-ignored
run_mutation jq-empty-unsafe "jq // empty after a safe path (10-27 08:39)" jq-empty-unsafe
run_mutation jq-slice-end-required "jq open slice then length (10-27 07:42)" jq-slice-end-required
run_mutation jq-slice-start-required "jq slice without a start then length" jq-slice-start-required
run_mutation jq-hook-asyncrewake-missing "jq hook asyncRewake (10-24 05:35)" jq-hook-asyncrewake-missing
run_mutation jq-section-permissions-off "jq permissions allow list (10-24 12:23)" jq-section-permissions-off
run_mutation jq-section-automode-off "jq autoMode allow list (10-20 17:30)" jq-section-automode-off
run_mutation jq-section-statusline-off "jq statusLine object (10-27 08:38)" jq-section-statusline-off
run_mutation jq-section-any-depth "jq permissions below the top level" jq-section-any-depth
run_mutation jq-section-any-file "jq permissions in .mcp.json" jq-section-any-file
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

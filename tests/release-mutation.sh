#!/usr/bin/env bash
# Prove selected release safety gates are independently enforced.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SOURCE="$REPO/release.sh"
KILLED=0
SURVIVED=0
NO_RUN=0
RAN=0
PENDING=()

mutate_and_check() {
  local name="$1" expected="$2" output="$TMP/$1.out" mutant="$TMP/release-$1.sh" rc=0
  if ! python3 - "$SOURCE" "$mutant" "$name" <<'PY'
import pathlib
import sys
src, dest, name = sys.argv[1:]
text = pathlib.Path(src).read_text()
mutations = {
    "branch": ('[ "$("${GIT[@]}" branch --show-current)" = main ] || stop branch \'must be on main\'', 'true'),
    "dirty": ('[ -z "$("${GIT[@]}" status --porcelain=v1 --untracked-files=normal)" ] || stop worktree \'worktree is not clean\'', 'true'),
    "version": ('version_gt "$VERSION" "$PRIOR_TAG" || stop version "must be greater than latest tag $PRIOR_TAG"', 'true'),
    "live_remote": ('"${GIT[@]}" cat-file -e "$remote_main^{commit}" 2>/dev/null || stop remote \'origin/main commit is not available locally; refusing without fetch\'\n  "${GIT[@]}" merge-base --is-ancestor "$remote_main" HEAD 2>/dev/null || stop remote \'origin/main is not an ancestor of HEAD\'', 'true'),
    "stamp": ('[ "$stamp_head" = "$HEAD_SHA" ] && [ "$stamp_tree" = "$HEAD_TREE" ] ||\n    stop stamp \'HEAD or tree differs from the successful check\'', 'true'),
    "notes_changed": ('grep -Fq "## What\'s changed" "$NOTES" || stop notes "notes must contain ## What\'s changed"', 'true'),
    "notes_verification": ('grep -Fq \'## Verification\' "$NOTES" || stop notes \'notes must contain ## Verification\'', 'true'),
    "machine_path": ("if grep -Eq '/(home|data|tmp)/' \"$NOTES\"; then", 'if false; then'),
    "gh_query": ('elif [ "$(<"$err_file")" = \'release not found\' ]; then', 'elif true; then'),
    "local_tag": ('[ "$("${GIT[@]}" rev-parse "$VERSION^{commit}")" = "$HEAD_SHA" ] || stop tag \'local tag points to a different commit\'', 'true'),
    "remote_tag": ('[ "$peeled" = "$HEAD_SHA" ] || stop tag \'remote tag points to a different commit\'', 'true'),
    "release_create": ('if [ "$RELEASE_STATE" = absent ]; then', 'if false; then'),
}
old, new = mutations[name]
if text.count(old) != 1:
    raise SystemExit(2)
pathlib.Path(dest).write_text(text.replace(old, new, 1))
PY
  then
    NO_RUN=$((NO_RUN + 1))
    printf 'NO-RUN %s (mutation anchor missing or ambiguous)\n' "$name"
    return
  fi
  if cmp -s "$SOURCE" "$mutant"; then
    NO_RUN=$((NO_RUN + 1))
    printf 'NO-RUN %s (mutant equals source)\n' "$name"
    return
  fi
  RAN=$((RAN + 1))
  # Mutants are independent (each test run makes its own temp dir), so run them in parallel and judge after `wait`.
  (
    rc=0
    RELEASE_TEST_SCRIPT="$mutant" bash "$HERE/release.sh" >"$output" 2>&1 || rc=$?
    printf '%s\n' "$rc" >"$output.rc"
  ) &
  PENDING+=("$name|$expected")
}

judge() {
  local name="$1" expected="$2" output="$TMP/$1.out"
  if [ "$(cat "$output.rc")" = 0 ]; then
    SURVIVED=$((SURVIVED + 1))
    printf 'SURVIVED %s\n' "$name"
    printf '%s\n' '--- survivor output ---'
    cat "$output"
  elif grep -Fq "not ok - $expected" "$output"; then
    KILLED=$((KILLED + 1))
    printf 'killed %s\n' "$name"
  else
    SURVIVED=$((SURVIVED + 1))
    printf 'SURVIVED %s (failed for another reason)\n' "$name"
    grep -E 'not ok|stopped at|fatal:|PASS|release v' "$output" | tail -15 || true
  fi
}

mutate_and_check branch 'non-main branch exits nonzero'
mutate_and_check dirty 'dirty worktree exits nonzero'
mutate_and_check version 'non-incrementing version exits nonzero'
mutate_and_check live_remote 'live remote main advanced exits nonzero'
mutate_and_check stamp 'mismatched check tree exits nonzero'
mutate_and_check notes_changed 'notes missing What changed heading exits nonzero'
mutate_and_check notes_verification 'notes missing Verification heading exits nonzero'
mutate_and_check machine_path 'notes machine path rejected exits nonzero'
mutate_and_check gh_query 'gh query error exits nonzero'
mutate_and_check local_tag 'local tag target mismatch is detected'
mutate_and_check remote_tag 'remote tag points elsewhere stops at tag'
mutate_and_check release_create 'publish completes end to end'

wait
for entry in "${PENDING[@]}"; do
  judge "${entry%%|*}" "${entry#*|}"
done

printf 'mutants: %d killed, %d survived, %d no-run\n' "$KILLED" "$SURVIVED" "$NO_RUN"
[ "$RAN" -eq 12 ] && [ "$SURVIVED" -eq 0 ] && [ "$NO_RUN" -eq 0 ]

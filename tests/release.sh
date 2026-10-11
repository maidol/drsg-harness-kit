#!/usr/bin/env bash
# Isolated contract tests for release.sh; every GitHub request is handled by a local stub.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
STARTED=$(date +%s)
OK=0
RAN=0
BASE="$TMP/base"
ORIGIN="$TMP/origin.git"
GH="$TMP/bin/gh"
COUNTER="$TMP/test-counter"
GH_LOG="$TMP/gh.log"
GH_STATE="$TMP/gh-state"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1)); printf 'ok - %s\n' "$1"
  else
    printf 'not ok - %s (got <%s>, want <%s>)\n' "$1" "$2" "$3" >&2
    exit 1
  fi
}

mkdir -p "$TMP/bin" "$BASE"
RELEASE_SCRIPT="${RELEASE_TEST_SCRIPT:-$REPO/release.sh}"
if [ ! -f "$RELEASE_SCRIPT" ]; then
  fail 'release.sh exists in the repository'
fi

git -C "$REPO" archive HEAD | tar -x -C "$BASE"
cp "$RELEASE_SCRIPT" "$BASE/release.sh"
cp "$HERE/release.sh" "$BASE/tests/release.sh"
cat > "$BASE/tests/test-all.sh" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'run\n' >> "${RELEASE_TEST_COUNTER:?}"
printf 'fixture test-all ran\n'
exit "${RELEASE_TEST_STATUS:-0}"
STUB
chmod +x "$BASE/tests/test-all.sh" "$BASE/release.sh" "$BASE/tests/release.sh"

cat > "$GH" <<'GHSTUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "${RELEASE_TEST_GH_LOG:?}"
git rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'fatal: not a git repository\n' >&2; exit 4; }
case "${1:-} ${2:-}" in
  'release view')
    case "$(cat "${RELEASE_TEST_GH_STATE:?}")" in
      absent) printf 'release not found\n' >&2; exit 1 ;;
      error) printf 'HTTP 503: temporarily unavailable\n' >&2; exit 1 ;;
      present) printf '{"tagName":"%s","isDraft":false,"isPrerelease":false,"assets":[{"name":"drsg-harness-kit-v1.7.1.tar.gz"},{"name":"drsg-harness-kit-v1.7.1.tar.gz.sha256"}]}\n' "${RELEASE_TEST_VERSION:-v1.7.1}" ;;
      incomplete) printf '{"tagName":"%s","isDraft":false,"isPrerelease":false,"assets":[{"name":"drsg-harness-kit-v1.7.1.tar.gz"}]}\n' "${RELEASE_TEST_VERSION:-v1.7.1}" ;;
      *) printf 'unknown fake release state\n' >&2; exit 2 ;;
    esac
    ;;
  'release create')
    printf 'present\n' > "$RELEASE_TEST_GH_STATE"
    ;;
  *) printf 'unexpected gh command: %s\n' "$*" >&2; exit 2 ;;
esac
GHSTUB
chmod +x "$GH"

git -C "$BASE" init -q -b main
git -C "$BASE" config user.name 'Release Test'
git -C "$BASE" config user.email 'release-test@example.invalid'
git -C "$BASE" add -A
git -C "$BASE" commit -qm 'fixture v1.7.0'
git -C "$BASE" tag -a v1.7.0 -m 'fixture v1.7.0'
git init -q --bare -b main "$ORIGIN"
git -C "$BASE" remote add origin "$ORIGIN"
git -C "$BASE" push -q origin main --tags
printf 'candidate\n' > "$BASE/.release-candidate"
git -C "$BASE" add .release-candidate
git -C "$BASE" commit -qm 'fixture release candidate'
git -C "$BASE" push -q origin main
BASE_SHA=$(git -C "$BASE" rev-parse HEAD)

env_for() {
  export PATH="$TMP/bin:$PATH"
  export RELEASE_TEST_COUNTER="$COUNTER"
  export RELEASE_TEST_GH_LOG="$GH_LOG"
  export RELEASE_TEST_GH_STATE="$GH_STATE"
  export RELEASE_TEST_VERSION=v1.7.1
}
new_case() {
  local name="$1"
  CASE="$TMP/$name"
  git clone -q "$ORIGIN" "$CASE"
  git -C "$CASE" config user.name 'Release Test'
  git -C "$CASE" config user.email 'release-test@example.invalid'
  : > "$COUNTER"
  : > "$GH_LOG"
  printf 'absent\n' > "$GH_STATE"
  env_for
}
notes_file() {
  NOTES="$TMP/release-notes.md"
  printf '## What\x27s changed\n\n- Test.\n\n## Verification\n\n- PASS.\n' > "$NOTES"
}
write_stamp() {
  local version="$1" commit tree stamp
  commit=$(git -C "$CASE" rev-parse HEAD)
  tree=$(git -C "$CASE" rev-parse 'HEAD^{tree}')
  stamp=$(git -C "$CASE" rev-parse --git-path "drsg-release-check-$version")
  printf 'HEAD=%s\nTREE=%s\n' "$commit" "$tree" > "$CASE/$stamp"
}
run_check() { (cd "$CASE" && ./release.sh check "$@"); }
run_publish() { (cd "$CASE" && ./release.sh publish "$1" --notes "$2"); }
expect_stop() {
  local name="$1" step="$2"; shift 2
  local out="$TMP/command.out" rc=0
  "$@" > "$out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$name exits nonzero"
  grep -Eq "^release v[^:]+: stopped at $step:" "$out" || {
    printf '%s\n' "--- $name output ---" "$(cat "$out")" >&2
    fail "$name stops at $step"
  }
  RAN=$((RAN + 1)); OK=$((OK + 1))
  printf 'ok - %s exits nonzero and stops at %s\n' "$name" "$step"
}
count_lines() { wc -l < "$1" | tr -d ' '; }

# A working test entry point must be present before any release behavior is exercised.
check 'test harness can see release.sh' "$(test -x "$REPO/release.sh" && printf yes || printf no)" yes

# The full happy path proves the package and both release assets are generated locally.
new_case happy
run_check v1.7.1 > "$TMP/happy-check.out"
grep -Fq 'release v1.7.1: check passed' "$TMP/happy-check.out" || fail 'check succeeds on clean candidate'
check 'check runs the fixture test stub once' "$(count_lines "$COUNTER")" 1
TESTS_LOG=$(sed -n 's/^tests: passed (log \(.*\))$/\1/p' "$TMP/happy-check.out")
check 'test log survives the later completeness step' "$(grep -c 'fixture test-all ran' "$TESTS_LOG" 2>/dev/null || true)" 1
notes_file
if ! run_publish v1.7.1 "$NOTES" > "$TMP/happy-publish.out"; then
  fail 'publish completes end to end'
fi
grep -Fq 'release v1.7.1: published' "$TMP/happy-publish.out" || fail 'publish completes end to end'
check 'publish creates one GitHub Release' "$(grep -c '^release create ' "$GH_LOG" || true)" 1
check 'published tag points to candidate' "$(git -C "$CASE" rev-parse 'v1.7.1^{commit}')" "$(git -C "$CASE" rev-parse HEAD)"
check 'published archive exists' "$(test -s "$CASE/dist/drsg-harness-kit-v1.7.1.tar.gz" && printf yes || printf no)" yes
check 'published checksum exists' "$(test -s "$CASE/dist/drsg-harness-kit-v1.7.1.tar.gz.sha256" && printf yes || printf no)" yes
# Restore the single shared bare origin to its fixture baseline for subsequent cases.
git --git-dir="$ORIGIN" update-ref refs/heads/main "$BASE_SHA"
git --git-dir="$ORIGIN" update-ref -d refs/tags/v1.7.1

# Check guards do not create tags or contact GitHub on invalid starting state.
new_case dirty
touch "$CASE/dirty"
expect_stop 'dirty worktree' worktree run_check v1.7.1
check 'dirty check creates no tag' "$(git -C "$CASE" tag -l v1.7.1)" ''
new_case wrong-branch
git -C "$CASE" checkout -qb not-main
expect_stop 'non-main branch' branch run_check v1.7.1
new_case invalid-version
expect_stop 'invalid version' version run_check v1.7
new_case old-version
expect_stop 'non-incrementing version' version run_check v1.6.9
grep -Fq 'must be greater than latest tag v1.7.0' "$TMP/command.out" || fail 'non-incrementing version uses the progression guard'
new_case equal-version
expect_stop 'equal version' version run_check v1.7.0
new_case local-tag
git -C "$CASE" tag -a v1.7.1 -m duplicate
expect_stop 'existing local tag' tag run_check v1.7.1
new_case local-tag-conflict
notes_file
write_stamp v1.7.1
git -C "$CASE" tag -a v1.7.1 HEAD^ -m conflicting
git -C "$CASE" tag -l v1.7.1 >/dev/null
expect_stop 'local tag points elsewhere' tag run_publish v1.7.1 "$NOTES"
grep -Fq 'local tag points to a different commit' "$TMP/command.out" || fail 'local tag target mismatch is detected'
new_case remote-tag
REMOTE_TAG="$TMP/remote-tag-writer"
git clone -q "$ORIGIN" "$REMOTE_TAG"
git -C "$REMOTE_TAG" tag -a v1.7.1 -m duplicate
git -C "$REMOTE_TAG" push -q origin v1.7.1
expect_stop 'existing remote tag' tag run_check v1.7.1
new_case remote-tag-conflict
notes_file
write_stamp v1.7.1
git --git-dir="$ORIGIN" update-ref refs/tags/v1.7.1 "$(git -C "$REMOTE_TAG" rev-parse 'HEAD^^{commit}')"
expect_stop 'remote tag points elsewhere' tag run_publish v1.7.1 "$NOTES"
grep -Fq 'remote tag points to a different commit' "$TMP/command.out" || fail 'remote tag target mismatch is detected'
git --git-dir="$ORIGIN" update-ref -d refs/tags/v1.7.1
new_case existing-release
printf 'present\n' > "$GH_STATE"
expect_stop 'existing release during check' release run_check v1.7.1
check 'check did not create release' "$(grep -c '^release create ' "$GH_LOG" || true)" 0

# Tree-bound check state and notes validation.
new_case tested-tree
TREE=$(git -C "$CASE" rev-parse 'HEAD^{tree}')
run_check v1.7.1 --tested-tree "$TREE" > "$TMP/tree-skip.out"
grep -Fq "tests: skipped, tree ${TREE:0:12} matches --tested-tree" "$TMP/tree-skip.out" || fail 'matching tree skips tests'
check 'matching tested-tree leaves counter unchanged' "$(count_lines "$COUNTER")" 0
new_case tested-tree-mismatch
TREE=$(git -C "$CASE" rev-parse 'HEAD^{tree}')
run_check v1.7.1 --tested-tree 0000000000000000000000000000000000000000 > "$TMP/tree-mismatch.out"
grep -Fq 'tests: passed' "$TMP/tree-mismatch.out" || fail 'mismatched tree runs tests'
check 'mismatched tested-tree runs tests once' "$(count_lines "$COUNTER")" 1
new_case missing-stamp
notes_file
expect_stop 'publish without check stamp' stamp run_publish v1.7.1 "$NOTES"
check 'missing stamp creates no tag' "$(git -C "$CASE" tag -l v1.7.1)" ''
new_case mismatched-stamp
notes_file
write_stamp v1.7.1
printf 'HEAD=%s\nTREE=0000000000000000000000000000000000000000\n' "$(git -C "$CASE" rev-parse HEAD)" > "$CASE/$(git -C "$CASE" rev-parse --git-path drsg-release-check-v1.7.1)"
expect_stop 'mismatched check tree' stamp run_publish v1.7.1 "$NOTES"
new_case bad-notes
write_stamp v1.7.1
BAD_NOTES="$TMP/bad-notes.md"
printf '## What\x27s changed\nno verification\n' > "$BAD_NOTES"
expect_stop 'notes missing Verification heading' notes run_publish v1.7.1 "$BAD_NOTES"
check 'invalid notes create no tag' "$(git -C "$CASE" tag -l v1.7.1)" ''
BAD_NOTES="$TMP/no-changes-heading.md"
printf '## Verification\nPASS\n' > "$BAD_NOTES"
expect_stop 'notes missing What changed heading' notes run_publish v1.7.1 "$BAD_NOTES"
BAD_NOTES="$TMP/empty-notes.md"
: > "$BAD_NOTES"
expect_stop 'empty notes rejected' notes run_publish v1.7.1 "$BAD_NOTES"
new_case machine-path-notes
write_stamp v1.7.1
BAD_NOTES="$TMP/machine-path-notes.md"
printf '## What\x27s changed\n/home/secret\n## Verification\nPASS\n' > "$BAD_NOTES"
expect_stop 'notes machine path rejected' notes run_publish v1.7.1 "$BAD_NOTES"
check 'machine-path notes create no tag' "$(git -C "$CASE" tag -l v1.7.1)" ''

# An unavailable GitHub query is not equivalent to a missing Release.
new_case gh-query-error
printf 'error\n' > "$GH_STATE"
expect_stop 'gh query error' release run_check v1.7.1
check 'gh query error never creates release' "$(grep -c '^release create ' "$GH_LOG" || true)" 0
notes_file
write_stamp v1.7.1
expect_stop 'publish gh query error' release run_publish v1.7.1 "$NOTES"
check 'publish gh query error never creates release' "$(grep -c '^release create ' "$GH_LOG" || true)" 0

new_case test-failure
export RELEASE_TEST_STATUS=1
expect_stop 'failing test stub' tests run_check v1.7.1
unset RELEASE_TEST_STATUS
check 'failing test stub ran exactly once' "$(count_lines "$COUNTER")" 1

new_case numeric-version
# Add a higher previous tag and verify SemVer components are compared numerically.
git -C "$CASE" tag -a v1.9.0 -m 'fixture v1.9.0'
export RELEASE_TEST_VERSION=v1.10.0
run_check v1.10.0 --tested-tree "$(git -C "$CASE" rev-parse 'HEAD^{tree}')" > "$TMP/numeric-version.out"
grep -Fq 'release v1.10.0: check passed' "$TMP/numeric-version.out" || fail 'v1.10.0 is greater than v1.9.0'
export RELEASE_TEST_VERSION=v1.7.1

new_case remote-advanced
REMOTE_ADVANCE="$TMP/remote-advance-writer"
git clone -q "$ORIGIN" "$REMOTE_ADVANCE"
git -C "$REMOTE_ADVANCE" config user.name 'Release Test'
git -C "$REMOTE_ADVANCE" config user.email 'release-test@example.invalid'
printf 'unknown remote commit\n' > "$REMOTE_ADVANCE/remote-only"
git -C "$REMOTE_ADVANCE" add remote-only
git -C "$REMOTE_ADVANCE" commit -qm 'remote-only commit'
git -C "$REMOTE_ADVANCE" push -q origin main
expect_stop 'live remote main advanced' remote run_check v1.7.1
notes_file
write_stamp v1.7.1
expect_stop 'publish with unknown remote main commit' remote run_publish v1.7.1 "$NOTES"
check 'unknown remote main commit is not fetched' "$(git -C "$CASE" cat-file -e "$(git --git-dir="$ORIGIN" rev-parse refs/heads/main)^{commit}" >/dev/null 2>&1 && printf present || printf absent)" absent
# Restore the one shared bare origin for following isolated clones.
git --git-dir="$ORIGIN" update-ref refs/heads/main "$BASE_SHA"

new_case push-resume
run_check v1.7.1 > "$TMP/push-check.out"
notes_file
HOOK_COUNT="$TMP/pre-receive-count"
cat > "$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -eu
count_file="${RELEASE_TEST_PUSH_COUNT:?}"
count=$(cat "$count_file" 2>/dev/null || printf 0)
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if [ "$count" -eq 1 ]; then
  printf 'intentional first push rejection\n' >&2
  exit 1
fi
exit 0
HOOK
chmod +x "$ORIGIN/hooks/pre-receive"
export RELEASE_TEST_PUSH_COUNT="$TMP/push-count"
expect_stop 'first push failure' push run_publish v1.7.1 "$NOTES"
check 'failed push left local tag for resume' "$(git -C "$CASE" rev-parse 'v1.7.1^{commit}')" "$(git -C "$CASE" rev-parse HEAD)"
run_publish v1.7.1 "$NOTES" > "$TMP/push-resume.out"
grep -Fq 'release v1.7.1: published' "$TMP/push-resume.out" || fail 'publish resumes after failed push'
check 'retry created exactly one Release' "$(grep -c '^release create ' "$GH_LOG" || true)" 1
rm -f "$ORIGIN/hooks/pre-receive" "$TMP/push-count"
git --git-dir="$ORIGIN" update-ref refs/heads/main "$BASE_SHA"
git --git-dir="$ORIGIN" update-ref -d refs/tags/v1.7.1

new_case matching-remote-tag
run_check v1.7.1 > "$TMP/matching-remote-check.out"
notes_file
git -C "$CASE" tag -a v1.7.1 -m 'fixture tag'
git -C "$CASE" push -q origin main v1.7.1
run_publish v1.7.1 "$NOTES" > "$TMP/matching-remote-publish.out"
grep -Fq 'release v1.7.1: published' "$TMP/matching-remote-publish.out" || fail 'matching remote tag resumes publish'
check 'matching remote tag resumes without duplicate tag' "$(git --git-dir="$ORIGIN" show-ref --tags | grep -c 'refs/tags/v1.7.1$')" 1
check 'matching remote tag resume creates one Release' "$(grep -c '^release create ' "$GH_LOG" || true)" 1
git --git-dir="$ORIGIN" update-ref refs/heads/main "$BASE_SHA"
git --git-dir="$ORIGIN" update-ref -d refs/tags/v1.7.1

new_case existing-release-resume
run_check v1.7.1 > "$TMP/existing-check.out"
notes_file
git -C "$CASE" tag -a v1.7.1 -m 'fixture tag'
git -C "$CASE" push -q origin main v1.7.1
printf 'present\n' > "$GH_STATE"
run_publish v1.7.1 "$NOTES" > "$TMP/existing-resume.out"
grep -Fq 'release v1.7.1: published' "$TMP/existing-resume.out" || fail 'existing complete Release is verified'
check 'existing Release skips create' "$(grep -c '^release create ' "$GH_LOG" || true)" 0
git --git-dir="$ORIGIN" update-ref refs/heads/main "$BASE_SHA"
git --git-dir="$ORIGIN" update-ref -d refs/tags/v1.7.1

new_case incomplete-release
write_stamp v1.7.1
notes_file
printf 'incomplete\n' > "$GH_STATE"
expect_stop 'incomplete existing Release' postflight run_publish v1.7.1 "$NOTES"
check 'incomplete Release creates no tag' "$(git -C "$CASE" tag -l v1.7.1)" ''

new_case checksum-failure
run_check v1.7.1 > "$TMP/checksum-check.out"
notes_file
REAL_SHA256=$(command -v sha256sum)
cat > "$TMP/bin/sha256sum" <<'SHASTUB'
#!/usr/bin/env bash
if [ "${1:-}" = -c ]; then
  printf 'checksum mismatch\n' >&2
  exit 1
fi
exec "$RELEASE_TEST_REAL_SHA256" "$@"
SHASTUB
chmod +x "$TMP/bin/sha256sum"
export RELEASE_TEST_REAL_SHA256="$REAL_SHA256"
expect_stop 'bundle checksum mismatch' package run_publish v1.7.1 "$NOTES"
check 'checksum mismatch creates no GitHub Release' "$(grep -c '^release create ' "$GH_LOG" || true)" 0
rm -f "$TMP/bin/sha256sum"
unset RELEASE_TEST_REAL_SHA256

new_case manifest-failure
run_check v1.7.1 > "$TMP/manifest-check.out"
notes_file
REAL_TAR=$(command -v tar)
cat > "$TMP/bin/tar" <<'TARSTUB'
#!/usr/bin/env bash
real_tar="${RELEASE_TEST_REAL_TAR:?}"
if [ "${1:-}" = -czf ]; then
  archive="$2"; stage=""; bundle=""
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C) stage="$2"; shift 2 ;;
      *) bundle="$1"; shift ;;
    esac
  done
  sed -i 's/^version: v1.7.1$/version: v0.0.0/' "$stage/$bundle/MANIFEST"
  exec "$real_tar" -czf "$archive" -C "$stage" "$bundle"
fi
exec "$real_tar" "$@"
TARSTUB
chmod +x "$TMP/bin/tar"
export RELEASE_TEST_REAL_TAR="$REAL_TAR"
expect_stop 'manifest version mismatch' package run_publish v1.7.1 "$NOTES"
check 'bad manifest creates no GitHub Release' "$(grep -c '^release create ' "$GH_LOG" || true)" 0
rm -f "$TMP/bin/tar"
unset RELEASE_TEST_REAL_TAR

new_case missing-bundle-file
rm -f "$CASE/tools/mcp_events.py"
git -C "$CASE" add -u tools/mcp_events.py
git -C "$CASE" commit -qm 'remove required bundle file for test'
run_check v1.7.1 > "$TMP/missing-file-check.out"
notes_file
expect_stop 'required bundle file missing' package run_publish v1.7.1 "$NOTES"
check 'missing required file creates no GitHub Release' "$(grep -c '^release create ' "$GH_LOG" || true)" 0

new_case check-from-another-directory
(cd "$TMP" && "$CASE/release.sh" check v1.7.1) > "$TMP/elsewhere.out" 2>&1 || { cat "$TMP/elsewhere.out" >&2; fail 'check run from another directory passes'; }
check 'check from another directory reaches the end' "$(grep -c 'release v1.7.1: check passed' "$TMP/elsewhere.out")" 1

ELAPSED=$(( $(date +%s) - STARTED ))
check 'release test suite duration is reported' "$ELAPSED" "$ELAPSED"
printf 'elapsed: %ss\n' "$ELAPSED"
printf 'PASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

#!/usr/bin/env bash
# Checked, resumable release workflow for drsg-harness-kit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${2:-unknown}"
ACTION="${1:-}"

stop() {
  local step="$1" reason="$2"
  printf 'release v%s: stopped at %s: %s\n' "${VERSION#v}" "$step" "$reason" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'usage: release.sh check vX.Y.Z [--tested-tree <40-hex-tree>]' \
    '       release.sh publish vX.Y.Z --notes <file>' >&2
}

if [[ ! "$VERSION" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  usage
  stop version 'expected vMAJOR.MINOR.PATCH'
fi

if [ "$ACTION" != check ] && [ "$ACTION" != publish ]; then
  usage
  stop arguments 'expected check or publish'
fi

TESTED_TREE=""
NOTES=""
if [ "$ACTION" = check ]; then
  if [ "$#" -eq 4 ] && [ "$3" = --tested-tree ]; then
    TESTED_TREE="$4"
    [[ "$TESTED_TREE" =~ ^[0-9a-f]{40}$ ]] || stop arguments '--tested-tree must be a 40-character lowercase tree SHA'
  elif [ "$#" -ne 2 ]; then
    usage
    stop arguments 'invalid check arguments'
  fi
else
  if [ "$#" -eq 4 ] && [ "$3" = --notes ] && [ -n "$4" ]; then
    NOTES="$4"
    case "$NOTES" in /*) ;; *) NOTES="$PWD/$NOTES" ;; esac
  else
    usage
    stop arguments 'publish requires --notes <file>'
  fi
fi

GIT=(git -C "$ROOT")
STAMP_PATH="$("${GIT[@]}" rev-parse --git-path "drsg-release-check-$VERSION")"
LOG_PATH="$("${GIT[@]}" rev-parse --git-path "drsg-release-$VERSION.log")"
case "$STAMP_PATH" in /*) STAMP="$STAMP_PATH" ;; *) STAMP="$ROOT/$STAMP_PATH" ;; esac
case "$LOG_PATH" in /*) LOG="$LOG_PATH" ;; *) LOG="$ROOT/$LOG_PATH" ;; esac
HEAD_SHA="$("${GIT[@]}" rev-parse HEAD 2>/dev/null)" || stop repository 'not inside a Git repository'
HEAD_TREE="$("${GIT[@]}" rev-parse 'HEAD^{tree}')"

show_failures() {
  local log="$1"
  grep -E '(^not ok([[:space:]]|$)|(^|[[:space:]])(FAIL|FAILED|ERROR)(:|[[:space:]]|$)|Traceback|refusing to build)' "$log" || true
  printf 'log: %s\n' "$log"
}

version_gt() {
  local left="$1" right="$2"
  local lmaj lmin lpat rmaj rmin rpat
  IFS=. read -r lmaj lmin lpat <<< "${left#v}"
  IFS=. read -r rmaj rmin rpat <<< "${right#v}"
  ((10#$lmaj > 10#$rmaj ||
    (10#$lmaj == 10#$rmaj && 10#$lmin > 10#$rmin) ||
    (10#$lmaj == 10#$rmaj && 10#$lmin == 10#$rmin && 10#$lpat > 10#$rpat)))
}

latest_tag() {
  local tag
  local -a valid=()
  while IFS= read -r tag; do
    [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] && valid+=("$tag")
  done < <("${GIT[@]}" tag -l 'v*' | sort -V)
  local latest=""
  for tag in "${valid[@]}"; do
    [ "$tag" = "$VERSION" ] && continue
    latest="$tag"
  done
  printf '%s' "$latest"
}

require_clean_main() {
  [ "$("${GIT[@]}" branch --show-current)" = main ] || stop branch 'must be on main'
  [ -z "$("${GIT[@]}" status --porcelain=v1 --untracked-files=normal)" ] || stop worktree 'worktree is not clean'
}

check_live_remote() {
  local remote_main
  remote_main=$("${GIT[@]}" ls-remote origin refs/heads/main 2>>"$LOG") || stop remote 'cannot query origin/main'
  remote_main="${remote_main%%$'\t'*}"
  [[ "$remote_main" =~ ^[0-9a-f]{40,64}$ ]] || stop remote 'origin/main is missing or has an invalid SHA'
  "${GIT[@]}" cat-file -e "$remote_main^{commit}" 2>/dev/null || stop remote 'origin/main commit is not available locally; refusing without fetch'
  "${GIT[@]}" merge-base --is-ancestor "$remote_main" HEAD 2>/dev/null || stop remote 'origin/main is not an ancestor of HEAD'
}

remote_tag_lines() {
  "${GIT[@]}" ls-remote --tags origin "refs/tags/$VERSION" "refs/tags/$VERSION^{}" 2>>"$LOG"
}

query_release() {
  local json_file="$1" err_file="$2"
  if (cd "$ROOT" && gh release view "$VERSION" --json tagName,isDraft,isPrerelease,assets) >"$json_file" 2>"$err_file"; then
    printf 'present'
  elif [ "$(<"$err_file")" = 'release not found' ]; then
    printf 'absent'
  else
    return 1
  fi
}

check_version_and_refs() {
  local remote_tags
  [ -n "$PRIOR_TAG" ] || stop version 'no prior vX.Y.Z tag exists'
  version_gt "$VERSION" "$PRIOR_TAG" || stop version "must be greater than latest tag $PRIOR_TAG"
  if "${GIT[@]}" show-ref --verify --quiet "refs/tags/$VERSION"; then
    if [ "$ACTION" = check ]; then stop tag 'local tag already exists'; fi
    [ "$("${GIT[@]}" rev-parse "$VERSION^{commit}")" = "$HEAD_SHA" ] || stop tag 'local tag points to a different commit'
  fi
  remote_tags=$(remote_tag_lines) || stop remote 'cannot query origin tags'
  if [ -n "$remote_tags" ]; then
    if [ "$ACTION" = check ]; then stop tag 'remote tag already exists'; fi
    local peeled
    peeled=$(printf '%s\n' "$remote_tags" | awk -v ref="refs/tags/$VERSION^{}" '$2 == ref {print $1}')
    [ -n "$peeled" ] || peeled=$(printf '%s\n' "$remote_tags" | awk -v ref="refs/tags/$VERSION" '$2 == ref {print $1}')
    [ "$peeled" = "$HEAD_SHA" ] || stop tag 'remote tag points to a different commit'
  fi
  RELEASE_STATE=$(query_release "$TMP_JSON" "$TMP_ERR") || stop release 'gh query failed'
  if [ "$ACTION" = check ] && [ "$RELEASE_STATE" = present ]; then
    stop release 'GitHub Release already exists'
  fi
}

verify_stamp() {
  [ -f "$STAMP" ] || stop stamp 'run check for this version before publish'
  local stamp_head stamp_tree
  stamp_head=$(awk -F= '$1 == "HEAD" {print $2}' "$STAMP")
  stamp_tree=$(awk -F= '$1 == "TREE" {print $2}' "$STAMP")
  [ "$stamp_head" = "$HEAD_SHA" ] && [ "$stamp_tree" = "$HEAD_TREE" ] ||
    stop stamp 'HEAD or tree differs from the successful check'
}

validate_notes() {
  [ -f "$NOTES" ] && [ -s "$NOTES" ] || stop notes 'notes file is missing or empty'
  grep -Fq "## What's changed" "$NOTES" || stop notes "notes must contain ## What's changed"
  grep -Fq '## Verification' "$NOTES" || stop notes 'notes must contain ## Verification'
  if grep -Eq '/(home|data|tmp)/' "$NOTES"; then
    stop notes 'notes contain a machine-specific path'
  fi
}

verify_release_json() {
  local json_file="$1"
  python3 - "$json_file" "$VERSION" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    release = json.load(stream)
version = sys.argv[2]
expected = {
    "drsg-harness-kit-%s.tar.gz" % version,
    "drsg-harness-kit-%s.tar.gz.sha256" % version,
}
assets = {asset.get("name") for asset in release.get("assets", [])}
if release.get("tagName") != version:
    raise SystemExit("Release tag does not match")
if release.get("isDraft") is not False or release.get("isPrerelease") is not False:
    raise SystemExit("Release must be published and not a prerelease")
if not expected.issubset(assets):
    raise SystemExit("Release is missing a required asset")
PY
}

verify_remote_postflight() {
  local main_line tag_lines main_sha peeled
  main_line=$("${GIT[@]}" ls-remote origin refs/heads/main 2>>"$LOG") || stop postflight 'cannot query remote main'
  main_sha="${main_line%%$'\t'*}"
  [ "$main_sha" = "$HEAD_SHA" ] || stop postflight 'remote main does not point to HEAD'
  tag_lines=$(remote_tag_lines) || stop postflight 'cannot query remote tag'
  peeled=$(printf '%s\n' "$tag_lines" | awk -v ref="refs/tags/$VERSION^{}" '$2 == ref {print $1}')
  [ -n "$peeled" ] || peeled=$(printf '%s\n' "$tag_lines" | awk -v ref="refs/tags/$VERSION" '$2 == ref {print $1}')
  [ "$peeled" = "$HEAD_SHA" ] || stop postflight 'remote tag does not point to HEAD'
}

mkdir -p "$(dirname "$STAMP")"
TMP_JSON="$(mktemp "${TMPDIR:-/tmp}/drsg-release-gh.XXXXXX")"
TMP_ERR="$(mktemp "${TMPDIR:-/tmp}/drsg-release-gherr.XXXXXX")"
trap 'rm -f "$TMP_JSON" "$TMP_ERR"' EXIT
: > "$LOG"

require_clean_main
check_live_remote
PRIOR_TAG=$(latest_tag)
check_version_and_refs
printf 'repository: main, clean; origin/main is an ancestor of HEAD\n'
printf 'version: %s is greater than %s\n' "$VERSION" "$PRIOR_TAG"

if [ "$ACTION" = check ]; then
  if [ "$TESTED_TREE" = "$HEAD_TREE" ]; then
    printf 'tests: skipped, tree %.12s matches --tested-tree\n' "$HEAD_TREE"
  else
    if ! bash "$ROOT/tests/test-all.sh" >"$LOG.tests" 2>&1; then
      show_failures "$LOG.tests"
      stop tests 'tests/test-all.sh failed'
    fi
    printf 'tests: passed (log %s)\n' "$LOG.tests"
  fi
  if ! python3 "$ROOT/tools/completeness-guard.py" --repo "$ROOT" --base "$PRIOR_TAG" >"$LOG.completeness" 2>&1; then
    show_failures "$LOG.completeness"
    stop completeness 'completeness-guard failed'
  fi
  printf 'completeness: passed against %s\n' "$PRIOR_TAG"
  COMMITS=$("${GIT[@]}" log --format='%h %s' "$PRIOR_TAG..HEAD" | paste -sd ';' -)
  [ -n "$COMMITS" ] || COMMITS=none
  printf 'commits since %s: %s\n' "$PRIOR_TAG" "$COMMITS"
  STAMP_TMP="$STAMP.tmp.$$"
  printf 'HEAD=%s\nTREE=%s\n' "$HEAD_SHA" "$HEAD_TREE" > "$STAMP_TMP"
  mv "$STAMP_TMP" "$STAMP"
  printf 'check stamp: recorded HEAD %.12s, tree %.12s\n' "$HEAD_SHA" "$HEAD_TREE"
  printf 'release %s: check passed\n' "$VERSION"
  exit 0
fi

verify_stamp
validate_notes
printf 'stamp and notes: verified\n'

if [ "$RELEASE_STATE" = present ]; then
  if ! verify_release_json "$TMP_JSON"; then stop postflight 'existing Release metadata or assets do not match'; fi
  verify_remote_postflight
  printf 'release %s: published\n' "$VERSION"
  exit 0
fi

if ! "${GIT[@]}" show-ref --verify --quiet "refs/tags/$VERSION"; then
  "${GIT[@]}" tag -a "$VERSION" HEAD -m "Release $VERSION" || stop tag 'could not create annotated tag'
  printf 'tag: created %s\n' "$VERSION"
else
  printf 'tag: resumed existing %s\n' "$VERSION"
fi
[ "$("${GIT[@]}" describe --tags --exact-match HEAD 2>/dev/null || true)" = "$VERSION" ] || stop tag 'tag does not exactly match HEAD'

if ! (cd "$ROOT" && ./pack.sh) >"$LOG.pack" 2>&1; then
  show_failures "$LOG.pack"
  stop package 'pack.sh failed'
fi
TARBALL="$ROOT/dist/drsg-harness-kit-$VERSION.tar.gz"
CHECKSUM="$TARBALL.sha256"
[ -s "$TARBALL" ] && [ -s "$CHECKSUM" ] || stop package 'pack.sh did not create both package assets'
printf 'package: built %s\n' "$TARBALL"
if ! (cd "$ROOT" && sha256sum -c "$CHECKSUM") >"$LOG.checksum" 2>&1; then
  show_failures "$LOG.checksum"
  stop package 'checksum verification failed'
fi
MANIFEST=$(tar -xOf "$TARBALL" "drsg-harness-kit-$VERSION/MANIFEST" 2>"$TMP_ERR") || stop package 'cannot read bundle manifest'
printf '%s\n' "$MANIFEST" | grep -Fxq "version: $VERSION" || stop package 'manifest version does not match'
printf '%s\n' "$MANIFEST" | grep -Fxq "source:  $HEAD_SHA" || stop package 'manifest source does not match HEAD'
for required in setup.sh install-drsg.sh tools/install.sh tools/mcp_events.py tools/permission-guard.py tools/audit_deployment.py tools/textual-tool-call-guard.py skills/codegraph/SKILL.md claude/AGENT-EFFICIENCY.md; do
  tar -tzf "$TARBALL" | grep -Fx "drsg-harness-kit-$VERSION/$required" >/dev/null || stop package "bundle is missing $required"
done
printf 'package verification: checksum, manifest and required files passed\n'

remote_tags=$(remote_tag_lines) || stop remote 'cannot query origin tags before push'
peeled=$(printf '%s\n' "$remote_tags" | awk -v ref="refs/tags/$VERSION^{}" '$2 == ref {print $1}')
[ -n "$peeled" ] || peeled=$(printf '%s\n' "$remote_tags" | awk -v ref="refs/tags/$VERSION" '$2 == ref {print $1}')
if [ -n "$peeled" ]; then
  [ "$peeled" = "$HEAD_SHA" ] || stop remote 'remote tag points to a different commit'
  if ! "${GIT[@]}" push origin main >"$LOG.push" 2>&1; then
    show_failures "$LOG.push"
    stop push 'git push origin main failed'
  fi
else
  if ! "${GIT[@]}" push origin main "$VERSION" >"$LOG.push" 2>&1; then
    show_failures "$LOG.push"
    stop push 'git push origin main <tag> failed'
  fi
fi
printf 'push: main and %s pushed without force\n' "$VERSION"

RELEASE_STATE=$(query_release "$TMP_JSON" "$TMP_ERR") || stop release 'gh query failed'
if [ "$RELEASE_STATE" = absent ]; then
  if ! (cd "$ROOT" && gh release create "$VERSION" --verify-tag --title "drsg-harness-kit $VERSION" --notes-file "$NOTES" "$TARBALL" "$CHECKSUM") >"$LOG.release" 2>&1; then
    show_failures "$LOG.release"
    stop release 'gh release create failed'
  fi
  printf 'release: created %s\n' "$VERSION"
else
  printf 'release: found existing %s; create skipped\n' "$VERSION"
fi
if ! (cd "$ROOT" && gh release view "$VERSION" --json tagName,isDraft,isPrerelease,assets) >"$TMP_JSON" 2>"$TMP_ERR"; then
  stop postflight 'gh query failed'
fi
if ! verify_release_json "$TMP_JSON"; then stop postflight 'Release metadata or assets do not match'; fi
verify_remote_postflight
printf 'postflight: Release and remote refs verified\n'
printf 'release %s: published\n' "$VERSION"

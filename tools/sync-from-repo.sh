#!/usr/bin/env bash
# Refresh this directory from a repository checkout of the memory-layer scripts.
#
# WHY THIS DIRECTORY EXISTS: the scripts are tracked on a branch (the personal
# branch, and the `feat/memory-layer-for-coding-agents` PR line), so checking
# out any other branch — an upstream-shaped PR branch, say — DELETES them from
# the working tree, and with them `drsg-events` (whose command path in
# ~/.claude.json used to point into the repo), `serve.sh` and `codegraph.sh`.
# Nothing here is tracked by any branch, which is the same reason `.claude/`
# and `.mcp.json` have always survived.
#
# The repo copy stays the source of truth — it is what ships in the PR. This
# copy is what RUNS. Re-run this after editing either one.
#
# Usage: sync-from-repo.sh [repo-dir]        # report what differs
#        sync-from-repo.sh [repo-dir] --apply
set -euo pipefail

REPO="${1:-${DRSG_REPO_DIR:-$(pwd)}}"
APPLY="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO"

[ -d "$SRC/tools" ] || {
  echo "no $SRC/tools — wrong branch checked out, or wrong repo" >&2
  exit 1
}

differs=0
while IFS= read -r f; do
  rel="${f#"$SRC"/tools/}"
  cmp -s "$f" "$HERE/$rel" || { echo "differs: $rel"; differs=1; }
done < <(find "$SRC/tools" -type f -not -path '*/__pycache__/*' -not -path '*/logs/*')
# Skills install under ~/.claude/skills, not here — that is where the harness
# looks. Same repo-is-source rule applies, and the same branch hazard: the
# source under skills/ vanishes on checkout, the installed copy does not.
SKILLS="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
if [ -d "$REPO/skills" ]; then
  while IFS= read -r f; do
    rel="${f#"$REPO"/skills/}"
    cmp -s "$f" "$SKILLS/$rel" || { echo "differs: skills/$rel"; differs=1; }
  done < <(find "$REPO/skills" -type f -name '*.md')
fi

if [ "$APPLY" = "--apply" ]; then
  cp -a "$SRC/tools/." "$HERE/"
  [ -d "$REPO/skills" ] && { mkdir -p "$SKILLS"; cp -a "$REPO/skills/." "$SKILLS/"; }
  chmod +x "$HERE"/*.sh "$HERE"/*.py 2>/dev/null || true
  echo "synced from $SRC"
elif [ "$differs" = 0 ]; then
  echo "in sync with $SRC"
else
  echo "run with --apply to overwrite this copy from the repo" >&2
  exit 1
fi

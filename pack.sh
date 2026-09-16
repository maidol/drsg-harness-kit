#!/usr/bin/env bash
# pack.sh — build the one-click install bundle for the agent side of DrSG:
# the memory layer (shared daemon, hooks, Event tools) and the code graph
# (per-repo watcher, router, usage report), plus the setup script that puts
# them on a machine that has none of this.
#
# The bundle's tools/ is exactly what ~/.drsg-memory/tools/ has to hold. That
# directory exists because everything here is tracked by a branch, and checking
# out any other branch deletes it from the working tree — the copies outside
# the repository are the ones that RUN.
#
# Usage: pack.sh [--out DIR] [--name NAME]
#
#   --out DIR    where to write the tarball   (default: <repo>/dist)
#   --name NAME  bundle name without .tar.gz  (default: drsg-harness-kit-<version>)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$REPO/dist"
NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out)  OUT="${2:?--out needs a path}"; shift 2 ;;
    --name) NAME="${2:?--name needs a name}"; shift 2 ;;
    *) echo "unknown argument '$1'" >&2; exit 1 ;;
  esac
done

VERSION="$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)"
COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
NAME="${NAME:-drsg-harness-kit-$VERSION}"

# Resolved once as a command, not wrapped in a function: the manifest pipes
# through xargs, which cannot see a shell function.
if command -v sha256sum >/dev/null 2>&1; then SHA=(sha256sum); else SHA=(shasum -a 256); fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$NAME"
mkdir -p "$ROOT/tools"

# 1. the memory layer, minus what is state rather than tooling
cp -a "$REPO/tools/." "$ROOT/tools/"
rm -rf "$ROOT/tools/logs" "$ROOT/tools/benchmark"
find "$ROOT/tools" -name '__pycache__' -type d -prune -exec rm -rf {} +

# 2. the code graph: watcher control, router, usage analytics, hub setup
cp -a "$REPO"/tools/codegraph*.sh "$REPO"/tools/codegraph*.py "$ROOT/tools/"

# 3. the Stop-hook usage report already lives in tools/ in this standalone kit.
#    It is copied by step 1 along with the other runtime files.

# 4. the setup script, at the bundle root where an unpacking user will look
cp -a "$REPO/setup.sh" "$ROOT/setup.sh"

# 5. the binary installer, for a machine with no drsg at all
cp -a "$REPO/install-drsg.sh" "$ROOT/install-drsg.sh"

# 6. the codegraph skill — operating the daemon, onboarding a repo, auditing
#    usage. Installed under ~/.claude/skills, not the tools directory.
if [ -d "$REPO/skills" ]; then
  mkdir -p "$ROOT/skills"
  cp -a "$REPO/skills/." "$ROOT/skills/"
  find "$ROOT/skills" -name '__pycache__' -type d -prune -exec rm -rf {} +
fi

chmod +x "$ROOT/setup.sh" "$ROOT/install-drsg.sh"
chmod +x "$ROOT"/tools/*.sh "$ROOT"/tools/*.py "$ROOT/tools/drsg-usage-report" 2>/dev/null || true

# The manifest records where the bundle came from, so a deployment that has
# drifted can be told apart from one built at a different commit.
{
  echo "bundle:  $NAME"
  echo "source:  $COMMIT"
  echo "version: $VERSION"
  echo "built:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  (cd "$ROOT" && find . -type f -not -name MANIFEST | sort | xargs "${SHA[@]}")
} > "$ROOT/MANIFEST"

mkdir -p "$OUT"
TARBALL="$OUT/$NAME.tar.gz"
tar -czf "$TARBALL" -C "$STAGE" "$NAME"
"${SHA[@]}" "$TARBALL" > "$TARBALL.sha256"

echo "built $TARBALL"
echo "      $(wc -c < "$TARBALL" | tr -d ' ') bytes, $(find "$ROOT" -type f | wc -l | tr -d ' ') files, from $COMMIT"
echo
echo "on the target machine:"
echo "  tar xzf $NAME.tar.gz && cd $NAME"
echo "  ./setup.sh --project /path/to/project --repo /path/to/repo --bin /path/to/drsg"

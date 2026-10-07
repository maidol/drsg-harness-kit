#!/usr/bin/env bash
# install-precommit-guard.sh PROJECT_DIR TOOLS_DIR
# Installs the completeness-guard pre-commit hook into PROJECT_DIR.
# Called by install.sh; kept as its own file so tests/completeness-guard.sh
# runs the real installer instead of a copy of its logic.
set -u
PROJECT_DIR="$1"
TOOLS_DIR="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

GUARD_BIN="$TOOLS_DIR/completeness-guard.py"
if [ ! -f "$GUARD_BIN" ] && [ -f "$HERE/completeness-guard.py" ]; then
  mkdir -p "$TOOLS_DIR"
  cp -a "$HERE/completeness-guard.py" "$GUARD_BIN"
  chmod +x "$GUARD_BIN"
fi

# With core.hooksPath set, git never reads .git/hooks: a hook written there
# would look installed and check nothing.
HOOKS_PATH="$(git -C "$PROJECT_DIR" config core.hooksPath || true)"
if [ -n "$HOOKS_PATH" ]; then
  echo "   NOTE: $PROJECT_DIR sets core.hooksPath=$HOOKS_PATH; pre-commit guard not installed."
  echo "         Chain manually: python3 $GUARD_BIN --staged  (exit 2 is advisory: let it pass)"
  exit 0
fi

# --absolute-git-dir, not --git-dir: the latter prints ".git", which resolves
# against the caller's cwd rather than PROJECT_DIR.
GIT_DIR="$(git -C "$PROJECT_DIR" rev-parse --absolute-git-dir)"
HOOK_TARGET="$GIT_DIR/hooks/pre-commit"
mkdir -p "$GIT_DIR/hooks"
if [ -f "$HOOK_TARGET" ] && ! grep -q '# drsg-harness-kit completeness-guard' "$HOOK_TARGET"; then
  echo "   NOTE: $HOOK_TARGET exists and is customized by project; not overwritten."
  echo "         Chain manually: python3 $GUARD_BIN --staged  (exit 2 is advisory: let it pass)"
  exit 0
fi
cat > "$HOOK_TARGET" <<HOOKEOF
#!/bin/sh
# drsg-harness-kit completeness-guard
# python3 also exits 2 when the script file is missing, and exit 2 is turned
# into a pass below — so a missing guard has to be caught first, out loud.
if [ ! -f "$GUARD_BIN" ]; then
  echo "WARN: completeness-guard not found at $GUARD_BIN; commit NOT checked. Re-run setup.sh." >&2
  exit 0
fi
python3 "$GUARD_BIN" --staged
rc=\$?
if [ "\$rc" -eq 2 ]; then
  exit 0
fi
exit \$rc
HOOKEOF
chmod +x "$HOOK_TARGET"
echo "== installed git pre-commit completeness guard in $HOOK_TARGET"

#!/usr/bin/env bash
# install-precommit-guard.sh PROJECT_DIR TOOLS_DIR
# Installs completeness-guard and forbidden-literals-guard git hooks into PROJECT_DIR.
# Called by install.sh; kept as its own file so tests/completeness-guard.sh
# and tests/commit-auth.sh run the real installer instead of a copy of its logic.
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

FORBIDDEN_BIN="$TOOLS_DIR/forbidden-literals-guard.py"
if [ ! -f "$FORBIDDEN_BIN" ] && [ -f "$HERE/forbidden-literals-guard.py" ]; then
  mkdir -p "$TOOLS_DIR"
  cp -a "$HERE/forbidden-literals-guard.py" "$FORBIDDEN_BIN"
  chmod +x "$FORBIDDEN_BIN"
fi

# With core.hooksPath set, git never reads .git/hooks: a hook written there
# would look installed and check nothing.
HOOKS_PATH="$(git -C "$PROJECT_DIR" config core.hooksPath || true)"
if [ -n "$HOOKS_PATH" ]; then
  echo "   NOTE: $PROJECT_DIR sets core.hooksPath=$HOOKS_PATH; git guards not installed."
  echo "         Chain manually: python3 $FORBIDDEN_BIN --staged && python3 $GUARD_BIN --staged"
  echo "         and for commit-msg: python3 $FORBIDDEN_BIN --commit-msg \$1"
  exit 0
fi

# --absolute-git-dir, not --git-dir: the latter prints ".git", which resolves
# against the caller's cwd rather than PROJECT_DIR.
GIT_DIR="$(git -C "$PROJECT_DIR" rev-parse --absolute-git-dir)"
HOOK_TARGET="$GIT_DIR/hooks/pre-commit"
MSG_HOOK_TARGET="$GIT_DIR/hooks/commit-msg"
mkdir -p "$GIT_DIR/hooks"

# 1. pre-commit hook
if [ -f "$HOOK_TARGET" ] && ! grep -q '# drsg-harness-kit completeness-guard' "$HOOK_TARGET"; then
  echo "   NOTE: $HOOK_TARGET exists and is customized by project; not overwritten."
  echo "         Chain manually: python3 $FORBIDDEN_BIN --staged && python3 $GUARD_BIN --staged"
else
  cat > "$HOOK_TARGET" <<HOOKEOF
#!/bin/sh
# drsg-harness-kit completeness-guard
LIST_FILE="\$(git rev-parse --show-toplevel 2>/dev/null)/.drsg/forbidden-literals"
FORBIDDEN_BIN="$FORBIDDEN_BIN"
if [ -f "\$LIST_FILE" ]; then
  if [ ! -f "\$FORBIDDEN_BIN" ]; then
    echo "ERROR: forbidden-literals-guard not found at \$FORBIDDEN_BIN; commit BLOCKED. Re-run setup.sh." >&2
    exit 1
  fi
  python3 "\$FORBIDDEN_BIN" --staged
  rc=\$?
  if [ "\$rc" -ne 0 ]; then
    exit \$rc
  fi
fi

GUARD_BIN="$GUARD_BIN"
if [ ! -f "\$GUARD_BIN" ]; then
  echo "WARN: completeness-guard not found at \$GUARD_BIN; commit NOT checked. Re-run setup.sh." >&2
  exit 0
fi
python3 "\$GUARD_BIN" --staged
rc=\$?
if [ "\$rc" -eq 2 ]; then
  exit 0
fi
exit \$rc
HOOKEOF
  chmod +x "$HOOK_TARGET"
  echo "== installed git pre-commit completeness guard in $HOOK_TARGET"
fi

# 2. commit-msg hook
if [ -f "$MSG_HOOK_TARGET" ] && ! grep -q '# drsg-harness-kit commit-msg' "$MSG_HOOK_TARGET"; then
  echo "   NOTE: $MSG_HOOK_TARGET exists and is customized by project; not overwritten."
  echo "         Chain manually: python3 $FORBIDDEN_BIN --commit-msg \$1"
else
  cat > "$MSG_HOOK_TARGET" <<MSGHOOKEOF
#!/bin/sh
# drsg-harness-kit commit-msg
COMMIT_MSG_FILE="\$1"
if [ -z "\$COMMIT_MSG_FILE" ]; then
  exit 0
fi
LIST_FILE="\$(git rev-parse --show-toplevel 2>/dev/null)/.drsg/forbidden-literals"
FORBIDDEN_BIN="$FORBIDDEN_BIN"
if [ -f "\$LIST_FILE" ]; then
  if [ ! -f "\$FORBIDDEN_BIN" ]; then
    echo "ERROR: forbidden-literals-guard not found at \$FORBIDDEN_BIN; commit BLOCKED. Re-run setup.sh." >&2
    exit 1
  fi
  python3 "\$FORBIDDEN_BIN" --commit-msg "\$COMMIT_MSG_FILE"
  rc=\$?
  if [ "\$rc" -ne 0 ]; then
    exit \$rc
  fi
fi
exit 0
MSGHOOKEOF
  chmod +x "$MSG_HOOK_TARGET"
  echo "== installed git commit-msg guard in $MSG_HOOK_TARGET"
fi

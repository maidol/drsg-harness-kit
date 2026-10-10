#!/usr/bin/env bash
# Manage the user-level main-branch workflow rule.
set -euo pipefail

usage() {
  printf 'Usage: %s {enable|disable|status}\n' "${0##*/}" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
command_name="$1"
case "$command_name" in
  enable|disable|status) ;;
  *) usage; exit 2 ;;
esac

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
RULE="$CLAUDE_DIR/MAIN-BRANCH-WORKFLOW.md"
GLOBAL_CLAUDE="$CLAUDE_DIR/CLAUDE.md"
MARKER="$CLAUDE_DIR/.main-branch-workflow.disabled"
SOURCE="${MAIN_BRANCH_RULE_SOURCE:-}"
if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
  candidate="$(dirname "${BASH_SOURCE[0]}")/main-branch-workflow-rule.md"
  if [ -f "$candidate" ]; then SOURCE="$candidate"; fi
fi
if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
  candidate="$(cd "$(dirname "${BASH_SOURCE[0]}")/../claude" 2>/dev/null && pwd)/MAIN-BRANCH-WORKFLOW.md" || true
  if [ -f "$candidate" ]; then SOURCE="$candidate"; fi
fi
if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
  SOURCE="$RULE"
fi

python3 - "$command_name" "$CLAUDE_DIR" "$RULE" "$GLOBAL_CLAUDE" "$MARKER" "$SOURCE" <<'PY'
import os
import stat
import sys
import tempfile

command, config_dir, rule_path, claude_path, marker_path, source_path = sys.argv[1:]
IMPORT = b"@MAIN-BRANCH-WORKFLOW.md"
MANUAL = "不要自行新建功能分支或 worktree".encode("utf-8")


def atomic_write(path, data, mode=None):
    directory = os.path.dirname(path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=directory)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_bytes(path):
    try:
        with open(path, "rb") as src:
            return src.read()
    except FileNotFoundError:
        return b""


def matching_import(line):
    return line.rstrip(b"\r\n") == IMPORT


def remove_import(data):
    return b"".join(line for line in data.splitlines(keepends=True) if not matching_import(line))


def import_count(data):
    return sum(matching_import(line) for line in data.splitlines(keepends=True))


def ensure_one_import(data):
    lines = []
    found = False
    for line in data.splitlines(keepends=True):
        if matching_import(line):
            if found:
                continue
            found = True
        lines.append(line)
    updated = b"".join(lines)
    if found:
        return updated
    if updated and not updated.endswith((b"\n", b"\r")):
        updated += b"\n"
    return updated + IMPORT + b"\n"


def advisory(data):
    if MANUAL in data:
        print("Advisory: the managed main-branch policy is authoritative; remove any hand-written duplicate yourself.")


def ensure_marker():
    if os.path.exists(marker_path):
        return
    atomic_write(marker_path, b"")


def install_rule():
    if not os.path.isfile(source_path):
        raise SystemExit("ERROR: managed rule source is unavailable; rerun setup.sh to install it")
    source = read_bytes(source_path)
    existing = read_bytes(rule_path)
    if existing == source:
        return
    try:
        mode = stat.S_IMODE(os.stat(rule_path).st_mode)
    except FileNotFoundError:
        mode = stat.S_IMODE(os.stat(source_path).st_mode)
    atomic_write(rule_path, source, mode)


def state(data):
    marker = os.path.exists(marker_path)
    copied = os.path.isfile(rule_path)
    imports = import_count(data)
    if marker and imports == 0:
        return "disabled"
    if not marker and copied and imports == 1:
        return "enabled"
    if not marker and not copied and imports == 0:
        return "not-installed"
    return "inconsistent"


claude_data = read_bytes(claude_path)
if command == "enable":
    install_rule()
    without_marker = os.path.exists(marker_path)
    if without_marker:
        os.unlink(marker_path)
    imported_before = import_count(claude_data)
    updated = ensure_one_import(claude_data)
    if updated != claude_data:
        mode = stat.S_IMODE(os.stat(claude_path).st_mode) if os.path.exists(claude_path) else None
        atomic_write(claude_path, updated, mode)
    print("main-branch workflow enabled")
    if imported_before == 0:
        advisory(claude_data)
elif command == "disable":
    ensure_marker()
    updated = remove_import(claude_data)
    if updated != claude_data:
        mode = stat.S_IMODE(os.stat(claude_path).st_mode) if os.path.exists(claude_path) else None
        atomic_write(claude_path, updated, mode)
    print("main-branch workflow disabled")
else:
    current = state(claude_data)
    print(f"main-branch workflow: {current}")
    print(f"rule: {rule_path}")
    print(f"global instructions: {claude_path}")
    print(f"disabled marker: {marker_path}")
    advisory(claude_data)
PY

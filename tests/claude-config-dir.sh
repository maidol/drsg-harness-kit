#!/usr/bin/env bash
# The analysis tools find Claude Code's files under $CLAUDE_CONFIG_DIR when it
# is set (and non-empty), and under ~/.claude otherwise: the rule Claude Code
# itself uses. Each tool resolves the directory on its own, so each is checked.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/.claude" "$T/config" "$T/proj"
printf '{"env":{"DRSG_CONFIG_DIR_PROBE":"from-config-dir"}}\n' > "$T/config/settings.json"
printf '{"env":{"DRSG_CONFIG_DIR_PROBE":"from-home"}}\n' > "$T/home/.claude/settings.json"
cat > "$T/probe.py" <<'PY'
import importlib.util
import os

repo = os.environ["REPO"]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(repo, "tools", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


print(load("cgu", "codegraph-usage.py").PROJECTS)
print(load("ar", "analyze_recall.py").TRANSCRIPT_ROOT)
os.environ["CLAUDE_PROJECT_DIR"] = "/x/proj"
print(load("dur", "drsg_usage_report.py").project_transcript_dir())
print(load("cmd", "claude-model-discovery.py")._merged_env().get("DRSG_CONFIG_DIR_PROBE"))
PY

fail=0
expect() {
  if [ "$3" = "$2" ]; then
    echo "PASS $1"
  else
    echo "FAIL $1"
    echo "  want: $2"
    echo "  got:  $3"
    fail=1
  fi
}

run_mode() {
  local mode="$1" root="$2" probe_value="$3" out
  shift 3
  out="$(cd "$T/proj" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_PROJECT_DIR HOME="$T/home" "$@" \
    REPO="$REPO" python3 "$T/probe.py" 2>&1)"
  expect "$mode codegraph-usage" "$root/projects" "$(printf '%s\n' "$out" | sed -n 1p)"
  expect "$mode analyze_recall" "$root/projects" "$(printf '%s\n' "$out" | sed -n 2p)"
  expect "$mode drsg_usage_report" "$root/projects/-x-proj" "$(printf '%s\n' "$out" | sed -n 3p)"
  expect "$mode claude-model-discovery" "$probe_value" "$(printf '%s\n' "$out" | sed -n 4p)"
}

run_mode config "$T/config" from-config-dir CLAUDE_CONFIG_DIR="$T/config"
run_mode home "$T/home/.claude" from-home
run_mode empty "$T/home/.claude" from-home CLAUDE_CONFIG_DIR=

if [ "$fail" -eq 0 ]; then
  echo "claude-config-dir: all checks passed"
else
  echo "claude-config-dir: FAILED"
  exit 1
fi

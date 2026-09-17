#!/usr/bin/env bash
# codegraph-hub-setup.sh — One-click setup of CodeGraph Router and Stop-hook
# usage reporting for a review or hub project — one that reads several
# repositories' code rather than holding a graph of its own.
#
# What it does:
#   1. Validates target project directory.
#   2. Registers the `Stop` hook (`drsg-usage-report`) into <proj>/.claude/settings.local.json.
#   3. Registers the `codegraph` MCP server (`codegraph-router.py`) via `claude mcp add --scope local`
#      (or fallback to <proj>/.mcp.json).
#   4. Checks ~/.drsg-memory/graphs registry to verify reachable repositories.
#   5. Runs a quick self-check to ensure no silent configuration failures.
#
# Usage:
#   ./tools/codegraph-hub-setup.sh [--router|--usage-report] [project-dir]
#   (default mode: both; default project-dir: current working directory)
set -euo pipefail

MODE="both"
case "${1:-}" in
  --router) MODE="router"; shift ;;
  --usage-report) MODE="usage-report"; shift ;;
  --help|-h) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
TARGET_DIR="${1:-.}"
PROJECT_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd || { mkdir -p "$TARGET_DIR" && cd "$TARGET_DIR" && pwd; })"

TOOLS_DIR="${DRSG_MEM_DIR:-$HOME/.drsg-memory}/tools"
USAGE_REPORT_BIN="$TOOLS_DIR/drsg-usage-report"
ROUTER_BIN="$TOOLS_DIR/codegraph-router.py"
REGISTRY="${DRSG_GRAPHS:-$HOME/.drsg-memory/graphs}"

echo "============================================================"
case "$MODE" in
  router) echo " Setting up CodeGraph Router" ;;
  usage-report) echo " Setting up CodeGraph Usage Reporting" ;;
  *) echo " Setting up CodeGraph Hub & Usage Reporting" ;;
esac
echo " Target project: $PROJECT_DIR"
echo "============================================================"

# 1. Pre-flight checks on global tools
if [ "$MODE" != "router" ] && [ ! -f "$USAGE_REPORT_BIN" ]; then
  echo "ERROR: Usage report tool not found at $USAGE_REPORT_BIN" >&2
  echo "       Install the runtime copies first: pack.sh, then the" >&2
  echo "       bundle's setup.sh (or tools/install.sh)." >&2
  exit 1
fi

if [ "$MODE" != "usage-report" ] && [ ! -f "$ROUTER_BIN" ]; then
  echo "ERROR: CodeGraph router tool not found at $ROUTER_BIN" >&2
  echo "       Install the runtime copies first: pack.sh, then the" >&2
  echo "       bundle's setup.sh (or tools/install.sh)." >&2
  exit 1
fi

if [ "$MODE" != "router" ]; then
# Register Stop hook in settings.local.json
SETTINGS_LOCAL="$PROJECT_DIR/.claude/settings.local.json"
mkdir -p "$PROJECT_DIR/.claude"

echo "== 1/3: Registering Stop hook in $SETTINGS_LOCAL"
python3 - "$SETTINGS_LOCAL" "$USAGE_REPORT_BIN" <<'PYEOF'
import json, os, sys, shutil

settings_file = sys.argv[1]
hook_cmd = sys.argv[2]

if os.path.exists(settings_file):
    try:
        shutil.copy(settings_file, settings_file + ".bak")
        with open(settings_file, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"   WARN: Failed to parse existing {settings_file}: {e}; creating fresh structure")
        data = {}
else:
    data = {}

hooks = data.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

entry = {"hooks": [{"command": hook_cmd, "timeout": 20, "type": "command"}]}

# Check if already present
serialized = json.dumps(stop_hooks)
if "drsg-usage-report" in serialized:
    print("   Stop hook already registered; kept existing configuration.")
else:
    stop_hooks.append(entry)
    with open(settings_file, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("   Stop hook registered successfully.")
PYEOF
fi

if [ "$MODE" != "usage-report" ]; then
# Register MCP server (codegraph)
echo "== 2/3: Registering 'codegraph' MCP server"
REGISTERED_MCP=0

if command -v claude >/dev/null 2>&1; then
  # Remove previous registration if any (idempotent re-run)
  (cd "$PROJECT_DIR" && claude mcp remove codegraph --scope local) >/dev/null 2>&1 || true
  MCP_ENV=()
  [ "$REGISTRY" = "$HOME/.drsg-memory/graphs" ] || MCP_ENV=(-e "DRSG_GRAPHS=$REGISTRY")
  if (cd "$PROJECT_DIR" && claude mcp add --scope local "${MCP_ENV[@]}" codegraph -- python3 "$ROUTER_BIN") >/dev/null 2>&1; then
    echo "   MCP server registered via 'claude mcp add --scope local'."
    REGISTERED_MCP=1
  fi
fi

if [ "$REGISTERED_MCP" -eq 0 ]; then
  # Fallback to writing/updating .mcp.json directly
  MCP_JSON="$PROJECT_DIR/.mcp.json"
  python3 - "$MCP_JSON" "$ROUTER_BIN" "$REGISTRY" <<'PYEOF'
import json, os, sys

mcp_path = sys.argv[1]
router_path = sys.argv[2]
registry = sys.argv[3]

if os.path.exists(mcp_path):
    try:
        with open(mcp_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
else:
    data = {}

servers = data.setdefault("mcpServers", {})
servers["codegraph"] = {
    "type": "stdio",
    "command": "python3",
    "args": [router_path],
    "env": {} if registry == os.path.expanduser("~/.drsg-memory/graphs") else {"DRSG_GRAPHS": registry}
}

with open(mcp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"   MCP server configured in {mcp_path}.")
PYEOF
fi
fi

if [ "$MODE" != "usage-report" ]; then
# 4. Check registry
echo "== 3/3: Verifying repository registry ($REGISTRY)"
if [ -f "$REGISTRY" ]; then
  COUNT=$(grep -c -vE '^[[:space:]]*(#|$)' "$REGISTRY" || true)
  echo "   Registry has $COUNT active repositories:"
  grep -vE '^[[:space:]]*(#|$)' "$REGISTRY" | while read -r line; do
    echo "     - $line"
  done
else
  echo "   WARN: Registry file $REGISTRY does not exist yet."
  echo "         Add target repository paths with: codegraph.sh install --dir <repo-path>"
fi
fi

if [ "$MODE" != "router" ]; then
# Self-check
echo "== Self-check"
python3 - "$USAGE_REPORT_BIN" <<'PYEOF'
import json, subprocess, sys, tempfile

usage_report_bin = sys.argv[1]

# Test both native and routed graph calls share the same report.
with tempfile.NamedTemporaryFile("w+", suffix=".jsonl") as f:
    for i, name in enumerate(("mcp__drsg-watch__context", "mcp__codegraph__graph_context")):
        f.write(json.dumps({"type":"assistant","message":{"role":"assistant","content":[
            {"type":"tool_use","id":f"s{i}","name":name,"input":{}}]}}) + "\n")
    f.flush()
    proc = subprocess.run(
        [usage_report_bin],
        input=json.dumps({"transcript_path": f.name}),
        capture_output=True, text=True, timeout=10
    )
    if proc.returncode != 0:
        print(f"   WARN: drsg-usage-report exited {proc.returncode}: {proc.stderr}")
    else:
        try:
            out = json.loads(proc.stdout)
            msg = out.get("systemMessage", "")
            if "2 calls" in msg and "context×2" in msg:
                print("   drsg-usage-report: OK (native and routed calls counted)")
            else:
                print(f"   WARN: routed calls not counted — runtime copy is stale? got: {msg}")
        except Exception as e:
            print(f"   WARN: could not parse drsg-usage-report output: {e}")
PYEOF
fi

echo
echo "Setup complete! In new Claude sessions in '$PROJECT_DIR':"
if [ "$MODE" != "usage-report" ]; then
  echo "  1. 'mcp__codegraph__graph_*' tools will be available to query any registered repo."
fi
# An `&& echo` on the last line makes a false condition the script's exit
# status: `set -e` exempts the left side of `&&`, so it exits 1 in silence
# after printing the success banner. Keep these as `if`.
if [ "$MODE" != "router" ]; then
  echo "  2. End-of-turn usage statistics count native and routed graph calls."
fi

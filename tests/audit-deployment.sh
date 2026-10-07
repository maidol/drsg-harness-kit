#!/usr/bin/env bash
# Synthetic contract tests for tools/audit_deployment.py.
# Fully hermetic: uses temporary directories for repository, deployed tools,
# global claude configuration, and target projects.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$HERE/../tools/audit_deployment.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

RAN=0
OK=0
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
  fi
}

REPO="$T/repo"
DEPLOYED_TOOLS="$T/deployed_tools"
CLAUDE_DIR="$T/claude"
PROJ="$T/project"

mkdir -p "$REPO/tools/templates/hooks" "$REPO/claude" "$REPO/skills/agent-efficiency-retro" "$REPO/skills/codegraph" "$REPO/skills/diagram-conventions"
mkdir -p "$DEPLOYED_TOOLS/templates/hooks"
mkdir -p "$CLAUDE_DIR/skills/agent-efficiency-retro" "$CLAUDE_DIR/skills/codegraph" "$CLAUDE_DIR/skills/diagram-conventions"
mkdir -p "$PROJ/.claude/hooks" "$PROJ/.drsg"

# Initialize git repo in $REPO to test HEAD-based logic
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

echo "#!/bin/sh" > "$REPO/tools/sample.sh" && chmod +x "$REPO/tools/sample.sh"
cp "$REPO/tools/sample.sh" "$DEPLOYED_TOOLS/sample.sh"

echo "hook" > "$REPO/tools/templates/hooks/session_start.py"
echo "hook" > "$REPO/tools/templates/hooks/session_end.py"
echo "hook" > "$REPO/tools/templates/hooks/user_prompt.py"
cp -r "$REPO/tools/templates/hooks/." "$DEPLOYED_TOOLS/templates/hooks/"
cp -r "$REPO/tools/templates/hooks/." "$PROJ/.claude/hooks/"
chmod +x "$PROJ/.claude/hooks/"*.py

echo "rules" > "$REPO/claude/AGENT-EFFICIENCY.md"
cp "$REPO/claude/AGENT-EFFICIENCY.md" "$CLAUDE_DIR/AGENT-EFFICIENCY.md"
echo "@AGENT-EFFICIENCY.md" > "$CLAUDE_DIR/CLAUDE.md"
echo "skill" > "$REPO/skills/agent-efficiency-retro/SKILL.md"
echo "skill" > "$REPO/skills/codegraph/SKILL.md"
echo "skill" > "$REPO/skills/diagram-conventions/SKILL.md"
cp "$REPO/skills/agent-efficiency-retro/SKILL.md" "$CLAUDE_DIR/skills/agent-efficiency-retro/SKILL.md"
cp "$REPO/skills/codegraph/SKILL.md" "$CLAUDE_DIR/skills/codegraph/SKILL.md"
cp "$REPO/skills/diagram-conventions/SKILL.md" "$CLAUDE_DIR/skills/diagram-conventions/SKILL.md"

cat > "$CLAUDE_DIR/settings.json" <<'JSON'
{
  "hooks": {
    "Stop": [{"matcher": "*", "hooks": [{"command": "python3 /path/event-poller.py"}]}],
    "PostToolUse": [{"matcher": "*", "hooks": [{"command": "python3 /path/single-tool-streak.py"}]}]
  }
}
JSON
chmod 600 "$CLAUDE_DIR/settings.json"

cat > "$PROJ/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [{"matcher": "*", "hooks": [{"command": "python3 session_start.py"}]}],
    "UserPromptSubmit": [{"matcher": "*", "hooks": [{"command": "python3 user_prompt.py"}]}],
    "SessionEnd": [{"matcher": "*", "hooks": [{"command": "python3 session_end.py"}]}]
  }
}
JSON
echo "DRSG_TOKEN=token" > "$PROJ/.drsg/env"
echo "DRSG_API=api" >> "$PROJ/.drsg/env"
cat > "$PROJ/CLAUDE.md" <<'MD'
<!-- drsg-memory:events:begin -->
event block
<!-- drsg-memory:events:end -->
MD

git -C "$REPO" add .
git -C "$REPO" commit -q -m "initial commit"

# Helper to find a layer in JSON output by name prefix
find_layer_ok() {
  local json_file="$1"
  local prefix="$2"
  python3 - "$json_file" "$prefix" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    layers = data.get("layers", [])
    matching = [l for l in layers if l["name"].startswith(sys.argv[2])]
    if not matching:
        print("missing")
    else:
        print("ok" if matching[0]["ok"] else "failed")
except Exception:
    print("error")
PY
}

# 1. Hermetic audit: all in sync
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out1.json" 2>&1 || true
l1_status=$(find_layer_ok "$T/out1.json" "L1")
check "hermetic audit passes L1 when sync" "$l1_status" "ok"

# 2. R2: uncommitted changes in repo working tree do NOT trigger L1 DRIFT
echo "uncommitted draft" > "$REPO/tools/sample.sh"
echo "untracked" > "$REPO/tools/untracked_tool.py"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_r2.json" 2>&1 || true
l1_r2_status=$(find_layer_ok "$T/out_r2.json" "L1")
check "r2_uncommitted_changes_not_counted_as_drift" "$l1_r2_status" "ok"
git -C "$REPO" checkout -q -- tools/sample.sh
rm -f "$REPO/tools/untracked_tool.py"

# 3. R1: daemon stopped (not running) with database present is considered OK
mkdir -p "$PROJ/graph.drsg"
echo '{"mcpServers":{"drsg-watch":{"url":"http://127.0.0.1:7708/mcp"}}}' > "$PROJ/.mcp.json"
cat > "$DEPLOYED_TOOLS/codegraph.sh" <<'SH'
#!/bin/sh
echo "not running ($2: nothing holds its database; .mcp.json says 127.0.0.1:7708)"
exit 1
SH
chmod +x "$DEPLOYED_TOOLS/codegraph.sh"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_r1_ok.json" 2>&1 || true
l5_r1_status=$(find_layer_ok "$T/out_r1_ok.json" "L5")
check "r1_stopped_daemon_is_ok" "$l5_r1_status" "ok"

# 4. R1: misconfigured port or health FAILING triggers L5 DRIFT even if exit 0
cat > "$DEPLOYED_TOOLS/codegraph.sh" <<'SH'
#!/bin/sh
echo "WARNING: .mcp.json points at 127.0.0.1:7708 but running on 7709"
exit 0
SH
chmod +x "$DEPLOYED_TOOLS/codegraph.sh"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_r1_drift.json" 2>&1 || true
l5_drift_status=$(find_layer_ok "$T/out_r1_drift.json" "L5")
check "r1_port_mismatch_is_drift" "$l5_drift_status" "failed"

# 5. R3: discovery failure when running --all must produce L0 failure, not silent degradation
DRSG_API="http://127.0.0.1:1/rpc" python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --all --json > "$T/out_r3.json" 2>&1 || true
l0_status=$(find_layer_ok "$T/out_r3.json" "L0")
check "r3_discovery_failure_not_silent" "$l0_status" "failed"

# 6. N2: settings.json permissions not 0600 is reported in L2
chmod 644 "$CLAUDE_DIR/settings.json"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_n2.json" 2>&1 || true
l2_n2_status=$(find_layer_ok "$T/out_n2.json" "L2")
check "n2_settings_permissions_reported" "$l2_n2_status" "failed"
chmod 600 "$CLAUDE_DIR/settings.json"

# 7. N3: project with .drsg/audit-skip is skipped and does not fail audit
SKIP_PROJ="$T/skip_project"
mkdir -p "$SKIP_PROJ/.drsg"
touch "$SKIP_PROJ/.drsg/audit-skip"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$SKIP_PROJ" --json > "$T/out_n3.json" 2>&1 || true
overall_n3=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["overall_ok"])' "$T/out_n3.json" 2>/dev/null || echo "False")
check "n3_audit_skip_does_not_fail" "$overall_n3" "True"

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

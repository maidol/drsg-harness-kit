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
cp "$HERE/../claude/MAIN-BRANCH-WORKFLOW.md" "$REPO/claude/MAIN-BRANCH-WORKFLOW.md"
cp "$REPO/claude/MAIN-BRANCH-WORKFLOW.md" "$CLAUDE_DIR/MAIN-BRANCH-WORKFLOW.md"
printf '@AGENT-EFFICIENCY.md\n@MAIN-BRANCH-WORKFLOW.md\n' > "$CLAUDE_DIR/CLAUDE.md"
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
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"command": "python3 pre_tool_use.py"}]}],
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

find_layer_details() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    matching = [l for l in data.get("layers", []) if l["name"].startswith(sys.argv[2])]
    print("\\n".join(matching[0].get("details", [])) if matching else "missing")
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

# Main-branch workflow: enabled/disabled are healthy, partial installs are drift.
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_main_enabled.json" 2>&1 || true
l2_main_enabled=$(find_layer_ok "$T/out_main_enabled.json" "L2")
check "main_branch_enabled_state_is_healthy" "$l2_main_enabled" "ok"
printf '用户手写：不要自行新建功能分支或 worktree\n' >> "$CLAUDE_DIR/CLAUDE.md"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_main_advisory.json" 2>&1 || true
main_advisory_details=$(find_layer_details "$T/out_main_advisory.json" "L2")
case "$main_advisory_details" in *"managed main-branch policy is authoritative"*) check "main_branch_audit_advisory_is_reported" yes yes ;; *) check "main_branch_audit_advisory_is_reported" no yes ;; esac
if grep -Fq '用户手写：不要自行新建功能分支或 worktree' "$T/out_main_advisory.json"; then
  check "main_branch_audit_does_not_dump_user_text" no yes
else
  check "main_branch_audit_does_not_dump_user_text" yes yes
fi

MAIN_IMPORT='@MAIN-BRANCH-WORKFLOW.md'
MAIN_MARKER="$CLAUDE_DIR/.main-branch-workflow.disabled"
MAIN_RULE="$CLAUDE_DIR/MAIN-BRANCH-WORKFLOW.md"
touch "$MAIN_MARKER"
python3 - "$CLAUDE_DIR/CLAUDE.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
data = p.read_bytes()
imp = b'@MAIN-BRANCH-WORKFLOW.md'
p.write_bytes(b''.join(line for line in data.splitlines(keepends=True)
                       if line.rstrip(b'\r\n') != imp))
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_main_disabled.json" 2>&1 || true
l2_main_disabled=$(find_layer_ok "$T/out_main_disabled.json" "L2")
detail_main_disabled=$(find_layer_details "$T/out_main_disabled.json" "L2")
check "main_branch_opt_out_is_healthy" "$l2_main_disabled" "ok"
case "$detail_main_disabled" in *disabled*) check "main_branch_opt_out_is_reported" yes yes ;; *) check "main_branch_opt_out_is_reported" no yes ;; esac

rm -f "$MAIN_MARKER" "$MAIN_RULE"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_main_missing.json" 2>&1 || true
l2_main_missing=$(find_layer_ok "$T/out_main_missing.json" "L2")
detail_main_missing=$(find_layer_details "$T/out_main_missing.json" "L2")
check "main_branch_not_installed_is_drift" "$l2_main_missing" "failed"
case "$detail_main_missing" in *not-installed*enable*) check "main_branch_missing_state_has_setup_hint" yes yes ;; *) check "main_branch_missing_state_has_setup_hint" no yes ;; esac

cp "$REPO/claude/MAIN-BRANCH-WORKFLOW.md" "$MAIN_RULE"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_main_partial.json" 2>&1 || true
check "main_branch_partial_install_is_drift" "$(find_layer_ok "$T/out_main_partial.json" "L2")" "failed"
printf '@AGENT-EFFICIENCY.md\n@MAIN-BRANCH-WORKFLOW.md\n' > "$CLAUDE_DIR/CLAUDE.md"
touch "$MAIN_MARKER"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_main_stale_marker.json" 2>&1 || true
check "main_branch_marker_with_import_is_drift" "$(find_layer_ok "$T/out_main_stale_marker.json" "L2")" "failed"
rm -f "$MAIN_MARKER"
printf '@AGENT-EFFICIENCY.md\n@MAIN-BRANCH-WORKFLOW.md\n' > "$CLAUDE_DIR/CLAUDE.md"
printf 'local edit\\n' >> "$MAIN_RULE"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_main_copy_drift.json" 2>&1 || true
check "main_branch_modified_copy_is_drift" "$(find_layer_ok "$T/out_main_copy_drift.json" "L2")" "failed"
cp "$REPO/claude/MAIN-BRANCH-WORKFLOW.md" "$MAIN_RULE"
printf '@AGENT-EFFICIENCY.md\n@MAIN-BRANCH-WORKFLOW.md\n' > "$CLAUDE_DIR/CLAUDE.md"

# 7. N3: project with .drsg/audit-skip is skipped and does not fail audit
SKIP_PROJ="$T/skip_project"
mkdir -p "$SKIP_PROJ/.drsg"
touch "$SKIP_PROJ/.drsg/audit-skip"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$SKIP_PROJ" --json > "$T/out_n3.json" 2>&1 || true
overall_n3=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["overall_ok"])' "$T/out_n3.json" 2>/dev/null || echo "False")
check "n3_audit_skip_does_not_fail" "$overall_n3" "True"

echo "{\"projects\": {\"$PROJ\": {\"mcpServers\": {\"drsg\": {\"type\": \"http\"}, \"drsg-events\": {\"type\": \"stdio\"}}}, \"$T/r2_project\": {\"mcpServers\": {\"drsg\": {\"type\": \"http\"}, \"drsg-events\": {\"type\": \"stdio\"}}}}}" > "$CLAUDE_DIR/.claude.json"

# R2: test audit_deployment.py distinguishes kit legacy rules from user-written event.py rules
R2_PROJ="$T/r2_project"
mkdir -p "$R2_PROJ/.claude/hooks" "$R2_PROJ/.drsg"
cp -r "$REPO/tools/templates/hooks/." "$R2_PROJ/.claude/hooks/"
cat > "$R2_PROJ/.drsg/env" <<'EOF'
DRSG_TOKEN=token
DRSG_API=api
EOF
cat > "$R2_PROJ/CLAUDE.md" <<'EOF'
<!-- drsg-memory:events:begin -->
events
<!-- drsg-memory:events:end -->
EOF

# User written rule that contains 'event.py' but is NOT the kit legacy allow rule
cat > "$R2_PROJ/.claude/settings.local.json" <<EOF
{
  "hooks": {
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"command": "python3 pre_tool_use.py"}]}],
    "SessionStart": [{"matcher": "*", "hooks": [{"command": "python3 session_start.py"}]}],
    "UserPromptSubmit": [{"matcher": "*", "hooks": [{"command": "python3 user_prompt.py"}]}],
    "SessionEnd": [{"matcher": "*", "hooks": [{"command": "python3 session_end.py"}]}]
  },
  "permissions": {
    "allow": ["Bash(git checkout --ours scripts/memory-layer/event.py)"]
  }
}
EOF
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$R2_PROJ" --json > "$T/out_r2_custom.json" 2>&1 || true
l4_r2_custom=$(find_layer_ok "$T/out_r2_custom.json" "L4")
check "r2_user_custom_event_rule_not_drift" "$l4_r2_custom" "ok"

# Now add exact legacy rule
python3 - "$R2_PROJ/.claude/settings.local.json" "$DEPLOYED_TOOLS" <<'PY'
import json, sys
path, tools = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["permissions"]["allow"].append("Bash(python3 %s/event.py list *)" % tools)
json.dump(d, open(path, "w"))
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$R2_PROJ" --json > "$T/out_r2_legacy.json" 2>&1 || true
l4_r2_legacy=$(find_layer_ok "$T/out_r2_legacy.json" "L4")
check "r2_legacy_rule_is_drift" "$l4_r2_legacy" "failed"

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

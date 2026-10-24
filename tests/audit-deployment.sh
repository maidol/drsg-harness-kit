#!/usr/bin/env bash
# Synthetic contract tests for tools/audit_deployment.py.
# Fully hermetic: uses temporary directories for repository, deployed tools,
# global claude configuration, and target projects.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${AUDIT_SOURCE:-$HERE/../tools/audit_deployment.py}"
ONLY="${ONLY:-}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

RAN=0
OK=0
check() {
  if [ -n "$ONLY" ] && [ "$ONLY" != "$1" ]; then return; fi
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
mkdir -p "$T/xdg" "$T/home" "$T/drsg-memory"
export HOME="$T/home"
export DRSG_MEM_DIR="$T/drsg-memory"
export XDG_CONFIG_HOME="$T/xdg"
cp "$HERE/../tools/templates/compact-instructions.md" "$REPO/tools/templates/compact-instructions.md"
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
cp "$REPO/tools/templates/compact-instructions.md" "$DEPLOYED_TOOLS/templates/compact-instructions.md"
cp -r "$REPO/tools/templates/hooks/." "$PROJ/.claude/hooks/"
chmod +x "$PROJ/.claude/hooks/"*.py

echo "rules" > "$REPO/claude/AGENT-EFFICIENCY.md"
cp "$REPO/claude/AGENT-EFFICIENCY.md" "$CLAUDE_DIR/AGENT-EFFICIENCY.md"
for rule in AGENT-EFFICIENCY-TESTING.md AGENT-EFFICIENCY-OPERATIONS.md; do
  echo "$rule" > "$REPO/claude/$rule"
  cp "$REPO/claude/$rule" "$CLAUDE_DIR/$rule"
done
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
    "Stop": [
      {"matcher": "*", "hooks": [{"command": "python3 /path/event-poller.py"}]},
      {"matcher": "*", "hooks": [{"command": "python3 /path/textual-tool-call-guard.py"}]}
    ],
    "PostToolUse": [{"matcher": "*", "hooks": [{"command": "python3 /path/single-tool-streak.py"}]}],
    "PreToolUse": [{"matcher": "Bash|Read|Grep", "hooks": [{"command": "python3 /path/sensitive-file-read-guard.py"}]}]
  }
}
JSON
python3 - "$CLAUDE_DIR/settings.json" "$DEPLOYED_TOOLS/reviewer-assist-stop-guard.py" <<'PY'
import json, sys
path, script = sys.argv[1:]
data = json.load(open(path))
data["hooks"]["Stop"].append({
    "matcher": "*",
    "hooks": [{"type": "command", "command": "python3 " + script, "timeout": 3}],
})
json.dump(data, open(path, "w"))
PY
chmod 600 "$CLAUDE_DIR/settings.json"

cat > "$PROJ/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"command": "python3 pre_tool_use.py"}]},
      {"matcher": "Bash|Write|Edit|NotebookEdit", "hooks": [{"command": "python3 /path/superpowers-doc-guard.py"}]}
    ],
    "SessionStart": [{"matcher": "startup|resume|compact|clear", "hooks": [{"command": "python3 session_start.py"}]}],
    "PreCompact": [{"hooks": [{"command": "python3 compact_handoff.py"}]}],
    "PostCompact": [{"hooks": [{"command": "python3 compact_handoff.py"}]}],
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
XDG_CONFIG_HOME="$XDG_CONFIG_HOME" HOME="$T/home" bash "$HERE/../tools/install.sh" --compact-instructions "$PROJ" > "$T/install-compact.out" 2>&1

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
check "synced on-demand rules have no L2 audit issue" \
  "$(find_layer_details "$T/out1.json" "L2" | grep -Ec '(Missing|Drift in|Unexpected @-import).*AGENT-EFFICIENCY-(TESTING|OPERATIONS)\.md' || true)" 0
check "reviewer-assist-valid-registration-passes" \
  "$(find_layer_ok "$T/out1.json" "L2")/$(find_layer_details "$T/out1.json" "L2" | grep -Fc 'Global reviewer-assist Stop hook missing or misconfigured' || true)" ok/0
cp "$CLAUDE_DIR/settings.json" "$T/reviewer-assist-settings.json"
reviewer_assist_audit_case() {
  local name="$1" mutation="$2"
  python3 - "$T/reviewer-assist-settings.json" "$CLAUDE_DIR/settings.json" \
    "$DEPLOYED_TOOLS/reviewer-assist-stop-guard.py" "$mutation" <<'PY'
import copy, json, sys
source, target, script, mutation = sys.argv[1:]
data = json.load(open(source))
groups = data.setdefault("hooks", {}).setdefault("Stop", [])
command = "python3 " + script
matches = [(group, hook) for group in groups for hook in group.get("hooks", [])
           if hook.get("command") == command]
if mutation == "missing":
    data["hooks"]["Stop"] = [
        group for group in groups
        if not any(hook.get("command") == command for hook in group.get("hooks", []))]
elif mutation == "duplicate":
    group, hook = matches[0]
    group["hooks"].append(copy.deepcopy(hook))
elif mutation == "timeout":
    matches[0][1]["timeout"] = 5
elif mutation == "async":
    matches[0][1]["asyncRewake"] = True
elif mutation == "event":
    group, hook = matches[0]
    group["hooks"].remove(hook)
    data["hooks"].setdefault("SessionStart", []).append({"matcher": "*", "hooks": [hook]})
elif mutation == "path":
    matches[0][1]["command"] = "python3 /different/path/reviewer-assist-stop-guard.py"
json.dump(data, open(target, "w"))
PY
  python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" \
    --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_reviewer_assist.json" 2>&1 || true
  check "$name" \
    "$(find_layer_ok "$T/out_reviewer_assist.json" "L2")/$(find_layer_details "$T/out_reviewer_assist.json" "L2" | grep -Fc 'Global reviewer-assist Stop hook missing or misconfigured' || true)" failed/1
  cp "$T/reviewer-assist-settings.json" "$CLAUDE_DIR/settings.json"
}
reviewer_assist_audit_case "reviewer-assist-missing-registration" missing
reviewer_assist_audit_case "reviewer-assist-duplicate-registration" duplicate
reviewer_assist_audit_case "reviewer-assist-wrong-timeout" timeout
reviewer_assist_audit_case "reviewer-assist-async-registration" async
reviewer_assist_audit_case "reviewer-assist-wrong-event" event
reviewer_assist_audit_case "reviewer-assist-wrong-command-path" path
for rule in AGENT-EFFICIENCY-TESTING.md AGENT-EFFICIENCY-OPERATIONS.md; do
  short="${rule#AGENT-EFFICIENCY-}"
  short="${short%.md}"
  deployed="$CLAUDE_DIR/$rule"
  source_rule="$REPO/claude/$rule"
  mv "$source_rule" "$T/$rule.source"
  python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_${short}_source_missing.json" 2>&1 || true
  check "on-demand-$short-missing-source-is-reported" \
    "$(find_layer_details "$T/out_${short}_source_missing.json" "L2" | grep -Fc "Missing repository source $source_rule" || true)" 1
  mv "$T/$rule.source" "$source_rule"

  mv "$deployed" "$T/$rule"
  python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_${short}_missing.json" 2>&1 || true
  check "on-demand-$short-missing-copy-is-reported" \
    "$(find_layer_details "$T/out_${short}_missing.json" "L2" | grep -Fc "Missing $deployed" || true)" 1
  mv "$T/$rule" "$deployed"

  printf 'local edit\\n' >> "$deployed"
  python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_${short}_drift.json" 2>&1 || true
  check "on-demand-$short-drift-is-reported" \
    "$(find_layer_details "$T/out_${short}_drift.json" "L2" | grep -Fc "Drift in $deployed vs repository source" || true)" 1
  cp "$REPO/claude/$rule" "$deployed"

  printf '@%s\n' "$rule" >> "$CLAUDE_DIR/CLAUDE.md"
  python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_${short}_import.json" 2>&1 || true
  check "on-demand-$short-import-is-reported" \
    "$(find_layer_details "$T/out_${short}_import.json" "L2" | grep -Fc "Unexpected @-import of $rule in $CLAUDE_DIR/CLAUDE.md" || true)" 1
  python3 - "$CLAUDE_DIR/CLAUDE.md" "$rule" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
import_line = ("@" + sys.argv[2]).encode()
path.write_bytes(b"".join(line for line in path.read_bytes().splitlines(keepends=True)
                       if line.rstrip(b"\r\n") != import_line))
PY

  printf '@~/.claude/%s \n' "$rule" >> "$CLAUDE_DIR/CLAUDE.md"
  python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_${short}_prefixed_import.json" 2>&1 || true
  check "on-demand-$short-prefixed-import-is-reported" "$(find_layer_details "$T/out_${short}_prefixed_import.json" "L2" | grep -Fc "Unexpected @-import of $rule in $CLAUDE_DIR/CLAUDE.md" || true)" 1
  python3 - "$CLAUDE_DIR/CLAUDE.md" "$rule" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
import_line = ("@~/.claude/" + sys.argv[2] + " ").encode()
path.write_bytes(b"".join(line for line in path.read_bytes().splitlines(keepends=True)
                       if line.rstrip(b"\r\n") != import_line))
PY
done

# install.sh --audit run from the deployed copy passes a --repo that has no claude/; the on-demand source check must stay quiet there.
python3 "$AUDIT" --repo "$DEPLOYED_TOOLS" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_on_demand_not_kit.json" 2>&1 || true
check "on-demand-source-check-skipped-outside-kit-checkout" \
  "$(find_layer_details "$T/out_on_demand_not_kit.json" "L2" | grep -Fc "Missing repository source" || true)" 0
check "PostCompact registration passes L4 when present" "$(find_layer_details "$T/out1.json" "L4" | grep -c 'compact_handoff.py (PostCompact)' || true)" "0"
check "PreCompact registration passes L4 when present" "$(find_layer_details "$T/out1.json" "L4" | grep -c 'compact_handoff.py (PreCompact)' || true)" "0"
check "SessionStart matcher with clear passes audit" "$(find_layer_details "$T/out1.json" "L4" | grep -c 'SessionStart matcher missing clear' || true)" "0"
check "managed compact block passes audit" "$(find_layer_details "$T/out1.json" "L4" | grep -c 'Compact instructions block missing\|differs from template\|repeated or malformed' || true)" "0"
cp "$PROJ/CLAUDE.md" "$T/claude-project.md"
python3 - "$PROJ/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
begin = b"<!-- BEGIN DRSG COMPACT INSTRUCTIONS -->"
end = b"<!-- END DRSG COMPACT INSTRUCTIONS -->"
start = data.find(begin)
finish = data.find(end, start) + len(end)
open(p, "wb").write(data[:start] + data[finish:])
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_compact_missing.json" 2>&1 || true
check "missing compact block is audit drift" "$(find_layer_details "$T/out_compact_missing.json" "L4" | grep -c 'Compact instructions block missing' || true)" "1"
cp "$T/claude-project.md" "$PROJ/CLAUDE.md"
python3 - "$PROJ/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
open(p, "wb").write(data.replace("逐项写".encode(), "逐行写".encode(), 1))
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_compact_drift.json" 2>&1 || true
check "modified compact block is audit drift" "$(find_layer_details "$T/out_compact_drift.json" "L4" | grep -c 'Compact instructions block differs from template' || true)" "1"
cp "$T/claude-project.md" "$PROJ/CLAUDE.md"
python3 - "$PROJ/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
begin = b"<!-- BEGIN DRSG COMPACT INSTRUCTIONS -->"
end = b"<!-- END DRSG COMPACT INSTRUCTIONS -->"
start = data.find(begin)
finish = data.find(end, start) + len(end)
block = data[start:finish]
open(p, "wb").write(data + b"\\n" + block + b"\\n")
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_compact_duplicate.json" 2>&1 || true
check "duplicate compact block is audit drift" "$(find_layer_details "$T/out_compact_duplicate.json" "L4" | grep -c 'Compact instructions block repeated or malformed' || true)" "1"
cp "$T/claude-project.md" "$PROJ/CLAUDE.md"
python3 - "$PROJ/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
data = open(p, "rb").read()
end = b"<!-- END DRSG COMPACT INSTRUCTIONS -->"
open(p, "wb").write(data.replace(end, b"", 1))
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_compact_unpaired.json" 2>&1 || true
check "unpaired compact marker is audit drift" "$(find_layer_details "$T/out_compact_unpaired.json" "L4" | grep -c 'Compact instructions block repeated or malformed' || true)" "1"
mv "$T/claude-project.md" "$PROJ/CLAUDE.md"
# D4: a tracked project gets an advisory only, with no audit failure.
printf '{"projects":{"%s":{"mcpServers":{"drsg":{},"drsg-events":{}}}}}' "$PROJ" > "$CLAUDE_DIR/.claude.json"
git -C "$PROJ" init -q
git -C "$PROJ" add CLAUDE.md
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_compact_tracked.json" 2>&1 || true
check "tracked CLAUDE.md advisory does not fail audit" "$(find_layer_ok "$T/out_compact_tracked.json" "L4")/$(find_layer_details "$T/out_compact_tracked.json" "L4" | grep -Fc '这一段会出现在 git diff 里，需要你自己决定要不要提交。' || true)" ok/1
# The drsg entry's Bearer token must match .drsg/env (DRSG_TOKEN=token), by hash.
audit_drsg_header() {
  printf '{"projects":{"%s":{"mcpServers":{"drsg":{"type":"http","headers":{"Authorization":"%s"}},"drsg-events":{}}}}}' \
    "$PROJ" "$1" > "$CLAUDE_DIR/.claude.json"
  python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_drsg_header.json" 2>&1 || true
  echo "$(find_layer_ok "$T/out_drsg_header.json" "L4")/$(find_layer_details "$T/out_drsg_header.json" "L4" | grep -c 'drsg MCP token differs' || true)"
}
check "drsg header token differing from .drsg/env is audit drift" "$(audit_drsg_header 'Bearer stale-value')" failed/1
check "token mismatch report does not print either token" \
  "$(grep -Ec 'stale-value|=token' "$T/out_drsg_header.json" || true)" 0
check "drsg header token matching .drsg/env passes" "$(audit_drsg_header 'Bearer token')" ok/0
check "drsg header that is not a literal Bearer token is not compared" "$(audit_drsg_header 'Bearer ${DRSG_TOKEN}')" ok/0
printf '{"projects":{"%s":{"mcpServers":{"drsg":{},"drsg-events":{}}}}}' "$PROJ" > "$CLAUDE_DIR/.claude.json"
# Opt-out must not read CLAUDE.md, including when it is absent.
cp "$PROJ/CLAUDE.md" "$T/claude-before-optout.md"
XDG_CONFIG_HOME="$XDG_CONFIG_HOME" HOME="$T/home" bash "$HERE/../setup.sh" --no-compact-instructions "$PROJ" > "$T/compact-optout.out" 2>&1
cmp -s "$PROJ/CLAUDE.md" "$T/claude-before-optout.md"
check "setup opt-out leaves CLAUDE.md unchanged" "$?" 0
check "per-project opt-out marker stored with private mode" "$(python3 - "$XDG_CONFIG_HOME" "$PROJ" <<'PY'
import hashlib, os, stat, sys
root, project = sys.argv[1:]
marker = os.path.join(root, "drsg", "compact-instructions-opt-outs",
                      hashlib.sha256(os.path.realpath(project).encode()).hexdigest())
print("yes" if os.path.isfile(marker) and stat.S_IMODE(os.stat(marker).st_mode) == 0o600 else "no")
PY
)" yes
mv "$PROJ/CLAUDE.md" "$T/claude-while-opted-out.md"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_compact_optout.json" 2>&1 || true
check "audit skips absent CLAUDE.md for opted-out project" "$(find_layer_ok "$T/out_compact_optout.json" "L4")" ok
check "audit reports compact opt-out" "$(find_layer_details "$T/out_compact_optout.json" "L4" | grep -c 'Compact instructions intentionally disabled' || true)" 1
cp "$T/claude-while-opted-out.md" "$PROJ/CLAUDE.md"
XDG_CONFIG_HOME="$XDG_CONFIG_HOME" HOME="$T/home" bash "$HERE/../setup.sh" --compact-instructions "$PROJ" > "$T/compact-enable.out" 2>&1
check "setup enable restores block and clears opt-out" "$(grep -c 'BEGIN DRSG COMPACT INSTRUCTIONS' "$PROJ/CLAUDE.md" || true)/$(test ! -e "$(python3 - "$XDG_CONFIG_HOME" "$PROJ" <<'PY'
import hashlib, os, sys
print(os.path.join(sys.argv[1], "drsg", "compact-instructions-opt-outs", hashlib.sha256(os.path.realpath(sys.argv[2]).encode()).hexdigest()))
PY
)" && echo absent)" 1/absent
XDG_CONFIG_HOME="$XDG_CONFIG_HOME" HOME="$T/home" bash "$HERE/../tools/install.sh" --compact-instructions "$PROJ" > "$T/compact-idempotent.out" 2>&1
cmp -s "$PROJ/CLAUDE.md" "$T/claude-before-optout.md"
check "reinstall is idempotent and preserves outside text" "$?" 0
cp "$PROJ/.claude/settings.local.json" "$T/settings.local.json"
python3 - "$PROJ/.claude/settings.local.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["hooks"]["SessionStart"][0]["matcher"] = "startup|resume|compact"
json.dump(data, open(path, "w"))
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_clear_missing.json" 2>&1 || true
check "old SessionStart matcher is audit drift" "$(find_layer_details "$T/out_clear_missing.json" "L4" | grep -c 'SessionStart matcher missing clear' || true)" "1"
mv "$T/settings.local.json" "$PROJ/.claude/settings.local.json"
cp "$PROJ/.claude/settings.local.json" "$T/settings.local.json"
python3 - "$PROJ/.claude/settings.local.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["hooks"].pop("PostCompact", None)
json.dump(data, open(path, "w"))
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_postcompact_missing.json" 2>&1 || true
check "missing PostCompact registration is audit drift" "$(find_layer_details "$T/out_postcompact_missing.json" "L4" | grep -c 'compact_handoff.py (PostCompact)' || true)" "1"
mv "$T/settings.local.json" "$PROJ/.claude/settings.local.json"
cp "$PROJ/.claude/settings.local.json" "$T/settings.local.json"
python3 - "$PROJ/.claude/settings.local.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["hooks"].pop("PreCompact", None)
json.dump(data, open(path, "w"))
PY
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_precompact_missing.json" 2>&1 || true
check "missing PreCompact registration is audit drift" "$(find_layer_details "$T/out_precompact_missing.json" "L4" | grep -c 'compact_handoff.py (PreCompact)' || true)" "1"
mv "$T/settings.local.json" "$PROJ/.claude/settings.local.json"

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

# 6b. CROSS-PROJECT-REVIEW.md is audited like AGENT-EFFICIENCY.md: a missing or
# modified copy fails L2, a synced copy passes.
chmod 600 "$CLAUDE_DIR/settings.json"
echo "cross" > "$REPO/claude/CROSS-PROJECT-REVIEW.md"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_cross_missing.json" 2>&1 || true
check "cross_review_missing_copy_is_drift" "$(find_layer_ok "$T/out_cross_missing.json" "L2")/$(find_layer_details "$T/out_cross_missing.json" "L2" | grep -c 'Missing .*CROSS-PROJECT-REVIEW.md' || true)" "failed/1"
cp "$REPO/claude/CROSS-PROJECT-REVIEW.md" "$CLAUDE_DIR/CROSS-PROJECT-REVIEW.md"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_cross_ok.json" 2>&1 || true
check "cross_review_synced_copy_is_ok" "$(find_layer_ok "$T/out_cross_ok.json" "L2")" "ok"
echo "local edit" >> "$CLAUDE_DIR/CROSS-PROJECT-REVIEW.md"
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$PROJ" --json > "$T/out_cross_drift.json" 2>&1 || true
check "cross_review_modified_copy_is_drift" "$(find_layer_ok "$T/out_cross_drift.json" "L2")/$(find_layer_details "$T/out_cross_drift.json" "L2" | grep -c 'Drift in .*CROSS-PROJECT-REVIEW.md' || true)" "failed/1"
rm -f "$REPO/claude/CROSS-PROJECT-REVIEW.md" "$CLAUDE_DIR/CROSS-PROJECT-REVIEW.md"
chmod 644 "$CLAUDE_DIR/settings.json"
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
XDG_CONFIG_HOME="$XDG_CONFIG_HOME" HOME="$T/home" bash "$HERE/../tools/install.sh" --compact-instructions "$R2_PROJ" > "$T/install-r2-compact.out" 2>&1

# User written rule that contains 'event.py' but is NOT the kit legacy allow rule
cat > "$R2_PROJ/.claude/settings.local.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"command": "python3 pre_tool_use.py"}]},
      {"matcher": "Bash|Write|Edit|NotebookEdit", "hooks": [{"command": "python3 /path/superpowers-doc-guard.py"}]}
    ],
    "SessionStart": [{"matcher": "startup|resume|compact|clear", "hooks": [{"command": "python3 session_start.py"}]}],
    "PreCompact": [{"hooks": [{"command": "python3 compact_handoff.py"}]}],
    "PostCompact": [{"hooks": [{"command": "python3 compact_handoff.py"}]}],
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

# The pre-commit report follows core.hooksPath, where a project may keep its hook.
git -C "$R2_PROJ" init -q
mkdir -p "$R2_PROJ/.githooks"
printf '#!/bin/sh\npython3 completeness-guard.py --staged\n' > "$R2_PROJ/.githooks/pre-commit"
chmod +x "$R2_PROJ/.githooks/pre-commit"
git -C "$R2_PROJ" config core.hooksPath .githooks
python3 "$AUDIT" --repo "$REPO" --tools-dir "$DEPLOYED_TOOLS" --claude-dir "$CLAUDE_DIR" --project "$R2_PROJ" --json > "$T/out_hookspath.json" 2>&1 || true
case "$(find_layer_details "$T/out_hookspath.json" "L4")" in
  *"completeness-guard pre-commit hook active"*) check "l4_precommit_follows_core_hookspath" yes yes ;;
  *) check "l4_precommit_follows_core_hookspath" no yes ;;
esac
case "$(find_layer_details "$T/out_hookspath.json" "L4")" in
  *"forbidden-literals guard not installed"*) check "l4_forbidden_literals_hookspath_reported" yes yes ;;
  *) check "l4_forbidden_literals_hookspath_reported" no yes ;;
esac
rm -rf "$R2_PROJ/.git" "$R2_PROJ/.githooks"

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

# Superpowers archive L4 contract. Keep this in an isolated temporary HOME/XDG.
python3 - "$HERE/.." <<'PY' || exit $?
import hashlib
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
from unittest import mock

repo = pathlib.Path(sys.argv[1])
tools = repo / "tools"
sys.path.insert(0, str(tools))
audit_source = pathlib.Path(os.environ.get("AUDIT_SOURCE", tools / "audit_deployment.py"))
spec = importlib.util.spec_from_file_location("audit_deployment", audit_source)
audit_deployment = importlib.util.module_from_spec(spec)
sys.modules["audit_deployment"] = audit_deployment
spec.loader.exec_module(audit_deployment)
import superpowers_docs

checks = 0
failures = []
def check(name, got, want):
    global checks
    checks += 1
    if got == want:
        print("ok   " + name)
    else:
        failures.append("%s: got %r want %r" % (name, got, want))
        print("FAIL " + failures[-1])

def has_detail(layer, text):
    return any(text in line for line in layer["details"])

def audit(project, known=...):
    claude_json = root / "claude.json"
    claude_json.write_text(json.dumps({"projects": {str(project): {"mcpServers": {
        "drsg": {}, "drsg-events": {}}}}}), encoding="utf-8")
    def run():
        return audit_deployment.check_layer4(
            str(project), str(claude_json), str(tools), None)
    if known is ...:
        return run()
    with mock.patch.object(superpowers_docs, "_known_projects", return_value=known):
        return run()

def set_config(path, reviewer):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"reviewer": str(reviewer)}), encoding="utf-8")

def project_fixture(root, name):
    project = root / name
    (project / ".claude" / "hooks").mkdir(parents=True)
    (project / ".drsg").mkdir()
    (project / ".drsg" / "env").write_text("DRSG_TOKEN=test\nDRSG_API=test\n")
    (project / "CLAUDE.md").write_text(
        "<!-- drsg-memory:events:begin -->\nevents\n"
        "<!-- drsg-memory:events:end -->\n", encoding="utf-8")
    return project

with tempfile.TemporaryDirectory(prefix="audit-superpowers-") as td:
    root = pathlib.Path(td)
    home, memory, xdg = root / "home", root / "memory", root / "xdg"
    reviewer, moved = root / "reviewer", root / "reviewer-moved"
    for path in (home, memory, xdg, reviewer, moved):
        path.mkdir(parents=True, exist_ok=True)
    os.environ.update({"HOME": str(home), "DRSG_MEM_DIR": str(memory),
                       "XDG_CONFIG_HOME": str(xdg), "DRSG_API": "http://127.0.0.1:1/rpc"})
    config = memory / "commit-auth.json"
    template = str(tools / "templates" / "settings-hooks.json")
    project = project_fixture(root, "consumer")

    # Inactive configuration is a supported state; the fixed guard is still required.
    superpowers_docs.install_project(str(project), [str(project)], hooks_template=template)
    layer = audit(project, [str(project)])
    check("inactive reviewer configuration is healthy", layer["ok"], True)

    set_config(config, reviewer)
    result = superpowers_docs.install_project(str(project), [str(project)], hooks_template=template)
    check("audit fixture installs enabled archive", result["ok"], True)
    layer = audit(project, [str(project)])
    check("enabled archive with matching state and narrow allow is healthy", layer["ok"], True)

    # An unavailable project registry is advisory; it must not silently hide audit status.
    layer = audit(project, None)
    check("registry fallback warning does not fail healthy archive", layer["ok"], True)
    check("registry fallback is visible as warning", has_detail(layer, "registry"), True)

    collision = root / "other" / "consumer"
    collision.mkdir(parents=True)
    layer = audit(project, [str(project), str(collision)])
    check("known basename collision is audit drift", layer["ok"], False)
    check("basename collision reason is visible", has_detail(layer, "conflict"), True)

    claude = project / "CLAUDE.md"
    original_claude = claude.read_bytes()
    begin = b"<!-- drsg-memory:superpowers-docs:begin -->"
    end = b"<!-- drsg-memory:superpowers-docs:end -->"
    claude.write_bytes(original_claude.replace(begin, b"", 1).replace(end, b"", 1))
    layer = audit(project, [str(project)])
    check("missing Superpowers marker is audit drift", layer["ok"], False)
    claude.write_bytes(original_claude + b"\n" + original_claude[original_claude.find(begin):])
    layer = audit(project, [str(project)])
    check("duplicate Superpowers markers are audit drift", layer["ok"], False)
    claude.write_bytes(original_claude)

    settings_path = project / ".claude" / "settings.local.json"
    original_settings = settings_path.read_bytes()
    data = json.loads(original_settings)
    allow = data["permissions"]["additionalDirectories"]
    allow.append(str(reviewer))
    settings_path.write_text(json.dumps(data), encoding="utf-8")
    layer = audit(project, [str(project)])
    check("reviewer-wide additionalDirectory is audit drift", layer["ok"], False)
    settings_path.write_bytes(original_settings)

    # A changed reviewer must not leave the old managed rule or allow silently accepted.
    set_config(config, moved)
    layer = audit(project, [str(project)])
    check("reviewer migration residual is audit drift", layer["ok"], False)
    check("reviewer migration reason is visible", has_detail(layer, "reviewer"), True)
    set_config(config, reviewer)

    state_path = xdg / "drsg" / "superpowers-docs-state" / (
        hashlib.sha256(os.path.realpath(project).encode()).hexdigest() + ".json")
    state_bytes = state_path.read_bytes()
    state_path.unlink()
    layer = audit(project, [str(project)])
    check("missing ownership state is audit drift", layer["ok"], False)
    state_path.write_bytes(state_bytes)
    state = json.loads(state_bytes)
    state["project"] = str(root / "wrong-project")
    state_path.write_text(json.dumps(state), encoding="utf-8")
    layer = audit(project, [str(project)])
    check("mismatched ownership state is audit drift", layer["ok"], False)
    state_path.write_bytes(state_bytes)

    # The reviewer project gets its own rule but never an additionalDirectories allow.
    self_project = project_fixture(root, "reviewer")
    set_config(config, self_project)
    result = superpowers_docs.install_project(str(self_project), [str(self_project)],
                                              hooks_template=template)
    layer = audit(self_project, [str(self_project)])
    check("reviewer self-project is healthy", result["ok"] and layer["ok"], True)
    self_settings = json.loads((self_project / ".claude" / "settings.local.json").read_text())
    check("reviewer self-project has no archive allow",
          self_settings.get("permissions", {}).get("additionalDirectories", []), [])

    # Opt-out removes the rule and allow, but must not remove the fixed hook registration.
    set_config(config, reviewer)
    superpowers_docs.set_opt_out(str(project), True)
    layer = audit(project, [str(project)])
    check("opt-out project is healthy", layer["ok"], True)
    check("opt-out retains the fixed guard registration", has_detail(layer, "superpowers-doc-guard.py"), True)
    optout_settings = settings_path.read_bytes()
    data = json.loads(optout_settings)
    data["permissions"]["additionalDirectories"].append(
        str(reviewer / "reviews" / "consumer" / "docs" / "superpowers"))
    settings_path.write_text(json.dumps(data), encoding="utf-8")
    layer = audit(project, [str(project)])
    check("opt-out with stale archive allow is audit drift", layer["ok"], False)
    settings_path.write_bytes(optout_settings)

    # Settings failures do not leak file contents and all registration shapes are audited.
    settings_path.write_bytes(b"{invalid settings")
    layer = audit(project, [str(project)])
    check("invalid settings JSON is audit drift", layer["ok"], False)
    check("invalid settings contents are not reported", has_detail(layer, "invalid settings"), False)
    settings_path.write_bytes(original_settings)
    superpowers_docs.set_opt_out(str(project), False)
    superpowers_docs.install_project(str(project), [str(project)], hooks_template=template)
    original_settings = settings_path.read_bytes()

    for name, change, fragment in (
        ("missing guard registration", lambda d: d["hooks"]["PreToolUse"].pop(), "registration"),
        ("duplicate guard registration", lambda d: d["hooks"]["PreToolUse"].append(
            dict(d["hooks"]["PreToolUse"][-1])), "duplicate"),
        ("wrong guard matcher", lambda d: d["hooks"]["PreToolUse"][-1].update(
            {"matcher": "Bash|Write"}), "matcher"),
    ):
        data = json.loads(original_settings)
        change(data)
        settings_path.write_text(json.dumps(data), encoding="utf-8")
        layer = audit(project, [str(project)])
        check(name + " is audit drift with reason visible",
              not layer["ok"] and has_detail(layer, fragment), True)
        settings_path.write_bytes(original_settings)

if failures:
    print("FAIL %d/%d" % (checks - len(failures), checks))
    sys.exit(1)
print("PASS %d/%d" % (checks, checks))
PY

if [ -n "$ONLY" ] && [ "$RAN" -eq 0 ]; then
  echo "FAIL requested assertion was not run: $ONLY"
  exit 2
fi
printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

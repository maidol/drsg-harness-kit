#!/usr/bin/env bash
# Contract tests for the three follow-ups after R1-R4 (2026-10-08):
#   F1 permission-guard docs: plan scripts must not install executables
#   F2 codegraph-router: note on an empty literal graph_grep with regex syntax
#   F3 audit_deployment L4: drsg / drsg-events MCP registered for the project
# Hermetic: no daemon, no network, no real ~/.claude.json.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
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

# ---- F1: docs -------------------------------------------------------------
check f1_doc_en "$(grep -c 'plain data only' "$REPO/tools/README.md")" 1
check f1_doc_zh "$(grep -c '只允许分类器把 DIR 下的其他文件当数据读' "$REPO/tools/README.zh-CN.md")" 1

# ---- F2: router note ------------------------------------------------------
router() {  # router <case>; prints one word
  python3 - "$REPO/tools/codegraph-router.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("router", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
case = sys.argv[2]
sent = {}
reply = {"empty": "no matches",
         "hit": "tools/x.py:3: hint(\n    in x.f",
         "upstream_note": "no matches\nnote: the pattern contains `|`, and this search is literal"}
m.resolve_repo = lambda r: {"name": "x", "plane": "x"}
def fake(entry, tool, payload, _r=[None]):
    sent.update(payload)
    return reply[_r[0]], False
m.call_upstream = fake
def run(tool, args, r):
    fake.__defaults__[0][0] = r
    return m.call_tool(tool, args)[0]
noted = lambda s: "noted" if "regex: true" in s.split("\n", 2)[-1] and s.count("note:") == 1 else "quiet"
if case == "escaped_paren":
    print(noted(run("graph_grep", {"repo": "x", "pattern": "hint\\("}, "empty")))
elif case == "bracket_class":
    print(noted(run("graph_grep", {"repo": "x", "pattern": "v[0-9]+"}, "empty")))
elif case == "anchor":
    print(noted(run("graph_grep", {"repo": "x", "pattern": "^def "}, "empty")))
elif case == "regex_on":
    out = run("graph_grep", {"repo": "x", "pattern": "hint\\(", "regex": True}, "empty")
    print("noted" if "note:" in out else ("quiet" if sent.get("regex") is True else "dropped"))
elif case == "plain_literal":
    print(noted(run("graph_grep", {"repo": "x", "pattern": "refreshSkew"}, "empty")))
elif case == "dotted_literal":
    print(noted(run("graph_grep", {"repo": "x", "pattern": "w.hint(Hint{"}, "empty")))
elif case == "has_hits":
    print(noted(run("graph_grep", {"repo": "x", "pattern": "hint\\("}, "hit")))
elif case == "upstream_noted":
    out = run("graph_grep", {"repo": "x", "pattern": "a|b"}, "upstream_note")
    print("notes=%d" % out.count("note:"))
elif case == "other_tool":
    print(noted(run("graph_context", {"repo": "x", "name": "hint\\(", "pattern": "hint\\("}, "empty")))
PY
}
check f2_escaped_paren_noted   "$(router escaped_paren)"  noted
check f2_bracket_class_noted   "$(router bracket_class)"  noted
check f2_anchor_noted          "$(router anchor)"         noted
check f2_regex_on_quiet        "$(router regex_on)"       quiet
check f2_plain_literal_quiet   "$(router plain_literal)"  quiet
check f2_dotted_literal_quiet  "$(router dotted_literal)" quiet
check f2_hits_quiet            "$(router has_hits)"       quiet
check f2_upstream_note_once    "$(router upstream_noted)" notes=1
check f2_other_tools_untouched "$(router other_tool)"     quiet

# ---- F3: audit L4 MCP registration ----------------------------------------
P="$T/proj"
OTHER="$T/other"
mkdir -p "$P/.claude/hooks" "$P/.drsg" "$OTHER"
cat > "$P/.claude/settings.local.json" <<'JSON'
{"hooks": {
  "PreToolUse": [{"matcher": "Bash", "hooks": [{"command": "python3 pre_tool_use.py"}]}],
  "SessionStart": [{"matcher": "*", "hooks": [{"command": "python3 session_start.py"}]}],
  "UserPromptSubmit": [{"matcher": "*", "hooks": [{"command": "python3 user_prompt.py"}]}],
  "SessionEnd": [{"matcher": "*", "hooks": [{"command": "python3 session_end.py"}]}]}}
JSON
printf 'DRSG_TOKEN=t\nDRSG_API=a\n' > "$P/.drsg/env"
printf '<!-- drsg-memory:events:begin -->\nx\n<!-- drsg-memory:events:end -->\n' > "$P/CLAUDE.md"

cfg() {  # cfg <file> <mode>: write a .claude.json for $P
  python3 - "$1" "$2" "$P" "$OTHER" <<'PY'
import json, sys
path, mode, proj, other = sys.argv[1:]
both = {"drsg": {"type": "http"}, "drsg-events": {"type": "stdio"}}
d = {"projects": {}}
if mode == "local_both":
    d["projects"][proj] = {"mcpServers": both}
elif mode == "local_drsg_only":
    d["projects"][proj] = {"mcpServers": {"drsg": {"type": "http"}}}
elif mode == "user_both":
    d["mcpServers"] = both
    d["projects"][proj] = {"mcpServers": {}}
elif mode == "other_project":
    d["projects"][other] = {"mcpServers": both}
json.dump(d, open(path, "w"))
PY
}

audit() {  # audit <mode>: prints "<ok|failed> <details joined>"
  rm -f "$T/c.json"
  [ "$1" = "unreadable" ] || cfg "$T/c.json" "$1"
  python3 - "$REPO/tools/audit_deployment.py" "$P" "$T/c.json" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("audit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
r = m.check_layer4(sys.argv[2], sys.argv[3], "/opt/tools")
print("ok" if r["ok"] else "failed", " | ".join(r["details"]))
PY
}
first() { echo "$1" | cut -d' ' -f1; }

out="$(audit local_drsg_only)"
check f3_missing_events_is_drift "$(first "$out")" failed
check f3_names_missing_server "$(echo "$out" | grep -c 'not registered for this project: drsg-events')" 1
check f3_gives_fix_command "$(echo "$out" | grep -c 'claude mcp add --scope local drsg-events -- python3 /opt/tools/mcp_events.py')" 1
check f3_drsg_present_not_reported "$(echo "$out" | grep -c 'not registered for this project: drsg -')" 0
check f3_both_local_ok "$(first "$(audit local_both)")" ok
check f3_user_scope_counts "$(first "$(audit user_both)")" ok
out="$(audit other_project)"
check f3_other_project_does_not_count "$(echo "$out" | grep -o 'not registered for this project' | wc -l | tr -d ' ')" 2
check f3_unreadable_is_drift "$(first "$(audit unreadable)")" failed

# claude_json_path follows --claude-dir / CLAUDE_CONFIG_DIR, else ~/.claude.json
path_of() {
  env -u CLAUDE_CONFIG_DIR HOME="$T/home" ${2:+CLAUDE_CONFIG_DIR="$2"} python3 - "$REPO/tools/audit_deployment.py" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("audit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.claude_json_path("/cfg", sys.argv[2] == "explicit"))
PY
}
check f3_path_default_home "$(path_of implicit)" "$T/home/.claude.json"
check f3_path_claude_dir "$(path_of explicit)" "/cfg/.claude.json"
check f3_path_config_env "$(path_of implicit /cfg)" "/cfg/.claude.json"

# main() wires it: --claude-dir's .claude.json is the one read
mkdir -p "$T/claude"
cfg "$T/claude/.claude.json" local_drsg_only
python3 "$REPO/tools/audit_deployment.py" --claude-dir "$T/claude" --tools-dir "$T/tools" \
  --project "$P" --json > "$T/out.json" 2>/dev/null
l4() { python3 -c 'import json,sys; l=[x for x in json.load(open(sys.argv[1]))["layers"] if x["name"].startswith("L4")][0]; print("ok" if l["ok"] else "failed", " | ".join(l["details"]))' "$T/out.json"; }
out="$(l4)"
check f3_cli_reports_missing "$(first "$out")" failed
check f3_cli_fix_uses_tools_dir "$(echo "$out" | grep -c "python3 $T/tools/mcp_events.py")" 1
cfg "$T/claude/.claude.json" local_both
python3 "$REPO/tools/audit_deployment.py" --claude-dir "$T/claude" --tools-dir "$T/tools" \
  --project "$P" --json > "$T/out.json" 2>/dev/null
check f3_cli_ok_when_registered "$(first "$(l4)")" ok

check f3_doc_en "$(grep -c 'the `drsg` and `drsg-events` MCP servers are registered' "$REPO/tools/README.md")" 1
check f3_doc_zh "$(grep -c '注册了 `drsg` 和 `drsg-events` 两个 MCP server' "$REPO/tools/README.zh-CN.md")" 1

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

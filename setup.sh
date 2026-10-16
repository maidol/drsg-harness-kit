#!/usr/bin/env bash
# setup.sh — install the agent side of DrSG on a machine that has none of it:
# the shared memory daemon with its hooks, a per-repository code graph, and the
# router that puts several graphs behind one MCP surface.
#
# This script ships at the root of the bundle built by `pack.sh`; its
# `tools/` directory is what lands in ~/.drsg-memory/tools/, which is where the
# copies that actually RUN live. They live outside any repository on purpose:
# every one of them is tracked by a branch, so checking out another branch
# would delete them from the working tree, taking the MCP servers with them.
#
# Nothing here touches a running daemon's database. Steps are idempotent and
# any failure stops the script, because an install that reports success and
# then silently does nothing is the failure mode worth preventing.
#
# Usage: setup.sh [options]
#
#   --project DIR     install the memory layer into this project (hooks + MCP)
#   --all-projects    refresh memory hooks for every registered project
#   --repo DIR        build and serve a code graph for this git repository
#   --hub DIR         explicitly register router + usage report here
#   --router DIR      explicitly register only the code-graph router
#   --usage-report DIR explicitly register only the usage report Stop hook
#                     (none is inferred from --project or --repo)
#   --bin PATH        the drsg binary to run (default: `drsg` on PATH)
#   --addr host:port  memory daemon address            (default 127.0.0.1:7700)
#   --token T         memory daemon token for a new project joining a running
#                     daemon; installed projects reuse .drsg/env automatically
#   --port N          port for this repository's code-graph daemon
#   --tools-dir DIR   where the runtime copies go   (default ~/.drsg-memory/tools)
#   --fetch-drsg      download a release binary if none is found (network)
#   --no-skills       do not install the bundled skills or AGENT-EFFICIENCY.md
#   --no-main-branch-workflow  leave the managed main-branch rule disabled
#   --no-event-poller do not register the global to-do poller hooks
#   --no-streak-hint do not register the global single-tool reminder hook
#   --no-textual-tool-call-guard do not register the textual tool call stop guard
#   --permission-guard DIR  add commit/push ask rules and narrow read-only allow
#                     rules to DIR/.claude/settings.local.json (opt-in)
#   --reviews-dir DIR teach the auto-mode classifier (~/.claude/settings.json)
#                     that scripts under DIR may run once shown in a Write call
#   --prune-broad     with --permission-guard: also remove Bash(python3 *)-style rules
#   --self-commit     with --permission-guard / --reviews-dir: no commit ask rules
#                     (push and PR still ask) and an autoMode rule allowing local commits
#   --model-picker    source claude-model-picker.sh from ~/.bashrc, so an
#                     interactive `claude` asks which model to use first (opt-in)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=""; ALL_PROJECTS=0; REPO=""; HUB=""; ROUTER=""; USAGE_REPORT=""; BIN=""; ADDR=""; TOKEN=""; PORT=""
TOOLS="${DRSG_MEM_DIR:-$HOME/.drsg-memory}/tools"
FETCH=0; SKILLS=1; MAIN_BRANCH_WORKFLOW=1; POLLER=1; STREAK_HINT=1; TEXTUAL_TOOL_GUARD=1
PG_DIR=""; REVIEWS_DIR=""; PRUNE=0; SELF_COMMIT=0; MODEL_PICKER=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)    PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --all-projects) ALL_PROJECTS=1; shift ;;
    --repo)       REPO="${2:?--repo needs a path}"; shift 2 ;;
    --hub)        HUB="${2:?--hub needs a path}"; shift 2 ;;
    --router)     ROUTER="${2:?--router needs a path}"; shift 2 ;;
    --usage-report) USAGE_REPORT="${2:?--usage-report needs a path}"; shift 2 ;;
    --bin)        BIN="${2:?--bin needs a path}"; shift 2 ;;
    --addr)       ADDR="${2:?--addr needs host:port}"; shift 2 ;;
    --token)      TOKEN="${2:?--token needs a value}"; shift 2 ;;
    --port)       PORT="${2:?--port needs a number}"; shift 2 ;;
    --tools-dir)  TOOLS="${2:?--tools-dir needs a path}"; shift 2 ;;
    --fetch-drsg) FETCH=1; shift ;;
    --no-skills)  SKILLS=0; shift ;;
    --no-main-branch-workflow) MAIN_BRANCH_WORKFLOW=0; shift ;;
    --no-event-poller) POLLER=0; shift ;;
    --no-streak-hint) STREAK_HINT=0; shift ;;
    --no-textual-tool-call-guard) TEXTUAL_TOOL_GUARD=0; shift ;;
    --permission-guard) PG_DIR="${2:?--permission-guard needs a path}"; shift 2 ;;
    --reviews-dir) REVIEWS_DIR="${2:?--reviews-dir needs a path}"; shift 2 ;;
    --prune-broad) PRUNE=1; shift ;;
    --self-commit) SELF_COMMIT=1; shift ;;
    --model-picker) MODEL_PICKER=1; shift ;;
    -h|--help)    sed -n '2,/^set -euo/{/^#/p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Argument validation happens here, before step 1: rejecting a bad combination
# after the memory layer and the code graph are already installed is a late
# error for a mistake that is knowable at parse time.
if [ "$ALL_PROJECTS" -eq 1 ]; then
  for option in PROJECT REPO HUB ROUTER USAGE_REPORT; do
    if [ -n "${!option}" ]; then
      case "$option" in
        PROJECT) label=--project ;;
        REPO) label=--repo ;;
        HUB) label=--hub ;;
        ROUTER) label=--router ;;
        USAGE_REPORT) label=--usage-report ;;
      esac
      echo "ERROR: --all-projects cannot be combined with $label" >&2
      exit 1
    fi
  done
fi
if [ -n "$HUB" ] && { [ -n "$ROUTER" ] || [ -n "$USAGE_REPORT" ]; }; then
  echo "ERROR: --hub cannot be combined with --router or --usage-report" >&2
  exit 1
fi
if [ "$PRUNE" -eq 1 ] && [ -z "$PG_DIR" ]; then
  echo "ERROR: --prune-broad only applies together with --permission-guard DIR" >&2
  exit 1
fi
if [ "$SELF_COMMIT" -eq 1 ] && [ -z "$PG_DIR" ] && [ -z "$REVIEWS_DIR" ]; then
  echo "ERROR: --self-commit only applies together with --permission-guard DIR or --reviews-dir DIR" >&2
  exit 1
fi

[ -d "$HERE/tools" ] || { echo "ERROR: no tools/ next to $0 — run this from the unpacked bundle" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required (hooks and router are Python)" >&2; exit 1; }

echo "== 1/6: runtime copies -> $TOOLS"
mkdir -p "$TOOLS"
# When $TOOLS is a symlink back into this checkout, `cp -a x/. x/` exits 1 and
# takes the whole script with it under `set -e`. Same inode means the copies
# are already in place by construction — say so rather than failing.
if [ "$(cd "$HERE/tools" && pwd -P)" = "$(cd "$TOOLS" && pwd -P)" ]; then
  echo "   already the same directory (symlinked) — nothing to copy"
else
  cp -a "$HERE/tools/." "$TOOLS/"
fi
chmod +x "$TOOLS"/*.sh "$TOOLS"/*.py "$TOOLS/drsg-usage-report" 2>/dev/null || true
if [ -f "$HERE/claude/MAIN-BRANCH-WORKFLOW.md" ]; then
  cp "$HERE/claude/MAIN-BRANCH-WORKFLOW.md" "$TOOLS/main-branch-workflow-rule.md"
fi
echo "   $(find "$TOOLS" -maxdepth 1 -type f | wc -l | tr -d ' ') files in place"

# The managed main-branch rule is default-on and independent of --no-skills.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MAIN_BRANCH_MARKER="$CLAUDE_DIR/.main-branch-workflow.disabled"
MAIN_BRANCH_RULE="$CLAUDE_DIR/MAIN-BRANCH-WORKFLOW.md"
mkdir -p "$CLAUDE_DIR"
if [ "$MAIN_BRANCH_WORKFLOW" -eq 0 ]; then
  # Keep a local source copy so the standalone enable command can restore it.
  if [ ! -e "$MAIN_BRANCH_MARKER" ] && [ ! -e "$MAIN_BRANCH_RULE" ]; then
    cp "$HERE/claude/MAIN-BRANCH-WORKFLOW.md" "$MAIN_BRANCH_RULE"
  fi
  "$TOOLS/main-branch-workflow-config.sh" disable
elif [ -e "$MAIN_BRANCH_MARKER" ]; then
  "$TOOLS/main-branch-workflow-config.sh" disable
  echo "   main-branch workflow remains disabled ($MAIN_BRANCH_MARKER)"
else
  MAIN_BRANCH_RULE_SOURCE="$HERE/claude/MAIN-BRANCH-WORKFLOW.md" \
    "$TOOLS/main-branch-workflow-config.sh" enable
fi

# The model picker is opt-in. The standalone command owns the exact-line
# ~/.bashrc edit so users can also enable or disable it without rerunning setup.
if [ "$MODEL_PICKER" -eq 1 ]; then
  "$TOOLS/claude-model-picker-config.sh" enable
fi

# The to-do poller: global hooks, so every session in every project checks its
# open Events every 15 minutes without a model call, and wakes the model only
# when there is one it has not been told about. Projects without .drsg/env are
# skipped by the script itself. Idempotent: an existing registration is kept.
if [ "$POLLER" -eq 1 ] || [ "$STREAK_HINT" -eq 1 ] || [ "$TEXTUAL_TOOL_GUARD" -eq 1 ]; then
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  mkdir -p "$CLAUDE_DIR"
  python3 - "$CLAUDE_DIR/settings.json" "$TOOLS/event-poller.py" "$TOOLS/single-tool-streak.py" "$POLLER" "$STREAK_HINT" "$TOOLS/stop-failure-notify.py" "$TOOLS/textual-tool-call-guard.py" "$TEXTUAL_TOOL_GUARD" <<'PY'
import json, os, sys
path, script, streak_script = sys.argv[1], sys.argv[2], sys.argv[3]
poller_enabled, streak_hint = sys.argv[4] == "1", sys.argv[5] == "1"
notify_script, textual_guard_script = sys.argv[6], sys.argv[7]
textual_guard_enabled = sys.argv[8] == "1"
d = json.load(open(path)) if os.path.exists(path) and os.path.getsize(path) else {}
cmd = "python3 " + script
hooks = d.setdefault("hooks", {})
added = []
def add(event, entry, marker):
    groups = hooks.setdefault(event, [])
    if any(marker in h.get("command", "") for g in groups for h in g.get("hooks", [])):
        return
    groups.append({"matcher": "*", "hooks": [entry]})
    added.append(event + "/" + marker)
# asyncRewake: runs in the background, wakes the model only on exit code 2.
# The timeout is the background lifetime; the poller exits on its own when its
# Claude Code process is gone.
bg = {"type": "command", "command": cmd, "asyncRewake": True, "timeout": 604800}
if streak_hint:
    add("PostToolUse", {
        "type": "command", "command": "python3 " + streak_script, "timeout": 5
    }, "single-tool-streak.py")
if poller_enabled:
    add("SessionStart", dict(bg), "event-poller.py")
    add("Stop", dict(bg), "event-poller.py")
    # A turn that ends in an API error fires StopFailure instead of Stop; without
    # this the poller that woke that turn is never started again.
    add("StopFailure", dict(bg), "event-poller.py")
    # StopFailure cannot wake the model; this one only tells the terminal.
    add("StopFailure", {"type": "command", "command": "python3 " + notify_script,
                        "timeout": 5}, "stop-failure-notify.py")
    add("SessionEnd", {"type": "command", "command": cmd, "timeout": 10},
        "event-poller.py")
if textual_guard_enabled:
    add("Stop", {"type": "command", "command": "python3 " + textual_guard_script,
                 "timeout": 5}, "textual-tool-call-guard.py")
if added:
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
        f.write("\n")
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
print("   global hooks: " + (", ".join(added) + " added" if added else "already registered")
      + " in " + path)
PY
fi

if [ "$SKILLS" -eq 1 ] && [ -d "$HERE/skills" ]; then
  SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
  echo "== 2/6: skills -> $SKILLS_DIR"
  mkdir -p "$SKILLS_DIR"
  cp -a "$HERE/skills/." "$SKILLS_DIR/"
  # Agent efficiency rules: loaded every session through an @-import in the
  # global CLAUDE.md. The copy is overwritten on every
  # run — edit claude/AGENT-EFFICIENCY.md in the repository, not the copy.
  if [ -f "$HERE/claude/AGENT-EFFICIENCY.md" ]; then
    CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    mkdir -p "$CLAUDE_DIR"
    cp "$HERE/claude/AGENT-EFFICIENCY.md" "$CLAUDE_DIR/AGENT-EFFICIENCY.md"
    touch "$CLAUDE_DIR/CLAUDE.md"
    if ! grep -qx '@AGENT-EFFICIENCY.md' "$CLAUDE_DIR/CLAUDE.md"; then
      printf '\n@AGENT-EFFICIENCY.md\n' >> "$CLAUDE_DIR/CLAUDE.md"
      echo "   @AGENT-EFFICIENCY.md appended to $CLAUDE_DIR/CLAUDE.md"
    fi
  fi
else
  echo "== 2/6: skills skipped"
fi

# Permission guard: opt-in, and independent of the drsg binary and the
# daemon, so it runs before them. Project rules go to the project's
# settings.local.json; the autoMode rules only take effect from the
# user-level settings.json, so that is where --reviews-dir writes.
if [ -n "$PG_DIR" ] || [ -n "$REVIEWS_DIR" ]; then
  echo "== optional: permission guard"
  if [ -n "$PG_DIR" ]; then
    set -- apply --project "$PG_DIR" --tools-dir "$TOOLS"
    if [ "$PRUNE" -eq 1 ]; then set -- "$@" --prune-broad; fi
    if [ "$SELF_COMMIT" -eq 1 ]; then set -- "$@" --self-commit; fi
    python3 "$TOOLS/permission-guard.py" "$@"
  fi
  if [ -n "$REVIEWS_DIR" ]; then
    set -- apply --user --reviews-dir "$REVIEWS_DIR"
    if [ "$SELF_COMMIT" -eq 1 ]; then set -- "$@" --self-commit; fi
    python3 "$TOOLS/permission-guard.py" "$@"
  fi
fi

echo "== 3/6: locating drsg"
if [ -z "$BIN" ]; then
  if command -v drsg >/dev/null 2>&1; then
    BIN="$(command -v drsg)"
  elif [ "$FETCH" -eq 1 ] && [ -x "$HERE/install-drsg.sh" ]; then
    "$HERE/install-drsg.sh"
    BIN="${DRSG_INSTALL_DIR:-$HOME/.local/bin}/drsg"
  fi
fi
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
  echo "   $BIN ($("$BIN" --version 2>/dev/null || echo 'version unknown'))"
elif [ -n "$PROJECT" ] || [ -n "$REPO" ] || [ "$ALL_PROJECTS" -eq 1 ]; then
  # Installing either half without a binary would leave hooks and MCP entries
  # pointing at a daemon that can never start.
  echo "ERROR: no drsg binary. Pass --bin PATH, or --fetch-drsg to download one," >&2
  echo "       or run ./install-drsg.sh yourself." >&2
  exit 1
else
  echo "   none found; nothing to install without --project/--all-projects/--repo, continuing"
fi

install_memory_project() {
  local target="$1"
  local -a args=("$target" --bin "$BIN")
  if [ -n "$ADDR" ]; then args+=(--addr "$ADDR"); fi
  if [ -n "$TOKEN" ]; then args+=(--token "$TOKEN"); fi
  "$TOOLS/install.sh" "${args[@]}"
}

if [ -n "$PROJECT" ]; then
  echo "== 4/6: memory layer -> $PROJECT"
  # install.sh self-checks (daemon reachable, plane present, a Fact readable
  # through the hooks' own recall query) and exits non-zero if any of it fails.
  install_memory_project "$PROJECT"
elif [ "$ALL_PROJECTS" -eq 1 ]; then
  echo "== 4/6: memory layer -> all registered projects"
  MEMORY_DIR="${DRSG_MEM_DIR:-$HOME/.drsg-memory}"
  DAEMON_ENV="$MEMORY_DIR/env"
  # Without --addr or DRSG_MEM_ADDR, list projects from the daemon this
  # machine's env file names (serve.sh rewrites DRSG_API there on every start),
  # not from whatever answers on the default port.
  REGISTRY_API=""
  if [ -z "$ADDR" ] && [ -z "${DRSG_MEM_ADDR:-}" ] && [ -f "$DAEMON_ENV" ]; then
    REGISTRY_API="$(sed -n 's/^DRSG_API=//p' "$DAEMON_ENV" | head -1 || true)"
  fi
  if [ -z "$REGISTRY_API" ]; then
    REGISTRY_ADDR="${ADDR:-${DRSG_MEM_ADDR:-127.0.0.1:7700}}"
    REGISTRY_ADDR="${REGISTRY_ADDR#http://}"
    REGISTRY_ADDR="${REGISTRY_ADDR#https://}"
    REGISTRY_API="http://$REGISTRY_ADDR/rpc"
  fi
  PROJECTS_FILE="$(mktemp "${TMPDIR:-/tmp}/setup-all-projects.XXXXXX")"
  QUERY_ERROR="$PROJECTS_FILE.err"
  if ! "$TOOLS/project_registry.py" --env "$DAEMON_ENV" --api "$REGISTRY_API" \
      --plane memory --nul > "$PROJECTS_FILE" 2> "$QUERY_ERROR"; then
    QUERY_DETAIL="$(<"$QUERY_ERROR")"
    rm -f "$PROJECTS_FILE" "$QUERY_ERROR"
    echo "ERROR: could not list projects${QUERY_DETAIL:+: $QUERY_DETAIL}" >&2
    exit 1
  fi
  rm -f "$QUERY_ERROR"
  if [ ! -s "$PROJECTS_FILE" ]; then
    rm -f "$PROJECTS_FILE"
    echo "no projects found"
    echo "summary: 0 ok, 0 failed, 0 skipped"
    exit 0
  fi

  LOG_ROOT="$MEMORY_DIR/logs"
  mkdir -p "$LOG_ROOT"
  OLD_UMASK="$(umask)"
  umask 077
  LOG_DIR="$(mktemp -d "$LOG_ROOT/setup-all-projects.XXXXXX")"
  declare -a SEEN_REALPATHS=()
  OK_COUNT=0; FAILED_COUNT=0; SKIPPED_COUNT=0; ATTEMPT=0
  while IFS= read -r -d '' target; do
    if [ ! -d "$target" ]; then
      echo "skipped $target (directory missing)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    resolved="$(realpath "$target")"
    duplicate=0
    for prior in "${SEEN_REALPATHS[@]}"; do
      if [ "$prior" = "$resolved" ]; then duplicate=1; break; fi
    done
    if [ "$duplicate" -eq 1 ]; then
      echo "skipped $target (duplicate realpath: $resolved)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    SEEN_REALPATHS+=("$resolved")
    if [ ! -f "$target/.drsg/env" ]; then
      echo "skipped $target (no .drsg/env)"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi
    ATTEMPT=$((ATTEMPT + 1))
    LOG_FILE="$LOG_DIR/$(printf '%04d' "$ATTEMPT").log"
    if install_memory_project "$target" 2>&1 | \
        DRSG_LOG_REDACT="$TOKEN" python3 -c 'import os,sys; t=os.environ.get("DRSG_LOG_REDACT", ""); [sys.stdout.write(line.replace(t, "<hidden>") if t else line) for line in sys.stdin]' \
        > "$LOG_FILE"; then
      echo "ok $target"
      OK_COUNT=$((OK_COUNT + 1))
    else
      echo "FAILED $target (log: $LOG_FILE)"
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
  done < "$PROJECTS_FILE"
  rm -f "$PROJECTS_FILE"
  echo "summary: $OK_COUNT ok, $FAILED_COUNT failed, $SKIPPED_COUNT skipped"
  [ "$FAILED_COUNT" -eq 0 ]
  exit $?
else
  echo "== 4/6: memory layer skipped (no --project/--all-projects)"
fi

if [ -n "$REPO" ]; then
  echo "== 5/6: code graph -> $REPO"
  set -- install --dir "$REPO"
  [ -n "$PORT" ] && set -- "$@" --port "$PORT"
  DRSG_CODE_BIN="$BIN" "$TOOLS/codegraph.sh" "$@"
else
  echo "== 5/6: code graph skipped (no --repo)"
fi

if [ -n "$HUB" ]; then
  echo "== optional: router + usage report -> $HUB"
  DRSG_MEM_DIR="$(dirname "$TOOLS")" "$TOOLS/codegraph-hub-setup.sh" "$HUB"
fi
if [ -n "$ROUTER" ]; then
  echo "== optional: router -> $ROUTER"
  DRSG_MEM_DIR="$(dirname "$TOOLS")" "$TOOLS/codegraph-router-setup.sh" "$ROUTER"
fi
if [ -n "$USAGE_REPORT" ]; then
  echo "== optional: usage report -> $USAGE_REPORT"
  DRSG_MEM_DIR="$(dirname "$TOOLS")" "$TOOLS/codegraph-usage-setup.sh" "$USAGE_REPORT"
fi

cat <<EOF

done. Restart the Claude Code session — hooks and MCP servers are read at startup.

then check, in order:
  $TOOLS/serve.sh status                     memory daemon, its db and token
  $TOOLS/codegraph.sh doctor --dir <repo>    plane exists, folded to HEAD, rules block current
  graph_repos (MCP, when --router/--hub was selected) which repositories the router can reach
  $TOOLS/drsg-usage-report (when --usage-report/--hub was selected) usage summary
  $TOOLS/install.sh --check                  deployed hooks vs the templates they came from
  $TOOLS/install.sh --audit                  full 5-layer deployment audit across all projects

to add another repository to the router later:
  DRSG_CODE_BIN=$BIN $TOOLS/codegraph.sh install --dir <repo> --port <n>
EOF

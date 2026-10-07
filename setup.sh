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
#   --repo DIR        build and serve a code graph for this git repository
#   --hub DIR         explicitly register router + usage report here
#   --router DIR      explicitly register only the code-graph router
#   --usage-report DIR explicitly register only the usage report Stop hook
#                     (none is inferred from --project or --repo)
#   --bin PATH        the drsg binary to run (default: `drsg` on PATH)
#   --addr host:port  memory daemon address            (default 127.0.0.1:7700)
#   --token T         memory daemon token — REQUIRED when joining a daemon
#                     that is already running
#   --port N          port for this repository's code-graph daemon
#   --tools-dir DIR   where the runtime copies go   (default ~/.drsg-memory/tools)
#   --fetch-drsg      download a release binary if none is found (network)
#   --no-skills       do not install the bundled skills or AGENT-EFFICIENCY.md
#   --no-event-poller do not register the global to-do poller hooks
#   --no-streak-hint do not register the global single-tool reminder hook
#   --permission-guard DIR  add commit/push ask rules and narrow read-only allow
#                     rules to DIR/.claude/settings.local.json (opt-in)
#   --reviews-dir DIR teach the auto-mode classifier (~/.claude/settings.json)
#                     that scripts under DIR may run once shown in a Write call
#   --prune-broad     with --permission-guard: also remove Bash(python3 *)-style rules
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=""; REPO=""; HUB=""; ROUTER=""; USAGE_REPORT=""; BIN=""; ADDR=""; TOKEN=""; PORT=""
TOOLS="${DRSG_MEM_DIR:-$HOME/.drsg-memory}/tools"
FETCH=0; SKILLS=1; POLLER=1; STREAK_HINT=1
PG_DIR=""; REVIEWS_DIR=""; PRUNE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project)    PROJECT="${2:?--project needs a path}"; shift 2 ;;
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
    --no-event-poller) POLLER=0; shift ;;
    --no-streak-hint) STREAK_HINT=0; shift ;;
    --permission-guard) PG_DIR="${2:?--permission-guard needs a path}"; shift 2 ;;
    --reviews-dir) REVIEWS_DIR="${2:?--reviews-dir needs a path}"; shift 2 ;;
    --prune-broad) PRUNE=1; shift ;;
    -h|--help)    sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 1 ;;
  esac
done

# Argument validation happens here, before step 1: rejecting a bad combination
# after the memory layer and the code graph are already installed is a late
# error for a mistake that is knowable at parse time.
if [ -n "$HUB" ] && { [ -n "$ROUTER" ] || [ -n "$USAGE_REPORT" ]; }; then
  echo "ERROR: --hub cannot be combined with --router or --usage-report" >&2
  exit 1
fi
if [ "$PRUNE" -eq 1 ] && [ -z "$PG_DIR" ]; then
  echo "ERROR: --prune-broad only applies together with --permission-guard DIR" >&2
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
echo "   $(find "$TOOLS" -maxdepth 1 -type f | wc -l | tr -d ' ') files in place"

# The to-do poller: global hooks, so every session in every project checks its
# open Events every 15 minutes without a model call, and wakes the model only
# when there is one it has not been told about. Projects without .drsg/env are
# skipped by the script itself. Idempotent: an existing registration is kept.
if [ "$POLLER" -eq 1 ] || [ "$STREAK_HINT" -eq 1 ]; then
  CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  mkdir -p "$CLAUDE_DIR"
  python3 - "$CLAUDE_DIR/settings.json" "$TOOLS/event-poller.py" "$TOOLS/single-tool-streak.py" "$POLLER" "$STREAK_HINT" "$TOOLS/stop-failure-notify.py" <<'PY'
import json, os, sys
path, script, streak_script = sys.argv[1], sys.argv[2], sys.argv[3]
poller_enabled, streak_hint = sys.argv[4] == "1", sys.argv[5] == "1"
notify_script = sys.argv[6]
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
  # global CLAUDE.md, the same way RTK.md is. The copy is overwritten on every
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
    python3 "$TOOLS/permission-guard.py" "$@"
  fi
  if [ -n "$REVIEWS_DIR" ]; then
    python3 "$TOOLS/permission-guard.py" apply --user --reviews-dir "$REVIEWS_DIR"
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
elif [ -n "$PROJECT" ] || [ -n "$REPO" ]; then
  # Installing either half without a binary would leave hooks and MCP entries
  # pointing at a daemon that can never start.
  echo "ERROR: no drsg binary. Pass --bin PATH, or --fetch-drsg to download one," >&2
  echo "       or run ./install-drsg.sh yourself." >&2
  exit 1
else
  echo "   none found; nothing to install without --project/--repo, continuing"
fi

if [ -n "$PROJECT" ]; then
  echo "== 4/6: memory layer -> $PROJECT"
  set -- "$PROJECT" --bin "$BIN"
  [ -n "$ADDR" ]  && set -- "$@" --addr "$ADDR"
  [ -n "$TOKEN" ] && set -- "$@" --token "$TOKEN"
  # install.sh self-checks (daemon reachable, plane present, a Fact readable
  # through the hooks' own recall query) and exits non-zero if any of it fails.
  "$TOOLS/install.sh" "$@"
else
  echo "== 4/6: memory layer skipped (no --project)"
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

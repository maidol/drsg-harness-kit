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
#   --no-skills       do not install the bundled skills
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=""; REPO=""; HUB=""; ROUTER=""; USAGE_REPORT=""; BIN=""; ADDR=""; TOKEN=""; PORT=""
TOOLS="${DRSG_MEM_DIR:-$HOME/.drsg-memory}/tools"
FETCH=0; SKILLS=1

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
    -h|--help)    sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 1 ;;
  esac
done

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

if [ "$SKILLS" -eq 1 ] && [ -d "$HERE/skills" ]; then
  SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
  echo "== 2/6: skills -> $SKILLS_DIR"
  mkdir -p "$SKILLS_DIR"
  cp -a "$HERE/skills/." "$SKILLS_DIR/"
else
  echo "== 2/6: skills skipped"
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

if [ -n "$HUB" ] && { [ -n "$ROUTER" ] || [ -n "$USAGE_REPORT" ]; }; then
  echo "ERROR: --hub cannot be combined with --router or --usage-report" >&2
  exit 1
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

to add another repository to the router later:
  DRSG_CODE_BIN=$BIN $TOOLS/codegraph.sh install --dir <repo> --port <n>
EOF

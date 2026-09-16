#!/usr/bin/env bash
# Global dr-strange memory daemon control.
#
# ONE shared daemon serves ALL projects' memory (each project is a Project
# node in the same db — dr-strange native backend allows one process per db).
#
# Env (override per-install; defaults shown):
#   DRSG_MEM_DIR   ~/.drsg-memory     data + pid + logs live here
#   DRSG_MEM_BIN   drsg               the patched drsg binary (path or PATH name)
#   DRSG_MEM_ADDR  127.0.0.1:7700     listen address
#   DRSG_MEM_TOKEN                    API token (generated if unset)
#
# Usage: serve.sh {start|stop|restart|status}
#
# The daemon reads the L3 LLM key (OPENAI_API_KEY, say) from ITS OWN env — install.sh
# persists the key value into this env file, and `start` exports it below. After a
# key change, restart the daemon to pick it up.
set -euo pipefail

DRSG_MEM_DIR="${DRSG_MEM_DIR:-$HOME/.drsg-memory}"
ENVFILE="$DRSG_MEM_DIR/env"
# Prefer process env; fall back to values persisted in the env file, so a bare
# `serve.sh restart` (no exported vars) still finds the right binary/addr.
if [ -f "$ENVFILE" ]; then
  [ -z "${DRSG_MEM_BIN:-}" ] && DRSG_MEM_BIN="$(sed -n 's/^DRSG_MEM_BIN=//p' "$ENVFILE" | head -1)"
  [ -z "${DRSG_MEM_ADDR:-}" ] && DRSG_MEM_ADDR="$(sed -n 's/^DRSG_MEM_ADDR=//p' "$ENVFILE" | head -1)"
fi
DRSG_MEM_BIN="${DRSG_MEM_BIN:-drsg}"
DRSG_MEM_ADDR="${DRSG_MEM_ADDR:-127.0.0.1:7700}"
PID="$DRSG_MEM_DIR/serve.pid"
LOG="$DRSG_MEM_DIR/serve.log"
cmd="${1:-status}"

require_bin() {
  if ! command -v "$DRSG_MEM_BIN" >/dev/null 2>&1 && [ ! -x "$DRSG_MEM_BIN" ]; then
    echo "ERROR: drsg binary not found ('$DRSG_MEM_BIN'). Set DRSG_MEM_BIN to a built drsg." >&2
    exit 1
  fi
}

start() {
  require_bin
  mkdir -p "$DRSG_MEM_DIR"
  [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && { echo "already running (pid $(cat "$PID"))"; return 0; }
  # Token: reuse from env file, or generate fresh.
  ENVFILE="$DRSG_MEM_DIR/env"
  if [ -n "${DRSG_MEM_TOKEN:-}" ]; then
    TOKEN="$DRSG_MEM_TOKEN"
  elif [ -f "$ENVFILE" ] && grep -q '^DRSG_TOKEN=' "$ENVFILE"; then
    TOKEN=$(grep '^DRSG_TOKEN=' "$ENVFILE" | head -1 | cut -d= -f2-)
  else
    TOKEN=$(openssl rand -hex 16)
  fi
  # Persist token + addr so install.sh and hooks can discover them. Merge over
  # the existing file instead of truncating, so foreign keys install.sh wrote
  # (the L3 LLM key, say) survive a restart.
  cat > "$ENVFILE.tmp" <<EOF
DRSG_TOKEN=$TOKEN
DRSG_API=http://$(echo "$DRSG_MEM_ADDR" | sed 's|^https\?://||')/rpc
DRSG_PLANE=memory
DRSG_MEM_ADDR=$DRSG_MEM_ADDR
DRSG_MEM_BIN=$DRSG_MEM_BIN
EOF
  if [ -f "$ENVFILE" ]; then
    # Append existing KEY=value lines whose KEY is not managed above.
    awk -F= 'NR==FNR{m[$1]=1; next} /^[A-Za-z_][A-Za-z0-9_]*=/ && !m[$1]' \
      "$ENVFILE.tmp" "$ENVFILE" >> "$ENVFILE.tmp" || true
  fi
  mv "$ENVFILE.tmp" "$ENVFILE"
  chmod 600 "$ENVFILE" 2>/dev/null || true
  # Launch detached. The daemon reads DRSG_TOKEN from its own env; it also
  # needs the L3 LLM key (persisted by install.sh) in ITS
  # env for digest.run to authenticate — export the env file's key=value pairs.
  set -a; [ -f "$ENVFILE" ] && source "$ENVFILE"; set +a
  # Launched from DRSG_MEM_DIR, not from wherever the caller happened to stand:
  # drsg auto-loads `./drsg.toml` from the working directory, so starting this
  # daemon inside a code repository silently hands it that repository's server
  # config. A repo that sets `[digest] embed_provider` this way turns on
  # embed-on-write for `/mcp` write_nodes, and every Fact write then fails on a
  # key the memory layer never needed — the memory plane is not vectorized and
  # recall runs on n-grams and BM25.
  (
    cd "$DRSG_MEM_DIR"
    DRSG_TOKEN="$TOKEN" nohup "$DRSG_MEM_BIN" --db "$DRSG_MEM_DIR/memory.drsg" serve --addr "$DRSG_MEM_ADDR" \
        >> "$LOG" 2>&1 &
    echo $! > "$PID"
  )
  echo "started pid $(cat "$PID"); db=$DRSG_MEM_DIR/memory.drsg; addr=$DRSG_MEM_ADDR"
  # Wait for readiness.
  for _ in $(seq 1 20); do
    curl -sf -m 2 "http://$(echo "$DRSG_MEM_ADDR" | sed 's|^https\?://||')/health" >/dev/null 2>&1 && break
    sleep 0.3
  done
}

stop() {
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    local oldpid
    oldpid="$(cat "$PID")"
    kill "$oldpid" 2>/dev/null || true
    # Graceful drain first — but a live MCP stream keeps the daemon draining
    # forever (it holds the db lock until fully exited), so escalate to SIGKILL
    # after a short grace period. WAL replays on next open, so this is safe.
    for _ in $(seq 1 30); do
      kill -0 "$oldpid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$oldpid" 2>/dev/null; then
      echo "   (force-killing pid $oldpid — still draining)" >&2
      kill -9 "$oldpid" 2>/dev/null || true
      for _ in $(seq 1 20); do kill -0 "$oldpid" 2>/dev/null || break; sleep 0.2; done
    fi
    rm -f "$PID"
    echo stopped
  else
    echo "not running"
  fi
}

status() {
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "running (pid $(cat "$PID"))"
    curl -sf -m 2 "http://$(echo "$DRSG_MEM_ADDR" | sed 's|^https\?://||')/health" && echo
  else
    echo "not running"
  fi
}

case "$cmd" in
  start) start ;;
  stop)  stop ;;
  restart) stop; start ;;
  status) status ;;
  *) echo "usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac

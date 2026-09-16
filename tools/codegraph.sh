#!/usr/bin/env bash
# Code-graph daemon control: `drsg serve watch` over a repository's graph.drsg,
# folding every commit into that repo's plane and exposing the seven verbs on
# /mcp. Works for any repository, not just this one — `--dir` (default: the
# git repository containing $PWD) picks the target.
#
# One daemon per repository, deliberately: `serve watch` takes a single --dir,
# and the native backend allows one process per database. So each repo gets its
# own db, its own port and its own token, all recorded in its own .mcp.json.
#
# NOT the memory layer. That is a separate global daemon on 7700 with its own
# controller (tools/serve.sh) and its own db in ~/.drsg-memory.
# No database is ever shared, so restarting either leaves the other alone.
#
# The bootstrap (minting a token, writing .mcp.json and the editor configs)
# belongs to `drsg init` and is not duplicated here: this script reads the
# address and token back out of .mcp.json, which is what MCP clients read too,
# so the daemon and the clients cannot drift apart.
#
# Env (defaults shown):
#   DRSG_CODE_BIN    whatever last started this repo's daemon, else the watched
#                    repo's target/release/drsg, else this checkout's, else
#                    `drsg` on PATH. A repository that does not build drsg
#                    itself needs this named once; it is remembered after that.
#   DRSG_CODE_DB     <repo>/graph.drsg        the db *directory* (native backend)
#   DRSG_CODE_PLANE  the repo's own name      plane to keep in sync
#
# Usage: codegraph.sh {install|start|stop|restart|status|rules|hook|logs}
#                     [--dir PATH] [--port N] [--force]
#
#   install     bootstrap a repository end to end: `drsg init` if it has never
#               been digested, start the daemon, write the rules block into its
#               CLAUDE.md, and register the SessionStart guard. Idempotent.
#   rules       (re)write the sentinel-delimited code-graph block in the repo's
#               CLAUDE.md from what the plane actually holds — its name, its
#               address, the kinds of node there are to ask for. A graph nobody
#               is told the plane name of is a graph nobody queries.
#   hook        SessionStart guard: restart a daemon that died, and say so.
#               Silent when everything is already up. Never fails a session.
#   doctor      check everything that has to agree — plane exists under the
#               documented name, folded up to HEAD, parsed from this repo, the
#               rules block names it and was written by this generator's version
#               of the rules, the guard is registered. Non-zero if not.
#
#   --dir PATH  repository to serve (default: the one $PWD is in)
#   --port N    listen on 127.0.0.1:N instead of the port .mcp.json records.
#               `start`/`restart` persist the new port into .mcp.json, because
#               a daemon the clients cannot reach is worse than no daemon.
#   --force     rebuild the plane from the whole tree before serving (drop,
#               re-create, fold every file). Only needed after changing which
#               plugins are installed; a normal start catches up incrementally
#               from the plane's synced_commit, which takes about a second.
set -euo pipefail

SELF_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# This script by absolute path: it is written into other repositories' CLAUDE.md
# and settings.local.json, which are read from anywhere but here.
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

cmd="${1:-status}"
shift || true
# A hook runs with the session's project directory in the environment and an
# unrelated cwd; every other command means the repository the caller is in.
if [ "$cmd" = "hook" ]; then target="${CLAUDE_PROJECT_DIR:-$PWD}"; else target="$PWD"; fi
force=""
port=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)   target="${2:?--dir needs a path}"; shift 2 ;;
    --port)  port="${2:?--port needs a number}"; shift 2 ;;
    --force) force="--force"; shift ;;
    *) echo "unknown argument '$1'" >&2; exit 1 ;;
  esac
done
case "$port" in
  ''|*[!0-9]*) [ -z "$port" ] || { echo "ERROR: --port wants a number, got '$port'" >&2; exit 1; } ;;
esac

# The repository root, not whatever subdirectory the caller happened to be in:
# the plane's name and the db's location both hang off it.
REPO="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)"
# The guard is opening someone's editor, not being run by them: a directory it
# has nothing to say about must cost nothing and print nothing.
[ -n "$REPO" ] || [ "$cmd" != "hook" ] || exit 0
if [ -z "$REPO" ]; then
  echo "ERROR: '$target' is not inside a git repository — 'serve watch' follows commits, so it needs one." >&2
  exit 1
fi

DB="${DRSG_CODE_DB:-$REPO/graph.drsg}"
# Matches drsg's own default_plane(): the source directory's name.
PLANE="${DRSG_CODE_PLANE:-$(basename "$REPO")}"
MCP_JSON="$REPO/.mcp.json"

# Runtime files live outside the target repository. `drsg init` teaches its
# .gitignore about *.drsg, logs/ and .mcp.json but nothing else, so a pid file
# dropped inside would show up as untracked noise in someone else's checkout.
# The path is hashed because two repos may share a basename.
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/drsg/codegraph/$(basename "$REPO")-$(printf %s "$REPO" | sha256sum | cut -c1-8)"
PID="$STATE/pid"
LOG="$STATE/log"
BIN_MEMO="$STATE/bin"

# Where drsg is, in the order that stays true wherever this script is run from.
# `$SELF_REPO` assumes the script sits in a checkout's `scripts/` — which stops
# being true the moment a copy is kept outside the repository (a copy exists
# precisely because a branch that does not track this file deletes it). The
# target repo is tried first for the same reason: with `--dir`, the repo being
# watched is the one the caller named, and its own build is the binary they
# most likely meant. Falls back to PATH for an installed one.
#
# Between the override and the guesses sits what actually started this repo's
# daemon last time. A repository that is not itself a drsg checkout has no
# binary of its own to find, so every guess below misses and the caller has to
# supply `DRSG_CODE_BIN` — once is reasonable, every restart forever is not.
# The path is remembered, never a copy of the binary, so an upgrade in place is
# picked up without touching this. A remembered path that has gone away (the
# checkout it named moved, or a branch switch deleted its target/) simply falls
# through to the guesses rather than becoming a permanent wrong answer.
if [ -n "${DRSG_CODE_BIN:-}" ]; then
  BIN="$DRSG_CODE_BIN"
elif [ -s "$BIN_MEMO" ] && [ -x "$(cat "$BIN_MEMO")" ]; then
  BIN="$(cat "$BIN_MEMO")"
elif [ -x "$REPO/target/release/drsg" ]; then
  BIN="$REPO/target/release/drsg"
elif [ -x "$SELF_REPO/target/release/drsg" ]; then
  BIN="$SELF_REPO/target/release/drsg"
else
  BIN="drsg"
fi

# Address and token both come from .mcp.json, the file the MCP clients read.
# Regenerating a token here would silently invalidate every client config that
# `drsg init` wrote (Cursor, Codex, ...), so a missing entry is an error with
# the one command that fixes it, not something to paper over.
#
# Sets CFG_ADDR (what the clients currently believe) and ADDR (where we are
# about to act). `--port` is the only thing that makes them differ.
read_config() {
  if [ ! -f "$MCP_JSON" ]; then
    echo "ERROR: no $MCP_JSON — run \`$BIN init\` in $REPO first (it mints the token and writes the client configs)." >&2
    exit 1
  fi
  eval "$(python3 - "$MCP_JSON" <<'PY'
import json, sys, urllib.parse
try:
    entry = json.load(open(sys.argv[1]))["mcpServers"]["drsg-watch"]
    u = urllib.parse.urlparse(entry["url"])
    print("CFG_ADDR=%s:%d" % (u.hostname, u.port))
    print("TOKEN=%s" % entry["headers"]["Authorization"].split()[-1])
except Exception as e:
    print("CFG_ADDR=; TOKEN=; CFG_ERR=%r" % (str(e),))
PY
)"
  if [ -z "${CFG_ADDR:-}" ]; then
    echo "ERROR: $MCP_JSON has no usable 'drsg-watch' entry (${CFG_ERR:-}) — run \`$BIN init\` in $REPO." >&2
    exit 1
  fi
  # Loopback stays loopback: the token is the only guard, so a port override
  # must not quietly widen the bind address.
  if [ -n "$port" ]; then ADDR="127.0.0.1:$port"; else ADDR="$CFG_ADDR"; fi
}

# Rewrite only the `drsg-watch` URL, leaving the token and every other server
# entry alone. Called after a successful start on a port the file did not name.
persist_addr() {
  python3 - "$MCP_JSON" "$1" <<'PY'
import json, sys, urllib.parse
path, addr = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
entry = doc["mcpServers"]["drsg-watch"]
u = urllib.parse.urlparse(entry["url"])
entry["url"] = u._replace(netloc=addr).geturl()
with open(path, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY
}

# The pid of the daemon serving THIS repository, whatever port it is on.
#
# Identity is the database's LOCK file, held open for the process's lifetime by
# the native backend. Two weaker identities were tried and are wrong:
#
#   - the port: `restart --port N` must stop a daemon that is by definition on
#     the *old* address, and an occupied port may be occupied by anything;
#   - the command line: `drsg init` spawns its daemon with `--dir .` and
#     `--db ./graph.drsg`, relative to a cwd the pattern never sees, so
#     matching on the repository path misses exactly the daemons init started
#     — and then a start opens a database that is already open, which is the
#     one error this lookup exists to prevent.
#
# The lock is also the resource that actually matters: one process per db.
db_holder_pid() {
  local lock
  lock="$(readlink -f "$DB/LOCK" 2>/dev/null || true)"
  [ -n "$lock" ] || return 0
  # One `find` rather than a readlink per fd: /proc has a few thousand of them.
  find /proc/[0-9]*/fd -maxdepth 1 -lname "$lock" -printf '%h\n' 2>/dev/null |
    sed -n 's|/proc/\([0-9]*\)/fd|\1|p' | head -1
  # Found nothing is a normal answer, not a failure: callers test for empty.
  return 0
}

# What a pid is listening on, and who holds an address — the two directions of
# the same `ss` table.
pid_addr()     { ss -ltnp 2>/dev/null | awk -v p="pid=$1," '$0 ~ p {print $4; exit}'; }
addr_holder()  { ss -ltnp 2>/dev/null | awk -v a="$1" '$4 == a {sub(/.*pid=/, ""); sub(/,.*/, ""); print; exit}'; }

healthy() { curl -sf -m 2 "http://$ADDR/health" >/dev/null 2>&1; }

# Checked before `restart` stops anything: a missing binary used to be found
# only on the way back up, which left the daemon down and the caller holding an
# error about a repository they were not working in.
require_bin() {
  if [ -x "$BIN" ] || command -v "$BIN" >/dev/null 2>&1; then
    return 0
  fi
  echo "ERROR: no drsg binary at '$BIN' — $REPO does not build one itself, so name the one to run:" >&2
  echo "         DRSG_CODE_BIN=/path/to/drsg $0 start --dir $REPO${port:+ --port $port}" >&2
  echo "       It is remembered per repository afterwards, so this is a one-time argument." >&2
  exit 1
}

start() {
  read_config
  require_bin
  local mine; mine="$(db_holder_pid)"
  if [ -n "$mine" ]; then
    echo "already running (pid $mine) on $(pid_addr "$mine") — use restart${port:+ --port $port} to move it"
    return 0
  fi
  # Someone else's process on the port we want: say so, rather than failing
  # later with a bind error buried in the log.
  local squatter; squatter="$(addr_holder "$ADDR")"
  if [ -n "$squatter" ]; then
    echo "ERROR: $ADDR is already taken by pid $squatter ($(tr '\0' ' ' < "/proc/$squatter/cmdline" 2>/dev/null | cut -c1-90)) — pick another --port." >&2
    exit 1
  fi
  mkdir -p "$STATE"
  # setsid so the daemon outlives the shell that ran this script.
  DRSG_TOKEN="$TOKEN" setsid nohup "$BIN" --db "$DB" serve --addr "$ADDR" \
      watch --dir "$REPO" --plane "$PLANE" ${force:+$force} \
      >> "$LOG" 2>&1 < /dev/null &
  for _ in $(seq 1 40); do healthy && break; sleep 0.5; done
  local pid; pid="$(db_holder_pid)"
  if [ -z "$pid" ] || ! healthy; then
    echo "ERROR: never started listening on $ADDR. Last lines of $LOG:" >&2
    tail -20 "$LOG" >&2
    exit 1
  fi
  echo "$pid" > "$PID"
  # Only after it is known to serve: remembering a binary that failed to start
  # would make the next run repeat the failure with no argument left to blame.
  local resolved
  if resolved="$(command -v "$BIN" 2>/dev/null)"; then
    printf '%s\n' "$resolved" > "$BIN_MEMO"
  fi
  echo "started pid $pid — http://$ADDR/mcp, repo=$REPO, db=$DB, plane=$PLANE${force:+ (rebuilt)}"
  if [ "$ADDR" != "$CFG_ADDR" ]; then
    persist_addr "$ADDR"
    echo "  .mcp.json: $CFG_ADDR → $ADDR (token unchanged)"
    # The other client configs `drsg init` may have written are not rewritten
    # here — they are four different file formats — so name the ones that
    # exist and still point at the old port.
    local f stale=()
    for f in .cursor/mcp.json .opencode.json .gemini/settings.json .codex/config.toml; do
      if [ -f "$REPO/$f" ] && grep -qF "${CFG_ADDR##*:}" "$REPO/$f" 2>/dev/null; then
        stale+=("$f")
      fi
    done
    if [ ${#stale[@]} -gt 0 ]; then
      echo "  still on the old port: ${stale[*]} — \`$BIN init --addr $ADDR --token <the same token>\` rewrites them all (it also force-rebuilds the plane)"
    fi
  fi
  # The one line worth reading: whether the plane actually caught up to HEAD.
  grep -aE 'in sync|folded|watching repository' "$LOG" | tail -2 || true
}

stop() {
  read_config
  # By repository, not by port: `restart --port N` must stop the daemon that is
  # running now, which is by definition on the *old* address.
  local pid; pid="$(db_holder_pid)"
  [ -z "$pid" ] && [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null && pid="$(cat "$PID")"
  if [ -z "$pid" ]; then
    rm -f "$PID"
    echo "not running"
    return 0
  fi
  local was; was="$(pid_addr "$pid")"
  kill "$pid" 2>/dev/null || true
  # Graceful first, but an open MCP stream keeps the server draining while it
  # still holds the db lock, which would make the next start fail. Escalate;
  # the WAL replays on the next open, so a hard kill loses nothing committed.
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$pid" 2>/dev/null; then
    echo "   (force-killing pid $pid — still draining)" >&2
    kill -9 "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  fi
  rm -f "$PID"
  echo "stopped (was pid $pid${was:+ on $was})"
}

status() {
  read_config
  local pid; pid="$(db_holder_pid)"
  if [ -z "$pid" ]; then
    echo "not running ($REPO: nothing holds its database; .mcp.json says $CFG_ADDR)"
    return 1
  fi
  ADDR="$(pid_addr "$pid")"
  echo "running (pid $pid) on http://$ADDR/mcp — $REPO"
  if [ "$ADDR" != "$CFG_ADDR" ]; then
    echo "  WARNING: .mcp.json points at $CFG_ADDR — clients are looking at the wrong port"
  fi
  healthy && echo "  health: ok" || echo "  health: FAILING"
  # Ask the server itself what the plane knows, rather than trusting the log:
  # `synced` names the commit the graph was folded up to.
  curl -sf -m 5 -X POST "http://$ADDR/rpc" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"plane.list","params":{}}' |
    python3 -c 'import json,sys; r=json.load(sys.stdin).get("result",{}); print("  planes:", json.dumps(r, ensure_ascii=False)[:400])' 2>/dev/null || true
  echo "  repo HEAD: $(git -C "$REPO" rev-parse --short HEAD)"
}

# One JSON-RPC call against the running daemon. Used by `rules`, which needs
# what the plane actually holds rather than what a copied document claims.
rpc() {
  curl -sf -m 10 -X POST "http://$ADDR/rpc" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}"
}

# The version stamped into every generated block: a hash of the block's own
# template, taken from the source of this script between the two anchors below.
#
# Derived rather than hand-kept because a version number you have to remember to
# bump gets forgotten in exactly the edit that mattered — which is the decay this
# is here to catch. The region hashed is the template, placeholders and all, so
# `{plane}` and `{addr}` never enter it: every repository on the same generator
# gets the same version, and it moves when and only when the prose moves.
rules_version() {
  sed -n '/^block = f"""{BEGIN}$/,/^{END}"""$/p' "$SELF_PATH" | sha256sum | cut -c1-8
}

# The same trick for the `codegraph` skill, which documents how to *operate*
# this script — as opposed to the block above, which says how to ask the graph
# questions. The two decay independently and for different reasons: the block
# goes stale when the prose about asking changes, the skill when the command
# surface does. So the region hashed here is the dispatch itself. Rename a
# subcommand and every sentence in the skill naming the old one is wrong, and
# nothing else in this file would have noticed.
SKILL_MD="${CODEGRAPH_SKILL:-$HOME/.claude/skills/codegraph/SKILL.md}"
skill_version() {
  sed -n '/^case "$cmd" in$/,/^esac$/p' "$SELF_PATH" | sha256sum | cut -c1-8
}

# Write the rules block into <repo>/CLAUDE.md, generated from the live plane.
#
# Generated rather than copied because copying is what went wrong: the second
# repository to get a code graph inherited the first one's block verbatim —
# its plane name, its port, its node counts — and every `context` call made
# against the name in that document failed with `not found: plane`. Numbers a
# human is expected to keep current go stale; numbers read out of the daemon
# cannot disagree with it.
rules() {
  read_config
  local pid; pid="$(db_holder_pid)"
  if [ -z "$pid" ]; then
    echo "ERROR: the daemon for $REPO is not running, so there is no plane to describe." >&2
    echo "       Run \`$0 start --dir $REPO\` first." >&2
    exit 1
  fi
  ADDR="$(pid_addr "$pid")"
  mkdir -p "$STATE"
  # Via a file, not a pipe: the heredoc below already owns this python's stdin.
  local catalog="$STATE/catalog.json"
  # A plane that answers before its first fold has landed reports 0/0, and the
  # whole point of generating this block is that its numbers are true — writing
  # "0 nodes" into a new repository's CLAUDE.md is worse than writing nothing.
  local n=0
  for _ in $(seq 1 30); do
    rpc plane.catalog "{\"plane\":\"$PLANE\"}" > "$catalog" || {
      echo "ERROR: plane.catalog failed on http://$ADDR/rpc — is the plane named '$PLANE'?" >&2
      exit 1
    }
    n="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("result") or {}).get("node_count",0))' "$catalog")"
    [ "$n" -gt 0 ] && break
    sleep 1
  done
  if [ "$n" -eq 0 ]; then
    echo "ERROR: plane '$PLANE' is empty after waiting 30s — no block written." >&2
    echo "       Either the first fold is still running (check \`$0 logs --dir $REPO\`)," >&2
    echo "       or no installed plugin claims any file here (\`$BIN plugin list\`)." >&2
    exit 1
  fi
  # Absolute: the block is read from inside a different repository than the one
  # this script happened to be invoked from, where `./scripts/...` means nothing.
  python3 - "$REPO" "$PLANE" "$ADDR" "$SELF_PATH" "$catalog" "$(rules_version)" <<'PY'
import json, os, sys

repo, plane, addr, ctl, catalog_path, version = sys.argv[1:7]
with open(catalog_path, encoding="utf-8") as fh:
    cat = json.load(fh).get("result") or {}
labels = {k: v.get("count", 0) for k, v in (cat.get("labels") or {}).items()}
nodes, edges = cat.get("node_count", 0), cat.get("edge_count", 0)
# Label names, never their counts. A count written into a document nobody
# regenerates per commit is a number that is wrong by the next commit, and this
# block exists because a stale document sent every call to the wrong plane. The
# names are what a caller can actually use — they say what there is to ask for —
# and they change only when the repository changes language.
askable = [n for n, c in sorted(labels.items(), key=lambda kv: -kv[1])
           if n not in ("UnresolvedRef", "External") and c]
named = ", ".join(askable[:10]) + (f", +{len(askable) - 10} more" if len(askable) > 10 else "")

BEGIN = "<!-- drsg-codegraph:begin -->"
END = "<!-- drsg-codegraph:end -->"

block = f"""{BEGIN}
<!-- rules={version} — regenerate with `{ctl} rules --dir {repo}` -->
## Code graph (structural questions go through the graph first)

This repository is folded into the **`{plane}`** plane, re-folded on every
commit, and served by the `drsg-watch` MCP tools on `http://{addr}/mcp`. It
models: {named}. For its current size and the commit it is synced up to, ask
`describe_plane` or run `{ctl} status --dir {repo}` — no count is written down
here, because a count in a document is wrong one commit later.

**Every call must pass `plane: "{plane}"`.** The tools default to `startup`,
which is an empty plane, and its answer — `no symbol matches` — is
indistinguishable from the graph genuinely not knowing. In the first audit of
this setup, plane addressing accounted for 6 of the 8 empty answers; only 2
were real gaps.

**The check on an answer is the graph's own symbol key.** A structural claim
must quote the full key the graph returned — `crate::module::Symbol`,
`github.com/acme/example/pkg.Type.Method` — not just a `file:line`, because grep
prints `file:line` too and so a rule written on it cannot catch its own
violation.

**The trigger is in the answer, not in the question.** The moment a reply
contains a quantified structural claim — "only X callers", "nothing uses it",
"nothing else is affected", "these are the places to change" — that claim has
to come from the graph, however casual the question sounded.

| Question | Verb |
|---|---|
| who calls X / all of X at once | `context` (start here) |
| what does changing X affect | `impact` |
| how does A reach B | `trace` |
| where is X, what is its signature | `describe` |
| give me the source of X | `snippet` |
| what is in the plane at all | `describe_plane`, `cypher` |
| text the graph does not model | `grep` (searches the watched tree) |

**A change question is not answered until `impact` has run.** Asking what
changing, renaming or deleting X reaches is a different question from who calls
X, and `context` cannot answer it: it walks one hop. Any reply about the reach
of a change must quote `impact`, which groups what it found by distance and
counts each group — a caller list does not have that shape, so pasting one is a
visible substitution, not an answer. `impact` finding nothing past distance 1 is
itself the answer; say so. It counts recorded edges only and says as much in its
own output — carry that caveat with the number, it is a lower bound. The same
rule holds for `trace`: a claim that A reaches B quotes the path `trace`
returned, hop by hop.

Expect to break this one. Over the first month of this setup `context` was
called 46 times, `impact` once, and `trace` never — every question about blast
radius was answered by the verb that only sees one hop, and none of those
answers looked wrong at the time.

**Ask with a symbol name, not a description.** `context` resolves a string in
three passes (exact key, then `::name`/`.name` suffix, then case-insensitive
substring). Naming a file sends the answer to `Read`; naming a symbol goes to
the graph. The third pass is the boundary: a descriptive word works only if it
is a substring of some symbol's name, so `plugin` resolves and a phrase in prose
— or in a language the code is not written in — does not. That is `grep`'s job,
and the answer has to say so.

**An ambiguous name is not a failure, but the candidate list is capped at 20 and
is not ranked by relevance.** Past about 20 candidates, do not pick from what is
shown — narrow and ask again, because the right symbol may be in the part that
was folded away. `Type::method` is the narrowing that usually lands in one call.
With 2–10 candidates, `describe` each and choose from the signatures: a function
returning another crate's type is usually a wrapper, and running `impact` on the
wrapper reports a strictly smaller blast radius than the thing it delegates to.

**Raise `impact`'s depth until a group comes back empty.** It walks 3 hops by
default, and cutting off where propagation has not stopped yields the first
three hops rather than the reach; two symbols measured at different depths are
not comparable. The empty group is the evidence that the answer is complete.

**The graph will also tell you it does not know**, and that is worth more than
a guess: the `UnresolvedRef` nodes are exactly where the parsers gave up (there
are thousands — `describe_plane` counts them), and cross-language edges are
generally broken. Comments (`//`), string
literals, and files no plugin claims (`.md`, `.sh`, CI config) are not modelled
at all. Use `grep` there and **say that the answer came from grep** — an empty
graph result is a finding to report, never a reason to fall back to impressions.

Daemon: `{ctl} {{start|stop|restart|status|rules}} --dir {repo}`. One per
repository; the address and token both live in `.mcp.json`, so never mint a new
token — that invalidates every client config `drsg init` wrote.
{END}"""

path = os.path.join(repo, "CLAUDE.md")
existing = ""
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        existing = fh.read()

if BEGIN in existing and END in existing:
    head, rest = existing.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(head + block + tail)
    print(f"   refreshed the code-graph block ({nodes} nodes / {edges} edges, plane '{plane}')")
elif "drsg-watch" in existing:
    # Hand-written docs outrank a generated block: appending would leave the
    # repository with two sections disagreeing about the plane name, which is
    # the failure this command exists to prevent, doubled.
    hits = [i + 1 for i, l in enumerate(existing.splitlines()) if "drsg-watch" in l]
    print(f"   CLAUDE.md already documents drsg-watch by hand (line{'s' if len(hits) > 1 else ''} "
          f"{', '.join(map(str, hits[:5]))}) — left untouched.")
    print(f"   Check it names plane '{plane}' and http://{addr}/mcp; delete the section and")
    print("   re-run to replace it with the generated one.")
    sys.exit(0)
else:
    sep = "" if not existing else ("\n" if existing.endswith("\n") else "\n\n")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(sep + block + "\n")
    print("   added the code-graph block" if existing else "   created CLAUDE.md with the code-graph block")
PY
}

# Register the SessionStart guard in the project's settings.local.json.
#
# settings.local.json rather than settings.json: the shared file is checked in
# by some repositories, and this hook points at an absolute path on one machine.
register_hook() {
  local settings="$REPO/.claude/settings.local.json"
  mkdir -p "$REPO/.claude"
  python3 - "$settings" "$SELF_PATH" "$REPO" <<'PY'
import json, os, sys

path, script, repo = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = f"{script} hook --dir {repo}"
doc = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        try:
            doc = json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"   WARNING: {path} is not valid JSON ({exc}) — hook not registered")
            raise SystemExit(0)

hooks = doc.setdefault("hooks", {}).setdefault("SessionStart", [])
for group in hooks:
    for h in group.get("hooks", []):
        if "codegraph.sh hook" in h.get("command", ""):
            h["command"] = cmd          # keep an older path pointing somewhere real
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, indent=2)
                fh.write("\n")
            print("   SessionStart guard already registered (command refreshed)")
            raise SystemExit(0)

hooks.append({
    "matcher": "startup|resume",
    "hooks": [{"type": "command", "command": cmd, "timeout": 30}],
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
print(f"   registered the SessionStart guard in {os.path.basename(path)}")
PY
}

# One terminal line, or none. Takes the message on stdin so nothing has to be
# escaped by hand, and emits the JSON a SessionStart hook is read as.
say() {
  printf '{"systemMessage":%s}\n' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))')"
}

# SessionStart guard. An MCP "http" entry is a connect instruction, not a launch
# one, so nothing in any agent client restarts a daemon that died or never came
# back after a reboot — the tools simply fail, and the session quietly does the
# whole task with grep instead. That silent degradation is the failure mode this
# catches, so it speaks on the terminal when it had to act, and stays quiet
# otherwise. It must never take a session down with it: every path exits 0.
#
# It then runs the consistency checks, because the rest of the setup rots
# silently too: the block in CLAUDE.md is written once and never refreshed, so a
# renamed plane or a moved port leaves a document that confidently names
# something that no longer exists — and a wrong plane name costs every call,
# where a dead daemon at least fails loudly. Checking is a couple of local RPCs;
# noticing three weeks later is not.
hook() {
  [ -f "$MCP_JSON" ] || exit 0
  grep -q '"drsg-watch"' "$MCP_JSON" 2>/dev/null || exit 0
  # Deliberately without read_config: a malformed .mcp.json makes it exit, and
  # an exit here is a hook that failed at the top of someone's session.
  local pid live="" restarted="" out
  pid="$(db_holder_pid)"
  [ -n "$pid" ] && live="$(pid_addr "$pid")"
  if [ -z "$live" ] || ! curl -sf -m 2 "http://$live/health" >/dev/null 2>&1; then
    if out="$(start 2>&1)"; then
      # `already running` means something else started it between the health
      # check and here — upstream's own ensure-server hook fires at the same
      # moment and usually wins. It has already said so on this terminal;
      # claiming the restart a second time is two lines about one event.
      case "$out" in
        "already running"*) : ;;
        *) restarted="daemon was down, restarted — ${out%%$'\n'*}" ;;
      esac
    else
      printf 'code graph: plane %s is NOT being served (%s) — drsg-watch tools will fail; run `%s start --dir %s`. Say so rather than answering structural questions from grep alone.' \
        "$PLANE" "${out%%$'\n'*}" "$SELF_PATH" "$REPO" | say
      exit 0
    fi
  fi
  # Only the lines that name a problem: `doctor` narrates its passes too, and a
  # guard that speaks when nothing is wrong gets ignored when something is.
  local report problems=""
  if ! report="$(doctor 2>&1)"; then
    problems="$(printf '%s\n' "$report" | grep -F '**' | tr -s ' ' | tr '\n' ';' | sed 's/^ *//; s/;$//')"
  fi
  if [ -n "$restarted" ] && [ -n "$problems" ]; then
    printf 'code graph: %s. Also wrong: %s — `%s doctor --dir %s` for the detail.' \
      "$restarted" "$problems" "$SELF_PATH" "$REPO" | say
  elif [ -n "$restarted" ]; then
    printf 'code graph: %s' "$restarted" | say
  elif [ -n "$problems" ]; then
    printf 'code graph: plane %s is served, but its setup disagrees with itself: %s. `%s rules --dir %s` regenerates the block; `%s doctor --dir %s` for the detail.' \
      "$PLANE" "$problems" "$SELF_PATH" "$REPO" "$SELF_PATH" "$REPO" | say
  fi
  exit 0
}

# Everything a repository needs, in the order that each step's failure is still
# cheap: a binary, a digest, a daemon, the rules, the guard.
install() {
  require_bin
  if [ ! -f "$MCP_JSON" ] || ! grep -q '"drsg-watch"' "$MCP_JSON" 2>/dev/null; then
    echo "== bootstrapping $REPO with \`drsg init\` (full digest, this takes a while)"
    "$BIN" init --dir "$REPO" ${port:+--addr "127.0.0.1:$port"} || {
      echo "ERROR: \`drsg init\` failed — nothing was changed in $REPO." >&2
      exit 1
    }
  fi
  echo "== daemon"
  start
  echo "== rules"
  rules
  echo "== SessionStart guard"
  register_hook
  echo "== router registry"
  register_graph
  echo
  echo "Done. Open a session in $REPO and ask for a symbol by name — a plane"
  echo "nobody queries is indistinguishable from no plane at all."
}

# Announce this repository to codegraph-router.py, the one MCP server that
# reaches every graph. Appending here rather than asking the operator to
# remember: a repo that is digested, running and documented but unlisted is
# reachable from its own sessions and invisible from everywhere else, which is
# the failure the router exists to remove.
#
# Only the path is recorded — the plane defaults to the same basename this
# script uses, and address and token stay in .mcp.json where the clients read
# them.
register_graph() {
  local reg="${DRSG_GRAPHS:-$HOME/.drsg-memory/graphs}"
  if [ -f "$reg" ] && grep -qxF "$REPO" "$reg"; then
    echo "  already listed in $reg"
    return 0
  fi
  mkdir -p "$(dirname "$reg")"
  if [ ! -f "$reg" ]; then
    printf '# Repositories with a code graph, for codegraph-router.py.\n# One path per line; optional TAB + plane when it is not the basename.\n' > "$reg"
  fi
  if [ -n "${DRSG_CODE_PLANE:-}" ] && [ "$PLANE" != "$(basename "$REPO")" ]; then
    printf '%s\t%s\n' "$REPO" "$PLANE" >> "$reg"
  else
    printf '%s\n' "$REPO" >> "$reg"
  fi
  echo "  added to $reg"
}

# Everything that has to agree for the graph to be reachable AND consulted,
# checked against the daemon rather than asserted: the plane exists under the
# name the documentation gives, it is folded up to HEAD, it was parsed from this
# repository and not another, the rules block names that plane and address, the
# guard is registered exactly once, and the skill describing how to operate all
# of this still matches the command surface. Each line is a failure seen at
# least once — a plane synced to a different repo's tree, a block naming a plane
# that does not exist here, a daemon that had been down for three days.
#
# Exits non-zero on the first thing that is wrong, so it can gate a loop over
# several repositories.
doctor() {
  read_config
  local rc=0
  local pid; pid="$(db_holder_pid)"
  if [ -z "$pid" ]; then
    echo "  daemon      ** DOWN — nothing holds $DB (.mcp.json says $CFG_ADDR) **"
    return 1
  fi
  ADDR="$(pid_addr "$pid")"
  echo "  daemon      up on $ADDR (pid $pid)$([ "$ADDR" = "$CFG_ADDR" ] || echo "  ** .mcp.json says $CFG_ADDR **")"
  [ "$ADDR" = "$CFG_ADDR" ] || rc=1
  rpc plane.list '{}' > "$STATE/planes.json" 2>/dev/null || { echo "  plane       RPC failed"; return 1; }
  python3 - "$STATE/planes.json" "$PLANE" "$REPO" "$(git -C "$REPO" rev-parse HEAD)" "$ADDR" "$(rules_version)" <<'PY' || rc=1
import json, os, sys
path, plane, repo, head, addr, version = sys.argv[1:7]
planes = {p["name"]: p for p in json.load(open(path)).get("result", [])}
bad = 0
if plane not in planes:
    print(f"  plane       MISSING '{plane}' (daemon has: {', '.join(planes) or 'nothing'})")
    raise SystemExit(1)
props = planes[plane].get("properties", {})
synced = (props.get("synced_commit") or {}).get("$value", "")
root = (props.get("synced_root") or {}).get("$value", "")
print(f"  plane       {plane}  {planes[plane]['nodes']} nodes / {planes[plane]['edges']} edges")
if synced != head:
    print(f"  synced      ** {synced[:12] or 'unknown'}, HEAD is {head[:12]} ** — a commit has not been folded")
    bad = 1
else:
    print(f"  synced      {synced[:12]} = HEAD")
if root != repo:
    print(f"  root        ** parsed from {root or 'unknown'}, not {repo} **")
    bad = 1
md = os.path.join(repo, "CLAUDE.md")
text = open(md, encoding="utf-8").read() if os.path.exists(md) else ""
if not text or "drsg-watch" not in text:
    print("  CLAUDE.md   ** no code-graph section — the tools exist and nothing tells anyone **")
    bad = 1
else:
    kind = "generated" if "drsg-codegraph:begin" in text else "hand-written"
    # The instruction as a caller copies it, not the bare name: `plane` is the
    # repository's basename, so it occurs in every path the document mentions
    # and a substring test passes even when the block names the wrong plane.
    names = f'plane: "{plane}"' in text and addr in text
    # A count in a file nobody regenerates per commit is wrong by the next one.
    stale = [n for n in __import__("re").findall(r"(\d{3,})\s*(?:nodes|edges|节点|边)", text)
             if int(n) not in (planes[plane]["nodes"], planes[plane]["edges"])]
    # A block generated by an older version of the rules. `generated` alone does
    # not mean current: the sentinel says where the block came from, not when,
    # so a repository can sit for weeks on prose the generator has since changed
    # and every check above still passes.
    m = __import__("re").search(r"<!-- rules=([0-9a-f]+)", text)
    if kind != "generated":
        old = ""  # hand-written sections are the author's; nothing to compare to
    elif not m:
        old = ", ** rules unversioned — predates the stamp, regenerate **"
    elif m.group(1) != version:
        old = f", ** rules {m.group(1)}, generator is at {version} — regenerate **"
    else:
        old = f", rules {version}"
    print(f"  CLAUDE.md   {kind}, names plane+address: {'yes' if names else '** NO **'}"
          + (f", ** stale counts: {', '.join(stale)} **" if stale else "") + old)
    bad = bad or not names or bool(stale) or "**" in old
raise SystemExit(bad)
PY
  python3 - "$REPO/.claude/settings.local.json" <<'PY' || rc=1
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print("  guard       ** not registered (no settings.local.json) **"); raise SystemExit(1)
try:
    doc = json.load(open(path))
except Exception as exc:
    print(f"  guard       ** settings.local.json is not valid JSON: {exc} **"); raise SystemExit(1)
cmds = [h.get("command", "") for g in doc.get("hooks", {}).get("SessionStart", [])
        for h in g.get("hooks", [])]
mine = [c for c in cmds if "codegraph.sh hook" in c]
if len(mine) != 1:
    print(f"  guard       ** {len(mine)} registrations, expected exactly 1 **"); raise SystemExit(1)
missing = "" if os.path.exists(mine[0].split()[0]) else "  ** that path does not exist **"
print(f"  guard       registered{missing}")
raise SystemExit(1 if missing else 0)
PY
  python3 - "$SKILL_MD" "$(skill_version)" <<'PY' || rc=1
import os, re, sys
path, version = sys.argv[1], sys.argv[2]
# Machine-wide, not per-repository: the skill is installed once under ~/.claude
# and serves every repo with a graph. Reported on each doctor run anyway,
# because the run that notices it is missing is the one that needed it.
if not os.path.exists(path):
    print(f"  skill       ** not installed at {path} — operating the graph is undocumented **")
    raise SystemExit(1)
m = re.search(r"<!-- codegraph-cli=([0-9a-f]+)", open(path, encoding="utf-8").read())
if not m:
    print("  skill       ** unversioned — predates the stamp, re-copy from skills/codegraph **")
    raise SystemExit(1)
if m.group(1) != version:
    print(f"  skill       ** cli {m.group(1)}, dispatch is at {version} — subcommands moved, update SKILL.md **")
    raise SystemExit(1)
print(f"  skill       installed, cli {version}")
PY
  return $rc
}

case "$cmd" in
  install) install ;;
  doctor)  echo "=== $REPO"; doctor ;;
  start)   start ;;
  stop)    stop ;;
  restart) read_config; require_bin; stop; start ;;
  status)  status ;;
  rules)   rules ;;
  hook)    hook ;;
  logs)    tail -f "$LOG" ;;
  *) echo "usage: $0 {install|start|stop|restart|status|rules|hook|doctor|logs} [--dir PATH] [--port N] [--force]"; exit 1 ;;
esac

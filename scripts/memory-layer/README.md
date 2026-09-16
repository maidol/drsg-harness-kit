# Long-term memory layer for Claude Code

> Today this supports Claude Code only. The hook contract (`SessionStart` /
> `UserPromptSubmit` / `SessionEnd` plus a transcript path) and the `claude mcp
> add` registration path are Claude Code's; porting to another harness means
> replacing `templates/hooks/` and those calls in `install.sh`, not the memory
> layer underneath. The two MCP servers (`codegraph-router.py`, `mcp_events.py`)
> are already harness-neutral — any stdio MCP client can register them today.

A one-command install that turns Dr Strange into persistent, cross-session
memory for [Claude Code](https://claude.com/claude-code) projects: the graph
remembers what earlier sessions concluded, and every new session starts with a
briefing instead of a blank slate.

The whole thing is four Python hooks, an installer, and a daemon control
script. No plugin, no service to sign up for, no data leaving the machine.

## Architecture

```
any Claude Code project                one shared daemon (~/.drsg-memory/)
┌────────────────────────────┐        ┌──────────────────────────────┐
│ .claude/hooks/ (4 scripts) │──RPC──▶│ a single `drsg serve`        │
│   session_start / end      │        │  holding memory.drsg         │
│   user_prompt / l3_digest  │        │  one Project node per repo   │
│ .drsg/env (points at it)   │        │  addr 127.0.0.1:7700         │
│ settings.local.json hooks  │        └──────────────────────────────┘
│ MCP: drsg @ /mcp           │──HTTP──▶ (several agents, one database)
└────────────────────────────┘
```

- **Shared, not per-project.** One daemon owns every project's memory. The
  native backend allows one process per database, so a daemon is the only way
  several agents — or several editors — can read and write one graph at once.
- **Separated, not mixed.** Each project is a `Project` node; Facts hang off it
  with `ABOUT` edges. Recall filters on the project's `path`.
- **Three ways in.** L1: structural facts the hooks mine from the transcript —
  files touched, commands run, tool outcomes. L2: conclusions the model writes
  itself, following a protocol injected at session start; this is where the
  value is, and it is *only* a prompt — nothing enforces or verifies it. L3:
  LLM distillation of the transcript tail (optional, off by default).
- **Two ways out.** SessionStart injects a compressed briefing for this
  project; UserPromptSubmit recalls Facts matching what you just typed, across
  *all* projects, labelled with where they came from.
- **A compaction re-injects.** SessionStart also runs on `compact`, because a
  compaction drops the briefing and the protocol out of context while the
  session keeps going. That path stamps the existing Session node instead of
  creating a second one.

## Prerequisites

- A `drsg` binary. `serve.sh` starts it; pass `--bin` or set `$DRSG_MEM_BIN`.
- **The `/mcp` endpoint on `drsg serve`**, for the MCP registration step. The
  hooks themselves only need `/rpc` and work without it.
- Python 3, `curl`, and `openssl` (token generation).

## Install

```bash
# from this directory
./install.sh /path/to/project --bin /path/to/drsg
```

**Restart the Claude Code session afterwards** — hooks and MCP servers are read
at startup.

L3 distillation is off unless you name a chat provider:

```bash
./install.sh /path/to/project --bin /path/to/drsg \
  --l3-chat openai            # or deepseek / qwen / ollama
```

`--l3-chat` also takes a raw OpenAI-compatible base URL — a self-hosted proxy,
say — but only against a daemon whose `digest.run` accepts one; with the preset
names above, any daemon will do.

## Joining an existing daemon

If something already answers `/health` at the target address, `install.sh`
**joins** it rather than starting a second one. Every project then lands in the
same `memory` plane, separated by its `Project` node, and recall can reach
across them. Joining requires that daemon's token:

```bash
./install.sh /path/to/other-project --bin /path/to/drsg \
  --addr 127.0.0.1:7700 --token <the daemon's token>
```

To move a project that was installed against its *own* daemon, migrate its
memory first:

```bash
# 1. export from the old daemon
python3 migrate.py dump --api http://127.0.0.1:7701/rpc --token <old token> \
  --plane memory --out project-memory.json
# 2. import into the shared one (deduplicates by external key, never overwrites)
python3 migrate.py load --api http://127.0.0.1:7700/rpc --token <new token> \
  --plane memory --in project-memory.json
# 3. re-run the installer against the shared address (idempotent)
./install.sh /path/to/other-project --bin /path/to/drsg \
  --addr 127.0.0.1:7700 --token <new token>
# 4. once you've confirmed it, stop the old daemon
./serve.sh stop
```

Back up both databases first — stop the daemon, then copy the directory.
`migrate.py` warns about and skips nodes with no external key; a `dump` will
tell you whether you have any.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--bin <path>` | `$DRSG_MEM_BIN` or `drsg` | the binary to run |
| `--addr <host:port>` | `127.0.0.1:7700` | daemon listen address |
| `--token <t>` | reused or generated | shared API token; **required when joining** an existing daemon |
| `--l3-chat <name\|url>` | empty (L3 off) | preset name or OpenAI-compatible base URL |
| `--l3-key-env <v>` | the preset's own | **name** of the env var holding the LLM key (see below) |
| `--l3-model <m>` | the provider's own | model id, exactly as the endpoint lists it |
| `--l3-reasoning <e>` | unset | `reasoning_effort`; `none` stops a reasoning model truncating the JSON |
| `--restart-daemon` | off | stop an existing daemon first (new token or address) |
| `--check` | off | install nothing; report hook drift and exit 1 if any (below) |

## Running the daemon

```bash
./serve.sh start|stop|restart|status
# overrides: DRSG_MEM_DIR / DRSG_MEM_BIN / DRSG_MEM_ADDR / DRSG_MEM_TOKEN
# BIN and ADDR fall back to the values persisted in the env file, so a bare
# `restart` works with no arguments.
```

State lives in `~/.drsg-memory/`: `memory.drsg`, `env`, `serve.log`,
`serve.pid`.

**Changing the L3 key needs a daemon restart.** `start` exports the env file's
`KEY=VALUE` pairs into the daemon's own process environment; a daemon already
running under the old environment will keep sending an empty key and
`digest.run` will come back 401. Run `./serve.sh restart` after editing it.

## What an install actually does

1. Ensures the shared daemon is running, generating or reusing a token. With
   L3 enabled, the key's **value** is written to `~/.drsg-memory/env` *before*
   the daemon starts, so `start` can export it.
2. Copies the four hooks into `<project>/.claude/hooks/`.
3. Writes `<project>/.drsg/env` (`chmod 600`) — daemon address, token, and the
   L3 settings, with the key's **name** only.
4. Merges the SessionStart / UserPromptSubmit / SessionEnd entries into
   `<project>/.claude/settings.local.json`, keeping whatever is already there.
5. Registers two MCP servers (project scope): `drsg` against the daemon's
   `/mcp`, and `drsg-events` — a stdio server in this directory exposing
   `event_post` / `event_list` / `event_done`. The second one is separate on
   purpose: `Event` and `NOTIFY` are conventions this layer keeps on top of a
   soft-schema graph, and the engine that does not know what a Fact is has no
   business learning what an Event is.
6. **Self-checks**: daemon reachable, plane present, the project key resolving
   to a `Project` node, and a temporary Fact readable through the hooks' own
   recall query. Any failure exits non-zero and says so, rather than reporting
   a successful install of something that will silently do nothing.

Add `.drsg/` to the target project's `.gitignore`.

## Are the installs still in sync? (`--check`)

`templates/hooks/` is canonical and version-controlled; every
`<project>/.claude/hooks/` is a copy, and `.claude/` is gitignored in the
projects — so nothing about a deployed hook is tracked anywhere. With several
installs sharing one daemon, they drift silently.

```bash
./install.sh --check                    # every project the plane knows about
./install.sh /path/to/project --check   # just that one  (dir comes FIRST)
```

```
  ok    /path/to/project
  DRIFT /path/to/other-project
          user_prompt.py: 58c508dc != 311c8e74  (deployment is newer)
```

Exit 1 on any drift, so it works as a CI or pre-commit gate.

Drift runs **both** ways, and the fix differs, so the report says which side
is ahead by mtime rather than guessing:

- **template is newer** — an install got left behind. Re-run `install.sh` on
  that project.
- **deployment is newer** — someone edited a hook in place. Copy it back into
  `templates/hooks/` and commit, **or the next install silently reverts it**.
  This is not hypothetical: it is how this flag came to exist.

With no project-dir the list comes from the memory plane's `Project` nodes —
the same list recall itself walks. A project installed but never recorded is
invisible here for exactly the reason it is invisible to recall, which is more
useful than a second registry that can disagree with the first.

## Is it working? (`analyze_recall.py`)

Both read hooks append one JSON line per decision to `<project>/.drsg/recall.jsonl`
— what was ranked, what was injected, what it cost, and how long it took.
Writing it can never fail a session; the record is made after the decision.

```bash
python3 scripts/memory-layer/analyze_recall.py            # every project the daemon knows
python3 scripts/memory-layer/analyze_recall.py --since 14
```

It pairs each injection with the reply that followed it in the transcript and
reports:

- **utilization** — of the facts injected, how many did the reply visibly use;
- **cross-project** — whether facts borrowed from another project are used at
  a rate comparable to local ones, which is the only honest way to decide
  whether sharing pays for its tokens;
- **dead facts** (injected repeatedly, never used) and **never-injected facts**
  (whose wording matches no real prompt);
- **cost** — injected characters, the briefing/protocol split, hook latency.

Utilization is a proxy and the script says so: it over-counts a reply that
merely acknowledges a memory, and under-counts a memory that worked by
preventing something — the toolchain fact succeeding looks exactly like a build
that simply did not fail. Read it as a floor and a trend. Below 30 recorded
sessions the script refuses to draw a conclusion at all.

## Notes

- **The LLM key never leaves the server.** `digest.run` is passed the *name* of
  an environment variable; the daemon reads the value from its own process
  environment. The project's `.drsg/env` holds the name, never the value.
- **L3 is opt-in and asynchronous.** With `--l3-chat` set, `session_end`
  spawns the distillation detached, so ending a session never waits on an LLM
  call. Failures land in the project's `.drsg/l3.log`.
- **Hooks are overwritten, not merged.** A project with its own SessionStart
  hook will lose it. Back it up first.
- **One config per project.** Each `.drsg/env` is independent: different
  projects can enable L3 differently, or point at different daemons.

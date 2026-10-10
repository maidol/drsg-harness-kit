# Long-term memory layer for Claude Code

[中文版](README.zh-CN.md)

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

The `tools/claude-model-picker.sh` Bash function asks which model to use before
an interactive `claude` starts. Unless `CLAUDE_PICK_MODELS` is set, it uses
`tools/claude-model-discovery.py` to query the configured gateway and falls back
to a static list on failure. Its runtime files are deployed with the tools, but
fresh installs leave it disabled. Enable during setup with
`setup.sh --model-picker`, or later run
`~/.drsg-memory/tools/claude-model-picker-config.sh enable`; disable with the
same command and `disable`. Ordinary setup/update runs preserve the current
choice. Full instructions are in the root README's “Model picker at startup”
section.

The main-worktree/current-branch rule is installed by `setup.sh` by default,
independently of `--no-skills`. Manage its user-level import and persistent opt-out
with `~/.drsg-memory/tools/main-branch-workflow-config.sh enable|disable|status`;
`setup.sh --no-main-branch-workflow` also opts out. The marker is stored in
`$CLAUDE_CONFIG_DIR/.main-branch-workflow.disabled` (normally
`~/.claude/.main-branch-workflow.disabled`). This is guidance, not an enforcement
sandbox; it never switches branches.

## Code graph router and usage reporting

The runtime bundle includes the router and usage-report binaries, but project
configuration is opt-in. Use `codegraph-router-setup.sh` for router MCP access,
`codegraph-usage-setup.sh` for the Stop-hook report, or the explicit combined
`codegraph-hub-setup.sh` convenience wrapper. The usage report counts both
native local graph calls and routed `codegraph` calls; it is not installed by
`install.sh` or by default `setup.sh`.

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
names above, any daemon will do. The provider contract is implemented by the
memory daemon, not by this repository.

## Joining an existing daemon

If something already answers `/health` at the target address, `install.sh`
**joins** it rather than starting a second one. Every project then lands in the
same `memory` plane, separated by its `Project` node, and recall can reach
across them. Re-running the installer for an existing project reuses its
`.drsg/env` credential internally, without printing or passing it as a
command-line argument. It refreshes `drsg-events` and preserves an existing
`drsg` registration. If `drsg` is missing, it warns rather than exposing the
reused token; `install.sh --audit` reports the drift. Register it manually
through a secret-safe workflow. A new project joining still requires that
daemon's token:

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
`migrate.py` warns about and skips nodes with no external key; a `dump`
will tell you whether you have any.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--bin <path>` | `$DRSG_MEM_BIN` or `drsg` | the binary to run |
| `--addr <host:port>` | `127.0.0.1:7700` | daemon listen address |
| `--token <t>` | reused or generated | explicit API token; existing projects reuse `.drsg/env`; **required for a new project joining** a running daemon |
| `--l3-chat <name\|url>` | empty (L3 off) | preset name or OpenAI-compatible base URL |
| `--l3-key-env <v>` | the preset's own | **name** of the env var holding the LLM key (see below) |
| `--l3-model <m>` | the provider's own | model id, exactly as the endpoint lists it |
| `--l3-reasoning <e>` | unset | `reasoning_effort`; `none` stops a reasoning model truncating the JSON |
| `--restart-daemon` | off | stop an existing daemon first (new token or address) |
| `--check` | off | install nothing; report hook drift and exit 1 if any (below) |
| `--audit` | off | install nothing; run 5-layer full deployment audit |

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

## Full layered deployment audit (`--audit`)

`--check` only compares hook files against templates. Real deployment drift also occurs in runtime tools, global configuration, project settings, or code graph configurations. The `--audit` flag runs a comprehensive 5-layer audit:

- **L0: Project Discovery** (when running `--all`): Discovers known projects from the memory plane via proxy-safe connection, failing explicitly on discovery errors.
- **L1: Global Runtime Tools**: Compares `~/.drsg-memory/tools/` against the git `HEAD` release baseline and verifies execution permissions; uncommitted drafts are noted as advisory hints without failing audit.
- **L2: Global Configuration & Skills**: Verifies `~/.claude/AGENT-EFFICIENCY.md`, skills, managed main-branch workflow state (enabled, intentional opt-out, or drift), global hooks, and `settings.json` permissions (`0600`).
- **L3: Project Memory Hooks**: Compares `.claude/hooks/*.py` in each project against canonical templates.
- **L4: Project Settings & Docs**: Checks `.claude/settings.local.json` registrations, `.drsg/env` credentials, `CLAUDE.md` cross-agent Event documentation, and that the `drsg` and `drsg-events` MCP servers are registered for the project in `~/.claude.json` (local or user scope; `$CLAUDE_CONFIG_DIR/.claude.json` when that is set, or the `--claude-dir` directory). A missing one is reported together with the command that registers it.
- **L5: Code Graph Status**: Verifies code graph daemon health and `.mcp.json` port bindings, recognizing on-demand stopped daemons as normal state.

```bash
./install.sh --audit                    # audit all known projects across all layers
./install.sh /path/to/project --audit   # audit a single project
python3 audit_deployment.py --all --json  # machine-readable JSON output
```

To exclude unmanaged projects from failing `--audit`, place a `.drsg/audit-skip` file in the project's root.

## Is it working? (`analyze_recall.py`)

Both read hooks append one JSON line per decision to `<project>/.drsg/recall.jsonl`
— what was ranked, what was injected, what it cost, and how long it took.
Writing it can never fail a session; the record is made after the decision.

```bash
python3 analyze_recall.py            # every project the daemon knows
python3 analyze_recall.py --since 14
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

The **control arm** is the one randomized readout. 15% of prompts are ranked
and logged but not injected, and `session_end.py` records each prompt's tool
calls and errors. The paired line takes every session that has both arms,
counts the sessions where treated prompts failed more often than suppressed
ones (and the reverse), and reads that count against the same count with the
arm labels shuffled inside each session (2,000 seeded shuffles):

```
  paired all errors  : treated worse in 57, better in 22, tied 6  → permutation p=0.091 (shuffled labels expect worse−better +20.1)
```

The shuffled expectation is not 0. The suppressed arm is small, so its error
rate is 0 more often by chance alone, and "treated worse" is the expected
majority even with no effect at all. Read `p`, not the raw count.

## Posting a to-do (`event.py post` / `event_post`)

For the execution-side review/acceptance stages and the one-time commit authorization boundary, see the [globally distributed workflow](../claude/AGENT-EFFICIENCY.md#跨项目审核与验收按阶段交接不跳闸); this README covers Event mechanics only.

`event.py post` and the `event_post` MCP tool share one implementation. Give a
to-do code-graph symbols and a verb, and the recipient gets an imperative
`↳ graph first:` line under it. When a handoff's summary reads like a change to
a judgment (a guard, a filter, a skip, a pause) and the verb is not `impact`,
the reply ends with one line of advice. The Event is posted either way.

A reply may identify the Event it answers with MCP field `reply_to` or CLI
option `--reply-to <event-key>`:

```bash
python3 ~/.drsg-memory/tools/event.py post /path/to/reviewer-project \
    "验收通过：已完成检查" --kind notice --reply-to evt-my-project-1791620000-a1b2c3
```

The target must be an Event sent by this recipient to the current project; its
NOTIFY edge must also target the current project. Old Events without a stored
sender path cannot be verified and are rejected with this prompt to resend
without `reply_to`, adding the context in the body:

```text
reply_to 指向的 Event 是旧格式（没有 from_path），无法核对来源；请去掉 reply_to 重发，正文里写明在回复哪一条。
```

Missing or misdirected Events are rejected with a prompt to check the key or
resend without `reply_to`.  The reply association only adds context in wake-up
text and `event_list`; it does not authorize actions or close the original Event. The original Event owner still closes it with
`event_done`. Both projects must deploy the updated `drsg-events` runtime and
restart Claude Code before using `reply_to`; if you deploy manually, run the
setup command from your own shell with the `!` prefix.

```bash
python3 ~/.drsg-memory/tools/event.py post /path/to/other-repo \
    "粘性取号缺代理判断" --symbol getSchedulableAccount --verb context
```

```
posted evt-other-repo-1791400000-1a2b3c to /path/to/other-repo
↳ graph first: context `…getSchedulableAccount` (plane other-repo)
  (resolved against plane other-repo)
advice: this reads like a change to a judgment ('判断') — verb=impact lists every caller by distance; context walks one hop
```

Re-post with `--verb impact` when the change has to reach every path that makes
the same decision.

## To-do poller (`event-poller.py`)

`setup.sh` registers it as four **global** hooks in `~/.claude/settings.json`
(skip with `--no-event-poller`). Every session then checks its project's open
Events every 15 minutes **without a model call**, and wakes the model only when
there is one this session has not been told about yet.

- **How it stays model-free.** `SessionStart`, `Stop` and `StopFailure` (a turn
  that ended in an API error) run it as an
  `asyncRewake` hook: Claude Code keeps it in the background and wakes the model
  only on exit code 2. Idle rounds sleep, ask the daemon over RPC, and print
  nothing. The wake-up text lists the Events and repeats that commit / push / PR
  still wait for the user.
- **One poller per project, held by a lease.** Two sessions in the same
  directory would both act on the same Event. The right to poll is a lease
  naming a session and its Claude Code process (pid + start time), not a lock
  held by the poller: the poller has to exit to wake its model, and a lock that
  died with it would hand the project over exactly when the first session starts
  working. A waiting session takes the lease over within a minute of the holder's
  process disappearing — clean exit (`SessionEnd` releases it) or not. A holder
  that is stopped (`Ctrl+Z`, state `T`) or a zombie counts as gone too: it can no
  longer act on a wake-up.
- **A background session yields to a foreground one.** In a background session
  (`claude --bg`, under `claude bg-pty-host`) `/exit` only detaches; the process
  lives on and so would its lease. Whether a client is attached is not exposed,
  so a foreground session in the same project takes the lease from any
  background holder within a minute — even one you are attached to. Background
  sessions never take it from each other. `claude stop <id>` still releases it
  at once.
- **Re-armed by `Stop`.** After a wake-up the poller is gone; the next `Stop`
  starts it again. A `Stop` while it is running exits at once.
- **Kicked by the sender.** After writing an Event, `event.py post()` (which the
  `drsg-events` MCP tool also goes through) touches `kick` in the recipient's
  state directory, if that directory exists. A waiting poller stats that file
  every second (`EVENT_POLL_KICK_STEP`) and asks the daemon at once when it
  changes, so an idle session sees a new Event within a second or two instead of
  at the next 15-minute check. Same machine only; a missed kick just leaves the
  15-minute interval in charge.
- **Silent on failure.** No `.drsg/env`, daemon down, bad answer: logged and
  retried next round, never a wake-up.
- State and log: `~/.drsg-memory/poller/<project-hash>/` (`lease.json`,
  `<session>.<pid>.seen.json`, `<session>.<pid>.pid`, `poller.log`; `<pid>` is
  the Claude Code process). Tuning for tests: `EVENT_POLL_INTERVAL`,
  `EVENT_POLL_TICK` (seconds); `EVENT_POLL_OWNER_PID` stands in for the Claude
  Code process, in the poller and in the hooks' owner line.
- After a takeover, Events the previous session was woken for but did not close
  are announced again — also to a session that takes the lease back: the poller
  cannot tell "half done" from "done, waiting for the user", so the wake-up text
  asks to check the working tree first.
- **One owner, every session sees.** The lease holder is the project's Event
  owner: it alone is woken to act. Two terminals running `claude --resume` on the
  same session id are two processes, and only one of them holds the lease; when it exits, the
  other one's poller is left running, takes over within a minute and is told
  about every open Event again. Every session still lists the open Events (at
  startup and before a prompt), with one line on top saying which it is:

  ```text
  本会话是这个项目的 Event owner：按 Event 流程处理。
  Event owner 是会话 f8e05069（pid 3651），本会话只读：……不要执行这些 Event；本会话调 event_done 会被拒绝，用户明确要求本会话接手时才带 force。……
  现在没有 Event owner。本会话的待办轮询拿到租约后会唤醒你；在那之前本会话只读，不要执行这些 Event。
  ```

Closing is enforced, not just advised: `event_done` (MCP) and `event.py done`
refuse when the project (`CLAUDE_PROJECT_DIR`, else the current directory) has
a live owner and the caller is a different Claude Code process, and write
nothing. With no live owner, or from a plain shell (no Claude Code above it),
closing works as before. Inside an agent session, closing an event must use the
MCP tool `event_done` (or `event_done force=true` when taking over). Running
`event.py done` via Bash inside sessions is blocked by the PreToolUse hook. Outside
sessions, humans can close an event from a shell:

```bash
python3 ~/.drsg-memory/tools/event.py done <event-key> --force
```

This does not stop a non-owner from editing code; it stops a second session
from finishing the same to-do.

## StopFailure notice (`stop-failure-notify.py`)

A turn that ends in an API error — model unavailable, rate limit, failed auth —
leaves the session idle, and nothing wakes it: Claude Code ignores a
`StopFailure` hook's exit code and output, so the poller cannot restart the
work. `setup.sh` registers this script as a second, ordinary `StopFailure` hook
next to the poller (skip both with `--no-event-poller`). It returns one
`terminalSequence`: the window title becomes `Claude stopped: <project> (<error>)`,
plus a desktop notification (OSC 9 for iTerm2 / Windows Terminal / WezTerm,
OSC 777 for Ghostty / urxvt / Warp) and a bell. Claude Code emits it only in an
interactive session whose interface is on screen.

Try it by hand — the output is the JSON Claude Code would receive:

```bash
echo '{"error":"rate_limit","error_details":"429 Too Many Requests"}' \
  | python3 ~/.drsg-memory/tools/stop-failure-notify.py
```

To keep the hook registered but silent, start Claude Code with the variable set:

```bash
DRSG_STOP_FAILURE_NOTIFY_DISABLED=1 claude
```

## Permission guard (`permission-guard.py`)

Opt-in. Nothing is written until you ask for it, either through `setup.sh`
(`--permission-guard DIR`, `--reviews-dir DIR`, `--prune-broad`) or by running
the tool directly. It has two scopes:

- **Project** (`--project DIR`): writes `DIR/.claude/settings.local.json` only —
  `DIR/.claude/settings.json` may be tracked by git and is never touched.
  It adds `ask` rules for `git commit` / `git push` in every spelling sessions
  use (`git`, `rtk git`, `/usr/bin/git`; bare, with `-C DIR`, with `-c k=v`) and
  for `gh pr create`. An ask rule wins over an allow rule, so a broad
  `Bash(rtk git *)` already in the file can no longer commit or push without
  asking. It also adds narrow `allow` rules for read-only git, `event.py
  list|done` and the modern-go guideline script: auto mode keeps narrow rules
  and settles them without a classifier call. Broad interpreter rules such as
  `Bash(python3 *)` — dropped by auto mode, allow-everything outside it — are
  reported; `--prune-broad` removes them. Nothing else is ever removed.
- **User** (`--user --reviews-dir DIR`): writes the `autoMode` block of
  `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), the only
  place Claude Code reads it from. Three prose rules tell the auto-mode
  classifier that a script under DIR may run once the agent has written an
  exact copy under `/tmp` with a Write call — the classifier sees tool inputs,
  not tool output, so a `cat` does not count — and that receipt files may be
  written there. Each entry starts with `(drsg-harness-kit permission-guard)`;
  hand-written copies of the same rules are replaced, everything else is kept.

```bash
# project scope; re-running adds nothing
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project --prune-broad
python3 ~/.drsg-memory/tools/permission-guard.py check --project /path/to/project   # exit 1 on drift
python3 ~/.drsg-memory/tools/permission-guard.py remove --project /path/to/project

# user scope
python3 ~/.drsg-memory/tools/permission-guard.py apply --user --reviews-dir /path/to/workspace/reviews
python3 ~/.drsg-memory/tools/permission-guard.py check --user --reviews-dir /path/to/workspace/reviews
python3 ~/.drsg-memory/tools/permission-guard.py remove --user

# event.py somewhere else than ~/.drsg-memory/tools
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project --tools-dir /opt/drsg/tools
```

Rules take effect in sessions started afterwards. `claude auto-mode config`
shows the user-scope entries the classifier will read.

The user-scope rules let the classifier treat the other files under DIR as
plain data only. A plan whose script copies a file from DIR into the
repository and then runs it — a new test script, say — is blocked as code
from external. Have the implementer write such files with Write, and let the
plan's script only check them (content with `cmp`, and the executable bit).

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

## Completeness guard (`completeness-guard.py`)

A generic anti-omission and delivery completeness guard for all projects.
It inspects git diffs for newly introduced user-facing names (CLI flags, environment
variables, HTTP routes, config keys) and verifies they exist in documentation.

```bash
python3 completeness-guard.py                         # check working tree
python3 completeness-guard.py --staged                 # check staged changes (used in pre-commit)
python3 completeness-guard.py --repo /path/to/project --base origin/main
python3 completeness-guard.py --json                  # machine-readable output
```

Projects can declare `.completeness.json` (or `.drsg/completeness.json`) to turn
advisory notices into blocking pre-commit errors.

What it reads: names are taken from `.sh`, `.bash`, `.yml`, `.yaml`, `.py`,
`.go` and extension-less scripts, never from test files (`tests/`,
`*_test.go`, `test_*.py`, …); a shell option counts only as a `case` label.
Without a `docs` list it searches `README*`, `*/README*.md` and
`docs/**/*.md`.


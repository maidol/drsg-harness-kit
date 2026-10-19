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

The runtime has seven Python hook templates, an installer, and a daemon control
script. `drsg_hook_common.py` is deployed beside SessionStart, UserPromptSubmit,
SessionEnd and the detached L3 digest hook; `tools/drsg_rpc.py` is the shared
loopback-aware RPC client for six tools. `memory-backup.py` keeps its separate transport. No plugin,
no service to sign up for, no data leaving the machine.

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

The same function can also show an Event-lane menu, served by
`tools/claude-lane-picker.py`, in projects that opt in with `.drsg/lanes`. It
runs only where the model picker is enabled; set `CLAUDE_PICK_MODEL=0` to keep
just the lane menu. See the same root README section.

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
- **The briefing is capped at 2000 characters.** It grows about 21 characters
  per Fact; past the cap the newest Facts are kept and a last line counts the
  rest, e.g. `（另有 37 条较早的 Fact 未列出）`. Set another limit, or `0` for none,
  in the project's `.drsg/env`; the next session start rebuilds the briefing:

  ```bash
  echo 'DRSG_BRIEFING_MAX_CHARS=3000' >> .drsg/env
  ```
- **Compaction keeps required context without repeating low-value sections.**
  SessionStart still runs on `compact` and stamps the existing Session node.
  After compaction it keeps the corrective `COMPACT_CONTEXT`, open Events, and
  write-memory protocol, while omitting `Briefing:` and `Recent sessions:`. On
  startup, resume, and clear, the current briefing and recent-session behavior
  remains unchanged.

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

Back up both databases first — stop the daemon, copy the directory, then start
the daemon again: `dump` and `load` talk to it over RPC.
`migrate.py` warns about and skips nodes with no external key; a `dump`
will tell you whether you have any.

### Loading a migration dump safely

Both `dump` and `load` accept `--limit` (default `100000`) for `graph.seed`.
If the source or target seed is truncated, the command exits `3`; `dump` does
not create or overwrite the output file, and `load` refuses before writing any
nodes. `load` is additive: it skips existing node keys and existing edges with
the same source key, destination key, type and canonical properties. Re-running
the same dump is safe. After a real load, `verify:` reports the imported node
and edge counts and `PASS` / `FAIL`; any write failure or missing item exits `1`.
`load --dry-run` reports planned create/skip counts without writing.

```bash
python3 migrate.py dump --api <source-rpc-url> --token <source-token> \
  --plane memory --limit 100000 --out project-memory.json
python3 migrate.py load --api <target-rpc-url> --token <target-token> \
  --plane memory --limit 100000 --in project-memory.json
python3 migrate.py load --api <target-rpc-url> --token <target-token> \
  --plane memory --limit 100000 --in project-memory.json --dry-run
```

Exit codes: `0` completed (or dry-run); `1` node/edge writes failed or
verification found missing data; `3` a seed was truncated. An empty dump keeps
the existing `nothing to migrate` exit code `1`.

`repair_dupe_key.py` has been removed: drsg 2.17 `digest.write` skips an
existing external key and `node.create` rejects duplicate keys, so this repair
is no longer needed. `setup.sh` does not prune old runtime files; after
upgrading, manually remove `repair_dupe_key.py` from the
`~/.drsg-memory/tools/` directory.

## Repairing a Project key index

Use `repair_project_key.py` only when `WHERE key(p) = …` no longer finds a
Project but `WHERE p.path = …` still does. `DRSG_PROJECT_DIR` selects the
project whose `.drsg/env` supplies `DRSG_API` and `DRSG_TOKEN`; the utility uses
that daemon address. Run the dry run first and review the captured node and
every incident edge. Before applying, stop the daemon, copy the database
directory as a backup, then restart the daemon; the utility needs a live daemon
for the `--apply` RPC calls. It writes a JSON snapshot in the current
directory by default, or to the path passed with `--snapshot`.

```bash
DRSG_PROJECT_DIR=/path/to/project python3 ~/.drsg-memory/tools/repair_project_key.py \
  memory /path/to/project <project-key>
# Stop the daemon, copy its database directory, then restart it before applying.
DRSG_PROJECT_DIR=/path/to/project python3 ~/.drsg-memory/tools/repair_project_key.py \
  memory /path/to/project <project-key> --apply \
  --snapshot /tmp/repair-<project-key>.json
```

Exit codes: `0` dry run or repair verified; `1` post-repair verification failed;
`2` an edge or recreation failed (use the printed snapshot and failed-edge
records); `3` unsafe input, truncated graph data or snapshot failure before any
mutation.

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
2. Copies all seven Python hook templates into `<project>/.claude/hooks/`, including `drsg_hook_common.py`, shared by SessionStart, UserPromptSubmit, SessionEnd, and L3 digest. `setup.sh` separately deploys the global `event-poller.py`.
3. Writes `<project>/.drsg/env` (`chmod 600`) — daemon address, token, and the
   L3 settings, with the key's **name** only.
4. Merges the SessionStart / UserPromptSubmit / SessionEnd entries into
   `<project>/.claude/settings.local.json`, keeping whatever is already there.
5. Registers two MCP servers (project scope): `drsg` against the daemon's
   `/mcp`, and `drsg-events` — a stdio server in this directory exposing
   `event_post` / `event_list` / `event_done` / `event_take`. The second one is separate on
   purpose: `Event` and `NOTIFY` are conventions this layer keeps on top of a
   soft-schema graph, and the engine that does not know what a Fact is has no
   business learning what an Event is.
6. **Self-checks**: daemon reachable, plane present, the project key resolving
   to a `Project` node, and a temporary Fact readable through the hooks' own
   recall query. Any failure exits non-zero and says so, rather than reporting
   a successful install of something that will silently do nothing.

Deployment commands are distinct: `setup.sh` deploys the global `event-poller.py`; `setup.sh --all-projects` copies the hook templates, including `session_start.py`, `session_end.py`, `l3_digest.py`, and their sibling `drsg_hook_common.py`, into registered projects.

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
useful than a second registry that can disagree with the first. The shared
`project_registry.py` reader is used by both `install.sh --check` and
`setup.sh --all-projects`; it uses `DRSG_PLANE` to select the memory plane
(default `memory`), and `--env` selects the daemon environment file instead of
the default. Scripts can request NUL-separated paths with:

```bash
python3 ~/.drsg-memory/tools/project_registry.py --nul
python3 ~/.drsg-memory/tools/project_registry.py --env <daemon-env-file> --nul
```

When a project's installed hooks differ from the runtime templates, SessionStart
shows a one-line human-visible refresh prompt with the shell-quoted install
command. It only reports drift; it does not run the installer. Run the shown
command yourself, adding `--bin <path>` if `drsg` is not on `PATH`.

## Full layered deployment audit (`--audit`)

`--check` only compares hook files against templates. Real deployment drift also occurs in runtime tools, global configuration, project settings, or code graph configurations. The `--audit` flag runs a comprehensive 5-layer audit:

- **L0: Project Discovery** (when running `--all`): Discovers known projects from the memory plane via proxy-safe connection, failing explicitly on discovery errors.
- **L1: Global Runtime Tools**: Compares `~/.drsg-memory/tools/` against the git `HEAD` release baseline and verifies execution permissions; uncommitted drafts are noted as advisory hints without failing audit.
- **L2: Global Configuration & Skills**: Verifies `~/.claude/AGENT-EFFICIENCY.md` and `~/.claude/CROSS-PROJECT-REVIEW.md`, skills, managed main-branch workflow state (enabled, intentional opt-out, or drift), global hooks, and `settings.json` permissions (`0600`).
- **L3: Project Memory Hooks**: Compares `.claude/hooks/*.py` in each project against canonical templates.
- **L4: Project Settings & Docs**: Checks `.claude/settings.local.json` registrations, `.drsg/env` credentials, `CLAUDE.md` cross-agent Event documentation, and that the `drsg` and `drsg-events` MCP servers are registered for the project in `~/.claude.json` (local or user scope; `$CLAUDE_CONFIG_DIR/.claude.json` when that is set, or the `--claude-dir` directory). A missing one is reported together with the command that registers it. It also reports the project's pre-commit hook (completeness-guard active, a custom hook, or none), looked up where git looks for hooks, so a `core.hooksPath` directory counts; this line is informational and never fails the layer.
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

For the execution-side review/acceptance stages and the one-time commit authorization boundary, see the [globally distributed workflow](../claude/CROSS-PROJECT-REVIEW.md) (installed as `~/.claude/CROSS-PROJECT-REVIEW.md`, read on demand); this README covers Event mechanics only.

`event.py post` and the `event_post` MCP tool share one implementation. Project paths passed to `event_post`, `event_list` and the CLI may use symlink aliases; they are resolved to their real paths. The MCP tool refuses the session's own project as recipient: an Event is for another agent, so write a Fact to remember something here, or tell the user directly. Give a
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

A follow-up can replace an earlier to-do the sender itself posted: pass MCP
field `supersedes` or CLI option `--supersedes <event-key>`. The new Event is
posted first; only then is the old one set to `done` with
`superseded_by=<new key>`, and the reply ends with `superseded <old key>: done`.
Typical use is a "continue now" message after the recipient got stuck, which
otherwise leaves two open to-dos for the same work:

```text
event_post recipient=/path/to/other-repo summary="现在继续：…" kind=handoff
           reply_to=<their blocked notice> supersedes=<your first dispatch>
```

```bash
python3 ~/.drsg-memory/tools/event.py post /path/to/other-repo \
    "现在继续：按新计划做" --supersedes evt-other-repo-1791620000-a1b2c3
```

Only an Event that is still `open`, was sent by this project (its stored
`from_path` is this project) and is addressed to the same recipient can be
superseded; anything else, including old Events without `from_path`, is
refused before anything is written. The recipient's owner lease is not
consulted, because the sender is withdrawing its own to-do rather than handling
it. If closing the old Event fails, the new one stays posted and the error
names both keys, so the recipient can close the old one by hand. `event_list`
shows `↳ 取代 <old key>` under the new Event.

These invariants prevent silent failures: Event recipients are matched through
`Project.path` rather than a potentially shadowed key; the Event node and its
`NOTIFY` edge are written together; and close operations use `key(e)` because
`e.key` can match nothing without an error. Timestamps are integer Unix seconds;
an ISO string can compare false silently. Events are separate from Facts because
recall is ranked and lossy, while a to-do must arrive intact. Use the MCP tools
rather than hand-written Cypher so the Event and its `NOTIFY` edge are created
together. Put code-graph `symbols` and `verb` in their fields: `summary` is
truncated to 80 characters, so a key there can lose the tail that identifies it.
Receiving needs no tool call, and agent sessions must not run `event.py` through
Bash; the hook and poller deliver the Event through their supported paths.

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

## MCP Event listing (`event_list`)

`event_list` accepts an optional integer `limit` from 1 to 200. For `status="all"`, the default is 20 newest Events. It first runs a bounded count query with the same recipient filter, then fetches at most `limit` rows. When the count is available and more rows exist, it appends `另有 N 条未列出，传 limit 看更多`. If the count query fails or returns a non-integer, it fetches `limit+1` rows and, when truncated, appends `还有更多未列出，传 limit 看更多` without a number. The count uses the daemon's supported `count(*)` projection.

`limit` applies only to MCP `status="all"`. `open` and `done` keep their existing status-filtered `STATUS_CAP` and filter-before-LIMIT behavior, regardless of `limit`. The `event.py list` CLI remains unchanged.

### Commit authorization tools (`commit_auth_post` / `commit_auth_apply`)

The candidate `commit_auth_post` MCP tool takes `recipient`, 40-character
`tree` and `parent`, explicit `target_branch`, exact `files`, `force_paths`
(always present; `[]` when empty), and verbatim `message`. The target branch may
be any valid name, but its ref must point at the authorized parent. It recomputes
the tree from the parent with a temporary index; those temporary-index Git
commands disable hooks with `-c core.hooksPath=/dev/null` to avoid executing
recipient hooks during review. `git add` still writes blob objects to the
recipient repository, so auto mode may classify this as a cross-project write. Only paths
listed in `force_paths` use `git add -f`; it must be a subset of `files`.

Authorization fields are stored as structured Event properties. The tool and
the Event do not authenticate the user: the sole authority remains the
user-global `CLAUDE.md` exception. The `commit_auth_apply` tool accepts only
`{"event_key":"<key>"}`; it reads the Event itself, verifies the open
handoff, matching tree prefix, and `NOTIFY` recipient path, then checks the
parent and authorization tree. A temporary-index preflight must match before it
touches the executor's formal index; the formal index must initially match the
parent. Before formal staging, it inspects only Git's effective hooks directory
(`core.hooksPath`, otherwise `git rev-parse --git-path hooks`), follows symlinks,
and hashes the active commit hooks. Only the pinned kit pre-commit hooks are
accepted; all other executable commit hooks are refused with their names and
resolved paths. Normal `git commit` runs accepted hooks; `--no-verify` and
plumbing commands are never used. A hook failure stops without retry and
surfaces its output (recognizable secret values are redacted). After commit, the
tool verifies `HEAD^`, `HEAD^{tree}`, and the exact commit message. If a hook or
race made them differ, the commit remains local and the tool reports the
mismatch; it never automatically resets or amends. When the commit does not
happen (a hook refused it, say), the tool puts the formal index back to the
authorized parent tree, so the files are no longer staged and the next
`commit_auth_apply` starts clean; the error ends with
`formal index restored to authorized parent tree`. If HEAD moved, it touches
nothing and says so; if restoring fails, the error tells you to run
`git reset --mixed HEAD`. On success its last line,
`receipt: post kind="notice" to <reviewer> with reply_to=<event-key>`, names
where the commit receipt goes, so the executor never reads `commit-auth.json`. It never pushes, creates a
PR/tag/release, or closes the Event; after successful verification, the
executor's Event owner closes it with `event_done`.

If auto mode blocks either authorization action, stop. Do not switch to Bash or
another MCP tool to retry the same tree; the reverse switch is also prohibited.
Both tools are off until you name the reviewer project yourself in
`~/.drsg-memory/commit-auth.json`; setup never writes that file. With it,
`commit_auth_post` runs only in that project, and `commit_auth_apply` accepts
only Events whose `from_path` is that project. This stops a mistaken
authorization coming from any other session; it is not authentication against a
hostile local process.

Turn the tools on (replace the path with your reviewer project):

```bash
! printf '{"reviewer": "%s"}\n' /path/to/reviewer-project > ~/.drsg-memory/commit-auth.json
```

To let an authorized commit go through without a permission prompt, allow only
the apply tool in `~/.claude/settings.json`. Bash `git commit` keeps its `ask`
rule and still prompts:

```bash
! python3 -c 'import json,pathlib; p=pathlib.Path.home()/".claude/settings.json"; d=json.loads(p.read_text()); a=d.setdefault("permissions",{}).setdefault("allow",[]); assert isinstance(a,list), "permissions.allow is not a list; edit manually"; t="mcp__drsg-events__commit_auth_apply"; a.append(t) if t not in a else None; p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+"\n")'
```

Paste it as one line. If your terminal breaks it across lines, Python stops with
`IndentationError`; save the `python3 -c` argument to a file and run that file
instead.

Turn them off by deleting `~/.drsg-memory/commit-auth.json` and removing
`mcp__drsg-events__commit_auth_apply` from `permissions.allow`.

## To-do poller (`event-poller.py`)

`setup.sh` registers it as four **global** hooks in `~/.claude/settings.json`
(skip with `--no-event-poller`). Every session then checks its project's open
Events every 15 minutes **without a model call**, and wakes the model only when
there is one this session has not been told about yet.

- **How it stays model-free.** `SessionStart`, `Stop` and `StopFailure` (a turn
  that ended in an API error) run it as an
  `asyncRewake` hook: Claude Code keeps it in the background and wakes the model
  only on exit code 2. Idle rounds sleep, ask the daemon over RPC, and print
  nothing. The fixed wake guidance is one line (under 80 characters):
  `按 Event 流程处理：handoff 直接开工；判定只 event_done；commit/push/PR 等先等用户确认。`
  It preserves the handoff, verdict, and user-confirmation rules; Event fields,
  owner/lease notices, graph hints, and re-nudge content are rendered separately.
- **One poller per project, held by a lease.** Two sessions in the same
  directory would both act on the same Event. The right to poll is a lease
  naming a session and its Claude Code process (pid + start time), not a lock
  held by the poller: the poller has to exit to wake its model, and a lock that
  died with it would hand the project over exactly when the first session starts
  working. A waiting session takes the lease over within a minute of the holder's
  process disappearing — clean exit (`SessionEnd` releases it) or not. A holder
  that is stopped (`Ctrl+Z`, state `T`) or a zombie counts as gone too: it can no
  longer act on a wake-up. A holder whose process lives but whose poller died
  (killed, crashed: its `<session>.<pid>.pid` still names a process that is
  gone) is taken over once the lease has gone unrefreshed for
  `EVENT_POLL_LEASE_STALE` seconds (default five `EVENT_POLL_TICK`s, 300). A
  poller that exited to wake its model removed that file first, so a session
  busy with a woken turn keeps the lease however long the turn runs. A holder
  that is merely idle with a live poller is never taken over automatically; use
  `event_take` or `--take` for that.
- **A background session yields to a foreground one.** In a background session
  (`claude --bg`, under `claude bg-pty-host`) `/exit` only detaches; the process
  lives on and so would its lease. Whether a client is attached is not exposed,
  so a foreground session in the same project takes the lease from any
  background holder within a minute — even one you are attached to. Background
  sessions never take it from each other. `claude stop <id>` still releases it
  at once.
- **Re-armed by `Stop`.** After a wake-up the poller is gone; the next `Stop`
  starts it again. A `Stop` while it is running exits at once.
- **One re-nudge for a still-open handoff.** After its first wake, a handoff that
  remains open is announced once more after `EVENT_POLL_RENUDGE` seconds (default
  `1800`). Set `EVENT_POLL_RENUDGE=600` in the poller's environment for ten
  minutes. The separate wake says how long it has waited and asks to continue
  existing work or send the sender a notice explaining what is awaited. This is
  one retry for the same Event, not a new Event or a lease change; notices are
  never re-nudged.
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
  `lease.<lane>.json` and `claims.json` when lanes are used,
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
  现在没有 Event owner（只是当前快照）。轮询器通常会在几秒内取得租约并稍后唤醒本会话；收到那次唤醒后，以它为准。在那之前本会话只读，不要执行这些 Event。
  ```

  When the owner's transcript (`~/.claude/projects/<project>/<session>.jsonl`)
  has not changed for an hour or more, the line says so — `Event owner 是会话
  f8e05069（pid 3651，已空闲 5 小时）…`, and for a lane `any-auto-register（会话
  f8e05069，已空闲 5 小时）`. A terminal lost with a closed VS Code window keeps its
  process, and so the lease, alive: find it with `Terminal: Attach to Session`
  and `/exit` there, or end that pid, and this session's poller takes over.

- **Lanes: one owner per sender.** A project that many projects send to (a
  reviewer) can run one session per sender. Start a session with
  `DRSG_EVENT_LANES` set to sender names — the sender's directory name, as
  `from_project` shows it in `event_list` — and it is woken only for Events from
  those senders, and closes only those. A session without the variable is the
  default lane and gets every other sender:

  ```bash
  DRSG_EVENT_LANES=any-auto-register claude
  DRSG_EVENT_LANES=drsg-harness-kit,sub2api claude
  claude
  ```

  Each lane has its own lease (`lease.<lane>.json`, same rules as `lease.json`).
  A sender whose lane has no live owner falls back to the default lane, so when
  a lane session exits its Events are taken over and announced again. An Event
  stays with the lane first woken for it (`claims.json`) while that lane has a
  live owner: a lane session started later does not get an Event the default
  session is already working on, only the sender's new ones. Nobody declaring a
  lane means only `lease.json` exists and nothing changes. With lanes, the
  owner line reads, for example:

  ```text
  本会话是车道 any-auto-register 的 Event owner：只执行待办轮询唤醒你处理的 Event；列表里其他 Event 只读，不要执行，也不要 event_done。
  本会话是这个项目的 Event owner：按 Event 流程处理。车道 any-auto-register 的 Event 归各自的车道会话，本会话对它们只读：不要执行，也不要 event_done。
  本会话声明的车道 any-auto-register（会话 f8e05069）由别的会话持有，本会话只读：不要执行这些 Event。owner 退出后，本会话的待办轮询会接管并唤醒你。
  本会话声明的车道 sub2api 现在没有 Event owner（只是当前快照）。轮询器通常会在几秒内取得租约并稍后唤醒本会话；收到那次唤醒后，以它为准。在那之前本会话只读，不要执行这些 Event。
  ```

  When no session holds the default lane (`lease.json`), a lane session's line
  ends with one more sentence: `默认车道现在没有 Event owner：没有车道的发件项目发来的 Event 不会唤醒任何会话；要有人处理，开一个不声明车道的会话。`
  With only lane sessions running, Events from every other sender wake nobody,
  and this is the only place that says so.

  A lane name is letters, digits, `.`, `_` and `-`; other names are ignored. A
  misspelt name is not reported: that lane never gets an Event and its sender's
  Events go to the default lane, so copy the name from `from_project`. To move
  one lane's lease to your session by hand (user only; the PreToolUse hook
  blocks the agent from running it):

  ```bash
  python3 ~/.drsg-memory/tools/event-poller.py --take --lane any-auto-register
  ```

  Inside a session, ask the agent instead — "take the any-auto-register lane"
  — and it calls the MCP tool `event_take` (`lane` optional when the session
  declared one lane, or none for the default lane). It takes only a lane this
  session was started for; any other lane, or the default lane from a lane
  session, is refused and nothing is written. The previous owner turns
  read-only, and Events it was already woken for may be handled twice.

Closing is enforced, not just advised: `event_done` (MCP) and `event.py done`
refuse when the project (`CLAUDE_PROJECT_DIR`, else the current directory) has
a live owner and the caller is a different Claude Code process, and write
nothing. With no live owner, or from a plain shell (no Claude Code above it),
closing works as before. With lanes, the owner checked is the owner of the
Event's lane, and the refusal names it (`Event owner of <project> lane <lane>`).
Inside an agent session, closing an event must use the
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

## Textual tool call stop guard (`textual-tool-call-guard.py`)

`setup.sh` registers this script as a global `Stop` hook in `~/.claude/settings.json` (skip with `--no-textual-tool-call-guard`). When a model outputs tool calls purely as textual markup (e.g. `<mcp__tool_name>{"arg": "value"}</mcp__tool_name>` or `<Bash>{"command": "..."}</Bash>`) without structured `tool_use` blocks, Claude Code treats it as a completed turn. This hook blocks completion via `{"decision": "block", "reason": "..."}` and prompts the model to reissue the call as a real tool call.

- Re-running `setup.sh` is required to register the hook on previously deployed machines.
- Multi-call outputs or regular prose mentioning tags are allowed without blocking.
- To disable at runtime:

```bash
DRSG_STOP_TEXTUAL_TOOL_CALL_GUARD_DISABLED=1 claude
```

## Sensitive file read guard (`sensitive-file-read-guard.py`)

`setup.sh` registers this script as a global `PreToolUse` hook with matcher `Bash|Read|Grep` (skip with `--no-sensitive-read-guard`). It denies whole-file reads of files that may hold credentials (`.mcp.json`, `~/.claude.json`, `.claude/settings*.json`, env files, `.netrc`, private keys) and allows structure-only reads such as `jq '.mcpServers | keys' .mcp.json`, `jq -r '.hooks[][] | .hooks[].command' ~/.claude/settings.json` and `grep -c KEY config.env`. Any parse error lets the call through. Full rules are in the top-level README.

```bash
DRSG_SENSITIVE_READ_GUARD_DISABLED=1 claude
```

## Single-tool reminder (`single-tool-streak.py`)

`setup.sh` also registers this script as a global `PostToolUse` hook in
`~/.claude/settings.json` (skip with `--no-streak-hint`). After each tool call
it reads the tail of the session transcript; when the last three model replies
each made exactly one call and that call was `Read`, `Edit` or `Write`, it adds
one line to the model's context:

```text
最近几轮都只发了一个调用。下一步如果有几处互不依赖的修改或读取，在同一轮里一起发；改完跑测试的那一步照旧单独发。
```

After a later successful tool call, the same hook can also diagnose a failed
`Edit` whose error is `String to replace not found`: if removing one leading tab
from each tab-prefixed line in `old_string` makes it match the current file
exactly once, it adds a hint like this (without quoting the anchor or file
contents):

```text
Edit anchor may have one extra leading tab in path/to/file: Read's line-number separator tab is not indentation; remove one leading tab per line and retry.
```

A later successful `Edit` or `Write` to that file, a different error, zero or
multiple matches, or an unreadable/missing file suppresses this diagnostic. Both
reminders fail open and never block a tool call. To keep the hook registered but
silent, disable both reminders by exporting this variable before starting Claude
Code:

```bash
export DRSG_SINGLE_TOOL_STREAK_DISABLED=1
claude
```

## Permission guard (`permission-guard.py`)

Opt-in. Nothing is written until you ask for it, either through `setup.sh`
(`--permission-guard DIR`, `--reviews-dir DIR`, `--prune-broad`, `--self-commit`) or by running
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
  reported; `--prune-broad` removes them. With `--self-commit` the `git commit`
  ask rules are left out and any this tool wrote before are removed (rules you
  wrote yourself are kept); `git push` and `gh pr create` still ask, and
  `check --self-commit` reports a leftover commit ask rule as drift. Nothing
  else is ever removed.
- **User** (`--user --reviews-dir DIR`): writes the `autoMode` block of
  `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`), the only
  place Claude Code reads it from. Three prose rules tell the auto-mode
  classifier that a script under DIR may run once the agent has written an
  exact copy under `/tmp` with a Write call — the classifier sees tool inputs,
  not tool output, so a `cat` does not count — and that receipt files may be
  written there. Each entry starts with `(drsg-harness-kit permission-guard)`;
  hand-written copies of the same rules are replaced, everything else is kept.
  `--self-commit` adds a fourth rule: a local `git commit` of the files the
  session changed, on the checked-out branch, without amending pushed history
  or `--no-verify`, is allowed without asking; push, tags, releases and PRs are
  never covered. Re-running `apply --user` without the flag removes it.

```bash
# project scope; re-running adds nothing
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project --prune-broad
python3 ~/.drsg-memory/tools/permission-guard.py check --project /path/to/project   # exit 1 on drift
python3 ~/.drsg-memory/tools/permission-guard.py remove --project /path/to/project
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project --self-commit
python3 ~/.drsg-memory/tools/permission-guard.py check --project /path/to/project --self-commit

# user scope
python3 ~/.drsg-memory/tools/permission-guard.py apply --user --reviews-dir /path/to/workspace/reviews
python3 ~/.drsg-memory/tools/permission-guard.py check --user --reviews-dir /path/to/workspace/reviews
python3 ~/.drsg-memory/tools/permission-guard.py remove --user
python3 ~/.drsg-memory/tools/permission-guard.py apply --user --reviews-dir /path/to/workspace/reviews --self-commit

# event.py somewhere else than ~/.drsg-memory/tools
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project --tools-dir /opt/drsg/tools
```

Use `--self-commit` only when your global `CLAUDE.md` lets changes that no
review covers be committed without asking; the rules only stop the prompt,
the model still follows your instructions. To switch every installed project,
run the project-scope `apply --self-commit` once per project directory.

Rules take effect in sessions started afterwards. `claude auto-mode config`
shows the user-scope entries the classifier will read.

The user-scope rules let the classifier treat the other files under DIR as
plain data only. A plan whose script copies a file from DIR into the
repository and then runs it — a new test script, say — is blocked as code
from external. Have the implementer write such files with Write, and let the
plan's script only check them (content with `cmp`, and the executable bit).

## Shared memory backups

Online backups export every plane while the DrSG daemon keeps running. The tool reads `DRSG_TOKEN` and `DRSG_API` from `~/.drsg-memory/env`; credentials are not command-line arguments.

```bash
python3 ~/.drsg-memory/tools/memory-backup.py backup --keep 7
python3 ~/.drsg-memory/tools/memory-backup.py drill
```

Backups live under `~/.drsg-memory/backups`. `--keep N` configures retention; the default is 7. A drill restores the newest backup to a disposable database, verifies it and removes the temporary database. It does not open the production library.

### SessionStart health warnings

SessionStart shows a terminal warning if the configured memory daemon is unreachable. This session then has no briefing, Events, or recall, and its Event list is not trustworthy until the daemon is restored. The default terminal message is:

```text
⚠ DrSG memory daemon is unreachable. This session has no briefing, Events, or recall. Restore it with: ~/.drsg-memory/tools/serve.sh start
```

Start it with:

```bash
~/.drsg-memory/tools/serve.sh start
```

The warning appears on startup, resume, and compact. If `DRSG_MEM_DIR` is set, the command uses that directory instead of `~/.drsg-memory`.

On a new startup only, when the daemon is reachable through a loopback `DRSG_API`, the hook checks the local backup directory and warns if no valid backup exists or the newest valid backup is older than the configured age. Example terminal messages:

```text
⚠ DrSG memory backup: no valid backup found. Run: python3 ~/.drsg-memory/tools/memory-backup.py backup; then python3 ~/.drsg-memory/tools/memory-backup.py drill
⚠ DrSG memory backup: latest valid backup is 10 days ago. Run: python3 ~/.drsg-memory/tools/memory-backup.py backup; then python3 ~/.drsg-memory/tools/memory-backup.py drill
```

Resolve either backup warning by running both commands manually:

```bash
python3 ~/.drsg-memory/tools/memory-backup.py backup
python3 ~/.drsg-memory/tools/memory-backup.py drill
```

`DRSG_BACKUP_MAX_AGE_DAYS` sets the age threshold in days (default `7`); set it to `0` to disable the backup check. An invalid value falls back to `7`. Set the variable in the environment inherited by Claude Code, for example `export DRSG_BACKUP_MAX_AGE_DAYS=14`. If `DRSG_MEM_DIR` is set, substitute `$DRSG_MEM_DIR/tools/...` for the default `~/.drsg-memory/tools/...` paths. The hook only checks and warns; it never starts the daemon or runs backup/drill for you.

To restore, stop the daemon first; this disconnects all active MCP sessions. Move the old `memory.drsg` directory and any `memory.drsg.bm25` / `memory.drsg.hnsw` sidecars aside. Restore refuses to overwrite an existing target, and refuses with `daemon still running` while anything still answers at `DRSG_API` — a daemon left running keeps writing to the directory you moved, and those writes would be lost:

```bash
python3 ~/.drsg-memory/tools/memory-backup.py restore --latest
~/.drsg-memory/tools/serve.sh start
```

Use the `--from` option in this code example to select an older backup:

```bash
python3 ~/.drsg-memory/tools/memory-backup.py restore --from /path/to/backup-directory
``` Restore rechecks the manifest and file hashes, remaps node IDs while preserving edge endpoints, and verifies plane counts, properties and index declarations before publishing. BM25/HNSW sidecars are rebuildable caches; the data and index declarations are restored and the caches are recreated when DrSG opens the library.

`setup.sh` does not install any scheduled task. Before upgrading DrSG or performing a large migration, manually run `backup` and then `drill`.

Cold backup is separate from online backup. It stops the daemon and disconnects every session:

```bash
DB="$HOME/.drsg-memory/memory.drsg"
SNAPSHOT="$HOME/.drsg-memory/cold-$(date -u +%Y%m%dT%H%M%SZ).drsgsnap"
"$HOME/.drsg-memory/tools/serve.sh" stop
"$HOME/.drsg-memory/bin/drsg" --db "$DB" snapshot "$SNAPSHOT"
"$HOME/.drsg-memory/tools/serve.sh" start
```

Backups live on the same disk as the library: they protect against logical damage, not against losing that disk. Copy the newest backup to another disk from time to time:

```bash
cp -a "$(ls -d ~/.drsg-memory/backups/backup-* | tail -1)" /path/on/another/disk/
```

## Operations checklist

What keeps a single-machine install healthy:

| When | Command | Healthy result |
|---|---|---|
| Daily, and before an upgrade or a large migration | `python3 ~/.drsg-memory/tools/memory-backup.py backup --keep 7` | `backup created` |
| Weekly | `python3 ~/.drsg-memory/tools/memory-backup.py drill` | `drill passed` |
| Weekly | copy the newest backup to another disk (command above) | the copy exists |
| After every kit upgrade | `python3 ~/.drsg-memory/tools/audit_deployment.py --all` | `Audit Result: PASSED` |
| A session warns the daemon is unreachable | `~/.drsg-memory/tools/serve.sh status`, then `~/.drsg-memory/tools/serve.sh start` | `running (pid …)` |

Upgrade: run `backup` and `drill`, then the new bundle's `setup.sh` and `setup.sh --all-projects --bin <path to drsg>`, restart the Claude Code sessions, and run the audit. Roll back the same way from the previous release's bundle; restore a backup only when the library itself is damaged.

Daemon warnings that are not routine — the idempotent creates (`already exists`, `conflict: external key`) are filtered out:

```bash
grep WARN ~/.drsg-memory/logs/drsg.log.$(date -u +%F) \
  | grep -v -e 'already exists' -e 'conflict: external key'
```

An `unauthorized` line means some client sent a token the daemon does not accept: compare the projects' `.drsg/env` with `~/.drsg-memory/env`, and look for a test or script that talks to the default address.

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

## Affected tests (`affected-tests.py`)

Selects the tests a working-tree change can reach, so a regression run does not
have to be the whole suite. It reads `git diff <base>` plus untracked files and
prints the commands to run:

```bash
python3 ~/.drsg-memory/tools/affected-tests.py                     # working tree vs HEAD
python3 ~/.drsg-memory/tools/affected-tests.py --base <tree-or-commit> --run
python3 ~/.drsg-memory/tools/affected-tests.py --repo /path/to/project --json
python3 ~/.drsg-memory/tools/affected-tests.py --config /tmp/at.json --graph-repo my-repo
```

How it selects:

- **Go**: package level, from `go list -test`. Every test binary whose
  dependencies include a changed package runs. A non-Go file inside a package
  (testdata, `//go:embed`) counts as a change to that package. A file the build
  tags exclude is listed as ignored.
- **Rust**: crate level, from `cargo metadata --no-deps --offline`. A changed
  file selects its owning crate and every crate that path-depends on it,
  including dependencies across workspaces; Cargo lockfiles and workspace-root
  manifests select their workspace members.
- **Python**: test functions that reach a changed function or class through
  recorded `CALLS` edges in the repository's code graph (up to 6 hops), plus
  every test file whose text names a changed symbol or module. A change outside
  any function (a constant, an import) counts as a change to every function in
  that module. The graph is asked through `codegraph-router.py`, so the
  repository must be registered with `codegraph.sh install`; a
  worktree passes `--graph-repo <main checkout name>`.
- **Shell** (only when configured): test scripts whose text names a changed
  file, after adding the Python modules that import a changed module.

It answers `mode: full` with the reasons, and exits 3, instead of a smaller
selection whenever it cannot reason about the change: a dependency manifest or
`conftest.py` changed, a file no rule covers, a graph that cannot be reached, a
symbol that exists at the base but not in the graph (a stale graph), a file the
graph has no definitions for, or a code change that reaches no test at all. With
`--run` it runs the configured `full` command in that case. Without `--run` the
exit code is 0 for a selection, 3 for full and 2 for a usage or git error; with
`--run` it is 1 when a command fails.

Output, one line per item: `mode:` (`selected`, `full` or `none`), `full:`
reasons, `ignored:` paths, `run:` commands, and `why:` lines naming what
selected each test. Paste all of it into an acceptance request; the reviewer
checks the selection against the `why:` lines.

Per-repository settings live in `.drsg/affected-tests.json` (all keys optional;
`--config` points elsewhere):

```json
{"full": "bash tests/test-all.sh",
 "always": ["make lint"],
 "full_triggers": ["tests/lib/*"],
 "ignore": ["frontend/*", "deploy/*"],
 "go": {"tags": "unit"},
 "rust": {"args": "--all-features", "exclude": ["plugins/*/component"]},
 "python": {"runner": ".venv/bin/python -m pytest"},
 "shell": {"tests": "tests/*.sh", "exclude": ["tests/test-all.sh"], "runner": "bash"}}
```

`rust.args` appends Cargo options before the selected `-p` packages; `rust.exclude`
contains glob patterns matching crate directories relative to the repository.
`always` commands run before every selection, `full_triggers` adds paths that
force the full suite, and `ignore` drops paths whose tests are outside this tool
(they are still printed as `ignored:`). When a first run reports many
`full: no rule covers …` lines for files no unit test reads (deployment files,
CI config), add them to `ignore`.

The graph is a lower bound: calls it could not resolve are not edges. The text
match covers most of that gap, and the full suite still runs before a release
(`release.sh check`). `DRSG_AFFECTED_ROUTER` points the tool at another router
module; the contract tests use it for a stub graph.

## Forbidden literals guard (`forbidden-literals-guard.py`)

Checks staged changes, commit messages, or git history for forbidden sensitive identifiers.
Does not echo matching literals in output (reports `file:line matches #index` only).
Binary files are skipped.

```bash
python3 forbidden-literals-guard.py --staged
python3 forbidden-literals-guard.py --commit-msg /path/to/COMMIT_EDITMSG
python3 forbidden-literals-guard.py --history
python3 forbidden-literals-guard.py --repo /path/to/project --list /path/to/list
```

- Target list defaults to `<project>/.drsg/forbidden-literals`.
- List file must be git-ignored and never tracked (exits 3 on violation).
- Exit codes: 0 clean or disabled, 1 forbidden literal found, 3 configuration error.
  An invalid or empty `re:` rule is a configuration error: nothing is checked, and
  the error names the list line instead of blaming the lines being committed:

  ```text
  ERROR: forbidden-literals list /path/to/project/.drsg/forbidden-literals has 1 invalid rule(s); nothing was checked. Fix the list:
    line 3: empty regex (it would match every line)
  ```
- Project opt-out: `git config --local drsg.forbiddenLiterals false`.


# drsg-harness-kit

[中文版](README.zh-CN.md)

The agent side of DrSG, as one repository: a shared long-term memory layer for
Claude Code (hooks + a daemon + cross-project to-dos), a per-repository code
graph with a router that puts several graphs behind one MCP surface, and the
scripts that install both on a machine that has neither.

**Linux only.** The daemon controllers identify a running daemon by the process
holding the database LOCK, found through `/proc/<pid>/fd`; there is no
equivalent elsewhere, so `install-drsg.sh` refuses any other platform rather
than installing a binary that would fail later. `setup.sh` writes into `$HOME` —
read it before running it.

## Layout

| Path | What it is |
|---|---|
| `tools/` | everything that RUNS. This directory is what lands in `~/.drsg-memory/tools/`. |
| `tools/templates/hooks/` | the four Claude Code hooks, copied into each project by `tools/install.sh` |
| `skills/codegraph/` | operating the code graph — installed under `~/.claude/skills/` |
| `skills/agent-efficiency-retro/` | retrospective on why a session was slow: tool-call counts, calls per turn, latency vs context size — installed under `~/.claude/skills/` |
| `skills/diagram-conventions/` | choosing architecture / workflow / sequence diagrams by the connective in the sentence — installed under `~/.claude/skills/`. The third-party `archify` skill is not ours to ship, so its pointer to this one is a hand-added `<!-- local: diagram-conventions -->` block at the end of its SKILL.md; re-add it after reinstalling archify |
| `claude/AGENT-EFFICIENCY.md` | agent efficiency rules, copied to `~/.claude/` and `@`-imported by the global CLAUDE.md (setup step 2) |
| `docs/{en,zh}/src/` | the guide, with five diagrams |
| `setup.sh` | install on a fresh machine — runs from an unpacked bundle |
| `pack.sh` | build that bundle |
| `install-drsg.sh` | download a `drsg` binary when the machine has none |
| `tools/codegraph-router-setup.sh` | opt-in router MCP setup for hub projects |
| `tools/codegraph-usage-setup.sh` | opt-in native/routed usage-report Stop hook |

## Install

On a machine that has none of this:

```bash
./pack.sh                                   # writes dist/drsg-harness-kit-<ver>.tar.gz
tar xzf dist/drsg-harness-kit-*.tar.gz -C /tmp
/tmp/drsg-harness-kit-*/setup.sh --project /path/to/project --repo /path/to/repo
```

Re-running setup for an installed project reuses its `.drsg/env` credential
inside the installer: it is not printed or passed as a command-line argument.
The `drsg-events` MCP entry is refreshed; an existing `drsg` entry is preserved.
If `drsg` is missing, setup warns and `install.sh --audit` reports the drift;
register it manually through a secret-safe workflow. A new project joining a
running daemon still needs its token via `--token <t>`; the installer never
mints a replacement, because that invalidates every client config already
written.

`--project` also installs a git pre-commit hook in that project that runs
`completeness-guard.py --staged`. A new CLI option, environment variable,
route or config key that no doc mentions is printed as a notice; it blocks
the commit only when the project declares `.completeness.json`. A project
that already has its own pre-commit hook, or sets `core.hooksPath`, is left
alone, and the installer prints the line to chain by hand. Usage and the
declaration file: [tools/README.md](tools/README.md#completeness-guard-completeness-guardpy).


## Permission guard (opt-in)

Not installed unless asked for. `--permission-guard DIR` adds ask rules for
`git commit` / `git push` / `gh pr create` and narrow read-only allow rules to
`DIR/.claude/settings.local.json`; `--reviews-dir DIR` teaches the auto-mode
classifier, in `~/.claude/settings.json`, that scripts under DIR may run once
shown in a Write call; `--prune-broad` also removes `Bash(python3 *)`-style
rules from the project file. Neither needs `--project`, the drsg binary or a
running daemon. Details: [tools/README.md](tools/README.md#permission-guard-permission-guardpy).

```bash
/tmp/drsg-harness-kit-*/setup.sh --permission-guard /path/to/project
/tmp/drsg-harness-kit-*/setup.sh --permission-guard /path/to/project --prune-broad \
  --reviews-dir /path/to/workspace/reviews
```

## Model picker at startup (opt-in)

The picker runtime is deployed with the tools, but a fresh install leaves it
disabled. Pass `--model-picker` to `setup.sh` to enable it by adding one line to
`~/.bashrc`, which sources `~/.drsg-memory/tools/claude-model-picker.sh`. In a
new shell, an interactive
`claude` then asks which model to use before the session starts, and runs the
real binary with `--model <choice>` in front of your own arguments (`--resume`,
`-c`, a prompt, …). Unless `CLAUDE_PICK_MODELS` supplies a non-empty list, the
picker helper `tools/claude-model-discovery.py` reads Claude Code's gateway
model cache when gateway discovery is enabled and its `baseUrl` matches the
configured gateway. It never writes or refreshes that cache. On a cache miss it
fetches live models with a 2-second hard deadline. A cached model's safe display
name is shown, and its `[1m]` ID is passed unchanged; live models receive `[1m]`
only when `max_input_tokens` is at least 1,000,000. The picker does not guess
context sizes from names or defaults. If discovery fails, it uses the static
menu `opus sonnet haiku fable`. Answer with a number, or type any model name or
full id; Enter alone keeps the `model` from settings.json; Ctrl+C starts nothing.

Discovery resolves `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`, and
`ANTHROPIC_AUTH_TOKEN` from the process environment, then merges `env` values
from `~/.claude/settings.json`, the current directory's `.claude/settings.json`,
and the current directory's `.claude/settings.local.json` in that order (later
values win). Start `claude` from the project directory for project settings to
be found; the picker does not search parent directories. `apiKeyHelper` and
Claude Code OAuth credentials are not supported for discovery; the static menu
is used instead. `ANTHROPIC_API_KEY` is sent as `x-api-key`; otherwise a
non-empty `ANTHROPIC_AUTH_TOKEN` is sent as a Bearer token.

```bash
/tmp/drsg-harness-kit-*/setup.sh --model-picker  # explicitly enable during install/update
~/.drsg-memory/tools/claude-model-picker-config.sh enable  # enable independently
~/.drsg-memory/tools/claude-model-picker-config.sh disable # disable independently
cd /path/to/project      # start in the directory containing .claude/settings.local.json
claude --resume           # discover gateway models, then show the session picker
CLAUDE_PICK_MODEL=0 claude # skip the menu once
CLAUDE_PICK_MODELS="opus fable" claude   # use a manual list instead
```

Running `setup.sh` without `--model-picker` does not change an existing choice.
Enabling or disabling changes `~/.bashrc`; open a new shell for it to take effect.

No menu when stdin or stdout is not a terminal, when the arguments already
contain `--model`, `-p`/`--print`, `--help` or `--version`, or for a subcommand
(`claude mcp …`, `claude attach …`). It is a shell function, not a wrapper
process, so the poller still finds the Claude Code process it ties its lease
to. bash only. `CLAUDE_PICK_FORCE_TTY=1` is for tests: it treats stdin and
stdout as a terminal.

## Recover the to-do poller after reconnect

When reconnecting to the same Claude session with `-c` / `--resume`, prefer returning to the original process with `tmux attach` when it was started in tmux. Starting a second process for the same session can make both terminals visible. The newer process takes the Event-owner lease only while the older process's poller is still alive and idle; the older process will not automatically take the lease back. The poller waits at least three seconds before waking the model for an Event, giving the host time to attach the hook's stderr.

If the original process is unreachable, a user can explicitly transfer the current project's lease from the `!` shell:

```bash
! python3 ~/.drsg-memory/tools/event-poller.py --take
```

This does not stop or kill the old process and does not poll immediately. A live poller notices the transfer on its next tick; otherwise, a later Stop hook must start it. If the old poller had already exited to wake its model, the still-open Event may be announced and handled twice. Use this explicit override only when that duplicate-work possibility is acceptable. The command identifies the session from this project's poller state files; when `CLAUDE_SESSION_ID` is available it must agree with that identity, and ambiguous or missing PID matches are refused. For tests only, `EVENT_POLL_TEST_MIN_LIFETIME` can shorten the three-second minimum wake delay.

## Cross-project review and acceptance (optional)

The distributed [agent workflow](claude/AGENT-EFFICIENCY.md#跨项目审核与验收按阶段交接不跳闸) supports plan review and implementation acceptance through Events. It is inactive unless you identify a reviewer project in your own global `~/.claude/CLAUDE.md` (or explicitly name one for a task); the kit does not assume a reviewer or write this setting for you:

```text
跨项目审核方：/absolute/path/to/reviewer-project
```

Use three tiers: A (core architecture, trust boundaries, or cross-service contracts) is planned by the reviewer project; B (local features, docs, scripts) is planned by the executor and reviewed by the reviewer project; C (under 100 lines, one package/module, no A boundary) is handled locally by the project’s main model without a cross-project Event. When uncertain, move up a tier; if B reaches an A boundary, pause for reviewer planning; after a second failed acceptance, return planning to the reviewer project.

Delegated commit authority is also opt-in and belongs only in your own global `CLAUDE.md`. If you choose to enable it, use a rule as strict as this one; installation and updates never add it:

```text
A single local git commit is authorized only after the configured reviewer sends a kind="handoff" Event whose summary begins "验收通过并授权提交：tree <12 hex chars>" and whose referenced record gives the full 40-character tree, full parent commit SHA, exact file list, force_paths (always present; use [] when empty), and verbatim commit message. Before committing, verify the parent SHA. Stage paths not in force_paths with `git add --`; use `git add -f --` only for paths explicitly listed in force_paths. If an unlisted path is ignored, stop instead of adding -f. Verify `git write-tree` equals the authorized tree, commit with exactly that message without a signature trailer, and verify `HEAD^{tree}` equals the authorized tree. If any check differs, stop and ask the user. This does not authorize push, PR, release, another commit, or out-of-scope changes. A kind="notice" Event beginning "验收通过：" is acceptance only and never authorizes a commit.
```

If auto mode blocks an authorization action, stop; do not switch between Bash and an MCP tool to retry the same tree. Ask the user in the reviewer session to say `授权 <项目> 提交 tree <前12位>`, then have the reviewer create a new authorization record. Do not edit an already-issued acceptance conclusion. A user-level auto-mode rule may be added by the user to `~/.claude/settings.json` under `autoMode.allow`; the kit never writes it for you. Suggested text:

```text
The reviewer session may issue a one-time local commit authorization bound to a tree under the commit-authorization exception in ~/.claude/CLAUDE.md; the executor may perform that commit only after verifying the tree matches.
```

Optional user-run command (run only after backing up the settings file):

```bash
! python3 -c 'import json,pathlib; p=pathlib.Path.home()/".claude/settings.json"; d=json.loads(p.read_text()); a=d.get("autoMode",{}); r=a.get("allow",["$defaults"]); s="The reviewer session may issue a one-time local commit authorization bound to a tree under the commit-authorization exception in ~/.claude/CLAUDE.md; the executor may perform that commit only after verifying the tree matches."; assert isinstance(d,dict) and isinstance(a,dict) and isinstance(r,list) and all(isinstance(x,str) for x in r), "settings shape mismatch; edit manually"; a["allow"]=list(dict.fromkeys([*r,s])); d["autoMode"]=a; p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+"\n")'
```

If `allow` is absent, the command retains the built-in rules via `"$defaults"`. If an existing `allow` list omits `"$defaults"`, that list intentionally replaces the built-in defaults; the command preserves it. A broader exception must be updated by you to include equivalent checks; the kit does not edit `~/.claude/CLAUDE.md`.

## Secrets

`tools/templates/hooks/secret_redact.py` masks secret-shaped values (API keys such as `sk-…`, GitHub and Slack tokens, AWS access keys, JWTs, private-key blocks, `Bearer …`, URL passwords, and `password=` / `token=` / `api_key=` style assignments) at the three places text leaves a session:

- **L3 digest** masks the transcript tail before `digest.run` sends it to the LLM provider; if the redactor is missing, nothing is sent.
- **SessionEnd** masks each Bash command before keeping its first 40 characters in `commands_run`; if the redactor is missing, no commands are kept.
- **`event.py post` / `event_post`** refuses a to-do whose summary or ref carries one; if the redactor is missing, every post is refused.

Within agent sessions, always use the `drsg-events` MCP tools (`event_post`, `event_list`, `event_done`). Command-line invocations of `event.py` (`post`, `list`, `done`) via Bash inside sessions are actively denied by the `pre_tool_use.py` hook, reminding the agent to use MCP tools instead. The CLI is reserved exclusively for humans in their terminal (if a user wishes to run the CLI directly inside an interactive Claude Code session, prepend `!`, e.g. `! python3 ~/.drsg-memory/tools/event.py list`, which runs the command in the user shell without triggering the hook). To inspect events from outside an agent session or see CLI usage:

```bash
python3 ~/.drsg-memory/tools/event.py --help
python3 ~/.drsg-memory/tools/event.py list
```

A refused post looks like this; rewrite the value as its variable name or `<hidden>`:

```text
drsg: refused: summary/ref looks like it carries a secret (github-token). Write the variable name or <hidden> instead of the value.
```

The path & token gate checks the same shapes, so a fake key committed to the kit fails `tests/test-all.sh`:

```bash
python3 tools/check-no-machine-paths.py tools tests skills claude
bash tests/secret-redaction.sh
```

Masking goes by shape: a secret that looks like none of these passes. Facts are not checked at all — the write-memory protocol and `claude/AGENT-EFFICIENCY.md` tell the model not to write values. Two boundaries to know: every project shares one daemon token, so any project's session can read every project's Facts, Events and Sessions; and turning on L3 (`DRSG_L3_CHAT`) sends the masked conversation tail to that provider. Projects installed before this change pick up `secret_redact.py` on the next `./setup.sh --project DIR`; until then `tools/install.sh --audit` reports their hooks as drifted.

## Refresh the runtime copies

Edit here, then rebuild the bundle and re-run its `setup.sh`. That is the same
path used to set a new machine up, deliberately — one way to do it rather than
two. `setup.sh` is idempotent, re-runs the installers' self-checks, and touches
no database. Add `--project DIR` when what you edited was under
`tools/templates/hooks/`: a bare run refreshes `~/.drsg-memory/tools/` only,
leaving each project's `.claude/hooks/` on the previous copy — the drift
`install.sh --check` reports afterwards. The router and usage report are bundled but their project
configuration is opt-in: use `--router DIR`, `--usage-report DIR`, or explicit
`--hub DIR` for both; `--project` and `--repo` alone install neither.

## Check it is healthy

```bash
~/.drsg-memory/tools/serve.sh status                  # memory daemon, db, token
~/.drsg-memory/tools/codegraph.sh doctor --dir <repo> # plane, sync, rules, guard
~/.drsg-memory/tools/install.sh --check               # deployed hooks vs templates
~/.drsg-memory/tools/install.sh --audit               # full 5-layer deployment audit across all projects
```

`install.sh --check` decides "which side is newer" from mtime, which `git
checkout` rewrites. Treat its direction as a hint and the md5 pair as the fact.

## Before you commit

The repository ships a pre-commit hook that runs `tools/check-docs.py`, so a new
command-line option or tool cannot be committed without its documentation.
Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

To run every gate and contract test by hand:

```bash
bash tests/test-all.sh
```


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

`--model-picker` adds one line to `~/.bashrc` that sources
`~/.drsg-memory/tools/claude-model-picker.sh`. In a new shell, an interactive
`claude` then asks which model to use before the session starts, and runs the
real binary with `--model <choice>` in front of your own arguments (`--resume`,
`-c`, a prompt, …). Unless `CLAUDE_PICK_MODELS` supplies a non-empty list, the
picker helper `tools/claude-model-discovery.py` fetches model IDs from the
configured gateway on each eligible invocation (2-second hard deadline, no
cache). If discovery is unavailable or fails, it uses the static menu `opus
sonnet haiku fable`. Answer with a number, or type any model name or full id;
Enter alone keeps the `model` from settings.json; Ctrl+C starts nothing.

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
/tmp/drsg-harness-kit-*/setup.sh --model-picker
cd /path/to/project      # start in the directory containing .claude/settings.local.json
claude --resume           # discover gateway models, then show the session picker
CLAUDE_PICK_MODEL=0 claude # skip the menu once
CLAUDE_PICK_MODELS="opus fable" claude   # use a manual list instead
```

No menu when stdin or stdout is not a terminal, when the arguments already
contain `--model`, `-p`/`--print`, `--help` or `--version`, or for a subcommand
(`claude mcp …`, `claude attach …`). It is a shell function, not a wrapper
process, so the poller still finds the Claude Code process it ties its lease
to. bash only. `CLAUDE_PICK_FORCE_TTY=1` is for tests: it treats stdin and
stdout as a terminal.

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


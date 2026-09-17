# drsg-harness-kit

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
| `docs/{en,zh}/src/` | the guide, with five diagrams |
| `docs/codegraph-event-dispatch.md` | how a hub project reaches another repository's graph, and how to hand work over |
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

Joining a memory daemon that is already running needs its token:
`--token <t>`. The installer refuses to guess one rather than minting a new
one, because a new token invalidates every client config already written.

## Refresh the runtime copies

Edit here, then rebuild the bundle and re-run its `setup.sh`. That is the same
path used to set a new machine up, deliberately — one way to do it rather than
two. `setup.sh` is idempotent, re-runs the installers' self-checks, and touches
no database. The router and usage report are bundled but their project
configuration is opt-in: use `--router DIR`, `--usage-report DIR`, or explicit
`--hub DIR` for both; `--project` and `--repo` alone install neither.

## Check it is healthy

```bash
~/.drsg-memory/tools/serve.sh status                  # memory daemon, db, token
~/.drsg-memory/tools/codegraph.sh doctor --dir <repo> # plane, sync, rules, guard
~/.drsg-memory/tools/install.sh --check               # deployed hooks vs templates
```

`install.sh --check` decides "which side is newer" from mtime, which `git
checkout` rewrites. Treat its direction as a hint and the md5 pair as the fact.

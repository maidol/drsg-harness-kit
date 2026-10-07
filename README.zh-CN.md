# drsg-harness-kit

DrSG 的智能体侧工具集，集中在一个仓库中：为 Claude Code 提供共享的长期记忆层（hooks、daemon 和跨项目待办），为每个仓库提供代码图及将多个代码图置于一个 MCP 入口后的路由器，同时提供在没有这些组件的机器上完成安装的脚本。

[English](README.md)

**仅支持 Linux。** daemon 控制器通过 `/proc/<pid>/fd` 查找持有数据库 LOCK 的进程，以此识别正在运行的 daemon；其他平台没有等价机制。因此 `install-drsg.sh` 会拒绝其他平台，而不是安装一个之后才会失败的二进制。`setup.sh` 会写入 `$HOME`，运行前请先阅读脚本。

## 目录结构

| 路径 | 用途 |
|---|---|
| `tools/` | 所有实际运行的内容。该目录会被安装到 `~/.drsg-memory/tools/`。 |
| `tools/templates/hooks/` | 四个 Claude Code hook，由 `tools/install.sh` 复制到各个项目。 |
| `skills/codegraph/` | 代码图运维 skill，安装到 `~/.claude/skills/`。 |
| `skills/agent-efficiency-retro/` | 会话效率复盘 skill：统计工具调用、一轮多调用比例、单轮耗时随上下文的变化，安装到 `~/.claude/skills/`。 |
| `skills/diagram-conventions/` | 出图约定 skill：按句子里的连接词选架构图/流程图/时序图，安装到 `~/.claude/skills/`。第三方的 `archify` 不归本仓库分发，它指向本 skill 的那段是手工追加在其 SKILL.md 末尾的 `<!-- local: diagram-conventions -->`，重装 archify 后要补回。 |
| `claude/AGENT-EFFICIENCY.md` | Agent 执行效率规则，复制到 `~/.claude/` 并由全局 CLAUDE.md 用 `@` 引入（setup 第 2 步）。 |
| `docs/{en,zh}/src/` | 使用指南，包含五张图。 |
| `setup.sh` | 在新机器上安装；从解包后的 bundle 中运行。 |
| `pack.sh` | 构建 bundle。 |
| `install-drsg.sh` | 机器没有 `drsg` 时下载其二进制。 |
| `tools/codegraph-router-setup.sh` | hub 项目的可选 router MCP 配置。 |
| `tools/codegraph-usage-setup.sh` | 可选的 native/routed usage-report Stop hook。 |

## 安装

在尚未安装这些组件的机器上：

```bash
./pack.sh                                   # 写入 dist/drsg-harness-kit-<ver>.tar.gz
tar xzf dist/drsg-harness-kit-*.tar.gz -C /tmp
/tmp/drsg-harness-kit-*/setup.sh --project /path/to/project --repo /path/to/repo
```

连接已经运行的 memory daemon 需要提供其 token：`--token <t>`。安装器不会猜测 token，也不会自行生成新的 token，因为新 token 会使已经写入的所有客户端配置失效。

`--project` 还会在该项目里装一个 git pre-commit hook，运行 `completeness-guard.py --staged`：新增的命令行选项、环境变量、路由或配置键在文档里找不到时打印提示；只有项目声明了 `.completeness.json` 才会拦下提交。项目已有自己的 pre-commit hook、或者设了 `core.hooksPath` 时不动它，安装器会打印手动串联的那一行。用法和声明文件见 [tools/README.zh-CN.md](tools/README.zh-CN.md#通用交付闭环守卫completeness-guardpy)。


## 权限护栏（可选）

不要求就不装。`--permission-guard DIR` 往 `DIR/.claude/settings.local.json` 加入 `git commit` / `git push` / `gh pr create` 的 ask 规则和只读的窄 allow 规则；`--reviews-dir DIR` 在 `~/.claude/settings.json` 里告诉 auto 模式分类器：DIR 下的脚本在 Write 里原样展示过之后可以运行；`--prune-broad` 同时从项目文件里删掉 `Bash(python3 *)` 这类规则。三者都不需要 `--project`、drsg 二进制或正在运行的 daemon。详见 [tools/README.zh-CN.md](tools/README.zh-CN.md#权限护栏permission-guardpy)。

```bash
/tmp/drsg-harness-kit-*/setup.sh --permission-guard /path/to/project
/tmp/drsg-harness-kit-*/setup.sh --permission-guard /path/to/project --prune-broad \
  --reviews-dir /path/to/workspace/reviews
```

## 刷新运行时副本

在本仓库中修改后，重新构建 bundle，再次运行其中的 `setup.sh`。这是为新机器安装时使用的同一条路径，这是有意的设计——避免维护两套流程。`setup.sh` 幂等，会重新运行安装器自检，但不会触碰数据库。改的是 `tools/templates/hooks/` 底下的东西时要加 `--project DIR`：不带参数的一次运行只刷新 `~/.drsg-memory/tools/`，各项目的 `.claude/hooks/` 仍停在旧副本上，也就是之后 `install.sh --check` 会报出来的 drift。router 和 usage report 虽然会随 bundle 提供，但项目配置默认是可选的：使用 `--router DIR`、`--usage-report DIR`，或者使用显式的 `--hub DIR` 同时启用两者；只使用 `--project` 和 `--repo` 不会安装其中任何一个。

## 检查运行状态

```bash
~/.drsg-memory/tools/serve.sh status                  # memory daemon、数据库、token
~/.drsg-memory/tools/codegraph.sh doctor --dir <repo> # plane、同步状态、规则、guard
~/.drsg-memory/tools/install.sh --check               # 已部署 hooks 与模板的对照
~/.drsg-memory/tools/install.sh --audit               # 跨项目 5 层全量部署审计
```

`install.sh --check` 根据 mtime 判断“哪一侧更新”，而 `git checkout` 会重写 mtime。因此应把它的方向判断视为提示，把 md5 对照结果视为事实。

## 提交之前

仓库自带一个 pre-commit hook，会运行 `tools/check-docs.py`：新增的命令行选项或工具
没有配套文档时，提交会被拦下。每个克隆启用一次：

```bash
git config core.hooksPath .githooks
```

手动跑全部门禁和契约测试：

```bash
bash tests/test-all.sh
```


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

对已安装项目重新运行 setup 时，安装器会在进程内部复用项目 `.drsg/env` 中的凭据：不打印 token、不将其放入命令行。`drsg-events` MCP 条目会刷新；已有 `drsg` 条目会保留。若 `drsg` 注册缺失，setup 会警告，`install.sh --audit` 也会报告漂移；请通过安全的凭据流程手动注册。新项目加入正在运行的 daemon 时仍需通过 `--token <t>` 提供 token；安装器不会自行生成替代 token，因为这会使已写入的客户端配置失效。

`--project` 还会在该项目里装一个 git pre-commit hook，运行 `completeness-guard.py --staged`：新增的命令行选项、环境变量、路由或配置键在文档里找不到时打印提示；只有项目声明了 `.completeness.json` 才会拦下提交。项目已有自己的 pre-commit hook、或者设了 `core.hooksPath` 时不动它，安装器会打印手动串联的那一行。用法和声明文件见 [tools/README.zh-CN.md](tools/README.zh-CN.md#通用交付闭环守卫completeness-guardpy)。


## 权限护栏（可选）

不要求就不装。`--permission-guard DIR` 往 `DIR/.claude/settings.local.json` 加入 `git commit` / `git push` / `gh pr create` 的 ask 规则和只读的窄 allow 规则；`--reviews-dir DIR` 在 `~/.claude/settings.json` 里告诉 auto 模式分类器：DIR 下的脚本在 Write 里原样展示过之后可以运行；`--prune-broad` 同时从项目文件里删掉 `Bash(python3 *)` 这类规则。三者都不需要 `--project`、drsg 二进制或正在运行的 daemon。详见 [tools/README.zh-CN.md](tools/README.zh-CN.md#权限护栏permission-guardpy)。

```bash
/tmp/drsg-harness-kit-*/setup.sh --permission-guard /path/to/project
/tmp/drsg-harness-kit-*/setup.sh --permission-guard /path/to/project --prune-broad \
  --reviews-dir /path/to/workspace/reviews
```

## 启动前选模型（可选）

picker 程序文件会随 runtime tools 一起部署，但全新安装默认不启用。安装或更新时明确传 `--model-picker`，才会在 `~/.bashrc` 添加一行，source `~/.drsg-memory/tools/claude-model-picker.sh`。开新 shell 之后，交互式的 `claude` 会在会话开始前先问用哪个模型，再把 `--model <所选>` 放在你自己的参数（`--resume`、`-c`、提示词……）前面，启动真正的 `claude`。除非设置了非空的 `CLAUDE_PICK_MODELS`，选单辅助程序 `tools/claude-model-discovery.py` 会在启用 gateway discovery 且缓存 `baseUrl` 匹配时读取 Claude Code 的模型缓存；它只读，不写入或刷新缓存。缓存不可用时，辅助程序用 2 秒墙钟超时实时查询网关；仅当 `max_input_tokens` 至少为 1,000,000 时才为模型 ID 加 `[1m]`，不按模型名称或默认设置猜上下文长度。缓存里的安全显示名称用于选单标签，模型 ID（含 `[1m]`）用于启动参数。查询失败或没有可用模型时，退回静态选项 `opus sonnet haiku fable`。输入菜单里的数字，或者直接输入任意模型名或完整 ID；直接回车用 settings.json 里的 `model`；Ctrl+C 什么都不启动。

辅助程序按顺序读取进程环境、`~/.claude/settings.json`、当前工作目录下的 `.claude/settings.json`、当前工作目录下的 `.claude/settings.local.json` 中的 `env` 值，后者覆盖前者。项目设置只从当前工作目录读取，不向父目录查找；要使用项目设置，请从项目目录启动 `claude`。选单不支持 `apiKeyHelper` 或 Claude Code OAuth 认证，遇到时使用静态选项。`ANTHROPIC_API_KEY` 会作为 `x-api-key` 发送；若没有非空 API key，则使用 `ANTHROPIC_AUTH_TOKEN` Bearer token。

```bash
/tmp/drsg-harness-kit-*/setup.sh --model-picker  # 安装/更新时显式启用
~/.drsg-memory/tools/claude-model-picker-config.sh enable  # 单独开启
~/.drsg-memory/tools/claude-model-picker-config.sh disable # 单独关闭
cd /path/to/project      # 从含有 .claude/settings.local.json 的项目目录启动
claude --resume           # 先发现网关模型，再进会话选择列表
CLAUDE_PICK_MODEL=0 claude # 这一次不弹菜单
CLAUDE_PICK_MODELS="opus fable" claude   # 手动指定选单
```

不带 `--model-picker` 的普通安装/更新不会改变已有开关状态。开启或关闭会修改 `~/.bashrc`，需在新 shell 中生效。

以下情况不弹菜单：stdin 或 stdout 不是终端；参数里已经有 `--model`、`-p`/`--print`、`--help` 或 `--version`；子命令（`claude mcp …`、`claude attach …`）。它是一个 shell 函数，不是包装进程，所以待办轮询仍能找到它要绑定租约的那个 Claude Code 进程。只支持 bash。`CLAUDE_PICK_FORCE_TTY=1` 只给测试用：把 stdin 和 stdout 当成终端。

## 跨项目审核与验收（可选）

分发的[执行方工作流](claude/AGENT-EFFICIENCY.md#跨项目审核与验收按阶段交接不跳闸)通过 Event 支持计划评审与实现验收。只有你在自己的全局 `~/.claude/CLAUDE.md` 指定了审核方项目（或当前任务明确指定审核方）才启用；kit 不会假定审核方，也不会替你写入此设置：

```text
跨项目审核方：/审核方项目的绝对路径
```

任务分三级：A（核心架构、信任边界、跨服务契约）由审核方项目出计划；B（局部功能、文档、脚本）由执行方出计划并交审核方评审；C（不到 100 行、一个包/模块且不碰 A 类边界）由本项目主模型直接处理，不发跨项目 Event。拿不准就升一级；B 级碰到 A 类边界时暂停并请审核方出计划；第二次验收不通过则转交审核方出新计划。

委托提交授权同样是可选项，唯一权威位置是你自己的全局 `CLAUDE.md`。如要启用，应加入不弱于以下内容的规则；安装或更新 kit 都不会自动加入：

```text
仅当配置的审核方通过 kind="handoff" Event 发出 summary 以“验收通过并授权提交：tree <12位十六进制>”开头的判定，且其 ref 记录完整 40 位 tree、完整父提交 SHA、精确文件清单、force_paths（始终列出；为空写 []）和逐字 commit message 时，才授权一次本地 git commit。提交前核对父提交 SHA；files 中不在 force_paths 的路径用 git add --，仅对 force_paths 中明确列出的路径用 git add -f --。未列入 force_paths 的路径若被 ignore，立即停止，不自行补 -f。确认 git write-tree 等于授权 tree；提交时使用逐字 message 且不加署名行，提交后确认 HEAD^{tree} 等于授权 tree。任一项不符就停止并询问用户。此授权不包括 push、PR、发布、额外提交或范围外改动。kind="notice" 且 summary 以“验收通过：”开头只表示验收通过，永不授权提交。
```

若 auto 模式拦截授权动作，立即停止，不要在 Bash 与 MCP 工具之间切换后重试同一 tree。请用户在审核方会话中说“授权 <项目> 提交 tree <前12位>”，再由审核方新建授权记录；不得改写已发出的验收结论。用户可自行在 `~/.claude/settings.json` 的 `autoMode.allow` 中加入 auto 模式提示，kit 不会代写。建议文案：

```text
审核方会话可按 ~/.claude/CLAUDE.md 的提交授权例外，发出绑定 tree 的一次性本地提交授权；执行方核对 tree 一致后可执行该次 commit。
```

可选的用户自助命令（仅由用户在运行前备份 settings 文件后主动执行）：

```bash
! python3 -c 'import json,pathlib; p=pathlib.Path.home()/".claude/settings.json"; d=json.loads(p.read_text()); a=d.get("autoMode",{}); r=a.get("allow",["$defaults"]); s="审核方会话可按 ~/.claude/CLAUDE.md 的提交授权例外，发出绑定 tree 的一次性本地提交授权；执行方核对 tree 一致后可执行该次 commit。"; assert isinstance(d,dict) and isinstance(a,dict) and isinstance(r,list) and all(isinstance(x,str) for x in r), "settings shape mismatch; edit manually"; a["allow"]=list(dict.fromkeys([*r,s])); d["autoMode"]=a; p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+"\n")'
```

若 `allow` 不存在，命令会加上 `"$defaults"` 以保留内置规则；已有 `allow` 且不含 `"$defaults"` 时，表示你有意替换内置默认规则，命令会保留现状。如果全局规则里已有更宽泛的例外，请由你自行改成包含等价核对步骤的版本；kit 不会修改 `~/.claude/CLAUDE.md`。

## 密钥

`tools/templates/hooks/secret_redact.py` 按形状给密钥打码（`sk-…` 这类 API key、GitHub 和 Slack token、AWS access key、JWT、私钥块、`Bearer …`、URL 里的口令，以及 `password=` / `token=` / `api_key=` 这类赋值），用在文本离开会话的三个地方：

- **L3 蒸馏**：`digest.run` 把会话末尾发给 LLM 服务商之前先打码；找不到脱敏模块时什么都不发。
- **SessionEnd**：每条 Bash 命令先打码，再取前 40 个字符存进 `commands_run`；找不到脱敏模块时不存命令。
- **`event.py post` / `event_post`**：summary 或 ref 里带密钥就拒发；找不到脱敏模块时所有待办都拒发。

在 agent 会话内，一律使用 `drsg-events` MCP 工具（`event_post`、`event_list`、`event_done`）。会话内通过 Bash 运行 `event.py`（`post`、`list`、`done`）会被 `pre_tool_use.py` 钩子主动拦截拒绝，并提示改用 MCP 工具。CLI 仅供人类在终端中独立使用（若用户本人要在交互式 Claude Code 会话中运行 CLI，使用 `!` 前缀，例如 `! python3 ~/.drsg-memory/tools/event.py list`，即可在用户 shell 中执行而不触发钩子）。要在会话外查看待办或帮助：

```bash
python3 ~/.drsg-memory/tools/event.py --help
python3 ~/.drsg-memory/tools/event.py list
```

被拒发时的输出如下，把值改写成变量名或 `<hidden>` 再发：

```text
drsg: refused: summary/ref looks like it carries a secret (github-token). Write the variable name or <hidden> instead of the value.
```

路径与 token 检查用的是同一套形状，往 kit 里提交假 key 会让 `tests/test-all.sh` 失败：

```bash
python3 tools/check-no-machine-paths.py tools tests skills claude
bash tests/secret-redaction.sh
```

打码只认形状，长得不像这些的密钥会漏过去。Fact 写入完全不检查，靠写记忆约定和 `claude/AGENT-EFFICIENCY.md` 要求模型不写值。另有两条边界：所有项目共用一个 daemon token，任何项目的会话都能读到全部项目的 Fact、Event 和 Session；开启 L3（`DRSG_L3_CHAT`）就会把打过码的会话末尾发给服务商。这次改动之前安装的项目，要再跑一次 `./setup.sh --project DIR` 才会装上 `secret_redact.py`，在那之前 `tools/install.sh --audit` 会报它们的 hooks 有漂移。

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


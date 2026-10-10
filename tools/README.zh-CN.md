# Claude Code 长期记忆层

[English](README.md)

> 当前仅支持 Claude Code。hook 契约（`SessionStart` / `UserPromptSubmit` / `SessionEnd` 以及 transcript 路径）和 `claude mcp add` 注册流程都属于 Claude Code；要移植到其他 harness，需要替换 `templates/hooks/` 以及 `install.sh` 中的相关调用，底层记忆层无需改变。两个 MCP server（`codegraph-router.py`、`mcp_events.py`）已经与 harness 无关，任何 stdio MCP 客户端现在都可以注册它们。

只需一条命令，即可把 Dr Strange 变成 Claude Code 项目的持久化跨会话记忆层：图会记住之前的会话结论，每个新会话都会从摘要而不是空白上下文开始。

整个系统由四个 Python hook、一个安装器和一个 daemon 控制脚本组成。不需要插件、不需要注册服务，也不会有数据离开本机。

`tools/claude-model-picker.sh` 是一个 Bash 函数，会在交互式 `claude` 启动前询问模型。未设置 `CLAUDE_PICK_MODELS` 时，它通过 `tools/claude-model-discovery.py` 查询配置的网关，失败时退回静态选单。程序文件随 tools 部署，但全新安装默认不启用。可在安装时用 `setup.sh --model-picker` 显式启用，也可之后运行 `~/.drsg-memory/tools/claude-model-picker-config.sh enable`；传 `disable` 可关闭。普通安装/更新会保留当前选择。详细说明见仓库根目录 README 的「启动前选模型」一节。

## 代码图路由器与 usage report

运行时 bundle 包含 router 和 usage-report 二进制，但项目配置默认是可选的。使用 `codegraph-router-setup.sh` 配置 router MCP 访问，使用 `codegraph-usage-setup.sh` 配置 Stop hook 报告，或者使用显式的组合封装脚本 `codegraph-hub-setup.sh`。usage report 同时统计本地原生代码图调用和经由 router 的 `codegraph` 调用；它不会由 `install.sh` 或默认的 `setup.sh` 安装。

主工作区/当前分支规则由 `setup.sh` 默认安装，且独立于 `--no-skills`。可用 `~/.drsg-memory/tools/main-branch-workflow-config.sh enable|disable|status` 管理用户级导入和持久关闭状态；`setup.sh --no-main-branch-workflow` 也可关闭。标记文件位于 `$CLAUDE_CONFIG_DIR/.main-branch-workflow.disabled`（通常是 `~/.claude/.main-branch-workflow.disabled`）。这是指导规则，不是强制执行的沙箱，也不会切换分支。

## 架构

```
任意 Claude Code 项目                  一个共享 daemon（~/.drsg-memory/）
┌────────────────────────────┐        ┌──────────────────────────────┐
│ .claude/hooks/（4 个脚本）  │──RPC──▶│ 一个 `drsg serve`             │
│   session_start / end      │        │   持有 memory.drsg             │
│   user_prompt / l3_digest  │        │   每个仓库一个 Project 节点    │
│ .drsg/env（指向它）         │        │   地址 127.0.0.1:7700          │
│ settings.local.json hooks  │        └──────────────────────────────┘
│ MCP: drsg @ /mcp           │──HTTP──▶（多个 agent，一个数据库）
└────────────────────────────┘
```

- **共享，而不是每个项目各自拥有。** 一个 daemon 管理所有项目的记忆。原生后端允许每个数据库只有一个进程，因此 daemon 是多个 agent（或多个编辑器）并发读写同一张图的唯一方式。
- **分离，而不是混在一起。** 每个项目都是一个 `Project` 节点；Facts 通过 `ABOUT` 边挂在项目下。Recall 按项目的 `path` 过滤。
- **三种写入途径。** L1：hook 从 transcript 中提取的结构化事实——涉及的文件、执行的命令和工具结果。L2：模型按照会话开始时注入的协议自行写入的结论；价值主要在这里，但它只是 prompt，没有任何机制强制或验证。L3：对 transcript 尾部进行 LLM 提炼（可选，默认关闭）。
- **两种读取途径。** SessionStart 为当前项目注入压缩后的摘要；UserPromptSubmit 根据刚刚输入的内容，从**所有**项目中召回 Facts，并标明来源。
- **压缩会重新注入。** SessionStart 也会在 `compact` 时运行，因为压缩会从上下文中移除摘要和协议，但会话本身仍在继续。这条路径会给现有 Session 节点加戳，而不是创建第二个节点。

## 前置条件

- `drsg` 二进制。`serve.sh` 会启动它；通过 `--bin` 或设置 `$DRSG_MEM_BIN` 指定。
- **`drsg serve` 的 `/mcp` endpoint**，用于 MCP 注册步骤。hook 本身只需要 `/rpc`，没有 `/mcp` 也能工作。
- Python 3、`curl` 和 `openssl`（用于生成 token）。

## 安装

```bash
# 在此目录执行
./install.sh /path/to/project --bin /path/to/drsg
```

**之后重启 Claude Code 会话**——hook 和 MCP server 在启动时读取。

除非指定 chat provider，否则 L3 提炼处于关闭状态：

```bash
./install.sh /path/to/project --bin /path/to/drsg \
  --l3-chat openai            # 或 deepseek / qwen / ollama
```

`--l3-chat` 也接受原始的、兼容 OpenAI 的 base URL——例如自托管 proxy——但只有接受该参数的 daemon 的 `digest.run` 才能使用；使用上面的 preset 名称时，任何 daemon 都可以。provider 契约由 memory daemon 实现，而不是由本仓库实现。

## 加入已有 daemon

如果目标地址已经有进程响应 `/health`，`install.sh` 会**加入**它，而不是启动第二个 daemon。之后所有项目都会进入同一个 `memory` plane，由各自的 `Project` 节点区分，recall 也可以跨项目访问。对已有项目重新运行时，安装器会在进程内部复用 `.drsg/env` 中的凭据，不打印 token、不将其放入命令行；它会刷新 `drsg-events`，保留已有 `drsg` 注册。若 `drsg` 缺失，安装器会警告，`install.sh --audit` 也会报告漂移；请通过安全的凭据流程手动注册。新项目加入仍需提供该 daemon 的 token：

```bash
./install.sh /path/to/other-project --bin /path/to/drsg \
  --addr 127.0.0.1:7700 --token <the daemon's token>
```

如果某个项目之前安装到了**自己的 daemon**，先迁移它的 memory：

```bash
# 1. 从旧 daemon 导出
python3 migrate.py dump --api http://127.0.0.1:7701/rpc --token <old token> \
  --plane memory --out project-memory.json
# 2. 导入共享 daemon（按 external key 去重，从不覆盖）
python3 migrate.py load --api http://127.0.0.1:7700/rpc --token <new token> \
  --plane memory --in project-memory.json
# 3. 对共享地址重新运行安装器（幂等）
./install.sh /path/to/other-project --bin /path/to/drsg \
  --addr 127.0.0.1:7700 --token <new token>
# 4. 确认无误后，停止旧 daemon
./serve.sh stop
```

先备份两个数据库——停止 daemon，然后复制目录。`migrate.py` 会警告并跳过没有 external key 的节点；dump 输出会告诉你是否存在这类节点。

## 选项

| 选项 | 默认值 | 含义 |
|---|---|---|
| `--bin <path>` | `$DRSG_MEM_BIN` 或 `drsg` | 要运行的二进制 |
| `--addr <host:port>` | `127.0.0.1:7700` | daemon 监听地址 |
| `--token <t>` | 复用或生成 | 显式 API token；已有项目自动复用 `.drsg/env`；新项目加入运行中的 daemon 时**必填** |
| `--l3-chat <name\|url>` | 空（关闭 L3） | preset 名称或兼容 OpenAI 的 base URL |
| `--l3-key-env <v>` | preset 自带的变量名 | 保存 LLM key 的环境变量**名称**（见下文） |
| `--l3-model <m>` | provider 自带的模型 | 与 endpoint 列出的内容完全一致的模型 id |
| `--l3-reasoning <e>` | 未设置 | `reasoning_effort`；`none` 可阻止 reasoning model 截断 JSON |
| `--restart-daemon` | 关闭 | 先停止已有 daemon（新 token 或新地址） |
| `--check` | 关闭 | 不安装任何内容；报告 hook 漂移，有漂移时退出 1（见下文） |
| `--audit` | 关闭 | 不安装任何内容；执行 5 层全量部署审计 |

## 运行 daemon

```bash
./serve.sh start|stop|restart|status
# 覆盖项：DRSG_MEM_DIR / DRSG_MEM_BIN / DRSG_MEM_ADDR / DRSG_MEM_TOKEN
# BIN 和 ADDR 会回退到 env 文件中持久化的值，因此不带参数的
# `restart` 也可以正常工作。
```

状态保存在 `~/.drsg-memory/`：`memory.drsg`、`env`、`serve.log`、`serve.pid`。

**修改 L3 key 后需要重启 daemon。** `start` 会把 env 文件中的 `KEY=VALUE` 对导出到 daemon 自己的进程环境；已经在旧环境下运行的 daemon 会继续发送空 key，`digest.run` 将返回 401。编辑完后运行 `./serve.sh restart`。

## 安装实际做了什么

1. 确保共享 daemon 正在运行，生成或复用 token。启用 L3 时，会在 daemon 启动**之前**把 key 的**值**写入 `~/.drsg-memory/env`，这样 `start` 才能导出它。
2. 把四个 hook 复制到 `<project>/.claude/hooks/`。
3. 写入 `<project>/.drsg/env`（`chmod 600`）——daemon 地址、token 和 L3 设置只包含 key 的**名称**。
4. 把 SessionStart / UserPromptSubmit / SessionEnd 条目合并到 `<project>/.claude/settings.local.json`，保留已有内容。
5. 注册两个 MCP server（项目级）：`drsg` 指向 daemon 的 `/mcp`，以及 `drsg-events`——本目录中的 stdio server，提供 `event_post` / `event_list` / `event_done`。第二个 server 有意独立：`Event` 和 `NOTIFY` 是本层建立在软 schema 图之上的约定，而不了解 Fact 的 engine 不应学习 Event 是什么。
6. **自检**：daemon 可访问、plane 存在、项目 key 能解析为 `Project` 节点，并且能通过 hook 自己的 recall query 读到临时 Fact。任何一步失败都会以非零状态退出并说明原因，而不是报告一个实际上什么都不会做的“成功安装”。

将 `.drsg/` 加入目标项目的 `.gitignore`。

## 安装是否仍然同步？（`--check`）

`templates/hooks/` 是规范版本并受版本控制；每个 `<project>/.claude/hooks/` 都是它的副本，而项目中的 `.claude/` 被 gitignore，因此部署的 hook 没有在任何地方被跟踪。多个安装共享一个 daemon 时，它们会无声地漂移。

```bash
./install.sh --check                    # plane 知道的所有项目
./install.sh /path/to/project --check   # 只检查这个项目（目录必须在前）
```

```
  ok    /path/to/project
  DRIFT /path/to/other-project
          user_prompt.py: 58c508dc != 311c8e74  （部署版本更新）
```

只要有任何漂移就退出 1，因此可以作为 CI 或 pre-commit gate。

漂移可能发生在**两个方向**，修复方式不同，因此报告会按 mtime 说明哪一侧领先，而不是猜测：

- **template 更新**——某次安装被遗漏。对该项目重新运行 `install.sh`。
- **deployment 更新**——有人直接编辑了 hook。把它复制回 `templates/hooks/` 并提交，**否则下一次安装会静默地将其覆盖**。这并非假设：这个选项正是因此而存在。

不带项目目录时，列表来自 memory plane 的 `Project` 节点——与 recall 遍历的是同一份列表。安装过但从未记录的项目在这里不可见，原因也正是它对 recall 不可见；这比再维护一份可能不一致的 registry 更有用。

## 全量分层部署审计（`--audit`）

`--check` 仅比对 hook 文件与模板。实际部署中的漂移还可能发生在全局运行时工具、全局配置、项目 settings 或代码图状态中。`--audit` 执行完整的 5 层全量审计：

- **L0: 项目发现层**（`--all` 全量模式）：通过无代理连接从 memory plane 发现所有登记项目，异常时显式报错；
- **L1: 全局运行时工具层**：将 `~/.drsg-memory/tools/` 与 git `HEAD` 对应版本对比，校验执行权限；工作区未提交草稿单独做提示，不计为漂移；
- **L2: 全局规则与技能层**：核验 `~/.claude/AGENT-EFFICIENCY.md`、skills、主分支工作流规则状态（启用、主动关闭或漂移）、全局 hooks，并校验 `settings.json` 的 `0600` 安全权限；
- **L3: 项目钩子层**：比对各项目 `.claude/hooks/*.py` 哈希与执行权限；
- **L4: 项目设置与文档层**：核验各项目 `.claude/settings.local.json` 注册、`.drsg/env` 凭据、`CLAUDE.md` 跨项目 Event 引导块，以及 `~/.claude.json` 里该项目是否注册了 `drsg` 和 `drsg-events` 两个 MCP server（local 或 user 范围；设了 `$CLAUDE_CONFIG_DIR` 时读 `$CLAUDE_CONFIG_DIR/.claude.json`，给了 `--claude-dir` 时读那个目录下的）。缺哪个就报哪个，并给出补注册的命令；
- **L5: 代码图健康层**：检查代码图 daemon 运行健康状态与 `.mcp.json` 端口匹配，正确将按需待机识别为正常状态。

```bash
./install.sh --audit                    # 跨项目执行 5 层全量部署审计
./install.sh /path/to/project --audit   # 仅审计单个项目
python3 audit_deployment.py --all --json  # 结构化 JSON 输出
```

若有特定项目无需安装 kit（如纯静态博客），可在该项目根目录下放置 `.drsg/audit-skip`，审计时将明确标为 `[SKIP]` 而不判定为失败。

## 它是否正常工作？（`analyze_recall.py`）

两个读取 hook 都会在 `<project>/.drsg/recall.jsonl` 追加一行 JSON，记录排名结果、注入内容、成本和耗时。写入永远不会使会话失败；记录是在决策完成后写入的。

```bash
python3 analyze_recall.py            # daemon 知道的所有项目
python3 analyze_recall.py --since 14
```

它会把每次注入与 transcript 中紧随其后的回复配对，并报告：

- **utilization**——注入的 Facts 中，有多少被回复显式使用；
- **cross-project**——借自其他项目的 Facts 是否以接近本地 Facts 的比例被使用，这是判断共享是否值得消耗 token 的唯一诚实方式；
- **dead facts**（反复注入但从未使用）和 **never-injected facts**（措辞与真实 prompt 不匹配）；
- **cost**——注入的字符数、briefing/protocol 的拆分以及 hook 延迟。

utilization 是一个 proxy，脚本也会明确说明这一点：它会把仅仅确认某条 memory 的回复计算进去，也会漏掉通过预防某件事而发挥作用的 memory——工具链事实成功时，看起来和一个本来就不会失败的构建完全一样。把它看作下限和趋势。少于 30 个有记录的会话时，脚本完全拒绝下结论。

**对照臂**是唯一随机化的读数。15% 的 prompt 照常排序、照常记录，但不注入；`session_end.py` 记下每个 prompt 的工具调用数和错误数。成对那一行取两臂都有数据的会话，数「treated 错误率高于 suppressed」和反过来的会话各有多少，再拿这个差去和「在每个会话内部打乱臂标签」之后的同一个数比（打乱 2,000 次，固定随机种子）：

```
  paired all errors  : treated worse in 57, better in 22, tied 6  → permutation p=0.091 (shuffled labels expect worse−better +20.1)
```

打乱后的期望值不是 0：suppressed 臂样本小，单凭运气错误率就更常是 0，所以即使毫无效应，「treated 更差」也会占多数。要看 `p`，不要看原始计数。

## 发待办（`event.py post` / `event_post`）

执行方的阶段评审/验收流程及一次性提交授权边界见[全局分发规范](../claude/AGENT-EFFICIENCY.md#跨项目审核与验收按阶段交接不跳闸)；本 README 只说明 Event 操作机制。

`event.py post` 和 MCP 工具 `event_post` 共用同一份实现。待办带上代码图符号和动词，收方会在它下面看到一行 `↳ graph first:`。如果是 handoff，summary 读起来像在改一个判断（守卫、过滤、跳过、暂停这类），而动词不是 `impact`，回复末尾会多一行建议。Event 照常发出。

回复某条待办时，可在 MCP 参数中传 `reply_to`，或在 CLI 中用 `--reply-to <event-key>`：

```bash
python3 ~/.drsg-memory/tools/event.py post /path/to/reviewer-project \
    "验收通过：已完成检查" --kind notice --reply-to evt-my-project-1791620000-a1b2c3
```

目标必须是一条由本次 recipient 发出、且 `NOTIFY` 收件方为当前项目的 Event。旧 Event 未保存精确发件路径时会拒绝关联，并显示提示：

```text
reply_to 指向的 Event 是旧格式（没有 from_path），无法核对来源；请去掉 reply_to 重发，正文里写明在回复哪一条。
```

目标不存在或关联路径不符时会提示核对 key，或去掉 `reply_to` 重发。该字段只在唤醒提示和 `event_list` 中添加关联信息，不授权任何操作，也不会关闭原 Event；原 Event 仍由 owner 调用 `event_done` 关闭。双方都需部署新版 `drsg-events` runtime 并重启 Claude Code 后再使用 `reply_to`。手动部署时请在自己的 shell 用 `!` 前缀运行 setup 命令。

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

改动要落到所有做同一个判断的路径上时，用 `--verb impact` 重发。

## 待办轮询（`event-poller.py`）

`setup.sh` 会把它注册成 `~/.claude/settings.json` 里的四个**全局** hook（`--no-event-poller` 可跳过）。之后每个会话每 15 分钟查一次本项目的待办 Event，**轮询本身不调用模型**；只有出现本会话还没通知过的待办时，才唤醒模型。

- **为什么不调用模型。** `SessionStart`、`Stop` 和 `StopFailure`（这一轮因 API 错误结束）用 `asyncRewake` 方式运行它：Claude Code 让它在后台跑，只有退出码是 2 时才唤醒模型。没有新待办的轮次只是睡眠、通过 RPC 问 daemon，什么都不输出。唤醒时的提示会列出这些 Event，并重申 commit、push、开 PR 仍要等用户确认。
- **每个项目只有一个轮询，靠租约保证。** 同一目录开两个会话时，两边都会去处理同一条 Event。所以轮询权是一份租约，记的是会话和它的 Claude Code 进程（pid 加启动时间），而不是轮询进程持有的文件锁。原因是：轮询进程要退出才能唤醒模型，锁如果随进程一起释放，就会在第一个会话刚开始干活时把项目交给另一个会话。持有者的进程消失后，等待中的会话一分钟内接管；不论持有者是正常退出（`SessionEnd` 会释放租约），还是被强行结束。被挂起（`Ctrl+Z`，状态 `T`）或成了僵尸进程的持有者也算已经不在：它已经处理不了唤醒。
- **后台会话让给前台会话。** 后台会话（`claude --bg`，挂在 `claude bg-pty-host` 下）里 `/exit` 只是 detach，进程还活着，租约也就一直占着。Claude Code 不对外暴露「有没有客户端连着」，所以只要持有者是后台会话，同项目的前台会话一分钟内就会接管——你正 attach 着的后台会话也一样。后台会话之间不互相抢。`claude stop <id>` 仍会立即释放。
- **由 `Stop` 重新拉起。** 唤醒后轮询进程就退出了，下一次 `Stop` 会再把它启动起来；如果它已经在运行，这次 `Stop` 拉起的进程会立刻退出。
- **发件方会踢一下。** `event.py post()`（`drsg-events` 的 MCP 工具也走它）写完 Event 后，如果收件项目的状态目录存在，就 touch 其中的 `kick` 文件。等待中的轮询进程每秒 stat 一次这个文件（`EVENT_POLL_KICK_STEP`），一变就立刻查 daemon，所以空闲会话一两秒内就能看到新 Event，不用等下一次 15 分钟的定时查询。只在同一台机器上有效；没踢到时仍由 15 分钟的定时查询兜底。
- **出错时不出声。** 没有 `.drsg/env`、daemon 没起来、返回结果不对，都只记日志，下一轮再试，不会唤醒模型。
- 状态和日志在 `~/.drsg-memory/poller/<项目哈希>/`（`lease.json`、`<会话>.<pid>.seen.json`、`<会话>.<pid>.pid`、`poller.log`；`<pid>` 是 Claude Code 进程）。测试时可以用 `EVENT_POLL_INTERVAL`、`EVENT_POLL_TICK`（单位：秒）调短间隔；`EVENT_POLL_OWNER_PID` 在轮询脚本和 hook 的 owner 行里代替 Claude Code 进程。
- 接管后，上一个会话被唤醒但还没关掉的 Event 会重新通知一次；把租约拿回来的会话也一样。轮询脚本分不清「做了一半」和「做完了、在等用户确认」，所以唤醒提示里要求先看工作区。
- **一个 owner，所有会话都看得见。** 持有租约的会话就是这个项目的 Event owner，只有它会被唤醒去处理。两个终端 `--resume` 同一个会话 ID 是两个进程，只有其中一个持有租约；它退出时不会停掉另一个进程的轮询，另一个一分钟内接管，并把所有未关的 Event 重新通知一次。每个会话照样会列出未关的 Event（启动时和提问前），最上面多一行说明本会话的身份：

  ```text
  本会话是这个项目的 Event owner：按 Event 流程处理。
  Event owner 是会话 f8e05069（pid 3651），本会话只读：……不要执行这些 Event；本会话调 event_done 会被拒绝，用户明确要求本会话接手时才带 force。……
  现在没有 Event owner。本会话的待办轮询拿到租约后会唤醒你；在那之前本会话只读，不要执行这些 Event。
  ```

关 Event 是硬拦，不只是提示：项目（`CLAUDE_PROJECT_DIR`，没有就是当前目录）有活着的 owner、而调用方是另一个 Claude Code 进程时，`event_done`（MCP）和 `event.py done` 都会拒绝，什么都不写。没有活着的 owner，或者从普通 shell 里运行（上面没有 Claude Code），照旧能关。在 agent 会话内，关闭待办必须使用 MCP 工具 `event_done`（接管时带 `force: true`）；在会话内通过 Bash 跑 `event.py done` 会被 PreToolUse 钩子拦截拒绝。人类在终端独立操作时，可以带 force 关：

```bash
python3 ~/.drsg-memory/tools/event.py done <event-key> --force
```

它拦不住非 owner 改代码，拦的是第二个会话把同一条待办做完关掉。

## API 错误停住提醒（`stop-failure-notify.py`）

一轮因 API 错误结束（模型不可用、限流、认证失败）之后，会话就停在那里，没有任何东西会唤醒它：Claude Code 会忽略 `StopFailure` hook 的退出码和输出，所以轮询脚本没法让工作继续。`setup.sh` 把这个脚本注册成轮询旁边的第二个普通 `StopFailure` hook（`--no-event-poller` 会把两者一起跳过）。它返回一个 `terminalSequence`：窗口标题改成 `Claude stopped: <项目> (<错误类型>)`，再发一条桌面通知（OSC 9 对应 iTerm2 / Windows Terminal / WezTerm，OSC 777 对应 Ghostty / urxvt / Warp）并响铃。只有交互式会话、并且界面在屏幕上时，Claude Code 才会发出它。

手动试一下——输出就是 Claude Code 会收到的 JSON：

```bash
echo '{"error":"rate_limit","error_details":"429 Too Many Requests"}' \
  | python3 ~/.drsg-memory/tools/stop-failure-notify.py
```

想保留注册、但不出提醒，启动 Claude Code 时设上这个变量：

```bash
DRSG_STOP_FAILURE_NOTIFY_DISABLED=1 claude
```

## 权限护栏（`permission-guard.py`）

可选开启。你不要求就什么都不写：可以经 `setup.sh`（`--permission-guard DIR`、`--reviews-dir DIR`、`--prune-broad`），也可以直接运行工具。分两个范围：

- **项目**（`--project DIR`）：只写 `DIR/.claude/settings.local.json`——`DIR/.claude/settings.json` 可能被 git 跟踪，一律不动。它为 `git commit` / `git push` 的各种写法（`git`、`rtk git`、`/usr/bin/git`；不带参数、带 `-C DIR`、带 `-c k=v`）以及 `gh pr create` 加上 `ask` 规则。ask 规则优先于 allow 规则，所以文件里已有的 `Bash(rtk git *)` 这类宽规则再也不能不问就 commit 或 push。它还为只读 git、`event.py list|done` 和 modern-go 指引脚本加上窄 `allow` 规则：auto 模式保留窄规则，并且不调用分类器就能放行。`Bash(python3 *)` 这类宽解释器规则——auto 模式会丢弃它，其他模式下等于放行一切——只报告；加 `--prune-broad` 才删除。除此之外什么都不删。
- **用户**（`--user --reviews-dir DIR`）：写 `~/.claude/settings.json`（或 `$CLAUDE_CONFIG_DIR/settings.json`）里的 `autoMode`，这是 Claude Code 读取它的唯一位置。三条自然语言规则告诉 auto 模式分类器：DIR 下的脚本，在 agent 用 Write 把一份原样副本写到 `/tmp` 之后可以运行——分类器看的是工具输入、看不到工具输出，所以 `cat` 不算——并且可以往那里写回执文件。每条以 `(drsg-harness-kit permission-guard)` 开头；手写的同内容规则会被替换，其他条目保留。

```bash
# 项目范围；重复运行不会重复添加
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project --prune-broad
python3 ~/.drsg-memory/tools/permission-guard.py check --project /path/to/project   # 有漂移时退出码 1
python3 ~/.drsg-memory/tools/permission-guard.py remove --project /path/to/project

# 用户范围
python3 ~/.drsg-memory/tools/permission-guard.py apply --user --reviews-dir /path/to/workspace/reviews
python3 ~/.drsg-memory/tools/permission-guard.py check --user --reviews-dir /path/to/workspace/reviews
python3 ~/.drsg-memory/tools/permission-guard.py remove --user

# event.py 不在 ~/.drsg-memory/tools 时
python3 ~/.drsg-memory/tools/permission-guard.py apply --project /path/to/project --tools-dir /opt/drsg/tools
```

规则对之后新开的会话生效。`claude auto-mode config` 会显示分类器将读取的用户范围条目。

用户范围的规则只允许分类器把 DIR 下的其他文件当数据读。计划里如果让脚本把 DIR 里的文件拷进仓库再执行（比如新的测试脚本），会被当成外部代码拦下。这类文件要让执行方自己用 Write 写进仓库，计划里的脚本只核对它（用 `cmp` 比内容，再看可执行位）。

## 说明

- **LLM key 永远不会离开 server。** 传给 `digest.run` 的是环境变量的*名称*；daemon 从自己的进程环境读取值。项目的 `.drsg/env` 只保存名称，不保存值。
- **L3 是可选且异步的。** 设置 `--l3-chat` 后，`session_end` 会 detach 地启动提炼，因此结束会话不会等待 LLM 调用。失败会写入项目的 `.drsg/l3.log`。
- **Hook 会被覆盖，而不是合并。** 如果项目已有自己的 SessionStart hook，它会丢失。请先备份。
- **每个项目一份配置。** 每个 `.drsg/env` 都是独立的：不同项目可以使用不同的 L3 设置，也可以指向不同的 daemon。

## 通用交付闭环守卫（`completeness-guard.py`）

为所有接入项目提供的通用交付防遗漏守卫。
检查 git diff 中新增的对外可见名字（CLI 选项、环境变量、HTTP 路由、配置键），
并确保它们在项目文档中已有记录。

```bash
python3 completeness-guard.py                         # 检查当前工作区
python3 completeness-guard.py --staged                 # 检查暂存区（用于 pre-commit）
python3 completeness-guard.py --repo /path/to/project --base origin/main
python3 completeness-guard.py --json                  # 结构化输出
```

项目可通过根目录 `.completeness.json`（或 `.drsg/completeness.json`）声明配置，
将提示级发现提升为阻断提交的 pre-commit 错误。

它看哪些文件：名字只从 `.sh`、`.bash`、`.yml`、`.yaml`、`.py`、`.go` 和没有扩展名的脚本里抽，测试文件（`tests/`、`*_test.go`、`test_*.py` 等）一律不看；shell 的选项只认 `case` 分支标签。没写 `docs` 列表时，搜 `README*`、`*/README*.md` 和 `docs/**/*.md`。


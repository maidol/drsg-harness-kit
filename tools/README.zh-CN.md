# Claude Code 长期记忆层

[English](README.md)

> 当前仅支持 Claude Code。hook 契约（`SessionStart` / `UserPromptSubmit` / `SessionEnd` 以及 transcript 路径）和 `claude mcp add` 注册流程都属于 Claude Code；要移植到其他 harness，需要替换 `templates/hooks/` 以及 `install.sh` 中的相关调用，底层记忆层无需改变。两个 MCP server（`codegraph-router.py`、`mcp_events.py`）已经与 harness 无关，任何 stdio MCP 客户端现在都可以注册它们。

只需一条命令，即可把 Dr Strange 变成 Claude Code 项目的持久化跨会话记忆层：图会记住之前的会话结论，每个新会话都会从摘要而不是空白上下文开始。

整个系统由四个 Python hook、一个安装器和一个 daemon 控制脚本组成。不需要插件、不需要注册服务，也不会有数据离开本机。

## 代码图路由器与 usage report

运行时 bundle 包含 router 和 usage-report 二进制，但项目配置默认是可选的。使用 `codegraph-router-setup.sh` 配置 router MCP 访问，使用 `codegraph-usage-setup.sh` 配置 Stop hook 报告，或者使用显式的组合封装脚本 `codegraph-hub-setup.sh`。usage report 同时统计本地原生代码图调用和经由 router 的 `codegraph` 调用；它不会由 `install.sh` 或默认的 `setup.sh` 安装。

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

如果目标地址已经有进程响应 `/health`，`install.sh` 会**加入**它，而不是启动第二个 daemon。之后所有项目都会进入同一个 `memory` plane，由各自的 `Project` 节点区分，recall 也可以跨项目访问。加入需要该 daemon 的 token：

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
| `--token <t>` | 复用或生成 | 共享 API token；加入已有 daemon 时**必填** |
| `--l3-chat <name\|url>` | 空（关闭 L3） | preset 名称或兼容 OpenAI 的 base URL |
| `--l3-key-env <v>` | preset 自带的变量名 | 保存 LLM key 的环境变量**名称**（见下文） |
| `--l3-model <m>` | provider 自带的模型 | 与 endpoint 列出的内容完全一致的模型 id |
| `--l3-reasoning <e>` | 未设置 | `reasoning_effort`；`none` 可阻止 reasoning model 截断 JSON |
| `--restart-daemon` | 关闭 | 先停止已有 daemon（新 token 或新地址） |
| `--check` | 关闭 | 不安装任何内容；报告 hook 漂移，有漂移时退出 1（见下文） |

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

## 说明

- **LLM key 永远不会离开 server。** 传给 `digest.run` 的是环境变量的*名称*；daemon 从自己的进程环境读取值。项目的 `.drsg/env` 只保存名称，不保存值。
- **L3 是可选且异步的。** 设置 `--l3-chat` 后，`session_end` 会 detach 地启动提炼，因此结束会话不会等待 LLM 调用。失败会写入项目的 `.drsg/l3.log`。
- **Hook 会被覆盖，而不是合并。** 如果项目已有自己的 SessionStart hook，它会丢失。请先备份。
- **每个项目一份配置。** 每个 `.drsg/env` 都是独立的：不同项目可以使用不同的 L3 设置，也可以指向不同的 daemon。

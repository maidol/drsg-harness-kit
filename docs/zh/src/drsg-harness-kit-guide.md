# DrSG 接入工具包使用指南

> 本文内容：讲解工具包怎么工作、怎么安装、怎么打包。
> 脚本自身的选项以各脚本头注释和 `--help` 为准；
> 记忆层的详细说明见仓库根目录的 `tools/README.md`；它会随 bundle 一起发布，
> 所以装好的机器上同一份文件在 `~/.drsg-memory/tools/README.md`。

---

## 一、架构与工作原理

### 1.1 两个平面

| | 代码图（code plane） | 记忆层（memory plane） |
|---|---|---|
| 内容 | 插件从源码解析出的符号与边 | 应用层约定的 Project / Session / Fact / Event |
| 谁写 | `drsg serve watch`，随每次提交增量叠加 | hooks（自动）+ 模型按协议主动写（Fact/Event） |
| 粒度 | **每仓一个** daemon、数据库、端口、plane | **全局一个**共享 daemon 和数据库，按 Project 隔离 |
| 数据库 | `<repo>/graph.drsg`（native 后端是目录） | `~/.drsg-memory/memory.drsg` |
| 回答什么 | 这个符号是什么、改它影响什么、A 怎么走到 B | 过去得出过什么结论、别的 agent 要我做什么 |

native 后端**同一数据库只允许一个进程打开**，所以「全塞进一个进程」不是简化方案，
却把两套生命周期复杂化。两边的数据库、端口、token 从不共用。

![一台机器上的部署拓扑：记忆层一个全局 daemon，代码图每仓一个](./images/daemon-topology.svg)

两边是**方向相反**的：记忆层聚合（一个 daemon、一个库，按 `p.path` 分项目），
代码图独立（一仓一端口、一仓一库）。两个 daemon 都不开机自启，按需启动。

### 1.2 代码图怎么来的

`serve watch` 监听仓库的提交：每次提交，语言插件把源码折成 Function / Method / Struct /
Trait / Module / File 等节点和 CALLS / REFERENCES / USES_TYPE / IMPORTS 等边，写进该仓
自己的 plane，并记下 `synced_commit`。解析器识别不了的引用记录为 `UnresolvedRef`——**它把猜
测和已解析边分开，这是图敢说「没有」的前提**。

代价有两段，别归错因：插件是 wasm，**首次加载约 13.7 秒且与仓库大小无关**，之后叠加才按体量算（约 1.36 秒）。
所以正常启动走增量追平，只有换了插件集合才 `--force` 整库重建。

![代码图的工作原理：源码树经 wasm 插件折进 plane，动词从 plane 读，snippet 还要读文件树](./images/code-plane-architecture.svg)

图里那条区别对待的线值得单独记：**结构类动词（`context` / `impact` / `trace` /
`describe`）只查 plane，所以跨仓可用；`grep` 和 `snippet` 要读文件树，而文件树是
进程级的（`--dir` 指定），与调用是传的 `plane` 无关**。跨仓问结构没问题，
跨仓要源码就得问那个仓自己的 daemon。

### 1.3 七个动词与两条最容易违反的规矩

| 你要什么 | 动词 | 给你什么 |
|---|---|---|
| 这个符号是什么、谁调用它 | `context` | 定义、签名、一跳调用者/被调用者 |
| 改它 / 删它会影响谁 | `impact` | 沿入边扩散，**按距离分组并给出每组计数** |
| A 怎么走到 B | `trace` | 逐跳路径 |
| 签名和位置 | `describe` | 一次几百字符 |
| 给我源码 | `snippet` | 源码正文 |
| 日志文案、配置、注释等图不建模的文本 | `grep` | 被监视源树里的字面命中，每条命中报出所属符号 |
| 这个仓库图里有什么、同步到哪 | `describe_plane` | 动态目录（**计数不要写进文档，下一个提交就错**） |

两条规矩来自真实失误，不是风格建议：

1. **`impact` 的深度要加到某一层返回空。** 默认 3 跳，没停住就截断，得到的是「前三跳」，
   而且不同深度的两个符号不可比。实证：`Plugins::load` 在 depth 3 报 12，depth 5 报 15
   且第 5 层为空——少的 3 个不是不存在，是没走到。上限是 6；到 6 仍非空就按工具自己声明
   的「只数已记录的边，是下限」报告，不是终止。
2. **候选超过 20 就别从清单里挑。** 歧义清单截断到前 20 且**不按相关性排序**，`plugin`
   的 99 个候选里可见的 20 条有 6 个 CSS 类、1 个 npm 包，真正的加载器一次都没出现。
   收窄的写法是 `类型::方法`。候选 2–10 个时先 `describe` 看签名：**返回类型指向别的
   crate 就是包装层**，对包装层跑 `impact` 拿到的是源的真子集。

还有一条兜底：**图查不到要说图查不到**。`.sh` / `.md` / CI 配置、跨语言边界、
未提交的工作区都不在图里；这时用 `grep` 并说明它是兜底。

### 1.3.1 使用案例：定位符号并返回源码

假设用户提出：「给我 `searches` 的实现源码。」按下面的顺序调用，并且每次
都传入这个仓库实际使用的 plane：

```text
context("searches", plane="drsg-harness-kit")
grep(pattern="def searches", path="tools/codegraph-usage.py",
     context=2, plane="drsg-harness-kit")
snippet(name="tools/codegraph-usage.py:131-142", plane="drsg-harness-kit")
```

三次调用各自负责不同的事情：

| 调用 | 作用 | 本例结果 |
| --- | --- | --- |
| `context` | 把用户给的名称解析成代码图符号 | `codegraph-usage.searches`，位于 `tools/codegraph-usage.py:131-142` 的 `Function` |
| `grep` | 在受监视的源码树中确认文本定义 | 第 131 行命中 `def searches(cmd):` |
| `snippet` | 读取已经确认的源码范围 | 返回第 131–142 行的实现和文档字符串 |

`context` 提供符号身份和关系，`grep` 确认文本与位置，真正返回源码正文的
是 `snippet`。「3 calls」统计的是 MCP 调用次数，不是读取了三遍源码。

#### 不用代码图：纯文本搜索路径

如果不知道符号在哪个文件，不用代码图时要从文件系统开始：

```bash
rg -n --glob '*.py' '^def searches\(' .
sed -n '131,142p' tools/codegraph-usage.py
```

它的路径是：

```text
目录 → 文本匹配 → 文件和行范围 → 源码正文
```

文本搜索匹配的是字符，不是已经解析的符号。要找调用者，还得再搜一次，
然后人工排除函数定义、注释、文档字符串、字符串内容和无关的同名文本：

```bash
rg -n '\bsearches\s*\(' tools
```

#### 代码图增加了什么

代码图的路径是：

```text
符号名 → 规范 key → 结构关系与位置 → 源码正文
```

在这个例子里，`context` 把 `searches` 解析为 `codegraph-usage.searches`，
识别出它是 `Function`，并报告已记录的调用者 `codegraph-usage.main`。
`grep` 确认源码树中的文本，`snippet` 读取实现。

| 对比项 | 代码图 | 仅纯文本搜索 |
| --- | --- | --- |
| 输入 | 符号名 | 路径、目录或文本模式 |
| 符号身份 | 规范 key 和类型 | 只有文本命中 |
| 调用者与被调用者 | 从已记录的结构边返回 | 需要再次搜索并人工筛选 |
| 变更分析 | 可继续用 `impact` 或 `trace` | 手工追踪引用 |
| 适合场景 | 结构和关系 | 注释、配置、日志、未建模文件或代码图不可用时 |
| 主要限制 | 依赖 plane 新鲜度和解析器覆盖范围 | 可能误匹配或漏掉引用 |

如果文件和行范围已经知道，`sed` 更短。代码图多出的调用成本，只有在请求需要
可靠的符号身份或结构上下文，而不只是几行源码时才真正有价值。

### 1.4 router：一个入口，多个图

`codegraph-router.py` 是 MCP-to-MCP 转发器，不重实现任何动词。每次调用读 registry
（`~/.drsg-memory/graphs`，一行一个仓库路径，plane 名不等于目录名时用 TAB 补上），
按仓库名解析目标，从**那个仓自己的 `.mcp.json`** 读地址和 token（token 不复制到第二处），
必要时按需拉起该仓 daemon，再转发请求。对外 9 个工具：本地的 `graph_repos` 加 8 个转发动词。

![router 的结构：registry 只存路径，地址与 token 现读各仓自己的 .mcp.json](./images/codegraph-router-architecture.svg)

它解决的是「模型写错 `plane`」：默认 plane 是空的 `startup`，而空 plane 回的
`no symbol matches` 和实际没有是一样的。走 router，plane 来自 registry，可信。

**失败必须不可伪造**：registry 缺失、`.mcp.json` 读不到、daemon 起不来、上游报错，
都要报成错误，不能返回空列表冒充「图里没有」。

### 1.5 记忆层：四类节点，三种边，两条读路径

```text
Project ←BELONGS_TO← Session      每次会话一个
Project ←ABOUT←      Fact         可复用结论；没有这条边的 Fact 永远读不出来
Project ←NOTIFY←     Event        给另一个项目的待办；独立队列，不参与排名
```

- **Project 一律按 `p.path` 定位**，不要按 key（同名节点会遮蔽）。
- **Event 的 external key 用 `key(e)` 读**，写成 `e.key` 一条都匹配不上，却返回
  `props_set: 0` 且不报错——待办还开着，关闭看起来成功了。
- **时间一律 epoch 整数**。ISO 字符串不报错，但和现存整数比较会静默为假。

一次会话的生命周期：

```text
SessionStart      写/恢复 Session → 聚合出常驻简报 → 列出未处理 Event（≤3）→ 注入写记忆协议
UserPromptSubmit  按 n-gram+IDF 召回相关 Fact（≤4 条，可跨项目，标来源）→ 命中才注入 → 记遥测
compact           再跑一次 SessionStart 重新注入，不重复建 Session
SessionEnd        盖 ended_at，从 transcript 挖文件/命令/工具成败统计
Stop（可选）      代码图用量报告；不由记忆层安装器装，要单独注册
```

![一次会话的完整流程：启动注入、每轮召回、会话内写入、收尾，六条泳道](./images/memory-sharing-flow.svg)

图里值得单独看的是下面两条流程。**遥测**（`recall.jsonl`）命中与否都记一行，
这是后续判断召回有没有用的唯一依据；**跨项目**那条是 Event，它不走排名，
由终端直接提示（`systemMessage` 只给人看，模型看不见），
`events_seen.json` 保证同一条待办每会话只提示一次。任何一步 hook 失败都只是少注入，
不阻塞会话。

写入分三条通道：L1 是 hooks 挖的结构事实，L2 是**模型按协议自己写的 Fact**（价值在这里，
但它只是提示词，不强制），L3 是 transcript 蒸馏（**当前默认关停**，它写的实体没有读路径）。
读出只有两条：常驻简报（按项目隔离）和按 prompt 的召回（可跨项目）。

简报怎么构建（`session_start.py` 的 `all_facts` / `short_tag` / `build_briefing` / `ensure_briefing`）：
取本项目全部 Fact（`ORDER BY created_at DESC LIMIT 1000`）→ 每条按规则压成 ≤18 字符的标签
（有 `→` 只留右边的结论侧，取第一句，超长截断；不调模型）→ 按 `kind` 聚合成
`• <kind> ×<n>: tag; tag; …` → 存进 `Project.briefing`，**只在 Fact 数变化时重建**。

所以它压的是每条 Fact，不是总长度：**简报没有长度上限，随 Fact 数线性增长**，实测约
21 字符/Fact（本仓库遥测：26 条 Fact 时 536 字符，114 条时 2383 字符，另加固定 820 字符的协议）。
真正硬限的只有 Event 块的 3 条。两个推论：Fact 攒多了要自己清，而**改了某条 Fact 的正文却没改
总数时简报不会刷新**（缓存按计数失效）。

---

## 二、环境搭建与启用

### 2.1 前置条件

- 可运行的 `drsg` 二进制（带 `serve` / `/rpc` / `/mcp`）；
- Python 3、`curl`、`openssl`；
- Claude Code 或其他能注册 MCP 与 hooks 的 harness；
- 确认 loopback 端口没被占用，并想好备份策略。

### 2.2 装记忆层（全局共享）

```bash
tools/install.sh <project-dir> --bin <path-to-drsg> --addr 127.0.0.1:7700
```

它会：确保共享 daemon 在跑（没有就起）→ 复制 hooks 到 `<project>/.claude/hooks/` →
写 `<project>/.drsg/env`（chmod 600，只放地址、token 和 L3 变量**名**）→ 合并三个 hook 到
`settings.local.json` → 注册 `drsg` 和 `drsg-events` 两个 MCP → **自检**（daemon 可达、
plane 存在、Project 按 path 可定位、临时 Fact 能被召回查询读出），任一失败非零退出。

![装完之后的样子：项目里只有配置与遥测，daemon 和库全机唯一一份](./images/memory-sharing-architecture.svg)

分界线就是上图那两个框：**留在项目里的只有 `.drsg/env`（token，chmod 600，已 gitignore）、
hooks 和 `.drsg/recall.jsonl`**，每个项目一份且内容相同；daemon 和 `memory.drsg`
全机只有一份。所以加一个项目不会多一个 daemon，删一个项目也带不走别人的记忆。

**daemon 已经在跑时必须给它的 token**，否则装不进同一个库：

```bash
tools/install.sh <project-dir> --bin <path-to-drsg> \
  --addr 127.0.0.1:7700 --token "$DRSG_TOKEN"
```

注意：**hooks 是覆盖不是合并**，项目自己有 SessionStart hook 会丢，先备份。
`<memory-home>` 不要放进任何工作树。L3 保持关停，除非你明确要它（`--l3-chat`，且只传
key 的**变量名** `--l3-key-env`，值留在 daemon 侧）。

### 2.3 装代码图（每仓一个）

```bash
tools/codegraph.sh install --dir <repo-root> --port <port>
```

一次做完：没图就 `drsg init`，起 `serve watch`，把 sentinel 规则块写进该仓 CLAUDE.md，
注册 SessionStart 守卫。幂等。日常命令：

```bash
tools/codegraph.sh status  --dir <repo-root>
tools/codegraph.sh doctor  --dir <repo-root>   # plane 在不在、追到 HEAD 没、规则块过期没、守卫注册没
tools/codegraph.sh restart --dir <repo-root>   # 增量追平，约一秒
tools/codegraph.sh restart --dir <repo-root> --force   # 整库重建，见下
```

**`--force` 有一个会给出错误答案的窗口**（2026-08-20 毫秒级日志对齐）：前约 13.4 秒旧 plane
还能查，但答的是旧 commit（它会自报 `synced_commit`）；随后约 1.36 秒 plane 已 drop/create
但还没灌满。只在换插件集合时用它，别对 memory plane 用代码图脚本。

显式指定drsg二进制：

```bash
DRSG_CODE_BIN=<path-to-drsg> tools/codegraph.sh install --dir <repo-root> --port <port>
```

### 2.4 独立安装 router 和用量报告

router 和用量报告是两个独立的可选组件，不会因为安装记忆层或代码图而自动启用。

需要从 hub 项目跨仓访问代码图时，只装 router：

```bash
tools/codegraph-router-setup.sh <hub-project>
```

它注册 `codegraph` MCP（router）并核对 registry。`codegraph.sh install` 会自动追加仓库；只有未走
`install` 的仓，或 plane 名不等于目录名时才手工追加，**用 `>>`，不要用 `>`**：

```bash
printf '%s\n'     '<repo-a>'            >> ~/.drsg-memory/graphs
printf '%s\t%s\n' '<repo-b>' '<plane-b>' >> ~/.drsg-memory/graphs   # 真 TAB
```

需要在任何项目查看本地代码图用量时，单独装用量报告：

```bash
tools/codegraph-usage-setup.sh <project-dir>
```

它只注册 `Stop` hook，不注册 router，也不修改 MCP。一个报告工具同时统计本地 native
`mcp__drsg*` / `drsg-watch` 调用和 router 的 `mcp__codegraph__graph_*` 跨仓调用；两条路径共用同一份
报告，因此 hub 不需要 router 才能启用用量报告。用量报告是估算值（返回 token 带 `~`），调用次数精确。

如果确实需要两者，可以显式使用组合兼容入口：

```bash
tools/codegraph-hub-setup.sh <hub-project>
```

自定义 registry 必须传入 router 的注册配置；只在 shell 中 `export` 一次不够：

```bash
claude mcp add --scope local -e DRSG_GRAPHS=<registry-file> codegraph -- python3 <router-path>
```

### 2.5 验收清单

装完**重启会话**（hooks 和 MCP 只在启动时读），然后逐项确认：

```text
记忆层
[ ] /health 通，且带 Bearer token 的 /rpc 也通
[ ] memory plane 存在，Project 按 p.path 可定位
[ ] SessionStart 能注入简报（或明确的空结果）
[ ] UserPromptSubmit 有 recall 记录（<project>/.drsg/recall.jsonl）
[ ] SessionEnd 能写 ended_at
[ ] event_post / event_list / event_done 三步都验通
[ ] LLM key 的值没进项目配置、命令历史或文档
[ ] 只有一个进程打开 memory 数据库

代码图
[ ] graph 数据库与 memory 数据库不是同一个
[ ] doctor 通过：plane 存在、追到 HEAD、规则块写明了正确 plane
[ ] graph_repos 能列出仓库
[ ] 停掉某仓 daemon 时 router 报错，而不是返回空答案
[ ] snippet 的来源和目标 plane 的 synced_root 对得上
```

日常还有两条只读检查：`tools/install.sh --check`（各项目已部署 hooks 与
模板是否漂移，有漂移退 1，可当 CI 闸门）和 `analyze_recall.py`（召回利用率与成本；
**注意它有 45% 的随机底噪**，别裸读百分比）。

---

## 三、打包与一键安装

### 3.1 为什么需要打包

运行副本必须在**仓库之外**。这些脚本都被某个分支跟踪，签出别的分支就会把它们从工作区
删掉，连带 `drsg-events` 的 MCP 命令路径指空——而 MCP 注册指向的是一个**当时不存在**的文件。
所以 `~/.drsg-memory/tools/` 存一份运行副本，仓库里那份是源码。打包就是把「仓库里那份」
变成可以搬到另一台机器、并原样铺成运行副本的东西。

### 3.2 构建

```bash
./pack.sh               # 产出 dist/drsg-harness-kit-<version>.tar.gz 和 .sha256
./pack.sh --out /tmp/x --name my-kit
```

包内布局（`tools/` 就是 `~/.drsg-memory/tools/` 该有的样子）：

```text
drsg-harness-kit-<version>/
  setup.sh          一键安装（下一节）
  install-drsg.sh   没有二进制时从 GitHub release 装一个
  tools/            memory-layer 全套（含 templates/hooks）+ codegraph.sh
                    + codegraph-router.py + codegraph-usage.py
                    + codegraph-router-setup.sh + codegraph-usage-setup.sh
                    + codegraph-hub-setup.sh + drsg-usage-report + drsg_usage_report.py
  skills/           codegraph skill，装到 ~/.claude/skills
  MANIFEST          源 commit、构建时间、逐文件 sha256
```

`MANIFEST` 的用处是把「部署漂移了」和「本来就是另一个 commit 构建的」分开。

### 3.3 在新机器上安装

```bash
tar xzf drsg-harness-kit-<version>.tar.gz && cd drsg-harness-kit-<version>
./setup.sh --project /path/to/project --repo /path/to/repo --bin /path/to/drsg
# 可选，互相独立：--router /path/to/hub 或 --usage-report /path/to/project
```

五步必做 + 一步可选，每步幂等，任一失败即退出：

1. `tools/` 铺进 `${DRSG_MEM_DIR:-~/.drsg-memory}/tools` 并加执行位；
2. `skills/` 铺进 `~/.claude/skills`（`--no-skills` 跳过）；
3. 定位 drsg：`--bin` → PATH → `--fetch-drsg` 才联网下载（联网是外向动作，不默认替你做）；
4. `--project`：跑记忆层安装器（含自检）；
5. `--repo`：`codegraph.sh install --dir …`，带上刚定位到的二进制；
6. 可选，且只在显式指定时才做：`--router DIR`、`--usage-report DIR`，或 `--hub DIR`（两者都装）。
   `--project` / `--repo` 都不会推导出其中任何一个。

常用参数：`--addr` / `--token`（加入已有 daemon 必给）、`--port`（该仓代码图端口）、
`--tools-dir`（改运行副本位置）。装完**重启会话**，再照 2.5 验收。

### 3.4 升级

改的永远是仓库里的源码，然后重新 `pack.sh` 出包、重跑 `setup.sh`——本机和别的机器同一条路，
`setup.sh` 幂等，会覆盖运行副本并重跑安装器的自检。它不动数据库，也不会重启正在跑的
daemon——那要自己显式做，并且先确认没有写入在进行。

---

## 四、别踩的几条

- **token 不进版本库**；`.drsg/` 写进 `.gitignore`；LLM key 只传变量名。
- **一库一进程**：hooks 走 RPC，不要再用会直接开库的 CLI。
- **Fact 没有 `ABOUT` 边等于不存在**；Project 按 `p.path`，Event 按 `key(e)`，时间用 epoch 整数。
- **待办写成 Event 不要写成 Fact**——Fact 走排名制召回，排名输了就永远送不到。
- **`--force` 之前**确认 plane 名、数据库目录和备份；代码图脚本不要对 memory plane 用。
- **量化断言必须来自图**：「只有 X 处调用」「不影响别处」这类话出现在回答里，那一刻就是
  结构性问题，`context` 答不了影响面，要 `impact` 并把分组计数和它自己的下界声明一起带上。

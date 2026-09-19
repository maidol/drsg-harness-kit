---
name: codegraph
description: 运维由 drsg / drsg-watch MCP 工具使用的 dr-strange 代码图 daemon——诊断、重启、接入新仓库，并审计代码图是否真的被使用。当代码图工具异常或无响应时（`not found: plane`、明明存在的内容却出现 `no symbol matches`、工具完全没有返回，或 MCP server 已列出但不应答），当会话启动提示 daemon 已停止或 `doctor` 发现问题时，当需要为没有代码图的仓库完成配置时，当 `CLAUDE.md` 规则块需要重新生成或已过期时，以及当需要判断代码图使用量或是否产生价值时，都应使用本 skill。遇到“代码图坏了”“drsg 没响应”“为 <repo> 配置代码图”“重新生成规则”“到底有没有人在用”等说法时使用；当代码图调用静默失败、让人想退回 grep 时也必须使用，因为静默失败正是本 skill 要防止的情况。
---

# 运维代码图

本 skill 负责让代码图**保持运行且诚实**：daemon、插件生成的 plane、规则块、会话守卫和使用量审计。

**本 skill 不是代码图提问规则。** 那些规则无条件写在仓库的 `CLAUDE.md` 中，因为调用关系问题很少会明确说“这是结构问题”——等你想到加载 skill 时，往往已经凭印象回答了。不要把读过本文件当成读过那些规则，也不要在这里重复它们。完整说明由本仓库的 `tools/templates/codegraph-rules.md` 生成到各项目的 `CLAUDE.md` 中；中文翻译模板是 `tools/templates/codegraph-rules.zh-CN.md`，可通过 `CODEGRAPH_RULES_TEMPLATE` 选择。生成后的规则块就是完整的提问规则集，本 skill 不重复维护它。

## 从 `doctor` 开始

下面几乎所有症状都可以由同一条命令诊断，所以先运行它，再形成判断：

```bash
~/.drsg-memory/tools/codegraph.sh doctor --dir <repo>
```

它会向运行中的 daemon 检查六项内容，把每一项出错的都报出来之后再返回非零；因此也可以作为多个仓库循环检查的 gate：

| 输出项 | 失败含义 |
|---|---|
| `daemon` | 没有进程持有数据库 LOCK，或者 daemon 应答的地址与 `.mcp.json` 声明的不一致。 |
| `plane` / `synced` | plane 不存在，或折叠到的提交不是 `HEAD`——某个提交尚未被摄入。 |
| `root` | plane 是从另一个工作树解析出来的。 |
| `CLAUDE.md` | 没有代码图规则段，或者它写了错误的 plane/地址，硬编码了已经变化的计数，或由旧版规则生成。 |
| `guard` | `SessionStart` hook 缺失、重复注册，或指向的路径已经不存在。 |
| `skill` | 本 skill 没有安装到 `~/.claude/skills/codegraph/SKILL.md`（`setup.sh --no-skills` 会跳过安装），或没有 `codegraph-cli` 戳，或戳与 `codegraph.sh` 当前的子命令分发不一致。这一项按机器检查、不按仓库——重新拷贝 `skills/codegraph/`，或去掉 `--no-skills` 重跑 `setup.sh`。 |

这些失败项每一项都曾真实发生过。最值得单独强调的是：如果 plane 同步到了**另一个仓库**的工作树，所有查询都会自信地返回错误答案。

## daemon

每个仓库一个 daemon。命令形式为：`codegraph.sh {start|stop|restart|status|logs} --dir <repo>`。

有两个问题经常导致误判：

- **地址和 token 来自该仓库的 `.mcp.json`。** 不要为了“修复”连接而重新生成 token——这会使 `drsg init` 已经写入的所有客户端配置失效，问题只会转移而不会消失。
- **进程身份由数据库 LOCK 文件决定，而不是由命令行决定。** `drsg init` 启动的 daemon 在 `ps` 中显示为 `--dir .`，所以按仓库路径匹配不到它，然后误以为 daemon 已停止。

如果仓库本身没有构建 `drsg`，就没有可启动的二进制。因此 `restart` 会停止 daemon，却无法再次启动。脚本会记住上次使用的 `drsg`；这类仓库第一次启动时必须显式指定一个。

## 接入仓库

```bash
~/.drsg-memory/tools/codegraph.sh install --dir <repo>
```

一条命令完成全部工作：仓库从未被解析时运行 `drsg init`，启动 daemon，将规则块生成到仓库的 `CLAUDE.md`，并注册 `SessionStart` 守卫。

规则块是**生成的，不是复制的**。复制正是这里要防止的错误：第二个仓库接入代码图时继承了第一个仓库的规则块，包括 plane 名、端口和节点计数，之后所有调用都以 `not found: plane` 失败。直接从运行中的 daemon 读取的数字不会与 daemon 自身矛盾；由人维护的数字一定会过期。

如果 `CLAUDE.md` 已经手写了 `drsg-watch` 说明，`rules` 会报告这一点，并**保持原样**，不会再追加一个互相矛盾的段落。手写段落属于作者；保持它与工具同步需要人工完成，这是已知缺口。

## 规则块与版本标记

`codegraph.sh rules --dir <repo>` 会重新生成 `<!-- drsg-codegraph:begin -->` 标记之间的规则块。它被设计为**生成一次，之后不会自动刷新**，这样任何会话都不会改写 `CLAUDE.md` 并使 prompt 缓存失效。代价是内容可能无声过期，这正是版本标记存在的原因：

- `<!-- rules=<8 hex> -->`：签入的 `tools/templates/codegraph-rules.md` 模板的 hash，包含占位符但不包含占位符的实际值。使用同一份模板的所有仓库都会有相同标记；只有说明文字改变时它才改变，不需要人工记住递增。换用另一份模板（例如中文版）会得到另一个戳。
- 本 skill 中的 `<!-- codegraph-cli=<8 hex> -->`：`codegraph.sh` 子命令分发逻辑的 hash。如果新增、重命名或删除子命令，描述旧接口的文字就会失效，`doctor` 会报告这一点。

当 `doctor` 输出 `** rules <old>, generator is at <new> — regenerate **` 时，为该仓库重新运行 `rules`。当它指出本 skill 已过期时，更新 `SKILL.md`，并使用 `codegraph.sh` 报告的值刷新标记。

## 会话守卫

`codegraph.sh hook --dir <repo>` 会注册 `SessionStart` hook（`startup` 与 `resume`，约 0.4 秒）。它会重启已经停止的 daemon，并在终端中**明确报告**结果，包括重启失败的情况。

这条提示正是守卫存在的意义。没有它，MCP 工具会静默失败，整个会话会在无人知晓的情况下退化为 grep；曾经有一个仓库的代码图空转了三天。成功启动后，守卫还会运行 `doctor`，只有确实存在问题时才输出内容。

## 审计使用量

```bash
~/.drsg-memory/tools/codegraph-usage.py [--project X] [--verbose]
```

它从 transcript 中统计真实调用：命中、空回答和地址错误的分布，以及代码图工具明明可用时使用 grep 的频率。

阅读输出时要记住它的局限：**它只能证明代码图被查询过，不能证明代码图改变了答案。** 当前没有 suppression 对照组，因此命中率不是有效性比率。引用统计数字时必须同时说明这一点。

阅读原始数字时还要做两项调整：管道中的 `| grep` 过滤不是回避代码图，不应计为错失机会；并且只有形似符号的模式才会被列为候选。

## 访问其他仓库的代码图

代码图按仓库隔离，所以需要询问其他项目代码的项目（例如 review workspace）本身没有可直接使用的图。这正是 `codegraph-router.py` 的用途：一个 stdio MCP server，将多个注册 daemon 代理到一个 MCP 接口上。

```bash
claude mcp add --scope local codegraph -- \
  python3 ~/.drsg-memory/tools/codegraph-router.py     # 从项目目录运行
```

注册**停放位置**，不要注册 checkout 内的路径：这些脚本受分支跟踪，切换分支可能让脚本从工作树中消失，随后 server 会在一个完全没有提到分支的会话里报路径不存在。

- **Registry**：`~/.drsg-memory/graphs`（可由 `$DRSG_GRAPHS` 覆盖），每行一个仓库路径；当 plane 名称不等于目录名时，在路径后用 TAB 补充 plane 名。`codegraph.sh install` 会追加记录。registry 中**不保存**地址和 token——router 每次调用都读取各仓库自己的 `.mcp.json`，因此没有第二份会过期或泄露的 token。
- **daemon 停止是正常状态。** `SessionStart` 守卫只在目标仓库内部触发，因此从其他项目查询时 daemon 通常是停止的；router 首次使用时会按需启动（约 1 秒）并重试。启动失败时，它会用明确的错误返回，绝不会伪造空结果——这正是 router 的目的。
- `graph_repos` 是定位入口：显示已注册仓库、对应 plane、地址和当前运行状态；它没有副作用，也不会启动 daemon。`graph_describe_plane` 用于询问仓库整体，而不是某个符号；其他动词都需要先提供符号名。它也是获取计数的唯一来源，因为 cypher 子集不支持聚合。

只有确实需要跨仓访问的项目才应注册 router；已经运行自身 `drsg-watch` 的仓库，本身已有完整的 22 工具接口。

## 脚本所在位置

仓库中的 `tools/codegraph.sh` 和 `tools/codegraph-usage.py` 是**源文件**，它们会随发布包一起交付；`~/.drsg-memory/tools/` 中的是实际运行的副本，本 skill 指向的也是后者。

这不是重复维护。仓库副本受当前分支跟踪，切换到其他分支可能使它们从工作树消失，从而在会话中途带走工具；`~/.drsg-memory/tools/` 下的文件不受任何分支跟踪，正因如此才可以持续存在。

修改仓库副本后，应重新构建 bundle 并再次运行安装器来刷新运行时副本——这与新机器安装所走的是同一条路径，因此不会出现两套流程：

```bash
./pack.sh                   # 写入 dist/drsg-harness-kit-<version>.tar.gz
tar xzf dist/drsg-harness-kit-*.tar.gz -C /tmp && /tmp/drsg-harness-kit-*/setup.sh
```

`setup.sh` 是幂等的：会覆盖运行时副本、重新运行各安装器的自检，但不会触碰数据库。

改的是 `tools/templates/hooks/` 底下的东西时要加 `--project DIR`。不带参数的
`setup.sh` 只刷新 `~/.drsg-memory/tools/`，各项目自己的 `.claude/hooks/` 仍停在旧
副本上——那正是之后 `install.sh --check` 会报出来的 drift。

## 本机拓扑

端口和 plane 名从各仓库自己的 `.mcp.json` 中读取；下表只是方便理解的示意，不是事实来源：

| 仓库 | Plane | 地址 |
|---|---|---|
| `dr-strange` | `dr-strange` | `127.0.0.1:7701` |
| `<repo-b>` | `<repo-b>` | `127.0.0.1:7702` |

运行 `graph_repos` 查看当前机器实际注册的仓库列表。

memory layer 是另一个独立组件，运行在 `127.0.0.1:7700`，由自己的 controller（`~/.drsg-memory/tools/serve.sh`）管理——不要从这里重启它。

[English](SKILL.md)

<!-- codegraph-cli=fb626a69 — 用 `codegraph.sh doctor` 刷新；该命令会报告当前值 -->

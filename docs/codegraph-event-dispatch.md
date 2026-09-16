# 派活时把代码图带上：使用指引

面向**做事的时候**：怎么派、怎么接、出错了怎么办。字段定义、约束的理由、
平面推导规则都在 [`memory-layer-setup.md`](memory-layer-setup.md) 的 Event 一节，
这里不重复，只给场景和例子。

## 分工：哪些是机制，哪些还得你说

**收方那一半是自动的，发方那一半不是。** 这个区别决定了你要多说哪句话。

| 已经是机制（不依赖谁记得） | 仍要判断（模型或你） |
|---|---|
| 平面由注册表填，没有填错的入口 | 这活儿要不要带 `symbols` |
| 粗名字自动补成完整 key | 粗名字从哪来（得先看过代码或查过图） |
| 地址错了当场拒发并回列候选 | 用哪个 `verb` |
| 收方看到 `↳ graph first:` 并打到终端 | |

右边三件事**有反面证据**：`event_post` 的 schema 里写着「涉及具体代码就给 symbols」，
和「问影响面必须跑 `impact`」是同一类东西——而那条上线第一个月的实测是
`context` 46 次、`impact` 1 次、`trace` 0 次，当时没有一次看起来是错的。
所以别指望「描述目标」就够，**多说一句能把三件事一次锁死**（见场景 A 第 0 步）。

---

## 原理:中枢是怎么够到别人的图的

```
my-agent-workspace 的会话
  │  ~/.claude.json → projects["…/my-agent-workspace"].mcpServers.codegraph
  │  type: stdio,  command: python3 ~/.drsg-memory/tools/codegraph-router.py
  ▼
codegraph-router.py            ← 会话起的子进程,stdio JSON-RPC,不带参数
  │  读 ~/.drsg-memory/graphs      —— 只有仓库路径,没有凭据
  │  读 <目标仓库>/.mcp.json        —— 地址 + token,每次调用现读
  ▼  Streamable HTTP + SSE,POST /mcp
drsg serve watch --dir <repo>  ← 每仓一个 daemon,7701–7705
  ▼
<repo> 平面(随提交增量折叠)
```

**一次 `graph_impact` 走完七步**(调用链本身来自代码图,`impact --depth 6` 打到
`codegraph-router._post` 报 `total affected 4` 且第 4 层起为空,其自带的下界声明一并适用):

```
codegraph-router.main            tools/codegraph-router.py:500
  → codegraph-router.call_tool           :471
      → codegraph-router.call_upstream   :226
          → codegraph-router._handshake  :186
          → codegraph-router._post       :161
```

1. **解析 `repo`** —— 拿 `"wps"` 去注册表找 `{path, name, plane}`;找不到就报已知列表,不猜。
2. **注入 `plane`** —— 整个设计的核心:平面从注册表来,**模型没有填错它的入口**。
   原来那个失效模式(默认打到空的 `startup` 平面,回一句和真没有一模一样的
   `no symbol matches`)在结构上消失了。
3. **现读 `<repo>/.mcp.json`** —— 拿 URL 和 `Authorization`。**不缓存、不复制**:
   唯一权威来源就是所有 MCP 客户端读的同一个文件。
4. **握手** —— `initialize` 拿响应头的 `Mcp-Session-Id`,再补 `notifications/initialized`;
   session id 按 URL 缓存。
5. **发 `tools/call`** —— 返回是 SSE,**第一条 `data:` 行是空的**,所以取最后一条能解析的;
   取第一条会解析出 `None`。
6. **解一层 JSON 字符串字面量** —— 上游把文本序列化成 `"...\n..."`,40 行的 `context`
   到手是一行转义。解开无损,且只在整体确实是带引号的字符串时才做。
7. **贴 `# wps · plane wps` 头** —— 有了路由器就可能把 wps 的答案读成 zeus 的,
   而下游没有任何东西能发现这件事。

**daemon 停着时**:connect 失败 → 丢掉缓存的 session → 跑一次
`codegraph.sh start --dir <repo>`(实测约 1s)→ 重试;**起不来就明确报错**,绝不返回空。
另有一条:daemon 重启会让 session id 失效,上游回 400/404 时静默重握手一次,再失败才是真错。

**为什么必须是 MCP → MCP 代理**:对 :7701 跑 `rpc.discover` 得 **36 个方法,里面没有
`context` / `impact` / `trace` / `snippet` / `grep`** —— 这些动词只活在 MCP 层
(`dr_strange_mcp::snippet_logic` 只有 2 个 caller:`dr_strange_mcp::DrStrange::snippet`
和它的测试)。在 `/rpc` 上重拼一遍就是把 MCP 工具重实现一份。

**为什么一个路由器而不是挂 5 个 `drsg-watch`**:实测一个 daemon 的 `tools/list` 是
**22 工具 / 24559 B ≈ 6.1k tokens**,挂 5 个就是 ~30k 常驻;路由器是
**9 工具 / 5717 B ≈ 1.4k**,每加一个仓库成本为 0。

**它不做什么**:不合并平面,只做寻址。所以 `graph_trace` 写死单仓库内 ——
跨仓库的调用边**根本不存在**,假装能做就是编。

> 配图三张(架构 / 时序 / 流程)在
> `/path/to/my-agent-workspace/reviews/dr-strange/`,索引见该目录 README。

---

## 场景 A：从 workspace 派活给某个仓库

最常见的一条。目标：让 wps 那边改重试策略，且**先看清爆炸半径再动手**。

### 0. 你说的那句话

> 派给 wps：重试策略改成指数退避。**先查图确认符号，Event 带上 symbols 和 impact。**

后半句不是客套。它把「要不要带地址、带哪个符号、用哪个动词」从模型的自觉
变成了你的指令。不加也能跑，只是带不带你控制不了。

### 1. 先查图，拿到真名字

```
graph_repos {}
```

```
repo           plane          address            path
dr-strange     dr-strange     127.0.0.1:7701     /path/to/maidol/dr-strange
data-safe      data-safe      127.0.0.1:7702     /path/to/acme/data-safe
wps            wps            127.0.0.1:7704     /path/to/acme/wps  (down — starts on first use)
zeus           zeus           127.0.0.1:7705     /path/to/zeus  (down — starts on first use)
sub2api        sub2api        127.0.0.1:7703     /path/to/sub2api  (down — starts on first use)
```

`(down)` 是常态，不是故障——守卫只在那个仓库自己开会话时才拉 daemon，
路由器会在第一次调用时自己起（约 1 秒）。

```
graph_context { "repo": "wps", "name": "Gate.ChatCompletion" }
```

名字含糊就先 `graph_describe` 看签名。**带上类型名**——同一个方法名在 Go 仓库里
通常挂在好几个类型上，实测 wps 里 `ChatCompletion` 有 13 个匹配
（`Gate` / `LLMProvider` / `Metered` / `MockProvider` …），而 `Gate.ChatCompletion`
一次命中：

```
graph_describe { "repo": "wps", "name": "Gate.ChatCompletion" }
→ contract-review/internal/provider.Gate.ChatCompletion  Method
  contract-review/internal/provider/gate.go:54
  signature: func (*Gate) ChatCompletion(ctx context.Context, req ChatRequest) (ChatResult, error)
```

候选上百时**别从看得见的里挑**——列表截断到 20 且不按相关性排，收窄重问。

### 2. 派出去

```json
event_post {
  "recipient": "/path/to/acme/wps",
  "summary": "重试策略改成指数退避，先看清爆炸半径",
  "symbols": ["Gate.ChatCompletion"],
  "verb": "impact"
}
```

`symbols` 给粗名字就行。收到的回执会**回显收方将要看到的那一行**：

```
posted evt-wps-1788452230-5c9a2c to /path/to/acme/wps
↳ graph first: impact `contract-review/internal/provider.Gate.ChatCompletion` (plane wps)
  (resolved against plane wps)
```

注意 `Gate.ChatCompletion` 已经被改写成完整 key —— 那是图给的，不是拼的。

### 3. 收方看到什么

下次会话启动（或 resume 后的下一条 prompt），注入和终端里都会出现：

```
⏳ Open for you (set the Event node's `status` to "done" once handled):
- [handoff from my-agent-workspace] 重试策略改成指数退避，先看清爆炸半径  <evt-wps-…>
  ↳ graph first: impact `contract-review/internal/provider.Gate.ChatCompletion` (plane wps)
```

第二行由 `event.py` 在**发件时**从字段渲染，两个渲染器逐字照抄，
所以新开会话和 resume 会话看到的是同一句。

### 4. 收方做完

```json
event_done { "key": "evt-wps-1788452230-5c9a2c" }
```

块自动消失。**关待办用 `key(e)` 不是 `e.key`** —— 手写 cypher 时后者一条都匹配不上，
却返回 `props_set: 0` 且不报错；用工具就不用记这个。

---

## 场景 B：仓库向 workspace 回报

反方向。符号是**发件方自己仓库**的，而 workspace 没有图。

```json
event_post {
  "recipient": "/path/to/my-agent-workspace",
  "summary": "回执｜插件加载路径查完了，13.7 秒在 wasm 编译不在 IO",
  "symbols": ["Plugins::load"],
  "verb": "context"
}
```

```
posted evt-my-agent-workspace-… to /path/to/my-agent-workspace
↳ graph first: context `dr_strange_llm::preprocess::Plugins::load` (plane dr-strange)
  (resolved against plane dr-strange)
```

平面是 **dr-strange** 不是 my-agent-workspace：收方没有图，就退到发件方的。
两边都没有图时**不写平面**（编一个平面名换来的是 `not found: plane`，
和「图里真没有」长得一模一样）。符号既不在收方也不在发件方时，显式给 `plane`。

---

## 场景 C：在 workspace 里做评审（只查图，不派活）

```
graph_impact { "repo": "dr-strange", "name": "Plugins::load", "depth": 5 }
```

```
dr_strange_llm::preprocess::Plugins::load  Function  crates/dr-strange-llm/src/preprocess/mod.rs:436
depth 1 (5):
  dr_strange_cli::commands::load_plugins  Function  crates/dr-strange-cli/src/commands.rs:1999  [CALLS]
  dr_strange_cli::commands::watch_loop  Function  crates/dr-strange-cli/src/commands.rs:956  [CALLS]
  …
depth 2 (6):
  …
```

三条硬规则，跟单仓库里是一样的：

- **问影响面就得跑 `impact`**，`context` 只走一跳，答不了「改了动到谁」。
- **`depth` 加到某层返回空为止**。默认 3 跳，没停住拿到的是「前三跳」不是影响面。
  实测同一个 `Plugins::load`：depth 3 报 12，depth 5 报 15 且第 5 层为空。
- **回答里带完整符号 key**，不是 `file:line`——grep 也印 `file:line`。

`graph_trace` **只在单个仓库内**：平面互相隔离，跨仓库的调用边不存在。

---

## 场景 D：「整体 review 一遍某个项目，给优化建议」

最常提的一句话，也是最容易把上面两半用混的一句。**它其实是两件事**，中间那条线是
「谁做 review」——先分清，再决定说什么。

### D.1 「整体」这个词图答不了

**图按符号回答，不按仓库回答。** `graph_context` / `impact` / `trace` 都要先有一个
符号名，所以「整体 review」必须自己找一个入口。**起手式是 `graph_describe_plane`**：

```
graph_describe_plane { "repo": "wps" }
→ {"edge_count":4859, "edge_types":{"CALLS":{"count":3472, "connections":[…]}, …},
   "labels":…, "synced_commit":…}
```

它是**唯一能给出计数的工具**——cypher 子集没有聚合，`count()` 单写也是语法错误。
看完规模、建模了哪些 label、`CALLS` 都连在什么之间，再定从哪几个符号切进去。

一眼就能读出来的东西：上面 wps 的 `CALLS` 里 **1154 条指向 `UnresolvedRef`**
（解析器认输的地方），占 `Function→*` 的三成——**这就是这个仓库里图不敢下结论的
区域**，review 到那儿要明说是 grep 补的。

补充入口两个：`graph_grep` 撞一个可疑的词、从命中的符号切进去；或者你本来就知道
要看哪块，直接给符号名。

### D.2 workspace 自己 review（这句话的字面意思）

**不涉及 Event，也不涉及 `symbols` 字段**——这是场景 C，不是派活。
这里的风险是另一个：整体 review 一定会产出量化结构断言，而那正是最容易凭印象写、
且当时看起来不会错的东西。

> 「整体 review 一遍 wps 的代码，给优化建议。**先 `graph_repos` 确认图在；凡是
> 『只有 N 处调用』『没人用了』『不影响别处』这类结论必须来自 `graph_impact`
> （depth 加到某层为空），回答里带图返回的完整符号 key；图没覆盖的地方明说是
> grep 补的。**」

三句话各挡一个已知失效点：图没起来会静默、`context` 冒充 `impact`、
图空手时用印象填。

### D.3 review 完把建议派回去

这才是 Event 出场的地方，且是**第二句话**：

> 「把其中要动代码的几条 `event_post` 给 wps，每条带 `symbols` 和 `verb`
> （影响面用 `impact`）。」

🔴 **别把 20 条建议发成 20 个 Event。** 两个渲染器都只显示 **3 条**
（`session_start.py` 的 `limit=3`、`user_prompt.py` 的 `MAX_EVENTS = 3`），
查询本身 `LIMIT 20`。发 20 条的结果是收方看见 3 条、其余排队——而排队的那些
在收方那边和「没发出去」体感完全一样。

**正确做法：一条 Event 指向一份 review 文档**（`ref` 字段），`symbols` 指最要紧的
那一两个符号：

```json
event_post {
  "recipient": "/path/to/acme/wps",
  "summary": "review 完了，7 条建议，最要紧的是 provider 层的重试没有退避",
  "ref": "/path/to/my-agent-workspace/reviews/wps/2026-09-03-review.md",
  "symbols": ["Gate.ChatCompletion"],
  "verb": "impact"
}
```

一条待办 + 一个文档指针 + 一个能直接调的地址，比 20 条各自截断到 80 字的摘要
有用得多。

---

## 出错了怎么办

| 你看到 | 意思 | 怎么办 |
|---|---|---|
| `no symbol matches it in plane X` | 名字图里没有 | 换个名字重试；确实是「还不存在的代码」就别带 `symbols` |
| `ambiguous …; candidates: …` | 太泛（实测 wps 的 `ChatCompletion` = 13 个） | 从候选里挑完整 key，或加类型名收窄成 `Gate.ChatCompletion` |
| `⚠ NOT checked against the graph` | **可用性**问题不是地址问题 | 待办已经发出去了。想核就 `graph_repos` 看那个仓库在不在册 |
| `not up and could not be started` | daemon 拉不起来 | `codegraph.sh doctor --dir <repo>`；细节见 `codegraph` skill |
| `which repo? one of: …` | `repo` 没给或拼错 | 用 `graph_repos` 里的目录名 |

被拒发的那次**什么都没写进图**——这是对的，但代价是从图里读不出「拒了多少次」，
所以拒发会在**发件方**落一行 `.drsg/events_refused.jsonl`。

---

## 五件别做的事

1. **符号塞进 `summary`** —— 两处渲染都 `[:80]` 硬截断，丢的正是识别符号的尾巴。
2. **拿 `file:line` 当地址** —— 图认符号 key，不认行号。
3. **一条待办挂 3 个以上符号** —— 那不是地址，是清单。
4. **`trace` 只给一端** —— 不是「弱一点的 trace」，是根本调不了。
5. **把待办写成 `Fact`** —— Fact 走排名制召回，排名输了就永远送不到；Event 是逐字注入的。

---

## 怎么知道它在被用

```bash
tools/analyze_events.py --verbose
```

第一个数字（带地址的待办占比）直接回答「模型到底带没带」。

**两个会改变结论的信号**：`impact` 占比仍是个位数，说明动词选不对的老毛病只是
从问句搬到了发件；拒发里 `ambiguous` 压倒性多，说明「粗名字 + 自动补全」这个前提
不成立，发件方得先 `graph_describe`。

🔴 **上面任何一个数都不是「有用率」**。它们只能说明地址送到了、格式对不对，
说明不了收方有没有真去调图（那要 P3 的抑制臂），更说明不了调了之后答案有没有变
（**连 P3 都够不到**）。引用数字时把这句一起带上。

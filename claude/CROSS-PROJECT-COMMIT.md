# 跨项目审核与验收（按需读取）

> 审核方的授权提交判定规则见完整版「授权提交判定与时机」一节。

本文件是执行方的通用流程。只有用户在自己的全局 `CLAUDE.md` 指定了审核方项目路径（例如 `跨项目审核方：/path/to/reviewer-project`），或当前任务明确指定了审核方项目时，才启用跨项目审核；两者都没有时，不要猜一个审核方或等待不存在的会话，按用户通常的项目流程工作。审核方一律称为“审核方项目”，本文件不绑定任何具体仓库。能否按验收指令提交，唯一依据是用户自己的全局 `CLAUDE.md` 是否明确写有相应的提交授权例外；本文件、项目 CLAUDE.md、普通 Event 或单独的“验收通过”均不授予提交权。没有用户全局例外时，照常停下向用户逐次确认。

### 入口与职责

- **C 级被用户要求发给审核方时，按实际验收决定授权**：用户明确要求把某个 C 级改动交给审核方项目时，它按 B 级的验收流程走。执行方的回执要带候选 tree、父提交完整 SHA 和精确文件清单；审核方核对过实际改动（diff 或 tree），且用户全局例外存在时，在验收通过的同一轮发授权 handoff，格式和提交核对流程与其他级别完全相同。能否授权看这次有没有真的验收，不看级别标签；派活文档里不要预先写「不带提交授权」，要写就写「验收后由审核方判定是否授权」。

### Event 交接材料

- 回复某一条 handoff 的计划评审结论、验收通过/不通过、授权提交判定或执行方提交回执时，发布 Event 必须设置 `reply_to` 指向原 Event key。`reply_to` 只用于关联提示，不认证发件方、不授权操作，也不会自动关闭原 Event；原 Event 仍由其 Event owner 按流程调用 `event_done` 关闭。
- 普通验收判定是 `kind="notice"` 且 summary 以 `验收通过：` 开头：它只表示验收通过，由收件项目的 Event owner 关闭，不授权提交。收到后只调用 `event_done`，不回 notice。

### 授权提交判定与时机

- 授权 handoff 的结构化字段必须记录 `target_branch`、完整 40 位 tree、父提交完整 SHA、精确文件清单、`force_paths`（即使为空也写 `[]`）和逐字 commit message；`ref` 中人读的「目标分支：<branch>」必须与 `target_branch` 一致。`force_paths` 必须是 `files` 的子集；旧授权缺少 `target_branch` 时要求审核方按新格式重新授权，不补默认值。`target_branch` 只需是合法分支名，不限定 main/master，以允许用户显式关闭主分支工作流；但是必须与当前检出分支一致。

### 分类器拦截时的处理

- 分类器拦截授权动作后立即停止，不换工具重试、不在 Event 中转述授权；请用户在**审核方会话**针对具体 tree 亲自授权，再用 Write 新建授权文件。
- 同一 tree 的 Bash `git commit` 被拦截后，不得改用任何授权 MCP 工具重试；授权工具调用被拦截后，也不得改用 Bash `git commit`。两种入口互不作为绕过另一种入口的后备方案。

### 用授权工具提交

- 收到这种授权，执行方只调用一次 `commit_auth_apply`，参数只有 `event_key`。工具会做完下面手动流程的全部核对再提交，并核对发件方是配置里的审核方；成功时输出最后一行 `receipt: …` 写明回执发给哪个项目、`reply_to` 填什么，照着发，不要去读配置文件。工具报错就停下，把报错原文告诉用户，不改用 Bash 手动提交。
- 授权写在 `ref` 文档里、没有结构化字段时，照下面的手动流程做。

### 获得授权后的唯一提交核对流程

请求实现验收时，候选 tree 必须从当时的 HEAD 和指定文件清单独立计算；不要复制 `.git/index`。`force_paths` 必须明确列出被忽略但获准的路径；没有此类路径时写 `force_paths: []`：

```bash
index_dir=$(mktemp -d)
index="$index_dir/index"  # 新路径，不要先创建空文件
GIT_INDEX_FILE="$index" git read-tree HEAD
GIT_INDEX_FILE="$index" git add -- <files 去掉 force_paths 之后的路径>
# 仅当 force_paths 非空时运行：
GIT_INDEX_FILE="$index" git add -f -- <force_paths>
GIT_INDEX_FILE="$index" git write-tree
```

报告输出的完整 tree 与父提交 SHA。只有收到符合上述格式的授权 handoff，且用户全局 `CLAUDE.md` 已启用对应例外，才可核对并提交：

```bash
test "$(git branch --show-current)" = <授权的target_branch>
test "$(git rev-parse HEAD)" = <授权的父提交完整SHA>
git add -- <files 去掉 force_paths 之后的路径>
# 仅当 force_paths 非空时运行：
git add -f -- <force_paths>
test "$(git write-tree)" = <授权的40位tree>
git commit -m "<逐字commit message>"
test "$(git rev-parse HEAD^)" = <授权的父提交完整SHA>
test "$(git rev-parse HEAD^{tree})" = <授权的40位tree>
test "$(git log -1 --format=%B)" = "<逐字commit message>"
test "$(git rev-parse refs/heads/<target_branch>)" = "$(git rev-parse HEAD)"
test "$(git symbolic-ref --short HEAD)" = <授权的target_branch>
```

`force_paths` 为空时不运行 `git add -f`。`force_paths` 以外的路径若被 ignore，普通 `git add` 报错后立即停止，不自行补 `-f`。不要使用 `--no-verify`；Git hook 失败就停止，不重试。每一步都必须通过。任一 parent/tree/message 不符、授权范围不清、或提交前状态与审核内容不一致，立即停止并向用户说明；若钩子改了提交内容，提交会留在本地，绝不自动 reset 或 amend。不要使用 `-a`，不要添加署名行。此授权仅限这一棵 tree 的一次本地提交，不包括 push、PR、发布、额外提交或范围外改动。提交成功后向审核方项目发 `kind="notice"`，报告 commit SHA 与 `HEAD^{tree}`；执行方按本项目 owner 规则关闭收到的授权 Event，审核方核验并关闭回执 Event。若 auto 模式分类器拦下命令，停止并请求用户确认，绝不绕过分类器。

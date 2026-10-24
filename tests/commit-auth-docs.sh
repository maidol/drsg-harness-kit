#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
CONTENT_FAILS=0
check() {
  if ! grep -Fq -- "$2" "$REPO/$1"; then
    printf 'FAIL %s missing %s\n' "$1" "$2" >&2
    CONTENT_FAILS=$((CONTENT_FAILS + 1))
  fi
  return 0
}
check claude/CROSS-PROJECT-REVIEW.md '验收通过并授权提交'
check claude/CROSS-PROJECT-REVIEW.md '无用户全局例外'
check claude/CROSS-PROJECT-REVIEW.md 'force_paths'
check claude/CROSS-PROJECT-REVIEW.md 'target_branch'
check claude/CROSS-PROJECT-REVIEW.md 'symbolic-ref --short HEAD'
check claude/CROSS-PROJECT-REVIEW.md 'HEAD^'
check claude/AGENT-EFFICIENCY.md '~/.claude/CROSS-PROJECT-REVIEW.md'
check claude/AGENT-EFFICIENCY.md '收到/处理 handoff、设计或计划评审、验收协作/判定、请求协助：只读 `~/.claude/CROSS-PROJECT-EXECUTION.md`。'
check claude/AGENT-EFFICIENCY.md '收到提交授权并准备提交：只读 `~/.claude/CROSS-PROJECT-COMMIT.md`。'
check claude/AGENT-EFFICIENCY.md '承担审核方角色，或同一会话同时承担执行方和审核方角色：读 `~/.claude/CROSS-PROJECT-REVIEW.md` 完整版，不要求再读两份短文件。'
check claude/CROSS-PROJECT-EXECUTION.md '审核方专用规则见完整版「入口与职责」「授权提交判定与时机」「Event 交接材料」各节。'
check claude/CROSS-PROJECT-COMMIT.md '审核方的授权提交判定规则见完整版「授权提交判定与时机」一节。'
check claude/CROSS-PROJECT-EXECUTION.md '【成功标准】可观察、可判定的行为，逐条编号'
check claude/CROSS-PROJECT-COMMIT.md 'C 级被用户要求发给审核方时，按实际验收决定授权'
check claude/AGENT-EFFICIENCY.md 'commit_auth_apply'
check claude/AGENT-EFFICIENCY.md '验收通过并授权提交'
check README.md 'autoMode.allow'
check README.zh-CN.md 'autoMode.allow'
check README.md '授权 <项目> 提交 tree <前12位>'
check README.zh-CN.md '授权 <项目> 提交 tree <前12位>'
check claude/CROSS-PROJECT-REVIEW.md '--no-verify'
check claude/CROSS-PROJECT-REVIEW.md 'C 级被用户要求发给审核方时，按实际验收决定授权'
check claude/CROSS-PROJECT-REVIEW.md '能否授权看这次有没有真的验收，不看级别标签'
check claude/CROSS-PROJECT-REVIEW.md 'commit_auth_apply'
check claude/CROSS-PROJECT-REVIEW.md '审核方直接实现时'
check claude/AGENT-EFFICIENCY-TESTING.md 'old_string` 和 `new_string` 完全相同的 Edit 不要发'
check claude/AGENT-EFFICIENCY-TESTING.md '`old_string` 取能唯一定位的最短片段，一般一两行、80 个字符以内'
check claude/AGENT-EFFICIENCY-TESTING.md '文件里嵌着另一种语言时，不做细粒度 Edit'
check claude/AGENT-EFFICIENCY-TESTING.md '变异自检：每个变异要配一个只有那一道门拦得住的用例。'
check claude/AGENT-EFFICIENCY-TESTING.md '变异自检只跑对应的用例'
check claude/AGENT-EFFICIENCY-TESTING.md '算出候选 tree 之后就不再改文件'
check claude/AGENT-EFFICIENCY.md '挨得近的几处合成一个覆盖整段的 Edit'
check claude/AGENT-EFFICIENCY.md '这时不要凭记忆换个写法再发。先确认现状：用 Grep 搜你要加的新内容，或者 Read 那一段。'
check claude/AGENT-EFFICIENCY.md 'tree 没变，就不重做验证'
check claude/AGENT-EFFICIENCY.md '回归只跑受影响的测试'
check claude/AGENT-EFFICIENCY.md '先在父提交上单跑'
check claude/AGENT-EFFICIENCY.md '被权限检查拦下的命令，本会话不再重跑'
check claude/AGENT-EFFICIENCY.md '要审核方代跑的，本回合结束前发 `kind="handoff"`、`summary` 以 `请求协助：` 开头的 Event，写明卡在哪一步、要审核方做什么、当前 tree、拦截原文；只有用户本人能拍板的事才在终端里问用户。'
check claude/AGENT-EFFICIENCY.md '若 `event_post` 自身被分类器拦截，不重试或换工具；请用户在审核方会话代为发出请求。'
check README.md 'If `event_post` itself is blocked, do not retry or switch tools; ask the user to relay the request in the reviewer session.'
check README.zh-CN.md '若 `event_post` 自身被分类器拦截，不重试或换工具；请用户在审核方会话代为发出请求。'
if grep -Fq '停下，写明命令、当前 tree 和拦截理由原文，请审核方或用户代跑。' "$REPO/claude/AGENT-EFFICIENCY.md"; then
  printf 'FAIL claude/AGENT-EFFICIENCY.md retains the ambiguous terminal-only assistance rule\n' >&2
  CONTENT_FAILS=$((CONTENT_FAILS + 1))
fi
check claude/AGENT-EFFICIENCY.md '私钥的值不进任何输出'
check claude/AGENT-EFFICIENCY.md '可能带凭据的文件'
check claude/AGENT-EFFICIENCY.md '真实账号、邮箱、域名、主机名不进代码、测试、文档和提交'
check claude/AGENT-EFFICIENCY.md '/compact'
check claude/AGENT-EFFICIENCY.md '/clear'
check claude/AGENT-EFFICIENCY.md '压缩摘要'
check claude/AGENT-EFFICIENCY.md 'completeness-guard.py'
check claude/AGENT-EFFICIENCY.md 'affected-tests.py --base'
check claude/CROSS-PROJECT-REVIEW.md '只调用 `event_done`，不回 notice'
check claude/CROSS-PROJECT-REVIEW.md '挂起 handoff 时先发 notice，写明等待什么及满足条件后会做什么'
check claude/CROSS-PROJECT-REVIEW.md '本回合结束前用 `kind="handoff"`、summary 以 `请求协助：` 开头的 Event 发出'
check claude/CROSS-PROJECT-REVIEW.md '卡在哪一步'
check claude/CROSS-PROJECT-REVIEW.md '要审核方做什么（逐字命令或要改的文件）'
check claude/CROSS-PROJECT-REVIEW.md '当前完整 tree'
check claude/CROSS-PROJECT-REVIEW.md '原始拦截/错误文本（先脱敏密钥值）'
check claude/CROSS-PROJECT-REVIEW.md 'summary 以 `协助完成：` 开头'
check claude/CROSS-PROJECT-REVIEW.md '`reply_to` 指向原请求 Event'
check claude/CROSS-PROJECT-REVIEW.md '执行方的 Event owner 负责关闭原请求 Event'
check claude/CROSS-PROJECT-REVIEW.md '回复不代表用户授权，也不会自动关闭原 Event'
check claude/CROSS-PROJECT-REVIEW.md '不回显密钥或无关 transcript 内容'
check README.md 'AGENT-EFFICIENCY-TESTING.md'
check README.zh-CN.md 'AGENT-EFFICIENCY-OPERATIONS.md'
check README.md '### Reviewer assistance'
check README.md 'After upgrading, run `setup.sh --all-projects` once'
check README.md '3-second synchronous Stop reminder'
check README.md 'The hook never sends Events'
check README.zh-CN.md '### 审核方协助'
check README.zh-CN.md '升级后先运行一次 `setup.sh --all-projects`'
check README.zh-CN.md '3 秒同步 Stop 提醒'
check README.zh-CN.md 'Hook 不会自动发送 Event'
check tools/README.md 'AE1'
check tools/README.md '3,500 estimated tokens'
check tools/README.md 'python3 check-docs.py'
check tools/README.md 'prints the estimate'
check tools/README.zh-CN.md 'AE1'
check tools/README.zh-CN.md '3,500 tokens'
check tools/README.zh-CN.md 'python3 check-docs.py'
check tools/README.zh-CN.md '显示当前估算值'
if grep -q '^- 由来' "$REPO/claude/AGENT-EFFICIENCY.md"; then
  printf 'FAIL claude/AGENT-EFFICIENCY.md still has 由来 bullets; keep origins out of the distributed rules\n' >&2
  CONTENT_FAILS=$((CONTENT_FAILS + 1))
fi
check claude/CROSS-PROJECT-REVIEW.md '不适用验收授权例外'
check claude/AGENT-EFFICIENCY.md '不适用验收授权例外'
check claude/AGENT-EFFICIENCY.md '先 Read `~/.claude/AGENT-EFFICIENCY-TESTING.md`'
check claude/AGENT-EFFICIENCY.md '先 Read `~/.claude/AGENT-EFFICIENCY-OPERATIONS.md`'
if grep -q '^@' "$REPO/claude/CROSS-PROJECT-REVIEW.md"; then
  printf 'FAIL claude/CROSS-PROJECT-REVIEW.md must not contain @-imports; it is read on demand\n' >&2
  CONTENT_FAILS=$((CONTENT_FAILS + 1))
fi
check README.md 'decides per task whether to implement it directly'
check README.zh-CN.md '自己直接实现，或出完整设计、判据和实施计划交执行方实现'
check README.md 'When a test command or result occurs'
check README.zh-CN.md '测试命令或结果出现时'
check README.md 'AGENT-EFFICIENCY-TESTING.md'
check README.zh-CN.md 'AGENT-EFFICIENCY-TESTING.md'
check README.md 'AGENT-EFFICIENCY-OPERATIONS.md'
check README.zh-CN.md 'AGENT-EFFICIENCY-OPERATIONS.md'
check README.md 'CROSS-PROJECT-REVIEW.md'
check README.zh-CN.md 'CROSS-PROJECT-REVIEW.md'
check README.md '~/.claude/CROSS-PROJECT-EXECUTION.md'
check README.md '~/.claude/CROSS-PROJECT-COMMIT.md'
check README.md 'ls ~/.claude/CROSS-PROJECT-EXECUTION.md ~/.claude/CROSS-PROJECT-COMMIT.md ~/.claude/CROSS-PROJECT-REVIEW.md'
check README.zh-CN.md '~/.claude/CROSS-PROJECT-EXECUTION.md'
check README.zh-CN.md '~/.claude/CROSS-PROJECT-COMMIT.md'
check README.zh-CN.md 'ls ~/.claude/CROSS-PROJECT-EXECUTION.md ~/.claude/CROSS-PROJECT-COMMIT.md ~/.claude/CROSS-PROJECT-REVIEW.md'
check README.md '300000'
check README.zh-CN.md '300000'
check README.md '300k'
check README.zh-CN.md '300k'
check README.md 'The default retention is 72'
check README.zh-CN.md '72 小时'
check README.md '10 records'
check README.zh-CN.md '10 条'
check README.md 'DRSG_COMPACT_HANDOFF=0'
check README.zh-CN.md 'DRSG_COMPACT_HANDOFF=0'
check README.md '/clear'
check README.zh-CN.md '/clear'
check tools/README.md 'commit_auth_post'
check tools/README.md 'commit_auth_apply'
check tools/README.md 'target_branch'
check tools/README.md 'effective hooks directory'
check tools/README.md 'core.hooksPath=/dev/null'
check tools/README.md 'commit-auth.json'
check tools/README.md 'mcp__drsg-events__commit_auth_apply'
check tools/README.zh-CN.md 'commit_auth_post'
check tools/README.zh-CN.md 'commit_auth_apply'
check tools/README.zh-CN.md 'target_branch'
check tools/README.zh-CN.md 'Git 实际生效的钩子目录'
check tools/README.zh-CN.md '白名单'
check tools/README.zh-CN.md 'core.hooksPath=/dev/null'
check tools/README.zh-CN.md 'commit-auth.json'
check tools/README.zh-CN.md 'mcp__drsg-events__commit_auth_apply'
if [ "$CONTENT_FAILS" -ne 0 ]; then
  printf 'FAIL %d content check(s) failed\n' "$CONTENT_FAILS" >&2
  exit 1
fi
python3 - "$REPO/claude/AGENT-EFFICIENCY.md" "$REPO/claude/AGENT-EFFICIENCY-TESTING.md" "$REPO/claude/CROSS-PROJECT-REVIEW.md" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
testing = open(sys.argv[2], encoding="utf-8").read()
cross = open(sys.argv[3], encoding="utf-8").read()
e1 = """## Edit 失败：先看文件现状，再重发

- **发之前**：`old_string` 和 `new_string` 完全相同的 Edit 不要发，它什么也不改，只会报 `No changes to make`。一批 Edit 只放这一轮真正要改的地方；本会话里已经改成功的不要再发一遍，拿不准就先 Grep 新内容在不在。锚点从最近一次 Read 的原文里抄，不凭记忆写；同一批里前一处改过的文字，后一处不要再拿来当锚点。
- Edit 报 `String to replace not found`，或者报 `No changes to make: old_string and new_string are exactly the same`，说明你记得的文件内容和磁盘上的已经不一样了。最常见的原因是：这一处在前面某次 Edit 里已经改上了（同一轮里发了好几处 Edit，有的成功了）。
- 这时不要凭记忆换个写法再发。先确认现状：用 Grep 搜你要加的新内容，或者 Read 那一段。新内容已经在了，这一处就算完成，跳过；不在，就照 Read 到的原文重新取锚点。
- 报 `No changes to make`，一律说明文件已经是目标的样子，直接跳过，不要重发。
- 同一个文件连续两次 Edit 失败，必须先 Read 这个文件，再动手。
- 这和「Edit 成功就不要重读」不冲突：成功了不读，失败了必须读。"""
e7 = """## 旧测试被你的改动弄红了：先分清是行为错了，还是断言过时了

- 一条本来是绿的现有测试，被你的改动弄红了，先到父提交上单跑这一条。父提交上也红，就是老红，按「已知的老红」处理，不归这次改动管。
- 父提交上绿、这次红，再问一句：这条测试保护的**行为**，现在还成立吗？行为指的是拒绝还是放行、调用了几次、最后是什么状态、写进去的是什么内容。
  - **行为不成立**：改实现，不许动断言。
  - **行为成立**，只是附带的细节变了（报错措辞、几项检查的先后顺序、字段顺序），而且是计划或判定批准过的改动造成的：可以改这条断言。但只能改**值**，不能降低它的**强度**：不许删掉，不许放宽成 `in (...)`、`any(...)`、更短的正则或 `assertRaises(Exception)`；也不许为了迁就旧断言，去调换或撤回批准过的改动。
- 改过的每一条现有断言，都要在验收请求里列出来：在哪个文件第几行、旧的写法、新的写法、是哪条批准的改动造成的。没有列出来，就当作没改过；验收时如果发现改了却没列，判不通过。
- 分不清是哪一种，就停下来，把逐字的红原样贴给审核方，不要猜。"""
status = text.index("## 状态检查：")
verification = text.index("## 验证：")
context = text.index("## 上下文：")
e1_at = testing.index(e1)
testing_verification = testing.index("## 验证：")
e7_at = testing.index(e7)
assert status < verification < context
assert e1_at < testing_verification < e7_at
checklist = "改过的现有断言清单（没改过就写「无」）"
request = cross.index("- **实现验收请求**：")
next_item = cross.find("\n- ", request + 1)
assert checklist in cross[request:next_item]
PY
printf 'edit-failure rule content checks: passed\n'
printf 'commit-auth docs: all checks passed\n'

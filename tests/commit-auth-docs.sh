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
check claude/AGENT-EFFICIENCY.md '验收通过并授权提交'
check claude/AGENT-EFFICIENCY.md '无用户全局例外'
check claude/AGENT-EFFICIENCY.md 'force_paths'
check claude/AGENT-EFFICIENCY.md 'target_branch'
check claude/AGENT-EFFICIENCY.md 'symbolic-ref --short HEAD'
check claude/AGENT-EFFICIENCY.md 'HEAD^'
check README.md 'autoMode.allow'
check README.zh-CN.md 'autoMode.allow'
check README.md '授权 <项目> 提交 tree <前12位>'
check README.zh-CN.md '授权 <项目> 提交 tree <前12位>'
check claude/AGENT-EFFICIENCY.md '--no-verify'
check claude/AGENT-EFFICIENCY.md 'C 级被用户要求发给审核方时，按实际验收决定授权'
check claude/AGENT-EFFICIENCY.md '能否授权看这次有没有真的验收，不看级别标签'
check claude/AGENT-EFFICIENCY.md 'commit_auth_apply'
check claude/AGENT-EFFICIENCY.md '审核方直接实现时'
check claude/AGENT-EFFICIENCY.md 'old_string` 和 `new_string` 完全相同的 Edit 不要发'
check claude/AGENT-EFFICIENCY.md '`old_string` 取能唯一定位的最短片段，一般一两行、80 个字符以内'
check claude/AGENT-EFFICIENCY.md '文件里嵌着另一种语言时，不做细粒度 Edit'
check claude/AGENT-EFFICIENCY.md '变异自检：每个变异要配一个只有那一道门拦得住的用例。'
check claude/AGENT-EFFICIENCY.md '变异自检只跑对应的用例'
check claude/AGENT-EFFICIENCY.md '算出候选 tree 之后就不再改文件'
check claude/AGENT-EFFICIENCY.md '挨得近的几处合成一个覆盖整段的 Edit'
if grep -q '^- 由来' "$REPO/claude/AGENT-EFFICIENCY.md"; then
  printf 'FAIL claude/AGENT-EFFICIENCY.md still has 由来 bullets; keep origins out of the distributed rules\n' >&2
  CONTENT_FAILS=$((CONTENT_FAILS + 1))
fi
check claude/AGENT-EFFICIENCY.md '不适用验收授权例外'
check README.md 'decides per task whether to implement it directly'
check README.zh-CN.md '自己直接实现，或出完整设计、判据和实施计划交执行方实现'
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
python3 - "$REPO/claude/AGENT-EFFICIENCY.md" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
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
e1_at = text.index(e1)
e7_at = text.index(e7)
assert status < e1_at < verification
assert verification < e7_at < context
checklist = "改过的现有断言清单（没改过就写「无」）"
request = text.index("- **实现验收请求**：")
next_item = text.find("\n- ", request + 1)
assert checklist in text[request:next_item]
PY
printf 'edit-failure rule content checks: passed\n'
printf 'commit-auth docs: all checks passed\n'

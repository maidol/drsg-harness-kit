#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
check() {
  if ! grep -Fq -- "$2" "$REPO/$1"; then
    printf 'FAIL %s missing %s\n' "$1" "$2" >&2
    exit 1
  fi
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
python3 - "$REPO/claude/AGENT-EFFICIENCY.md" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
e1 = """## Edit 失败：先看文件现状，再重发

- Edit 报 `String to replace not found`，或者报 `No changes to make: old_string and new_string are exactly the same`，说明你记得的文件内容和磁盘上的已经不一样了。最常见的原因是：这一处在前面某次 Edit 里已经改上了（同一轮里发了好几处 Edit，有的成功了）。
- 这时不要凭记忆换个写法再发。先确认现状：用 Grep 搜你要加的新内容，或者 Read 那一段。新内容已经在了，这一处就算完成，跳过；不在，就照 Read 到的原文重新取锚点。
- 报 `No changes to make`，一律说明文件已经是目标的样子，直接跳过，不要重发。
- 同一个文件连续两次 Edit 失败，必须先 Read 这个文件，再动手。
- 这和「Edit 成功就不要重读」不冲突：成功了不读，失败了必须读。
- 由来：2026-09-21 到 10-10，本机 3531 次 Edit 里有 286 次（8.1%）是这两种失败，同一个文件不读就连续失败 3 次以上的有 16 回。10-10 kit 改 `tests/commit-auth.sh`，9 处 `target_branch` 早就加上了，仍然连发 7 次 Edit，全部失败。"""
e7 = """## 旧测试被你的改动弄红了：先分清是行为错了，还是断言过时了

- 一条本来是绿的现有测试，被你的改动弄红了，先到父提交上单跑这一条。父提交上也红，就是老红，按「已知的老红」处理，不归这次改动管。
- 父提交上绿、这次红，再问一句：这条测试保护的**行为**，现在还成立吗？行为指的是拒绝还是放行、调用了几次、最后是什么状态、写进去的是什么内容。
  - **行为不成立**：改实现，不许动断言。
  - **行为成立**，只是附带的细节变了（报错措辞、几项检查的先后顺序、字段顺序），而且是计划或判定批准过的改动造成的：可以改这条断言。但只能改**值**，不能降低它的**强度**：不许删掉，不许放宽成 `in (...)`、`any(...)`、更短的正则或 `assertRaises(Exception)`；也不许为了迁就旧断言，去调换或撤回批准过的改动。
- 改过的每一条现有断言，都要在验收请求里列出来：在哪个文件第几行、旧的写法、新的写法、是哪条批准的改动造成的。没有列出来，就当作没改过；验收时如果发现改了却没列，判不通过。
- 分不清是哪一种，就停下来，把逐字的红原样贴给审核方，不要猜。
- 由来：10-10 kit 加了分支 ref 检查后，重放先被这一项拦下，旧断言要的却是 HEAD 那条报错（行为对，措辞变了）；09-16 any-auto-register 一条断言被正确的改动作废了，可当时的通用禁令把唯一正确的做法也禁掉了；09-18 两条断言被改弱了，回执却没提；本机 09-21 到 10-10，测试跑红 862 次，其中 49 次紧接着就改了现有断言，少数是改弱了。"""
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

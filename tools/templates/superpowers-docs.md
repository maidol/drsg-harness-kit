<!-- drsg-memory:superpowers-docs:begin -->

将新建的 Superpowers 文档保存到审核方仓库：
- 设计文档：`{{SPECS_PATH}}`
- 实施计划：`{{PLANS_PATH}}`
- 手写评审回执、验收请求和验收回执：`{{ARCHIVE_PATH}}`

以上路径优先于 brainstorming / writing-plans 技能的项目内默认目录。只归档新文件；旧文件不迁移。测试脚本、补丁等在收方项目执行的文件仍留在收方项目。

新文件名应包含 Event/ticket 短标识；没有时使用 lane 名或短唯一后缀。目标已存在则更换后缀，不覆盖并行会话的文件。例如：`2026-10-24-test-speedup-evt5918d6-plan.md`。
<!-- drsg-memory:superpowers-docs:end -->

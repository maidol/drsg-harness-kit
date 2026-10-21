# Compact instructions

压缩时，除默认各节外，摘要必须单列一节「交接」，逐项写（某项没有就写「无」）；每项在交接顶层独占一行，字段标记原样保留并紧跟值分隔冒号：
- 计划、判据、设计文档的路径 [handoff:docs]：
- 当前分支，起点 tree 或起点提交 [handoff:origin]：
- 做到计划的第几步，这一步完成到哪 [handoff:progress]：
- 下一步要做的第一件事 [handoff:next]：
- 未解决的报错 [handoff:errors]：逐字原文（命令加输出的关键行），不要转述
- 用户的口头约束 [handoff:constraints]：逐字原文，每条标注「长期」或「仅本次」
- 改过但还没提交的文件清单 [handoff:files]：
<!-- handoff-aliases [handoff:docs]=Plan, criteria and design document paths; [handoff:origin]=Current branch, and starting tree or commit; [handoff:progress]=Plan step and progress; [handoff:next]=First thing to do next; [handoff:errors]=Unresolved errors (verbatim); [handoff:constraints]=User verbal constraints (verbatim, with scope); [handoff:files]=Files changed but not committed -->

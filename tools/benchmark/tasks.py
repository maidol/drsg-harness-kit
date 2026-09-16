"""A-group tasks: REAL accumulated memory (memory plane, project dr-strange).
Each task targets one existing Fact by external_key; ground truth is that
Fact's summary, fetched at run time (never duplicated here)."""

MEM_PLANE = "memory"
MEM_PROJ = "dr-strange"

# (tid, fact_key, question)
REAL_TASKS = [
    ("A01", "exp-one-process-per-db",
     "我们在其他项目里也装了这套记忆层,现在两个 agent 同时开会话,第二个报『database is locked』。以前总结过根因和正确做法,是什么?"),
    ("A02", "exp-mcp-not-in-release",
     "想用 drsg 的 /mcp 端点做 MCP 集成,但从官网下的发布版里没有。为什么?"),
    ("A03", "exp-cc-env-var-broken",
     "在这台机器上 cargo build 报 ring 编译失败,和某个环境变量有关,以前是怎么解决的?"),
    ("A04", "exp-cypher-return-last-var",
     "用 openCypher 查中间节点,报『unsupported query』,正确写法是什么?"),
    ("A05", "exp-token-required-everywhere",
     "为什么 hooks 的 curl 和 MCP 配置都必须带 Authorization: Bearer?"),
    ("A06", "exp-bm25-chinese",
     "中文 prompt 下 plane.hybrid 的 keyword 通道召回不到中文记忆,为什么,我们怎么解决的?"),
    ("A07", "exp-deepseek-reasoning-truncate",
     "L3 蒸馏调 DeepSeek 时 digest 报 truncate、要 300 秒,怎么修复的?"),
    ("A08", "exp-sessionend-hook-budget",
     "SessionEnd hook 为什么只能做一次 RPC、还要 2s 超时、失败无害?"),
    ("A09", "exp-digest-chat-url",
     "digest.run 要连自建的 OpenAI 兼容代理,chat 参数应该传什么?"),
    ("A10", "exp-write-memory-layers",
     "这套记忆层的「自动写有价值信息」分哪几层,各自要不要配 LLM key?"),
]

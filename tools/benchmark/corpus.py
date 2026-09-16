"""Synthetic project knowledge for the benchmark: acme-pay, a payment
processing service. Written by HAND (not LLM digest) so ground truth is fully
controlled. Facts live in the 'bench-acme' plane, isolated from real memory."""
import bench_lib as bl

PLANE = "bench-acme"
PROJ_KEY = "acme-pay"
PROJ_PATH = "/synthetic/acme-pay"

# (external_key, kind, summary) — summary is the ground truth.
ACME_FACTS = [
    # ---- constraint: 强约束,违反即事故
    ("acme-decimal", "constraint",
     "金额字段一律用 decimal(18,2),禁止 float——舍入误差会导致支付对账失败"),
    ("acme-timezone", "constraint",
     "所有时间戳统一存 UTC 的 ISO-8601,展示层才转本地时区,禁止存本地时间"),
    ("acme-idempotency", "constraint",
     "所有对外写接口必须支持 idempotency_key 去重,重试携带同一 key 不得产生重复扣款"),
    ("acme-money-atomic", "constraint",
     "扣款/入账必须单事务内原子完成,禁止先扣款后异步入账"),
    # ---- gotcha: 踩过的坑
    ("acme-gotcha-psql-float", "gotcha",
     "PG 里 float8 比较 == 不可靠,金额查询要用 numeric/decimal 或范围匹配,踩过对账不平的坑"),
    ("acme-gotcha-retry-amplify", "gotcha",
     "无 idempotency 时网关重试会把同一笔失败交易重放成多笔,线上事故一次"),
    ("acme-gotcha-dst", "gotcha",
     "用本地时间存订单时间在夏令时切换日会出现重复一小时/缺失一小时"),
    ("acme-gotcha-round-half", "gotcha",
     "折扣计算用 round-half-even 而非 round-half-up,否则与银行对账差 0.01"),
    # ---- decision: 架构决策
    ("acme-dec-queue", "decision",
     "异步任务(通知/对账)统一走 Redis Stream,不用数据库轮询——轮询在量上来后打爆主库"),
    ("acme-dec-k8s-hpa", "decision",
     "支付服务按 CPU+QPS 双指标 HPA,单指标在流量突刺时反应滞后"),
    ("acme-dec-saga", "decision",
     "跨服务事务用 Saga 补偿,不用 2PC——2PC 在部分参与者故障时锁死全局"),
    ("acme-dec-feature-flag", "decision",
     "新结算规则走 feature flag 灰度,禁止直接改线上逻辑再回滚"),
    # ---- dependency: 版本与依赖约束
    ("acme-dep-rust-msrv", "dependency",
     "Rust 服务最低 MSRV 1.85,CI 用 RUSTFLAGS=-D warnings,禁止引入需更高版本的依赖"),
    ("acme-dep-redis-ver", "dependency",
     "Redis 必须 ≥7.0 才能用 Stream 的 consumer-group 特性,升级前先确认版本"),
    ("acme-dep-psql-min", "dependency",
     "PG 必须 ≥14,JSONB 下标赋值与 MERGE 依赖该版本"),
    # ---- environment: 环境细节
    ("acme-env-prod-vnet", "environment",
     "生产支付服务只允许从内网 VPC 访问,公网入口必须经 WAF 网关"),
    ("acme-env-secret-env", "environment",
     "密钥只从环境变量注入,禁止写进配置文件或镜像层"),
    ("acme-env-canary-zone", "environment",
     "新版本先发 canary 区(5% 流量)观察 15 分钟再全量"),
]
assert len(ACME_FACTS) >= 18, "spec targets ~30 entries; add more as needed"

ACME_QUESTIONS = [  # (qid, fact_key, question)
    ("B01", "acme-decimal",
     "新同事在 acme-pay 里给交易金额字段选型,随手用了 float。请评价这个选择,项目里有相关约束吗?"),
    ("B02", "acme-timezone",
     "要加一个订单时间字段,同事准备直接存本地时间。这是否违反项目已有约定?"),
    ("B03", "acme-idempotency",
     "对接网关的扣款接口需要支持重试。重试时应该注意什么,项目里有什么硬性要求?"),
    ("B04", "acme-money-atomic",
     "设计一个「余额扣减 + 账本入账」的流程,事务应该怎么切分?"),
    ("B05", "acme-gotcha-psql-float",
     "线上对账不平,怀疑是金额查询条件的问题。在 PG 里查金额字段用什么方式才可靠?"),
    ("B06", "acme-gotcha-retry-amplify",
     "有一次线上事故是同一笔失败交易被重复扣了多次,根因可能是什么?"),
    ("B07", "acme-gotcha-dst",
     "日志里订单时间有重复的一小时,可能是什么导致的?"),
    ("B08", "acme-gotcha-round-half",
     "折扣金额与银行对账总差 0.01,应该检查哪里的舍入规则?"),
    ("B09", "acme-dec-queue",
     "要给「下单后发通知」加异步化,消息中间件 vs 数据库轮询选哪个,为什么?"),
    ("B10", "acme-dec-k8s-hpa",
     "支付服务要做自动扩缩容,HPA 指标怎么配才不容易被打穿?"),
    ("B11", "acme-dec-saga",
     "跨服务(支付→库存)一致性怎么保证,项目决策里推荐什么模式?"),
    ("B12", "acme-dec-feature-flag",
     "要上线一套新的结算规则,怎么低风险地灰度?"),
    ("B13", "acme-dep-rust-msrv",
     "CI 上报了一个 Rust 依赖需要更高 MSRV,应该怎么处理?"),
    ("B14", "acme-dep-redis-ver",
     "想用 Redis Stream 的 consumer-group,部署环境的 Redis 需要满足什么?"),
    ("B15", "acme-dep-psql-min",
     "准备用 PG 的 JSONB 下标赋值语法,需要确认什么前提?"),
    ("B16", "acme-env-prod-vnet",
     "生产支付服务要不要开放公网直连,项目对网络入口有什么要求?"),
    ("B17", "acme-env-secret-env",
     "部署时密钥应该放在哪里,项目对这个有明确的约定吗?"),
    ("B18", "acme-env-canary-zone",
     "新版本上线前项目默认的验证策略是什么,流程上有什么要求?"),
]
assert len(ACME_QUESTIONS) >= 18, "spec targets ~20 tasks; add more as needed"


def ensure_corpus(cfg):
    """Create the bench plane + write facts idempotently (by external_key)."""
    try:
        bl.rpc(cfg, "plane.create", {"name": PLANE})
    except Exception:
        pass  # already exists
    try:
        bl.rpc(cfg, "node.create", {"plane": PLANE, "key": PROJ_KEY,
                                    "labels": ["Project"],
                                    "properties": {"path": PROJ_PATH}})
    except Exception:
        pass  # exists
    created = 0
    for key, kind, summary in ACME_FACTS:
        try:
            bl.rpc(cfg, "node.create", {"plane": PLANE, "key": key,
                                        "labels": ["Fact"],
                                        "properties": {"kind": kind,
                                                       "summary": summary,
                                                       "created_at": 1786000000}})
            bl.rpc(cfg, "edge.create", {"plane": PLANE, "src": key,
                                        "dst": PROJ_KEY, "type": "ABOUT"})
            created += 1
        except Exception:
            pass  # idempotent — key already exists
    return created

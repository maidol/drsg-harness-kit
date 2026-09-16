"""Aggregate scores → BENCHMARKS-MEMORY.md + cost summary.

Usage: python3 report.py --scores out/scores-A.csv out/scores-B.csv \
            --raw out/raw.csv --out BENCHMARKS-MEMORY.md
"""
import argparse
import csv
import os
import statistics


def load(path):
    return list(csv.DictReader(open(path, encoding="utf-8")))


def group_rows(rows):
    by = {}
    for r in rows:
        by.setdefault(r["tid"], []).append(r)
    return by


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scores", nargs="+", required=True)
    ap.add_argument("--raw", default="out/raw.csv")
    ap.add_argument("--out", default="BENCHMARKS-MEMORY.md")
    args = ap.parse_args()

    score_rows = [r for p in args.scores for r in load(p)]
    raw_rows = load(args.raw)

    # ---- A group: recall hit rate ------------------------------------------
    a_rows = [r for r in score_rows if r["group"] == "A"]
    a_by = group_rows(a_rows)
    lines = ["# 记忆层价值 Benchmark",
             "",
             "## A 组 · 真实记忆召回(10 题)",
             "",
             "| 题 | no-mem | with-mem |",
             "|---|---|---|"]
    for tid in sorted(a_by):
        arm_hit = {r["arm"]: r["objective_hit"] == "1" for r in a_by[tid]}
        lines.append("| %s | %s | %s |" % (
            tid, "✅" if arm_hit.get("no-mem") else "❌",
            "✅" if arm_hit.get("with-mem") else "❌"))
    no_rate, with_rate = recall_stats(a_by)
    lines.append("| **命中率** | **{:.0%}** | **{:.0%}** |".format(no_rate, with_rate))
    # ---- B group: judge scores ---------------------------------------------
    b_rows = [r for r in score_rows if r["group"] == "B"]
    b_by = group_rows(b_rows)
    no, with_ = [], []
    for tid, rs in b_by.items():
        m = {r["arm"]: r["score"] for r in rs}
        if m.get("no-mem") not in (None, ""):
            no.append(float(m["no-mem"]))
        if m.get("with-mem") not in (None, ""):
            with_.append(float(m["with-mem"]))
    lines += ["", "## B 组 · 合成任务质量(LLM judge 1-5)",
              "",
              "| 统计 | no-mem | with-mem | Δ |",
              "|---|---|---|---|",
              "| 平均 | {:.2f} | {:.2f} | **{:+.2f}** |".format(
                  mean(no), mean(with_), mean(with_) - mean(no)),
              "| 中位 | {:.1f} | {:.1f} | {:+.1f} |".format(
                  median(no), median(with_), median(with_) - median(no)),
              ""]
    # ---- cost: characters + estimated tokens injected on the with-mem arm ----
    ctx = [int(r["ctx_chars"]) for r in raw_rows if r["arm"] == "with-mem"]
    if ctx:
        avg_chars = mean(ctx)
        # CJK ≈ 1 token/char; latin ≈ 1 token/3.5 chars; 1.5 is a conservative
        # mid-point for mixed Chinese/English briefing + recall text.
        lines += ["## 成本开销(有记忆臂注入)",
                  "",
                  "| 指标 | 值 |",
                  "|---|---|",
                  "| 平均注入字符数 | {:.0f} chars |".format(avg_chars),
                  "| 估算注入 tokens | ~{:.0f} |".format(avg_chars / 1.5),
                  ""]
    lines += ["## 结论与建议", "", "(人工撰写:见报告正文)"]
    open(args.out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("wrote", args.out)


def mean(xs): return statistics.mean(xs) if xs else 0.0
def median(xs): return statistics.median(xs) if xs else 0.0


def recall_stats(by):
    """(no-mem hit rate, with-mem hit rate) across tasks."""
    no = sum(1 for rs in by.values()
             if any(r["arm"] == "no-mem" and r["objective_hit"] == "1" for r in rs))
    wi = sum(1 for rs in by.values()
             if any(r["arm"] == "with-mem" and r["objective_hit"] == "1" for r in rs))
    return (no / len(by) if by else 0), (wi / len(by) if by else 0)


if __name__ == "__main__":
    main()

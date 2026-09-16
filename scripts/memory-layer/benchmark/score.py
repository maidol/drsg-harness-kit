"""Score the raw A/B outputs.

A-group (real recall): objective — recall_hit(output, ground-truth summary).
B-group (synthetic tasks): LLM judge — DeepSeek scores 1-5 against the
ground-truth, blinded to arm. Also exports a handful of samples for human
spot-check.

Usage:
  python3 score.py --raw out/raw.csv --out out/scores.csv
                   [--judge-model DeepSeek/deepseek-v4-flash]
                   [--manual-review out/manual_review.md] [--manual-n 6]
                   [--limit B]   # only score one group (faster)
"""
import argparse
import csv
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_lib as bl
import corpus

# external_key -> ground-truth summary for B-group (from the synthetic corpus).
GT_BY_KEY = {k: s for k, _kind, s in corpus.ACME_FACTS}


def objective_score(cfg, plane, output, fact_key):
    """A-group: hit iff output contains the ground-truth conclusion of the
    real memory-plane Fact identified by external_key (e.g. exp-*)."""
    n = bl.rpc(cfg, "node.get", {"plane": plane, "key": fact_key})
    gt = n.get("properties", {}).get("summary", "") if n else ""
    return bl.recall_hit(output, gt), gt


JUDGE_PROMPT = """你是严格的任务评分员。给下面的回答按 1-5 打分(整数)。

评分标准:
- 5: 准确引用/复现了参考答案里的关键结论,且表达正确完整。
- 4: 包含核心结论,略有遗漏或表述不精确。
- 3: 部分相关,但缺失关键点或含少量错误。
- 2: 泛泛而谈,基本没答到点子上。
- 1: 与参考答案无关或严重错误。

只输出一行 JSON: {{"score": <1-5整数>, "reason": "<一句话理由>"}}

【任务】{question}
【参考答案】{gt}
【待评分回答】{answer}
"""


def llm_judge(cfg, judge_model, question, gt, answer):
    msg = JUDGE_PROMPT.format(question=question, gt=gt, answer=answer)
    out = bl.chat(cfg, judge_model, [{"role": "user", "content": msg}],
                  max_tokens=200, temperature=0)
    try:
        return json.loads(out)["score"], out
    except Exception:
        return None, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default="out/raw.csv")
    ap.add_argument("--out", default="out/scores.csv")
    ap.add_argument("--judge-model", default="DeepSeek/deepseek-v4-flash")
    ap.add_argument("--manual-review", default="out/manual_review.md")
    ap.add_argument("--manual-n", type=int, default=6)
    ap.add_argument("--limit", choices=["A", "B"], default=None)
    args = ap.parse_args()

    cfg = bl.config()

    rows = list(csv.DictReader(open(args.raw, encoding="utf-8")))
    if args.limit:
        rows = [r for r in rows if r["group"] == args.limit]

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    out_f = open(args.out, "w", newline="", encoding="utf-8")
    w = csv.writer(out_f)
    w.writerow(["tid", "group", "arm", "score", "objective_hit", "gt"])

    manual = []  # for spot-check
    for r in rows:
        tid, group, arm = r["tid"], r["group"], r["arm"]
        out, q = r["output"], r["question"]
        gt_key = r["gt_key"]
        if group == "A":
            # ground truth fetched live from the REAL memory plane fact
            hit, gt = objective_score(cfg, r["plane"], out, gt_key)
            w.writerow([tid, group, arm, "", "1" if hit else "0", gt])
            if arm == "no-mem":
                print(f"[{tid}] hit={hit}", flush=True)
        else:
            # B-group ground truth from the synthetic corpus by external_key
            gt = GT_BY_KEY[gt_key]
            score, judge_out = llm_judge(cfg, args.judge_model, q, gt, out)
            w.writerow([tid, group, arm, score or "", "", gt])
            if arm == "no-mem":
                print(f"[{tid}] score={score}", flush=True)
        manual.append(r)
    out_f.close()

    # spot-check export: random sample, both arms
    random.seed(7)
    sample = random.sample(manual, min(args.manual_n, len(manual)))
    os.makedirs(os.path.dirname(args.manual_review) or ".", exist_ok=True)
    with open(args.manual_review, "w", encoding="utf-8") as m:
        m.write("# 人工抽检样本\n\n")
        for r in sample:
            m.write("## %s / %s\n\n**任务:** %s\n\n**回答:**\n\n%s\n\n---\n\n"
                    % (r["tid"], r["arm"], r["question"], r["output"]))
    print("wrote %s; spot-check → %s" % (args.out, args.manual_review))


if __name__ == "__main__":
    main()

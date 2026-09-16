"""Run the A/B benchmark. For each task, build two arms and call the subject
model: no-mem (prompt only) vs with-mem (prompt + real hook-replayed context).
Writes raw outputs to out/raw.csv.

Usage:
  python3 run_ab.py [--subject-model <id>] [--group A|B|all]
                     [--max-tasks N] [--out out/raw.csv]
Model discovery: default picks the first 'claude'-containing id from /v1/models.
"""
import argparse
import csv
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_lib as bl
import corpus
import tasks


def build_arms(cfg, plane, proj, question):
    """Two messages-lists for the same question (replays the real hook
    memory_context for the 'with-mem' arm)."""
    arms = {"no-mem": [{"role": "user", "content": question}]}
    ctx, ctx_chars = bl.memory_context(cfg, plane, proj, question)
    arms["with-mem"] = (
        [{"role": "system", "content": ctx}, {"role": "user", "content": question}]
        if ctx else arms["no-mem"])
    return arms, ctx_chars


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject-model", default=os.environ.get("DRSG_BENCH_SUBJECT", ""))
    ap.add_argument("--group", choices=["A", "B", "all"], default="all")
    ap.add_argument("--max-tasks", type=int, default=0)
    ap.add_argument("--out", default="out/raw.csv")
    args = ap.parse_args()

    cfg = bl.config()
    subject = args.subject_model or bl.discover_subject_model(cfg)
    print("subject model:", subject)

    created = corpus.ensure_corpus(cfg)  # idempotent
    if created:
        print("corpus: created %d new acme-pay facts" % created)
    else:
        print("corpus: already present")

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    f = open(args.out, "w", newline="", encoding="utf-8")
    w = csv.writer(f)
    # gt_key lets score.py fetch each task's ground-truth Fact by external_key.
    w.writerow(["tid", "group", "plane", "proj", "question", "gt_key", "arm",
                "ctx_chars", "output", "subject_model", "ts"])
    n_done = 0
    rows = []

    def run_one(tid, group, plane, proj, question, gt_key):
        nonlocal n_done
        arms, ctx_chars = build_arms(cfg, plane, proj, question)
        for arm, msgs in arms.items():
            out = bl.chat(cfg, subject, msgs)
            rows.append([tid, group, plane, proj, question, gt_key, arm,
                         ctx_chars, out, subject, int(time.time())])
            print(f"[{tid}/{arm}] {len(out)} chars", flush=True)
        n_done += 1

    if args.group in ("A", "all"):
        for tid, fk, q in tasks.REAL_TASKS:
            if args.max_tasks and n_done >= args.max_tasks:
                break
            run_one(tid, "A", tasks.MEM_PLANE, tasks.MEM_PROJ, q, fk)
    if args.group in ("B", "all"):
        for qid, fk, q in corpus.ACME_QUESTIONS:
            if args.max_tasks and n_done >= args.max_tasks:
                break
            run_one(qid, "B", corpus.PLANE, corpus.PROJ_KEY, q, fk)

    w.writerows(rows)
    f.close()
    print("wrote %d rows → %s" % (len(rows), args.out))


if __name__ == "__main__":
    main()

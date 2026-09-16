"""Zero-dependency tests for the benchmark modules. Run: python3 test_bench.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_lib as bl


def _run_all():
    """Zero-dep runner: executes every test_* function in this module."""
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print("PASS", name)
            except AssertionError as e:
                failures += 1
                print("FAIL", name, "-", e)
            except Exception as e:
                failures += 1
                print("ERROR", name, "-", repr(e))
    if failures:
        print("%d failure(s)" % failures)
        sys.exit(1)
    print("all tests passed")


def test_est_tokens():
    assert bl.est_tokens("a" * 40) == 10          # 4 chars/token for latin
    assert bl.est_tokens("中文" * 40) == 80        # 1 token per CJK char


def test_recall_hit_match():
    gt = "dr-strange native 后端同一数据库只允许一个进程打开,记忆层用单个共享 drsg serve"
    good = "根因是 native 后端同一数据库只允许一个进程打开,必须用单个共享 drsg serve 进程"
    bad = "我建议重新审视需求,先补充单元测试覆盖边界情况"
    assert bl.recall_hit(good, gt) is True
    assert bl.recall_hit(bad, gt) is False


def test_recall_hit_empty_gt():
    assert bl.recall_hit("anything", "") is None


import corpus


def test_corpus_integrity():
    facts = dict((k, s) for k, _kind, s in corpus.ACME_FACTS)
    assert len(corpus.ACME_FACTS) == len(set(k for k, _k, _s in corpus.ACME_FACTS))
    kinds = [k for _k, k, _s in corpus.ACME_FACTS]
    assert {"constraint", "gotcha", "decision", "dependency", "environment"} <= set(kinds)
    # every question's fact must exist
    for qid, fk, _q in corpus.ACME_QUESTIONS:
        assert fk in facts, f"{qid} references missing fact {fk}"
        assert len(_q) > 20, f"{qid} question too short"


def test_corpus_distinct():
    # ground truths must be pairwise distinct (else A/B is uninformative)
    summaries = [s for _k, _k2, s in corpus.ACME_FACTS]
    assert len(set(summaries)) == len(summaries)


if __name__ == "__main__":
    _run_all()

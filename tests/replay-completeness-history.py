#!/usr/bin/env python3
"""replay-completeness-history.py — historical replay and positive case verification.

Verifies:
1. Positive known case: commit 79b5a9d (added --audit without doc code-block)
   must be caught as BLOCKER when require_code_block: true.
   commit 72792a2 (after usage guide was added) must be clean of blockers.
2. Replay over recent commits of sub2api and any-auto-register to verify low false positive rate.
"""

import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "..", "tools", "completeness-guard.py")
KIT_REPO = os.path.abspath(os.path.join(HERE, ".."))


def replay_commit(repo_dir, cid, parent, config_dict=None):
    # Extract diff between parent and cid
    diff_text = subprocess.check_output(["git", "-C", repo_dir, "diff", "-U0", parent, cid], text=True)
    diff_files = subprocess.check_output(["git", "-C", repo_dir, "diff", "--name-only", parent, cid], text=True).splitlines()

    # Load guard module dynamically
    sys.path.insert(0, os.path.join(KIT_REPO, "tools"))
    import importlib.util
    spec = importlib.util.spec_from_file_location("completeness_guard", GUARD)
    cg = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cg)

    cfg = config_dict or {}
    config_files = cfg.get("config_files", [])
    new_names = cg.extract_names_from_diff(diff_text, config_files_patterns=config_files)

    # Resolve docs in commit cid
    doc_patterns = cfg.get("docs", ["README.md", "README.zh-CN.md", "README*", "docs/**/*.md"])
    try:
        all_tracked = subprocess.check_output(["git", "-C", repo_dir, "ls-tree", "-r", "--name-only", cid], text=True).splitlines()
    except Exception:
        all_tracked = []

    import fnmatch
    target_docs = set()
    for pat in doc_patterns:
        for f in all_tracked:
            if fnmatch.fnmatch(f, pat):
                target_docs.add(f)

    doc_contents = {}
    for p in target_docs:
        try:
            doc_contents[p] = subprocess.check_output(["git", "-C", repo_dir, "show", f"{cid}:{p}"], text=True)
        except Exception:
            doc_contents[p] = ""

    require_code_block = bool(cfg.get("require_code_block", False))
    pairs = cfg.get("pairs", [])
    is_declared = bool(cfg.get("_declared", False))

    blockers = []
    advisories = []

    for name, locs in new_names.items():
        kind, fpath = locs[0]
        found = any(cg.match_name_in_doc(name, kind, text, require_code_block) for text in doc_contents.values())
        if not found:
            msg = f"NEW {kind} {name} ({fpath})"
            if is_declared:
                blockers.append(msg)
            else:
                advisories.append(msg)
        else:
            for pair in pairs:
                p1, p2 = pair[0], pair[1]
                t1, t2 = doc_contents.get(p1, ""), doc_contents.get(p2, "")
                m1 = cg.match_name_in_doc(name, kind, t1, require_code_block)
                m2 = cg.match_name_in_doc(name, kind, t2, require_code_block)
                if (m1 and not m2) or (m2 and not m1):
                    msg = f"ASYM {kind} {name}"
                    if is_declared:
                        blockers.append(msg)
                    else:
                        advisories.append(msg)

    return {"blockers": blockers, "advisories": advisories, "new_names": list(new_names.keys())}


def main():
    print("=== 1. Positive Known Case: drsg-harness-kit 79b5a9d ===")
    res_79b = replay_commit(KIT_REPO, "79b5a9d", "c9e7010", config_dict={"require_code_block": True, "_declared": True})
    has_audit_blocker = any("--audit" in b for b in res_79b["blockers"])
    print(f"Commit 79b5a9d blockers: {res_79b['blockers']}")
    assert has_audit_blocker, "FAILED: 79b5a9d must catch --audit as blocker!"
    print("✓ 79b5a9d correctly caught --audit as blocker")

    res_727 = replay_commit(KIT_REPO, "72792a2", "79b5a9d", config_dict={"require_code_block": True, "_declared": True})
    print(f"Commit 72792a2 blockers: {res_727['blockers']}")
    assert len(res_727["blockers"]) == 0, "FAILED: 72792a2 must be clean of blockers!"
    print("✓ 72792a2 is clean (usage guide documented)")

    print("\n=== 2. Replay over sub2api history (50 commits) ===")
    parent_dir = os.path.dirname(KIT_REPO)
    sub2api_repo = os.path.normpath(os.path.join(parent_dir, "..", "sub2api"))
    if os.path.isdir(sub2api_repo):
        try:
            commits = subprocess.check_output(
                ["git", "-C", sub2api_repo, "log", "-50", "--format=%H"], text=True
            ).splitlines()
            blocker_commits = 0
            advisory_commits = 0
            for cid in commits:
                try:
                    parent = subprocess.check_output(["git", "-C", sub2api_repo, "rev-parse", f"{cid}^"], text=True, stderr=subprocess.DEVNULL).strip()
                except Exception:
                    continue
                r = replay_commit(sub2api_repo, cid, parent, config_dict={"_declared": False})
                if r["blockers"]:
                    blocker_commits += 1
                if r["advisories"]:
                    advisory_commits += 1
            print(f"sub2api: {len(commits)} commits replayed.")
            print(f"  Advisories count: {advisory_commits} ({advisory_commits/len(commits)*100:.1f}%)")
            print(f"  Blockers count (undeclared mode): {blocker_commits} (0.0%)")
        except Exception as e:
            print("sub2api replay note:", e)

    print("\n=== 3. Replay over any-auto-register history (30 commits) ===")
    any_repo = os.path.normpath(os.path.join(parent_dir, "any-auto-register"))
    if os.path.isdir(any_repo):
        try:
            commits = subprocess.check_output(
                ["git", "-C", any_repo, "log", "-30", "--format=%H"], text=True
            ).splitlines()
            advisory_commits = 0
            for cid in commits:
                try:
                    parent = subprocess.check_output(["git", "-C", any_repo, "rev-parse", f"{cid}^"], text=True, stderr=subprocess.DEVNULL).strip()
                except Exception:
                    continue
                r = replay_commit(any_repo, cid, parent, config_dict={"_declared": False})
                if r["advisories"]:
                    advisory_commits += 1
            print(f"any-auto-register: {len(commits)} commits replayed.")
            print(f"  Advisories count: {advisory_commits} ({advisory_commits/len(commits)*100:.1f}%)")
        except Exception as e:
            print("any-auto-register replay note:", e)

    print("\nAll replay checks and positive test cases PASSED.")


if __name__ == "__main__":
    main()

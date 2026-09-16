#!/usr/bin/env python3
"""Refuse to ship strings that only make sense on one machine.

The kit was scrubbed once by hand on its way upstream — machine-specific
absolute paths and internal repository URLs were replaced with placeholders.
A cleanup done once by hand is a cleanup that rots, so it gets a gate.

Usage:  python3 tools/check-no-machine-paths.py [paths...]   (default: whole repo)
        python3 tools/check-no-machine-paths.py --history    (every commit)

Exit 0 clean, 1 hits found, 2 an argument could not be read. Add a deliberate
exception to ALLOW below.

Two things this gate learned the hard way:

- A path it cannot open is a FAILURE, not something to skip. Passing a
  directory — the obvious thing to do, and what the usage line invites — used
  to report `clean: 1 files` and exit 0 while reading nothing at all.
- The working tree being clean says nothing about the history. Machine paths
  entered this repository in one commit and left in a later one, so every
  tree-only check passed while `git log -p` still had them. `--history` is the
  half that looks there.
"""
import os
import re
import subprocess
import sys

PATTERNS = [
    (r"/" + "data/projects", "本机项目根"),
    (r"/home/[a-z][a-z0-9_-]*/", "本机家目录"),
    (r"\buniin\b", "内部组织名"),
    (r"github\.com/(?!acme/)[a-z0-9_-]+/(?!dr-strange\b)", "真实仓库路径"),
    (r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b(?<!127\.0\.0\.1)", "硬编码 IP"),
    (r"\b[0-9a-f]{32}\b", "疑似 token"),
]
ALLOW = {
    # 路径 -> 允许的原因。留空 dict 表示没有例外。
}
SKIP_DIRS = {".git", "__pycache__", "logs", "dist", "node_modules"}


def git(*args):
    result = subprocess.run(["git"] + list(args), capture_output=True)
    if result.returncode:
        error = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError("git %s failed: %s" % (" ".join(args), error))
    return result.stdout


def skipped_dir(path):
    return any(part in SKIP_DIRS for part in path.split(os.sep))


def files(argv):
    """Expand arguments to a file list, plus the ones that could not be read.

    Returning the unreadable ones rather than dropping them is the whole
    point: a typo and a directory both used to arrive here as "nothing to
    scan", which is indistinguishable from "nothing wrong".
    """
    if not argv:
        out = git("ls-files").decode("utf-8", "replace")
        return [f for f in out.split("\n") if f], []

    picked, bad = [], []
    for arg in argv:
        if os.path.isdir(arg):
            for root, dirs, names in os.walk(arg):
                dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
                picked += [os.path.join(root, n) for n in names]
        elif os.path.isfile(arg):
            picked.append(arg)
        else:
            bad.append(arg)
    return picked, bad


def scan(text, where, hits):
    for lineno, line in enumerate(text.split("\n"), 1):
        for pat, why in PATTERNS:
            if re.search(pat, line):
                hits.append((where, lineno, why, line.strip()[:100]))


def scan_worktree(argv):
    paths, bad = files(argv)
    if bad:
        for b in bad:
            print("cannot read: %s" % b, file=sys.stderr)
        print("\n%d 个参数读不进来。守卫不会跳过读不了的路径——"
              "那正是它上一次漏掉一整个仓库的方式。" % len(bad), file=sys.stderr)
        return 2, []

    hits, read, skipped = [], 0, 0
    for f in paths:
        if skipped_dir(f) or f in ALLOW:
            skipped += 1
            continue
        try:
            with open(f, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError) as error:
            print("cannot read: %s (%s)" % (f, error), file=sys.stderr)
            return 2, []
        read += 1
        scan(text, f, hits)

    report(hits)
    if hits:
        return 1, hits
    print("clean: %d files scanned, %d skipped" % (read, skipped))
    return 0, hits


def scan_history():
    """Every blob in every commit, not just the ones still in the tree."""
    commits = git("rev-list", "--all").decode().split()
    if not commits:
        print("no commits", file=sys.stderr)
        return 2, []

    hits, blobs = [], {}
    for commit in commits:
        for entry in git("ls-tree", "-r", commit).decode(
                "utf-8", "replace").split("\n"):
            if not entry.strip():
                continue
            meta, path = entry.split("\t", 1)
            sha = meta.split()[2]
            if skipped_dir(path) or path in ALLOW:
                continue
            blobs.setdefault(sha, (commit, path))

    for sha, (commit, path) in blobs.items():
        raw = git("cat-file", "blob", sha)
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        scan(text, "%s:%s" % (commit[:7], path), hits)

    report(hits)
    if hits:
        return 1, hits
    print("clean: %d commits, %d distinct blobs" % (len(commits), len(blobs)))
    return 0, hits


def report(hits):
    for where, n, why, line in hits:
        print("%s:%d  [%s]  %s" % (where, n, why, line))
    if hits:
        print("\n%d 处机器相关字符串。改掉，或在 ALLOW 里写明理由。" % len(hits))


def main():
    argv = sys.argv[1:]
    try:
        if "--history" in argv:
            if len(argv) > 1:
                print("--history 不接别的参数", file=sys.stderr)
                return 2
            code, _ = scan_history()
            return code
        code, _ = scan_worktree(argv)
        return code
    except RuntimeError as error:
        print("cannot inspect git history: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

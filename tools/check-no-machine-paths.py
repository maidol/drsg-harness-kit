#!/usr/bin/env python3
"""Refuse to ship strings that only make sense on one machine.

The kit was scrubbed once by hand on its way upstream — machine-specific
absolute paths and internal repository URLs were replaced with placeholders.
A cleanup done once by hand is a cleanup that rots, so it gets a gate.

Usage:  python3 tools/check-no-machine-paths.py [paths...]   (default: whole repo)
Exit 1 and prints every hit. Add a deliberate exception to ALLOW below.
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


def files(argv):
    if argv:
        return argv
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout
    return [f for f in out.split("\n") if f]


def main():
    hits = []
    for f in files(sys.argv[1:]):
        if any(part in SKIP_DIRS for part in f.split(os.sep)):
            continue
        if f in ALLOW:
            continue
        try:
            with open(f, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        for lineno, line in enumerate(text.split("\n"), 1):
            for pat, why in PATTERNS:
                m = re.search(pat, line)
                if m:
                    hits.append((f, lineno, why, line.strip()[:100]))
    for f, n, why, line in hits:
        print("%s:%d  [%s]  %s" % (f, n, why, line))
    if hits:
        print("\n%d 处机器相关字符串。改掉，或在 ALLOW 里写明理由。" % len(hits))
        return 1
    print("clean: %d files" % len(files(sys.argv[1:])))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check the shipped documentation against the repository it documents.

Every check here is one finding that a reader actually hit: a command that
cannot run from the directory the document names, a filename that does not
exist, a count that disagrees with the code, a link that escapes the book.

Usage:  python3 tools/check-docs.py          (from the repository root)
Exit 0 all pass, 1 any fail, 2 could not read the repository.
"""
import os
import re
import subprocess
import sys

FAILS = []


def tracked_md():
    out = subprocess.run(["git", "ls-files", "*.md"], capture_output=True)
    if out.returncode:
        print("cannot list tracked files — run this from the repository root", file=sys.stderr)
        raise SystemExit(2)
    return [p for p in out.stdout.decode().split("\n") if p]


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def check(tag, ok, detail):
    print(f"  {'pass' if ok else 'FAIL'}  {tag:<5} {detail}")
    if not ok:
        FAILS.append(tag)


def section(text, heading):
    """The body between `heading` and the next same-or-higher heading."""
    lines = text.split("\n")
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == heading)
    except StopIteration:
        return None
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("## "):
            return "\n".join(lines[start:j])
    return "\n".join(lines[start:])


def main():
    docs = tracked_md()
    body = {p: read(p) for p in docs}

    hits = [f"{n}: {l.strip()}" for n, l in enumerate(body["tools/README.md"].split("\n"), 1)
            if "python3 tools/" in l]
    check("B1", not hits, "tools/README.md commands are relative to tools/"
          + ("" if not hits else f" — {len(hits)} use a repo-root path: {hits[0]}"))

    for tag, path, count_phrase, first_phrase in [
            ("B3en", "skills/codegraph/SKILL.md", "It checks six things", "on the first that is wrong"),
            ("B3zh", "skills/codegraph/SKILL.zh-CN.md", "检查六项内容", "在第一项错误时返回非零")]:
        t = body[path]
        check(tag, count_phrase in t and "| `skill` |" in t and first_phrase not in t,
              f"{path}: six checks, a `skill` table row, no 'first that is wrong'")

    hits = [f"{p}:{n}" for p in docs for n, l in enumerate(body[p].split("\n"), 1)
            if re.match(r"^pack\.sh(\s|$)", l)]
    check("N1", not hits, "no bare `pack.sh` as a command"
          + ("" if not hits else f" — {len(hits)} at {', '.join(hits)}"))

    hits = [p for p in docs if "drsg-usage-report(.py)" in body[p]]
    check("N2", not hits, "bundle layout names real files"
          + ("" if not hits else f" — `drsg-usage-report(.py)` does not exist, in {', '.join(hits)}"))

    hits = [f"{p}:{n}" for p in docs if "/src/" in p
            for n, l in enumerate(body[p].split("\n"), 1) if "](.." in l]
    check("N3", not hits, "no mdBook link escapes src/"
          + ("" if not hits else f" — {', '.join(hits)}"))

    t = body["skills/codegraph/SKILL.zh-CN.md"]
    stale = [s for s in ("同一生成器", "模板区域", "样本上限") if s in t]
    check("N5N6", not stale, "SKILL.zh-CN.md has no superseded wording"
          + ("" if not stale else f" — still says {', '.join(stale)}"))

    for tag, path, heading in [
            ("N7a", "README.md", "## Refresh the runtime copies"),
            ("N7b", "README.zh-CN.md", "## 刷新运行时副本"),
            ("N7c", "skills/codegraph/SKILL.md", "## Where these scripts live"),
            ("N7d", "skills/codegraph/SKILL.zh-CN.md", "## 脚本所在位置")]:
        sec = section(body[path], heading)
        ok = sec is not None and "--project" in sec and ("hooks" in sec or "hook" in sec)
        check(tag, ok,
              f"{path} {heading!r} says --project is what refreshes deployed hooks"
              + ("" if sec is not None else " — HEADING NOT FOUND"))

    fence = "`" * 3
    hits = []
    for p in docs:
        fenced = False
        for n, l in enumerate(body[p].split("\n"), 1):
            if l.lstrip().startswith(fence):
                fenced = not fenced
                continue
            if not fenced and "/path/to/" in l and "reviews/" in l:
                hits.append(f"{p}:{n}")
    check("N8", not hits, "no dangling /path/to/…/reviews/ pointer"
          + ("" if not hits else f" — {', '.join(hits)}"))

    missing = set()
    for p in docs:
        for m in re.finditer(r"tools/[A-Za-z0-9_./-]+\.(?:sh|py|md|json|example)", body[p]):
            if not os.path.exists(m.group(0)):
                missing.add(f"{p}: {m.group(0)}")
    check("GEN1", not missing, "every tools/<file> named in a doc exists"
          + ("" if not missing else f" — {len(missing)}: {sorted(missing)[0]}"))

    broken = set()
    for p in docs:
        for m in re.finditer(r"\]\((?!https?:|#)([^)#]+)", body[p]):
            target = os.path.normpath(os.path.join(os.path.dirname(p), m.group(1)))
            if not os.path.exists(target):
                broken.add(f"{p} -> {m.group(1)}")
    check("GEN2", not broken, "every relative doc link resolves"
          + ("" if not broken else f" — {len(broken)}: {sorted(broken)[0]}"))

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED: {', '.join(FAILS)}")
        return 1
    print("all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check the shipped documentation against the repository it documents.

Every check here is one finding that a reader actually hit: a command that
cannot run from the directory the document names, a filename that does not
exist, a count that disagrees with the code, a link that escapes the book,
or newly added CLI options/tools missing code-block examples in documentation.

Usage:  python3 tools/check-docs.py [--base <rev>]   (from the repository root)
Exit 0 all pass, 1 any fail, 2 could not read the repository.
"""
import argparse
import os
import re
import subprocess
import sys

FAILS = []
OPT_RE = re.compile(r'(?<![\w-])--[a-z][a-z0-9-]*')


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


def extract_shell_options(content):
    res = set()
    for m in re.finditer(r'^\s*([a-zA-Z0-9_|*?-]*--[a-z0-9_-]+[a-zA-Z0-9_|*?-]*)\)', content, re.MULTILINE):
        branch = m.group(1)
        for part in branch.split('|'):
            part = part.strip()
            if part.startswith('--'):
                res.add(part)
    return sorted(res)


def extract_py_options(content):
    res = set()
    for m in re.finditer(r'add_argument\(\s*["\'](--[a-z0-9_-]+)["\']', content):
        res.add(m.group(1))
    return sorted(res)


def extract_script_options(rel_path, content=None):
    if content is None:
        if not os.path.exists(rel_path):
            return []
        with open(rel_path, encoding="utf-8") as f:
            content = f.read()
    if rel_path.endswith(".py"):
        return extract_py_options(content)
    elif rel_path.endswith(".sh"):
        return extract_shell_options(content)
    return []


def extract_code_blocks(doc_content):
    """Extract fenced code blocks (``` or ~~~)."""
    blocks = []
    # Match ``` or ~~~ fences
    pattern = re.compile(r'^(```|~~~)[^\n]*\n(.*?)\n\1', re.MULTILINE | re.DOTALL)
    for m in pattern.finditer(doc_content):
        blocks.append(m.group(2))
    return "\n".join(blocks)


def get_base_rev(explicit_base=None):
    if explicit_base:
        return explicit_base
    # Check origin/main
    try:
        res = subprocess.run(
            ["git", "rev-parse", "--verify", "origin/main"],
            capture_output=True, text=True
        )
        if res.returncode == 0:
            mb = subprocess.check_output(
                ["git", "merge-base", "HEAD", "origin/main"],
                text=True
            ).strip()
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
            if mb != head:
                return mb
            return "HEAD"
    except Exception:
        pass

    try:
        subprocess.check_output(["git", "rev-parse", "--verify", "HEAD~1"], text=True)
        return "HEAD~1"
    except Exception:
        return "HEAD"


def get_git_file_content(rev, path):
    try:
        return subprocess.check_output(
            ["git", "show", f"{rev}:{path}"],
            text=True, stderr=subprocess.DEVNULL
        )
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(description="Check documentation against codebase.")
    parser.add_argument("--base", help="Git revision to compare against for new options/tools.")
    args = parser.parse_args()

    docs = tracked_md()
    body = {p: read(p) for p in docs}

    hits = [f"{n}: {l.strip()}" for n, l in enumerate(body["tools/README.md"].split("\n"), 1)
            if "python3 tools/" in l]
    check("B1", not hits, "tools/README.md commands are relative to tools/"
          + ("" if not hits else f" — {len(hits)} use a repo-root path: {hits[0]}"))

    for tag, path, count_phrase, first_phrase in [
            ("B3en", "skills/codegraph/SKILL.md", "It checks six things", "on the first that is wrong"),
            ("B3zh", "skills/codegraph/SKILL.zh-CN.md", "检查六项内容", "在第一项错误时返回非零")]:
        t = body.get(path, "")
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

    t = body.get("skills/codegraph/SKILL.zh-CN.md", "")
    stale = [s for s in ("同一生成器", "模板区域", "样本上限") if s in t]
    check("N5N6", not stale, "SKILL.zh-CN.md has no superseded wording"
          + ("" if not stale else f" — still says {', '.join(stale)}"))

    for tag, path, heading in [
            ("N7a", "README.md", "## Refresh the runtime copies"),
            ("N7b", "README.zh-CN.md", "## 刷新运行时副本"),
            ("N7c", "skills/codegraph/SKILL.md", "## Where these scripts live"),
            ("N7d", "skills/codegraph/SKILL.zh-CN.md", "## 脚本所在位置")]:
        sec = section(body.get(path, ""), heading)
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

    # ==================== COV0 - COV4 Gates ====================
    base_rev = get_base_rev(args.base)

    # 1. Script to Docs Mapping
    script_doc_mapping = [
        ("setup.sh", ["README.md", "README.zh-CN.md"]),
        ("tools/install.sh", ["tools/README.md", "tools/README.zh-CN.md"]),
        ("tools/codegraph.sh", ["tools/README.md", "tools/README.zh-CN.md"]),
    ]
    if os.path.isdir("tools"):
        for f in sorted(os.listdir("tools")):
            if f.endswith(".py") and f not in ("check-docs.py", "check-no-machine-paths.py"):
                script_doc_mapping.append((f"tools/{f}", ["tools/README.md", "tools/README.zh-CN.md"]))

    # 2. Read baseline
    baseline_file = "tools/doc-coverage-baseline.txt"
    baseline_entries = set()
    if os.path.exists(baseline_file):
        with open(baseline_file, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    baseline_entries.add(line)

    # COV0: Every option must be mentioned in mapped docs (table or body), unless exempted by baseline.
    # Baseline is strictly decremental (no extra or stale entries).
    cov0_violations = []
    baseline_stale = []
    active_script_opts = {}

    for script_path, doc_paths in script_doc_mapping:
        opts = extract_script_options(script_path)
        active_script_opts[script_path] = opts
        for opt in opts:
            if opt in ("--help", "-h"):
                continue
            item = f"{script_path}:{opt}"
            # Check if mentioned in both docs
            mentioned = True
            for d in doc_paths:
                content = body.get(d, "")
                if not re.search(re.escape(opt) + r'(?![\w-])', content):
                    mentioned = False
                    break

            if mentioned:
                if item in baseline_entries:
                    baseline_stale.append(f"{item} is documented but remains in baseline (should be removed)")
            else:
                if item not in baseline_entries:
                    cov0_violations.append(f"{script_path} option {opt} is unmentioned in {doc_paths} and not in baseline")

    for item in sorted(baseline_entries):
        parts = item.split(":", 1)
        if len(parts) == 2:
            sc, op = parts
            if op not in active_script_opts.get(sc, []):
                baseline_stale.append(f"{item} in baseline does not exist in script {sc}")

    cov0_ok = not cov0_violations and not baseline_stale
    cov0_details = "all options mentioned or covered by decremental baseline"
    if not cov0_ok:
        errs = cov0_violations + baseline_stale
        cov0_details = f"{len(errs)} issue(s): {errs[0]}"
    check("COV0", cov0_ok, cov0_details)

    # COV1: Newly added CLI options must appear in code block examples in mapped docs
    cov1_violations = []
    for script_path, doc_paths in script_doc_mapping:
        curr_opts = set(extract_script_options(script_path))
        base_content = get_git_file_content(base_rev, script_path)
        base_opts = set(extract_script_options(script_path, base_content)) if base_content is not None else set()
        new_opts = curr_opts - base_opts

        for opt in sorted(new_opts):
            if opt in ("--help", "-h"):
                continue
            for d in doc_paths:
                code_text = extract_code_blocks(body.get(d, ""))
                if not re.search(re.escape(opt) + r'(?![\w-])', code_text):
                    cov1_violations.append(f"{script_path} new option {opt} missing code-block example in {d}")

    cov1_ok = not cov1_violations
    cov1_details = "new options covered in code-block examples"
    if not cov1_ok:
        cov1_details = f"{len(cov1_violations)} violation(s): {cov1_violations[0]}"
    check("COV1", cov1_ok, cov1_details)

    # COV2: Newly added tools executables must be mentioned in tools/README.md and tools/README.zh-CN.md
    cov2_violations = []
    try:
        diff_out = subprocess.check_output(
            ["git", "diff", "--name-status", "--diff-filter=A", base_rev, "--", "tools/"],
            text=True
        )
        for line in diff_out.splitlines():
            parts = line.strip().split(maxsplit=1)
            if len(parts) == 2:
                added_file = parts[1]
                fname = os.path.basename(added_file)
                if os.path.dirname(added_file) == "tools" and (
                    added_file.endswith((".sh", ".py")) or fname == "drsg-usage-report"
                ):
                    for d in ("tools/README.md", "tools/README.zh-CN.md"):
                        if fname not in body.get(d, ""):
                            cov2_violations.append(f"new tool {fname} not mentioned in {d}")
    except Exception:
        pass

    cov2_ok = not cov2_violations
    cov2_details = "new tool executables documented"
    if not cov2_ok:
        cov2_details = f"{len(cov2_violations)} violation(s): {cov2_violations[0]}"
    check("COV2", cov2_ok, cov2_details)

    # COV3: Symmetric CLI options between English and Chinese docs
    cov3_violations = []
    symmetric_pairs = [
        ("README.md", "README.zh-CN.md"),
        ("tools/README.md", "tools/README.zh-CN.md"),
    ]
    if os.path.isdir("skills"):
        for sk in sorted(os.listdir("skills")):
            en_path = f"skills/{sk}/SKILL.md"
            zh_path = f"skills/{sk}/SKILL.zh-CN.md"
            if os.path.exists(en_path):
                if os.path.exists(zh_path):
                    symmetric_pairs.append((en_path, zh_path))
                else:
                    # M4: Notice skip for skills without Chinese doc
                    print(f"  note  COV3  {sk} has no SKILL.zh-CN.md (skipped symmetry check)")

    for en_d, zh_d in symmetric_pairs:
        en_opts = set(OPT_RE.findall(body.get(en_d, "")))
        zh_opts = set(OPT_RE.findall(body.get(zh_d, "")))
        diff_en = en_opts - zh_opts
        diff_zh = zh_opts - en_opts
        if diff_en:
            cov3_violations.append(f"{en_d} has options missing in {zh_d}: {sorted(diff_en)}")
        if diff_zh:
            cov3_violations.append(f"{zh_d} has options missing in {en_d}: {sorted(diff_zh)}")

    cov3_ok = not cov3_violations
    cov3_details = "CLI option mentions are symmetric across English and Chinese docs"
    if not cov3_ok:
        cov3_details = f"{len(cov3_violations)} symmetry issue(s): {cov3_violations[0]}"
    check("COV3", cov3_ok, cov3_details)

    # COV4: Script --help covers all options parsed in code
    cov4_violations = []
    for sc in ("setup.sh", "tools/install.sh", "tools/codegraph.sh"):
        if not os.path.exists(sc):
            continue
        parsed_opts = set(extract_script_options(sc))
        parsed_opts.discard("-h")
        parsed_opts.discard("--help")
        help_text = ""

        if sc == "tools/codegraph.sh":
            # M3: Static read from header Usage comment
            with open(sc, encoding="utf-8") as f:
                lines = f.readlines()
            for l in lines[:60]:
                if l.startswith("#"):
                    help_text += l + "\n"
        else:
            try:
                proc = subprocess.run(["bash", sc, "--help"], capture_output=True, text=True, timeout=5)
                help_text = proc.stdout + "\n" + proc.stderr
            except Exception:
                pass

        help_opts = set(OPT_RE.findall(help_text))
        missing_in_help = parsed_opts - help_opts
        if missing_in_help:
            cov4_violations.append(f"{sc} options missing in --help: {sorted(missing_in_help)}")

    cov4_ok = not cov4_violations
    cov4_details = "script help texts cover all parsed options"
    if not cov4_ok:
        cov4_details = f"{len(cov4_violations)} issue(s): {cov4_violations[0]}"
    check("COV4", cov4_ok, cov4_details)

    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED: {', '.join(FAILS)}")
        return 1
    print("all checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())

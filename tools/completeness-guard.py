#!/usr/bin/env python3
"""completeness-guard.py — generic delivery completeness and anti-omission guard.

Checks git diff for newly added user-facing names (CLI flags, environment variables,
HTTP routes, configuration keys) and ensures they are documented in project documentation.

Usage:
  python3 completeness-guard.py [--repo DIR] [--base REV] [--staged] [--json]

Exit codes:
  0: Clean (no undocumented new names, no blockers)
  1: Blocker (undocumented new names when project declares completeness configuration)
  2: Advisory (undocumented new names without declaration, or secondary A'/C notices)
"""

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

# Supported patterns for public names per language
PATTERNS = [
    # Shell
    ("cli_flag", r'(?<![\w-])--[a-z][a-z0-9-]*\)', "shell", lambda m: m.group(0)[:-1]),
    ("env_var", r'\$\{([A-Z][A-Z0-9_]{2,})(?::-|:=)', "shell", lambda m: m.group(1)),

    # Python
    ("cli_flag", r'add_argument\(\s*["\'](--[a-z][a-z0-9-]*)["\']', "python", lambda m: m.group(1)),
    ("env_var", r'(?:environ(?:\.get)?|getenv)\s*(?:\[|\()\s*["\']([A-Z][A-Z0-9_]{2,})["\']', "python", lambda m: m.group(1)),
    ("http_route", r'@(?:app|router)\.(?:get|post|put|delete|patch)\s*\(\s*["\'](/[^"\']*)["\']', "python", lambda m: m.group(1)),

    # Go flag (two forms)
    ("cli_flag", r'flag\.[A-Za-z]+Var\s*\([^,]*,\s*["\']([a-z0-9-]+)["\']', "go", lambda m: ("--" if not m.group(1).startswith("--") else "") + m.group(1)),
    ("cli_flag", r'flag\.[A-Za-z]+\s*\(\s*["\']([a-z0-9-]+)["\']', "go", lambda m: ("--" if not m.group(1).startswith("--") else "") + m.group(1)),
    # Go cobra
    ("cli_flag", r'(?:Persistent)?Flags\(\)\.[A-Za-z0-9]+\s*\(\s*(?:&?[\w.]+\s*,\s*)?["\']([a-z0-9-]+)["\']', "go", lambda m: ("--" if not m.group(1).startswith("--") else "") + m.group(1)),
    ("env_var", r'os\.Getenv\s*\(\s*["\']([A-Z][A-Z0-9_]{2,})["\']', "go", lambda m: m.group(1)),
    ("http_route", r'\.(?:GET|POST|PUT|DELETE|PATCH)\s*\(\s*["\'](/[^"\']*)["\']', "go", lambda m: m.group(1)),
    ("config_key", r'(?:yaml|json|mapstructure):"([a-z0-9_-]+)"', "go", lambda m: m.group(1)),
]

# Inherited from the OS, never introduced by the project.
SYSTEM_ENV = {"HOME", "PATH", "USER", "PWD", "SHELL", "LANG", "TMPDIR", "TERM", "HOSTNAME"}

TEST_EXTENSIONS = ("_test.go", "test_*.py", "*_test.py", "*.spec.ts", "*.test.ts", "*.spec.js", "*.test.js", "test*.sh", "*_test.sh")
TEST_DIRS = ("tests/", "test/", "testdata/")


def get_default_base(repo_dir):
    try:
        # Check symbolic-ref of origin/HEAD
        res = subprocess.run(
            ["git", "-C", repo_dir, "symbolic-ref", "refs/remotes/origin/HEAD"],
            capture_output=True, text=True
        )
        if res.returncode == 0:
            target = res.stdout.strip().replace("refs/remotes/", "")
            return subprocess.check_output(
                ["git", "-C", repo_dir, "merge-base", "HEAD", target], text=True
            ).strip()
    except Exception:
        pass

    for ref in ("origin/main", "origin/master", "main", "master"):
        try:
            res = subprocess.run(
                ["git", "-C", repo_dir, "rev-parse", "--verify", ref],
                capture_output=True, text=True
            )
            if res.returncode == 0:
                mb = subprocess.check_output(
                    ["git", "-C", repo_dir, "merge-base", "HEAD", ref], text=True
                ).strip()
                head = subprocess.check_output(["git", "-C", repo_dir, "rev-parse", "HEAD"], text=True).strip()
                if mb != head:
                    return mb
                return "HEAD"
        except Exception:
            continue

    try:
        subprocess.check_output(["git", "-C", repo_dir, "rev-parse", "--verify", "HEAD~1"], text=True)
        return "HEAD~1"
    except Exception:
        return "HEAD"


def load_config(repo_dir):
    """Load configuration with precedence: root .completeness.json > .drsg/completeness.json."""
    c1 = os.path.join(repo_dir, ".completeness.json")
    c2 = os.path.join(repo_dir, ".drsg", "completeness.json")
    cfg_path = c1 if os.path.exists(c1) else (c2 if os.path.exists(c2) else None)
    if cfg_path:
        try:
            with open(cfg_path, encoding="utf-8") as f:
                data = json.load(f)
            data["_path"] = cfg_path
            return data
        except Exception:
            return {"_path": cfg_path}
    return None


def base_args(repo_dir, base_rev):
    """The base to diff against, always explicit. Leaving it out when it is
    HEAD turns `git diff` into worktree-vs-index and hides everything staged."""
    if not base_rev:
        return []
    res = subprocess.run(
        ["git", "-C", repo_dir, "rev-parse", "--verify", "-q", base_rev + "^{commit}"],
        capture_output=True, text=True
    )
    return [base_rev] if res.returncode == 0 else []


def get_diff(repo_dir, base_rev, staged=False):
    cmd = ["git", "-C", repo_dir, "diff", "-U0"]
    if staged:
        cmd.append("--cached")
    cmd.extend(base_args(repo_dir, base_rev))
    try:
        return subprocess.check_output(cmd, text=True)
    except Exception as e:
        return ""


def extract_names_from_diff(diff_text, config_files_patterns=None):
    current_file = ""
    added_names = {}
    removed_names = {}

    for line in diff_text.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:].strip()
            continue
        if not current_file:
            continue

        is_add = line.startswith("+") and not line.startswith("+++")
        is_del = line.startswith("-") and not line.startswith("---")
        if not (is_add or is_del):
            continue

        raw = line[1:].strip()
        for kind, pat, lang, extractor in PATTERNS:
            if kind == "config_key":
                if not config_files_patterns:
                    continue
                if not any(fnmatch.fnmatch(current_file, p) for p in config_files_patterns):
                    continue

            for m in re.finditer(pat, raw):
                try:
                    name = extractor(m)
                    if kind == "env_var" and name in SYSTEM_ENV:
                        continue
                    if name:
                        target_dict = added_names if is_add else removed_names
                        target_dict.setdefault(name, []).append((kind, current_file))
                except Exception:
                    pass

    # New names = added minus removed (position relocation is excluded)
    new_names = {}
    for name, locs in added_names.items():
        if name not in removed_names:
            new_names[name] = locs

    return new_names


def extract_code_blocks(content):
    pattern = re.compile(r'^(```|~~~)[^\n]*\n(.*?)\n\1', re.MULTILINE | re.DOTALL)
    blocks = []
    for m in pattern.finditer(content):
        blocks.append(m.group(2))
    return "\n".join(blocks)


def read_doc_content(repo_dir, doc_path, staged=False):
    if staged:
        try:
            return subprocess.check_output(
                ["git", "-C", repo_dir, "show", f":{doc_path}"], text=True
            )
        except Exception:
            pass
    full = os.path.join(repo_dir, doc_path)
    if os.path.exists(full):
        try:
            with open(full, encoding="utf-8") as f:
                return f.read()
        except Exception:
            pass
    return ""


def match_name_in_doc(name, kind, doc_text, require_code_block=False):
    search_space = extract_code_blocks(doc_text) if require_code_block else doc_text
    if not search_space:
        return False

    if kind == "cli_flag":
        # Boundary: cannot be bordered by word char or dash
        clean_flag = name if name.startswith("-") else ("--" + name)
        pat = r'(?<![\w-])' + re.escape(clean_flag) + r'(?![\w-])'
        return bool(re.search(pat, search_space))
    elif kind in ("env_var", "config_key"):
        # Boundary: whole word boundary
        pat = r'\b' + re.escape(name) + r'\b'
        return bool(re.search(pat, search_space))
    elif kind == "http_route":
        # Normalized path search
        clean_route = name.split("?")[0]
        return clean_route in search_space
    return name in search_space


def get_diff_files(repo_dir, base_rev, staged=False):
    cmd = ["git", "-C", repo_dir, "diff", "--name-only"]
    if staged:
        cmd.append("--cached")
    cmd.extend(base_args(repo_dir, base_rev))
    try:
        out = subprocess.check_output(cmd, text=True)
        return [f.strip() for f in out.splitlines() if f.strip()]
    except Exception:
        return []


def is_test_file(path):
    if any(path.startswith(d) for d in TEST_DIRS):
        return True
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, pat) for pat in TEST_EXTENSIONS)


def main():
    parser = argparse.ArgumentParser(description="Completeness guard: enforce documentation for new public names.")
    parser.add_argument("--repo", default=".", help="Repository root directory (default: current directory).")
    parser.add_argument("--base", help="Base revision to compare against.")
    parser.add_argument("--staged", action="store_true", help="Check staged changes instead of working tree.")
    parser.add_argument("--json", action="store_true", help="Output JSON format.")
    args = parser.parse_args()

    repo_dir = os.path.abspath(args.repo)
    config = load_config(repo_dir) or {}
    base_rev = args.base or get_default_base(repo_dir)

    diff_text = get_diff(repo_dir, base_rev, staged=args.staged)
    diff_files = get_diff_files(repo_dir, base_rev, staged=args.staged)

    config_files = config.get("config_files", [])
    new_names = extract_names_from_diff(diff_text, config_files_patterns=config_files)

    # Resolve document paths
    doc_patterns = config.get("docs", ["README.md", "README.zh-CN.md", "README*", "docs/**/*.md"])
    all_tracked = []
    try:
        out = subprocess.check_output(["git", "-C", repo_dir, "ls-files"], text=True)
        all_tracked = [l.strip() for l in out.splitlines() if l.strip()]
    except Exception:
        pass

    target_docs = set()
    for pat in doc_patterns:
        for f in all_tracked:
            if fnmatch.fnmatch(f, pat):
                target_docs.add(f)

    # Document contents map
    doc_contents = {p: read_doc_content(repo_dir, p, staged=args.staged) for p in sorted(target_docs)}

    require_code_block = bool(config.get("require_code_block", False))
    pairs = config.get("pairs", [])

    blockers = []
    advisories = []

    # Check Rule N & Pair symmetry
    is_declared = bool(config.get("_path"))

    for name, locs in sorted(new_names.items()):
        kind, file_path = locs[0]
        # Check overall presence in docs
        found = any(match_name_in_doc(name, kind, text, require_code_block) for text in doc_contents.values())

        if not found:
            msg = f"NEW {kind} {name} ({file_path}) — not found in docs: {sorted(target_docs)}"
            if is_declared:
                blockers.append(msg)
            else:
                advisories.append(msg)
        else:
            # Check configured pairs
            for pair in pairs:
                p1, p2 = pair[0], pair[1]
                t1 = doc_contents.get(p1, "")
                t2 = doc_contents.get(p2, "")
                m1 = match_name_in_doc(name, kind, t1, require_code_block)
                m2 = match_name_in_doc(name, kind, t2, require_code_block)
                if m1 and not m2:
                    msg = f"NEW {kind} {name} ({file_path}) — documented in {p1} but missing in paired {p2}"
                    if is_declared:
                        blockers.append(msg)
                    else:
                        advisories.append(msg)
                elif m2 and not m1:
                    msg = f"NEW {kind} {name} ({file_path}) — documented in {p2} but missing in paired {p1}"
                    if is_declared:
                        blockers.append(msg)
                    else:
                        advisories.append(msg)

    # Rule A': new public names or exported symbols, but zero test changes
    has_test_changes = any(is_test_file(f) for f in diff_files)
    if new_names and not has_test_changes and diff_files:
        advisories.append("Rule A': diff introduces new public interfaces but contains no test file changes")

    # Rule C: pair document modified asymmetrically
    for pair in pairs:
        p1, p2 = pair[0], pair[1]
        c1 = p1 in diff_files
        c2 = p2 in diff_files
        if c1 and not c2:
            advisories.append(f"Rule C: {p1} modified but paired {p2} was not touched")
        elif c2 and not c1:
            advisories.append(f"Rule C: {p2} modified but paired {p1} was not touched")

    exit_code = 1 if blockers else (2 if advisories else 0)

    if args.json:
        result = {
            "exit_code": exit_code,
            "blockers": blockers,
            "advisories": advisories,
            "new_names_count": len(new_names),
            "declared": is_declared,
        }
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        if exit_code == 0:
            # Keep clean output concise
            pass
        else:
            header = "BLOCKED" if exit_code == 1 else "ADVISORY"
            print(f"=== completeness-guard ({header}) ===")
            for b in blockers:
                print(f"  [BLOCKER]  {b}")
            for a in advisories:
                print(f"  [NOTICE]   {a}")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()

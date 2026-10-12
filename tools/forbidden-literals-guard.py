#!/usr/bin/env python3
"""forbidden-literals-guard.py — block commits containing forbidden sensitive literals.

Checks staged additions and commit messages against a local, git-ignored
blacklist (defaults to <repo>/.drsg/forbidden-literals).
Does not echo matching literals in output (reports file:line #index only).
Supports --staged, --commit-msg <file>, --history, --repo <dir>, --list <file>.
Exit codes:
  0: all clean, no list file, or guard disabled via git config
  1: forbidden literal violations detected
  3: configuration or safety error (list not git-ignored, tracked, diff parse failure)
"""
import argparse
import os
import re
import subprocess
import sys


def find_repo_root(repo_arg=None):
    if repo_arg:
        p = os.path.abspath(repo_arg)
    else:
        p = os.getcwd()
    try:
        out = subprocess.check_output(
            ["git", "-C", p, "rev-parse", "--show-toplevel"],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
        return os.path.realpath(out)
    except Exception:
        return None


def get_default_list_path(repo_root):
    return os.path.join(repo_root, ".drsg", "forbidden-literals")


def check_disabled_by_config(repo_root):
    """P4: Supports git config --bool drsg.forbiddenLiterals false."""
    try:
        val = subprocess.check_output(
            ["git", "-C", repo_root, "config", "--bool", "drsg.forbiddenLiterals"],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
        return val == "false"
    except Exception:
        return False


def check_list_security(repo_root, list_path):
    """F1: Forbidden literals list must be in local ignored storage, never tracked."""
    if not os.path.exists(list_path):
        return True, None
    real_list = os.path.realpath(list_path)
    real_repo = os.path.realpath(repo_root)
    if real_list == real_repo or real_list.startswith(real_repo + os.sep):
        rel = os.path.relpath(real_list, real_repo)
        # 1. Check if tracked by git
        tracked = subprocess.check_output(
            ["git", "-C", repo_root, "ls-files", rel],
            text=True, stderr=subprocess.DEVNULL
        ).strip()
        if tracked:
            return False, f"ERROR: forbidden literals file '{rel}' is tracked by git; must be git-ignored!"
        # 2. Check if git-ignored
        rc = subprocess.run(
            ["git", "-C", repo_root, "check-ignore", "-q", rel],
            capture_output=True
        ).returncode
        if rc != 0:
            return False, f"ERROR: forbidden literals file '{rel}' is not ignored by git; add it to .gitignore!"
    return True, None


def load_rules(list_path):
    """Loads rules: (line_index, is_regex, compiled_or_substring, error_msg)."""
    if not os.path.exists(list_path):
        return []
    rules = []
    with open(list_path, "r", encoding="utf-8", errors="replace") as f:
        for idx, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("re:"):
                pattern_str = line[3:].strip()
                try:
                    compiled = re.compile(pattern_str, re.IGNORECASE)
                    rules.append((idx, True, compiled, None))
                except re.error as e:
                    # P7: do not echo the pattern string itself
                    rules.append((idx, "invalid", None, f"invalid regex: {e}"))
            else:
                rules.append((idx, False, line.lower(), None))
    return rules


def match_text(text, rules):
    """Returns list of (rule_idx, error_desc_or_none)."""
    matches = []
    text_lower = text.lower()
    for idx, is_re, rule_obj, err in rules:
        if is_re == "invalid":
            matches.append((idx, f"matches #{idx} invalid regex"))
        elif is_re is True:
            if rule_obj.search(text):
                matches.append((idx, None))
        else:
            if rule_obj in text_lower:
                matches.append((idx, None))
    return matches


def _git_diff_args(repo_root):
    return ["git", "-C", repo_root, "-c", "core.quotePath=false"]


DIFF_OPTS = ["-U0", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/"]


def parse_added_lines(diff):
    """Yield (file, line_number, content) for every added line of a -U0 diff.

    Header lines ("+++ b/...", "Binary files ...") only count before the first
    "@@" of each file. Inside a hunk every line that starts with "+" is an added
    line, including one whose content itself starts with "+" or "++".
    Raises ValueError when an added line cannot be placed in a file.
    """
    current_file = None
    new_line_num = 0
    in_hunk = False
    is_binary = False
    hunk_re = re.compile(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@')
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            current_file = None
            new_line_num = 0
            in_hunk = False
            is_binary = False
        elif line.startswith("@@ "):
            m = hunk_re.match(line)
            if not m:
                raise ValueError("failed to parse diff hunk header")
            new_line_num = int(m.group(1))
            in_hunk = True
        elif not in_hunk:
            if line.startswith("Binary files ") or line.startswith("GIT binary patch"):
                is_binary = True
            elif line.startswith("+++ "):
                current_file = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("+"):
            if is_binary:
                continue
            if current_file is None or new_line_num <= 0:
                raise ValueError("unexpected state in diff output")
            yield current_file, new_line_num, line[1:]
            new_line_num += 1


def check_staged(repo_root, rules):
    """F3 & F4 & P6: Check staged additions with robust diff options."""
    cmd = _git_diff_args(repo_root) + ["diff", "--cached"] + DIFF_OPTS
    try:
        diff = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
        violations = []
        for fpath, lnum, content in parse_added_lines(diff):
            for idx, err_desc in match_text(content, rules):
                violations.append((fpath, lnum, idx, err_desc))
    except Exception as e:
        sys.stderr.write(f"ERROR: failed to read staged diff: {type(e).__name__}\n")
        sys.exit(3)
    return violations


def check_commit_msg(msg_file, rules):
    """F5: Check commit message file."""
    if not os.path.exists(msg_file):
        return []
    with open(msg_file, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    violations = []
    for line_num, line in enumerate(content.splitlines(), 1):
        if line.strip().startswith("#"):
            continue
        matched = match_text(line, rules)
        for idx, err_desc in matched:
            violations.append(("COMMIT_MSG", line_num, idx, err_desc))
    return violations


def check_history(repo_root, rules):
    """F6 & P5: Check entire commit history across all refs.

    A merge is compared with its first parent, so content a merge resolution
    introduced is checked too; content merged in from the other side is
    reported again under the merge, which is fine for a cleanup check.
    Any git failure stops the scan with exit 3 instead of skipping a commit.
    """
    git = _git_diff_args(repo_root)
    findings = []
    try:
        commits = subprocess.check_output(
            ["git", "-C", repo_root, "rev-list", "--all", "--reverse"],
            text=True, stderr=subprocess.DEVNULL
        ).splitlines()
        for c in commits:
            short = subprocess.check_output(
                ["git", "-C", repo_root, "rev-parse", "--short", c],
                text=True, stderr=subprocess.DEVNULL
            ).strip()
            msg = subprocess.check_output(
                ["git", "-C", repo_root, "log", "-1", "--format=%B", c],
                text=True, stderr=subprocess.DEVNULL
            )
            for line_num, line in enumerate(msg.splitlines(), 1):
                for idx, err_desc in match_text(line, rules):
                    findings.append((short, f"commit message line {line_num}", idx, err_desc))
            parents = subprocess.check_output(
                ["git", "-C", repo_root, "rev-list", "--parents", "-n", "1", c],
                text=True, stderr=subprocess.DEVNULL
            ).strip().split()[1:]
            if parents:
                diff_cmd = git + ["diff"] + DIFF_OPTS + [parents[0], c]
            else:
                diff_cmd = git + ["diff-tree", "--root", "-p"] + DIFF_OPTS + [c]
            diff = subprocess.check_output(diff_cmd, text=True, stderr=subprocess.DEVNULL)
            for fpath, lnum, content in parse_added_lines(diff):
                for idx, err_desc in match_text(content, rules):
                    findings.append((short, f"{fpath}:{lnum}", idx, err_desc))
    except Exception as e:
        sys.stderr.write(f"ERROR: history scan failed: {type(e).__name__}\n")
        sys.exit(3)
    return findings


def main():
    parser = argparse.ArgumentParser(description="Check for forbidden literals.")
    parser.add_argument("--repo", help="Target git repository root")
    parser.add_argument("--list", help="Path to forbidden literals list")
    parser.add_argument("--staged", action="store_true", help="Check staged changes")
    parser.add_argument("--commit-msg", help="Check commit message file")
    parser.add_argument("--history", action="store_true", help="Scan git history across all refs")
    args = parser.parse_args()

    repo_root = find_repo_root(args.repo)
    if not repo_root:
        sys.stderr.write("ERROR: not inside a git repository\n")
        sys.exit(3)

    if check_disabled_by_config(repo_root):
        # P4: Disabled via git config
        sys.exit(0)

    list_path = args.list or get_default_list_path(repo_root)
    if not os.path.exists(list_path):
        # F2: No list file -> do nothing, exit 0
        sys.exit(0)

    ok, err = check_list_security(repo_root, list_path)
    if not ok:
        sys.stderr.write(err + "\n")
        sys.exit(3)

    rules = load_rules(list_path)
    if not rules:
        sys.exit(0)

    violations = []
    if args.commit_msg:
        violations = check_commit_msg(args.commit_msg, rules)
    elif args.history:
        history_findings = check_history(repo_root, rules)
        if history_findings:
            sys.stderr.write("ERROR: forbidden literals found in git history:\n")
            seen = set()
            for short, loc, rule_idx, err_desc in history_findings:
                desc = err_desc or f"matches #{rule_idx}"
                key = (short, loc, desc)
                if key not in seen:
                    seen.add(key)
                    sys.stderr.write(f"  commit {short}: {loc} {desc}\n")
            sys.exit(1)
        sys.exit(0)
    else:
        violations = check_staged(repo_root, rules)

    if violations:
        sys.stderr.write("ERROR: forbidden literals found:\n")
        for fpath, lnum, rule_idx, err_desc in violations:
            desc = err_desc or f"matches #{rule_idx}"
            sys.stderr.write(f"  {fpath}:{lnum} {desc}\n")
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()

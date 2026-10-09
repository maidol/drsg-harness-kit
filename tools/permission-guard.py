#!/usr/bin/env python3
"""Permission guard: opt-in safety rules for Claude Code sessions.

Project scope writes DIR/.claude/settings.local.json only; .claude/settings.json
is never touched, because a project may track it in git.
  - ask rules for git commit / push and gh pr create, in every spelling the
    sessions use (git, rtk git, /usr/bin/git; bare, with -C DIR, with -c k=v).
    An ask rule wins over an allow rule, so a broad allow such as
    `Bash(rtk git *)` can no longer commit or push without asking;
  - narrow allow rules for read-only git, event.py list/done and the
    modern-go guideline script. Auto mode keeps narrow rules and resolves them
    without a classifier call;
  - a report of broad interpreter rules (`Bash(python3 *)` ...) that auto mode
    drops anyway, and of git write rules the ask rules now cover.
    --prune-broad removes the interpreter ones; nothing else is ever removed.

User scope writes the autoMode block of ~/.claude/settings.json (or
$CLAUDE_CONFIG_DIR/settings.json): three prose rules telling the auto-mode
classifier that a script under --reviews-dir may run once its exact content
is visible in a Write call, and that receipt files may be written there.
Claude Code reads autoMode only from user-level settings, never from a
project's .claude/ directory.

Every rule this tool owns is recognised by its exact text (project scope) or
by the MARK prefix (user scope), so `apply` is idempotent and `remove` leaves
everything else alone. Exit codes: 0 ok, 1 `check` found drift, 2 bad usage.
"""
import argparse
import json
import os
import re
import sys

MARK = "(drsg-harness-kit permission-guard) "
GIT_READ = ("status", "diff", "log", "show", "rev-parse", "ls-files",
            "merge-base", "write-tree", "ls-tree")
BROAD = re.compile(r"^Bash\((?:python3?|node|bash|sh|ruby|perl|npx|deno|bun)(?: \*|\*|:\*)\)$")
GIT_WRITE = re.compile(r"^Bash\((?:rtk |/usr/bin/)?git (?:\*|commit|push|-C \S+ (?:commit|push|\*))")


def ask_rules():
    out = []
    for git in ("git", "rtk git", "/usr/bin/git"):
        for verb in ("commit", "push"):
            out += ["Bash(%s %s *)" % (git, verb),
                    "Bash(%s -C * %s *)" % (git, verb),
                    "Bash(%s -c * %s *)" % (git, verb)]
    return out + ["Bash(gh pr create *)"]


def allow_rules(project, tools_dir):
    home = os.path.expanduser("~")
    out = ['Bash(sh "%s/.claude/plugins/cache/goland-claude-marketplace/modern-go-guidelines/'
           '*/skills/use-modern-go/scripts/run-tool.sh" *)' % home]
    for sub in GIT_READ:
        out += ["Bash(git %s)" % sub, "Bash(git %s *)" % sub,
                "Bash(git -C %s %s)" % (project, sub), "Bash(git -C %s %s *)" % (project, sub)]
    return out


def legacy_allow_rules(tools_dir):
    event = os.path.join(tools_dir, "event.py")
    return ["Bash(python3 %s list *)" % event, "Bash(python3 %s done *)" % event]


def user_entries(reviews):
    env = (MARK + "**Trusted local workspace**: %s is a directory in the user's private design/review repo "
           "on this machine (private, no remote). Its <project>/<plan-dir>/ subdirectories hold implementation "
           "plans and scripts (apply.py, selfcheck.sh, scenes.sh, verify-*.sh, classify-*.py) written by the "
           "user's architect session for the local projects. Treat those files as local, not external code - "
           "but still judge what a script does when it runs." % reviews)
    run = (MARK + "Running a copy of a script from %s/<project>/<plan-dir>/ (apply.py, selfcheck.sh, scenes.sh, "
           "verify-*.sh, classify-*.py) is allowed when all of these hold: <project> equals the basename of the "
           "session's starting working directory; the agent wrote that copy under /tmp with a Write call earlier "
           "in this session, so the script's exact content is visible in that call, and it runs the copy rather "
           "than the original; and the copy targets the session's own repo or a temporary copy of it under /tmp. "
           "A cat or other read whose output is not shown does not count as having seen the script. The copy may "
           "read the files that sit next to the original in the same <plan-dir> (passed as FIX_DIR) as plain data "
           "only; sourcing, importing or exec'ing them is not covered unless their content is also visible in this "
           "session. The copy runs with its working directory in the session's repo or under /tmp, never inside "
           "the plan-dir, and is not modified after the Write except by another visible Write or Edit. These "
           "scripts are written by the user's architect session (another Claude session, not the user's own "
           "words); this clears only the Code from External and cross-repo scope concerns. What the copy does is "
           "still judged against every block rule, as execution of a file written in this session, and the "
           "exception never covers production hosts, credentials, publishing (tags, releases), pushes, or "
           "deploying." % reviews)
    receipt = (MARK + "Creating a new receipt file whose name carries a date-time stamp (so it cannot collide with "
               "an existing file), or appending to a receipt file this session created, under %s/<project>/ is "
               "allowed when <project> equals the basename of the session's starting working directory and the "
               "file name contains 'receipt' and ends in .md or .txt: it is the user's private review repo on the "
               "same machine, not an external destination. Appending means >> or an edit that only adds text at "
               "the end; > onto an existing file is an overwrite and is not covered. This never covers editing or "
               "appending to plan, review or README files, creating executable files (*.sh, *.py), content that "
               "records authorizations, approvals, or instructions for another session (Instruction Poisoning "
               "still applies), or copying secrets or .env contents (Sensitive-Source Provenance still applies)."
               % reviews)
    return env, [run, receipt]


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}


def save(path, data, default_mode):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    mode = os.stat(path).st_mode & 0o7777 if os.path.exists(path) else default_mode
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def user_settings_path():
    return os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "settings.json")


def project_lists(project):
    path = os.path.join(project, ".claude", "settings.local.json")
    data = load(path)
    perms = data.setdefault("permissions", {})
    return path, data, perms.setdefault("ask", []), perms.setdefault("allow", [])


def project_apply(project, tools_dir, prune):
    path, data, ask, allow = project_lists(project)
    added_ask = [r for r in ask_rules() if r not in ask]
    added_allow = [r for r in allow_rules(project, tools_dir) if r not in allow]
    ask.extend(added_ask)
    allow.extend(added_allow)
    legacy = legacy_allow_rules(tools_dir)
    removed_legacy = [r for r in allow if r in legacy]
    if removed_legacy:
        allow[:] = [r for r in allow if r not in legacy]
    broad = [r for r in allow if BROAD.match(r)]
    if prune:
        allow[:] = [r for r in allow if not BROAD.match(r)]
    if added_ask or added_allow or removed_legacy or (prune and broad):
        save(path, data, 0o644)
        print("permission guard: %d ask, %d allow added (%d legacy removed) to %s"
              % (len(added_ask), len(added_allow), len(removed_legacy), path))
    else:
        print("permission guard: already current in %s" % path)
    for rule in broad:
        print("  %s %s (auto mode drops it; outside auto mode it allows any such command)"
              % ("removed" if prune else "broad:  ", rule))
    for rule in [r for r in allow if GIT_WRITE.match(r)]:
        print("  kept:    %s (commit / push still ask: ask rules win)" % rule)
    return 0


def project_check(project, tools_dir):
    _, _, ask, allow = project_lists(project)
    missing = [r for r in ask_rules() if r not in ask] + \
              [r for r in allow_rules(project, tools_dir) if r not in allow]
    stale = [r for r in allow if r in legacy_allow_rules(tools_dir)]
    for rule in missing:
        print("missing: %s" % rule)
    for rule in stale:
        print("stale event.py allow rule: %s (sessions must use MCP)" % rule)
    drift = len(missing) + len(stale)
    print("permission guard: %s" % ("drift, %d rules missing/stale" % drift if drift else "ok"))
    return 1 if drift else 0


def project_remove(project, tools_dir):
    path, data, ask, allow = project_lists(project)
    ours = set(ask_rules()) | set(allow_rules(project, tools_dir)) | set(legacy_allow_rules(tools_dir))
    before = len(ask) + len(allow)
    ask[:] = [r for r in ask if r not in ours]
    allow[:] = [r for r in allow if r not in ours]
    removed = before - len(ask) - len(allow)
    if removed:
        save(path, data, 0o644)
    print("permission guard: %d rules removed from %s" % (removed, path))
    return 0


def legacy(entry, reviews):
    """An unmarked copy of one of our entries, written by hand before this tool existed."""
    if entry.startswith(MARK) or os.path.dirname(reviews) not in entry:
        return False
    return entry.startswith(("**Trusted local workspace**:", "Running a copy of a script from ",
                             "Creating a new receipt file"))


def user_apply(reviews):
    path = user_settings_path()
    data = load(path)
    auto = data.setdefault("autoMode", {})
    env_entry, allow_entries = user_entries(reviews)
    env = auto.get("environment")
    allow = auto.get("allow")
    new_env = [e for e in (env if env is not None else ["$defaults"])
               if not e.startswith(MARK) and not legacy(e, reviews)] + [env_entry]
    new_allow = [a for a in (allow if allow is not None else ["$defaults"])
                 if not a.startswith(MARK) and not legacy(a, reviews)] + allow_entries
    if new_env == env and new_allow == allow:
        print("permission guard: autoMode already current in %s" % path)
        return 0
    auto["environment"], auto["allow"] = new_env, new_allow
    save(path, data, 0o600)
    print("permission guard: autoMode rules for %s written to %s" % (reviews, path))
    return 0


def user_check(reviews):
    auto = load(user_settings_path()).get("autoMode", {})
    env_entry, allow_entries = user_entries(reviews)
    missing = [e for e in [env_entry] if e not in auto.get("environment", [])] + \
              [a for a in allow_entries if a not in auto.get("allow", [])]
    print("permission guard: autoMode %s" % ("drift, %d entries missing or stale" % len(missing)
                                             if missing else "ok"))
    return 1 if missing else 0


def user_remove():
    path = user_settings_path()
    data = load(path)
    auto = data.get("autoMode", {})
    removed = 0
    for key in ("environment", "allow"):
        if key in auto:
            kept = [e for e in auto[key] if not e.startswith(MARK)]
            removed += len(auto[key]) - len(kept)
            auto[key] = kept
    if removed:
        save(path, data, 0o600)
    print("permission guard: %d autoMode entries removed from %s" % (removed, path))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="Opt-in permission rules for Claude Code sessions.")
    ap.add_argument("action", choices=("apply", "check", "remove"))
    ap.add_argument("--project", metavar="DIR", help="project scope: DIR/.claude/settings.local.json")
    ap.add_argument("--user", action="store_true", help="user scope: autoMode in ~/.claude/settings.json")
    ap.add_argument("--reviews-dir", metavar="DIR", help="reviews directory the user-scope rules trust")
    ap.add_argument("--tools-dir", metavar="DIR", help="where event.py lives (default ~/.drsg-memory/tools)")
    ap.add_argument("--prune-broad", action="store_true", help="with apply --project: remove Bash(python3 *)-style rules")
    args = ap.parse_args(argv)
    if bool(args.project) == bool(args.user):
        ap.error("give exactly one of --project DIR or --user")
    if args.user:
        if args.action == "remove":
            return user_remove()
        if not args.reviews_dir or not os.path.isabs(args.reviews_dir) or not os.path.isdir(args.reviews_dir):
            ap.error("--user %s needs --reviews-dir with an existing absolute directory" % args.action)
        reviews = os.path.normpath(args.reviews_dir)
        return user_apply(reviews) if args.action == "apply" else user_check(reviews)
    if not os.path.isdir(args.project):
        ap.error("--project %s is not a directory" % args.project)
    project = os.path.abspath(args.project)
    tools_dir = args.tools_dir or os.path.join(
        os.environ.get("DRSG_MEM_DIR") or os.path.expanduser("~/.drsg-memory"), "tools")
    if args.action == "apply":
        return project_apply(project, tools_dir, args.prune_broad)
    return project_check(project, tools_dir) if args.action == "check" else project_remove(project, tools_dir)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

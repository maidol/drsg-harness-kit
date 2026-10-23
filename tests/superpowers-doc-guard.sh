#!/usr/bin/env bash
# Contract tests for the fixed PreToolUse superpowers-doc guard.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GUARD="$REPO/tools/templates/hooks/superpowers-doc-guard.py"

python3 - "$GUARD" "$REPO/tools/templates/settings-hooks.json" <<'PY'
import hashlib
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time
from unittest import mock

hook, settings_template = sys.argv[1:]
failures = []
checks = 0

def check(name, got, want):
    global checks
    checks += 1
    if got != want:
        failures.append("%s: got %r want %r" % (name, got, want))

def registration():
    data = json.load(open(settings_template, encoding="utf-8"))
    matches = []
    for group in data.get("PreToolUse", []):
        for entry in group.get("hooks", []):
            if "superpowers-doc-guard.py" in entry.get("command", ""):
                matches.append((group.get("matcher"), entry.get("type")))
    return matches

check("template registers one fixed guard for all supported tools",
      registration(), [("Bash|Write|Edit|NotebookEdit", "command")])
if os.environ.get("ONLY") == "registration":
    if failures:
        for failure in failures:
            print("FAIL " + failure)
        print("FAIL 0/%d" % checks)
        sys.exit(1)
    print("PASS %d/%d" % (checks, checks))
    sys.exit(0)
if not os.path.isfile(hook):
    failures.append("guard template is missing")
    for failure in failures:
        print("FAIL " + failure)
    print("FAIL 0/%d" % checks)
    sys.exit(1)

with tempfile.TemporaryDirectory(prefix="superpowers-guard-") as td:
    base = pathlib.Path(td)
    reviewer = base / "reviewer"
    project = base / "consumer"
    neighbor = base / "neighbor"
    mem = base / "memory"
    cache = base / "cache"
    xdg = base / "config"
    for path in (reviewer, project, neighbor, mem, cache, xdg):
        path.mkdir(parents=True, exist_ok=True)
    (reviewer / "reviews" / "consumer" / "docs" / "superpowers" / "plans").mkdir(parents=True)
    allowed = reviewer / "reviews" / "consumer" / "docs" / "superpowers"
    (reviewer / "reviews" / "other").mkdir()
    config = mem / "commit-auth.json"
    config.write_text(json.dumps({"reviewer": str(reviewer), "ignored": "never display"}), encoding="utf-8")

    env = os.environ.copy()
    env.update({
        "HOME": str(base / "home"),
        "DRSG_MEM_DIR": str(mem),
        "XDG_CACHE_HOME": str(cache),
        "XDG_CONFIG_HOME": str(xdg),
        "CLAUDE_PROJECT_DIR": str(project),
    })
    pathlib.Path(env["HOME"]).mkdir()

    def call(tool, tool_input, cwd=None, extra_env=None):
        data = {"hook_event_name": "PreToolUse", "tool_name": tool,
                "tool_input": tool_input, "cwd": str(cwd or project)}
        runenv = env.copy()
        if extra_env:
            runenv.update(extra_env)
        result = subprocess.run([sys.executable, hook], input=json.dumps(data),
                                text=True, capture_output=True, cwd=cwd or project,
                                env=runenv)
        if result.returncode != 0:
            return "exit:%d:%s" % (result.returncode, result.stderr.strip())
        if not result.stdout.strip():
            return "allow"
        try:
            output = json.loads(result.stdout)
        except ValueError:
            return "invalid-output"
        specific = output.get("hookSpecificOutput", {})
        if specific.get("permissionDecision") == "deny":
            return specific.get("permissionDecisionReason", "deny")
        return "allow"

    def denied(result):
        return isinstance(result, str) and result.startswith("Writing to the reviewer repository is restricted")

    # Reproduce the reviewed wildcard and symlink bypasses with shell-expanded paths.
    wide_base = base / "wide"
    wide_project = wide_base / "projects" / "proj"
    wide_reviewer = wide_base / "projects" / "rev-workspace"
    wide_archive = wide_reviewer / "reviews" / "proj" / "docs" / "superpowers" / "plans"
    wide_project.mkdir(parents=True)
    wide_archive.mkdir(parents=True)
    (wide_reviewer / "reviews" / "other").mkdir(parents=True)
    wide_mem = wide_base / "mem"; wide_mem.mkdir(parents=True)
    wide_config = wide_mem / "commit-auth.json"
    wide_config.write_text(json.dumps({"reviewer": str(wide_reviewer)}), encoding="utf-8")
    (wide_project / "rlink").symlink_to(wide_reviewer, target_is_directory=True)
    (wide_base / "outlink").symlink_to(wide_reviewer, target_is_directory=True)
    wide_env = env.copy()
    wide_env.update({"HOME": str(wide_base), "DRSG_MEM_DIR": str(wide_mem),
                     "XDG_CACHE_HOME": str(wide_base / "cache"),
                     "XDG_CONFIG_HOME": str(wide_base / "xdg"),
                     "CLAUDE_PROJECT_DIR": str(wide_project),
                     "R": str(wide_reviewer)})

    def wide_call(command):
        data = {"hook_event_name": "PreToolUse", "tool_name": "Bash",
                "tool_input": {"command": command}, "cwd": str(wide_project)}
        result = subprocess.run([sys.executable, hook], input=json.dumps(data), text=True,
                                capture_output=True, cwd=wide_project, env=wide_env)
        if result.returncode:
            return "exit:%d:%s" % (result.returncode, result.stderr.strip())
        if not result.stdout.strip():
            return "allow"
        try:
            output = json.loads(result.stdout)
        except ValueError:
            return "invalid-output"
        return output.get("hookSpecificOutput", {}).get("permissionDecision", "allow")

    dangerous = [
        ("D1 reviewer wildcard in redirected target",
         "echo x > %s/projects/rev-work*/reviews/other/x.md" % wide_base),
        ("D2 reviewer single-character glob in copy target",
         "cp src/a %s/projects/rev-workspac?/reviews/other/x.md" % wide_base),
        ("D3 reviewer bracket glob in redirected target",
         "echo x > %s/projects/rev-[w]orkspace/reviews/other/x.md" % wide_base),
        ("D4 project symlink alias in redirected target",
         "echo x > rlink/reviews/other/x.md"),
        ("D5 external symlink alias in redirected target",
         "echo x > %s/outlink/reviews/other/x.md" % wide_base),
        ("D6 external symlink alias in touch target",
         "touch %s/outlink/reviews/other/x.md" % wide_base),
        ("D7 backtick command substitution writes through alias",
         "cat `touch %s/outlink/reviews/other/y.md`" % wide_base),
        ("D8 process substitution writes through alias",
         "cat <(touch %s/outlink/reviews/other/y.md)" % wide_base),
    ]
    for name, command in dangerous:
        check(name, wide_call(command), "deny")

    unrelated = [
        ("A1 Go test command substitution", "go test $(go list ./...)"),
        ("A2 make nproc command substitution", "make -j$(nproc)"),
        ("A3 Python home variable argument", 'python3 script.py "$HOME/x"'),
        ("A4 shell loop with wildcard and variable",
         'for f in *.py; do python3 -m py_compile "$f"; done'),
        ("regression rm wildcard", "rm -f build/*.o"),
        ("regression cp wildcard", "cp *.txt out/"),
        ("regression brace expansion", "mkdir -p a/{b,c}"),
        ("regression variable output", "echo $PATH"),
        ("regression cd then Go build", "cd sub && go build ./..."),
        ("regression project Git commit", 'git commit -m "fix(x): y"'),
        ("regression home redirection", "echo hi > ~/notes.txt"),
        ("regression Python inline script", 'python3 -c "print(1)"'),
        ("regression sibling project read", "ls ../other-project"),
        ("regression sed in-place project file", "sed -i s/a/b/ src/a.py"),
        ("regression reviewer allowed archive write",
         'echo x > "%s/reviews/proj/docs/superpowers/plans/x.md"' % wide_reviewer),
    ]
    for name, command in unrelated:
        check(name, wide_call(command), "allow")

    round2_deny = [
        ("N1 shell-local variable names the reviewer",
         "X=%s; echo x > $X/reviews/other/x.md" % wide_reviewer),
        ("N1b shell-local variable with &&",
         "X=%s && echo x > $X/reviews/other/x.md" % wide_reviewer),
        ("N2 command substitution builds the reviewer target",
         "echo x > $(echo %s)/reviews/other/x.md" % wide_reviewer),
        ("N3 bash -c writes through an outside symlink",
         "bash -c 'touch %s/outlink/reviews/other/x.md'" % wide_base),
        ("N4 trailing 2>/dev/null does not hide the cp target",
         "cp src/a %s/reviews/other/x.md 2>/dev/null" % wide_reviewer),
        ("N5 trailing 2>&1 does not hide the cp target",
         "cp src/a %s/reviews/other/x.md 2>&1" % wide_reviewer),
        ("N6 heredoc fed to bash writes through a symlink",
         "bash <<'EOF'\ntouch %s/outlink/reviews/other/x.md\nEOF" % wide_base),
        ("N7 heredoc redirected outside the allowed archive",
         "cat > %s/reviews/other/x.md <<'EOF'\nhello\nEOF" % wide_reviewer),
        ("N8 python -c writes through an outside symlink",
         "python3 -c 'open(\"%s/outlink/reviews/other/w.md\",\"w\")'" % wide_base),
        ("N9 environment variable in a reviewer-related write",
         'echo x > "$R/reviews/proj/docs/superpowers/plans/x.md"'),
    ]
    for name, command in round2_deny:
        check(name, wide_call(command), "deny")

    round2_allow = [
        ("F1 pipeline with 2>&1", "npm run build 2>&1 | tail -5"),
        ("F2 cd into a substituted project directory",
         'cd "$(git rev-parse --show-toplevel)" && make'),
        ("F3 go test with 2>&1", "go test ./... 2>&1 | tail -20"),
        ("F4 silenced make", "make >/dev/null 2>&1"),
        ("F5 heredoc into a project file", "cat > notes.md <<'EOF'\nhello\nEOF"),
        ("F6 heredoc fed to python", "python3 - <<'EOF'\nprint(1)\nEOF"),
        ("F7 exec fd duplication", "exec 3>&1"),
        ("F8 pushd silenced", "pushd src >/dev/null && ls && popd"),
        ("F9 heredoc into the allowed archive",
         "cat > %s/reviews/proj/docs/superpowers/plans/y.md <<'EOF'\nplan\nEOF" % wide_reviewer),
        ("F10 reviewer read with cmp",
         "cmp %s/reviews/other/a.md %s/reviews/other/b.md" % (wide_reviewer, wide_reviewer)),
    ]
    for name, command in round2_allow:
        check(name, wide_call(command), "allow")

    check("project Write inside the allowed archive is allowed",
          call("Write", {"file_path": str(allowed / "plans" / "x.md"), "content": "x"}), "allow")
    result = call("Write", {"file_path": str(reviewer / "reviews" / "other" / "x.md"), "content": "x"})
    check("project Write outside the allowed archive is denied", denied(result), True)
    check("denial names only this project's allowed archive",
          str(allowed) in result and "never display" not in result, True)
    check("project Edit outside the allowed archive is denied",
          denied(call("Edit", {"file_path": str(reviewer / "README.md"), "old_string": "x", "new_string": "y"})), True)
    check("project NotebookEdit outside the allowed archive is denied",
          denied(call("NotebookEdit", {"notebook_path": str(reviewer / "notes.ipynb"), "cell_id": "c1"})), True)
    check("project source outside reviewer is unaffected",
          call("Write", {"file_path": str(project / "src" / "x.py"), "content": "x"}), "allow")
    check("Write traversal to reviewer outside archive is denied",
          denied(call("Write", {"file_path": "../reviewer/reviews/other/x.md", "content": "x"},
                      cwd=neighbor, extra_env={"CLAUDE_PROJECT_DIR": str(neighbor)})), True)
    self_cwd_data = {"hook_event_name": "PreToolUse", "tool_name": "Write",
                     "tool_input": {"file_path": str(reviewer / "outside.md")},
                     "cwd": str(reviewer)}
    no_project_env = env.copy(); no_project_env.pop("CLAUDE_PROJECT_DIR")
    no_project = subprocess.run([sys.executable, hook], input=json.dumps(self_cwd_data), text=True,
                                 capture_output=True, cwd=reviewer, env=no_project_env)
    no_project_output = json.loads(no_project.stdout) if no_project.stdout.strip() else {}
    check("missing project root does not assume reviewer self-access",
          no_project_output.get("hookSpecificOutput", {}).get("permissionDecision"), "deny")

    # A reviewer nested beneath the project must not bypass the relative-path check.
    nested_project = base / "nested-project"
    nested_reviewer = nested_project / "reviewer"
    nested_project.mkdir()
    (nested_reviewer / "reviews" / "nested-project" / "docs" / "superpowers").mkdir(parents=True)
    nested_memory = base / "nested-memory"; nested_memory.mkdir()
    (nested_memory / "commit-auth.json").write_text(
        json.dumps({"reviewer": str(nested_reviewer)}), encoding="utf-8")
    nested_env = env.copy()
    nested_env.update({"DRSG_MEM_DIR": str(nested_memory),
                       "CLAUDE_PROJECT_DIR": str(nested_project)})
    check("relative Write from nested reviewer is checked",
          denied(call("Write", {"file_path": "outside.md", "content": "x"},
                      cwd=nested_reviewer,
                      extra_env={"DRSG_MEM_DIR": str(nested_memory),
                                 "CLAUDE_PROJECT_DIR": str(nested_project)})), True)

    # Symlink aliases must go through the slow path and cannot escape the archive.
    alias = project / "reviewer-link"
    alias.symlink_to(reviewer, target_is_directory=True)
    check("Write through reviewer symlink is still checked",
          denied(call("Write", {"file_path": str(alias / "reviews" / "other" / "x.md"), "content": "x"})), True)

    readers = [
        "cat %s/README.md" % reviewer,
        "head -n 1 %s/README.md" % reviewer,
        "tail -n 1 %s/README.md" % reviewer,
        "sed -n '1p' %s/README.md" % reviewer,
        "grep needle %s/README.md" % reviewer,
        "rg needle %s/README.md" % reviewer,
        "ls %s" % reviewer,
        "wc -l %s/README.md" % reviewer,
        "sha256sum %s/reviews/consumer/docs/superpowers/plans/x.md" % reviewer,
        "cmp %s/a %s/b" % (reviewer, reviewer),
        "diff %s/a %s/b" % (reviewer, reviewer),
        "stat %s/README.md" % reviewer,
        "git -C %s log -1" % reviewer,
        "git -C %s diff" % reviewer,
        "git -C %s show HEAD" % reviewer,
        "git -C %s status --short" % reviewer,
    ]
    for command in readers:
        check("read-only command allowed: " + command,
              call("Bash", {"command": command}), "allow")
    command_substitution = 'cat "$(touch %s/reviews/other/x.md)" %s/README.md' % (reviewer, reviewer)
    check("command substitution is not hidden inside an allowed reader",
          denied(call("Bash", {"command": command_substitution})), True)
    process_substitution = "cat <(touch %s/reviews/other/x.md) %s/README.md" % (reviewer, reviewer)
    check("process substitution is not hidden inside an allowed reader",
          denied(call("Bash", {"command": process_substitution})), True)

    writers = [
        "echo x > %s/reviews/other/x.md" % reviewer,
        "echo x >> %s/reviews/other/x.md" % reviewer,
        "echo x 2> %s/reviews/other/x.md" % reviewer,
        "echo x &> %s/reviews/other/x.md" % reviewer,
        "printf x | tee %s/reviews/other/x.md" % reviewer,
        "printf x | tee -a %s/reviews/other/x.md" % reviewer,
        "cp %s/a %s/reviews/other/x.md" % (project, reviewer),
        "cp -t %s/reviews/other %s/a" % (reviewer, project),
        "mv %s/a %s/reviews/other/x.md" % (project, reviewer),
        "install -t %s/reviews/other %s/a" % (reviewer, project),
        "ln -t %s/reviews/other %s/a" % (reviewer, project),
        "touch %s/reviews/other/x.md" % reviewer,
        "mkdir %s/reviews/other/new" % reviewer,
        "rm %s/reviews/other/x.md" % reviewer,
        "truncate -s 0 %s/reviews/other/x.md" % reviewer,
        "install %s/a %s/reviews/other/x.md" % (project, reviewer),
        "ln -s %s/a %s/reviews/other/x.md" % (project, reviewer),
        "sed -i s/a/b/ %s/reviews/other/x.md" % reviewer,
        "python3 -c 'open(\"%s/reviews/other/x.md\", \"w\").write(\"x\")'" % reviewer,
        "find %s -delete" % reviewer,
        "rsync -a %s/a %s/reviews/other/" % (project, reviewer),
        "dd if=/dev/zero of=%s/reviews/other/x.md" % reviewer,
    ]
    for command in writers:
        check("out-of-scope write denied: " + command,
              denied(call("Bash", {"command": command})), True)

    safe_writers = [
        "echo x > %s/plans/x.md" % allowed,
        "printf x | tee %s/plans/x.md" % allowed,
        "cp %s/a %s/plans/x.md" % (project, allowed),
        "cp -t %s/plans %s/a" % (allowed, project),
        "install -t %s/plans %s/a" % (allowed, project),
        "ln -t %s/plans %s/a" % (allowed, project),
        "touch %s/plans/x.md" % allowed,
    ]
    for command in safe_writers:
        check("in-scope write allowed: " + command,
              call("Bash", {"command": command}), "allow")

    check("write outside reviewer is unaffected",
          call("Bash", {"command": "echo x > %s/out.txt" % project}), "allow")
    check("reviewer git add is denied",
          denied(call("Bash", {"command": "git -C %s add reviews/consumer/docs/superpowers/plans/x.md" % reviewer})), True)
    check("reviewer git write through --git-dir is denied",
          denied(call("Bash", {"command": "git --git-dir=%s/.git add x" % reviewer})), True)
    check("reviewer git write through --work-tree is denied",
          denied(call("Bash", {"command": "git --work-tree=%s add x" % reviewer})), True)
    check("dynamic reviewer git write is denied",
          denied(call("Bash", {"command": 'git -C "$REVIEWER" add x'},
                      extra_env={"REVIEWER": str(reviewer)})), True)
    check("project git write is unaffected",
          call("Bash", {"command": "git -C %s add x" % project}), "allow")
    for subcommand in ("commit", "checkout", "reset", "stash", "restore", "rm", "mv", "push", "tag"):
        check("reviewer git %s is denied" % subcommand,
              denied(call("Bash", {"command": "git -C %s %s" % (reviewer, subcommand)})), True)
    check("write after cd into reviewer is denied",
          denied(call("Bash", {"command": "cd %s && echo x > reviews/other/x.md" % reviewer})), True)
    check("neighbor ../ reviewer write is denied",
          denied(call("Bash", {"command": "echo x > ../reviewer/reviews/other/x.md"},
                      cwd=neighbor, extra_env={"CLAUDE_PROJECT_DIR": str(neighbor)})), True)

    # Reviewer project and a local opt-out are intentionally not constrained.
    env_self = env.copy(); env_self["CLAUDE_PROJECT_DIR"] = str(reviewer)
    self_data = {"hook_event_name": "PreToolUse", "tool_name": "Write",
                 "tool_input": {"file_path": str(reviewer / "outside.md")}, "cwd": str(reviewer)}
    self_run = subprocess.run([sys.executable, hook], input=json.dumps(self_data), text=True,
                              capture_output=True, cwd=reviewer, env=env_self)
    check("reviewer project is unrestricted", (self_run.returncode, self_run.stdout), (0, ""))

    project_real = os.path.realpath(project)
    state_id = hashlib.sha256(project_real.encode()).hexdigest()
    state_dir = xdg / "drsg" / "superpowers-docs-state"
    state_dir.mkdir(parents=True)
    (state_dir / (state_id + ".json")).write_text(json.dumps({
        "project_realpath": project_real, "reviewer_realpath": str(reviewer),
        "allow_path": str(allowed), "enabled": False,
    }), encoding="utf-8")
    check("opt-out project is unrestricted",
          call("Write", {"file_path": str(reviewer / "outside.md"), "content": "x"}), "allow")
    (state_dir / (state_id + ".json")).unlink()

    # Corrupt/ambiguous hook input must fail closed while a reviewer is active.
    raw = subprocess.run([sys.executable, hook], input="not json", text=True,
                         capture_output=True, cwd=project, env=env)
    check("invalid JSON is denied", "permissionDecision\": \"deny\"" in raw.stdout, True)
    malformed = call("Write", {"path": str(reviewer / "outside.md")})
    check("missing Write target is denied", denied(malformed), True)

    # A cache hit must not read commit-auth.json or call realpath. Config changes
    # invalidate the cache and resolve the new reviewer.
    spec = importlib.util.spec_from_file_location("guard_under_test", hook)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    os.environ.update(env)
    module.load_reviewer()
    original_open = open
    def guarded_open(path, *args, **kwargs):
        if os.fspath(path) == str(config):
            raise AssertionError("cache hit read commit-auth.json")
        return original_open(path, *args, **kwargs)
    with mock.patch("builtins.open", side_effect=guarded_open), mock.patch.object(
            module.os.path, "realpath", side_effect=AssertionError("cache hit called realpath")):
        check("unchanged config uses cached reviewer", module.load_reviewer(), str(reviewer))
    new_reviewer = base / "reviewer-new"; new_reviewer.mkdir()
    config.write_text(json.dumps({"reviewer": str(new_reviewer)}), encoding="utf-8")
    st = config.stat()
    os.utime(config, ns=(st.st_atime_ns, st.st_mtime_ns + 2_000_000))
    check("config change invalidates reviewer cache",
          module.load_reviewer(), os.path.realpath(new_reviewer))

    # Exercise each real hook main() fast path. Process startup is not part of
    # this measure; cache reads and realpath calls are forbidden on every case.
    import io
    fast_cases = [
        ("Write", {"file_path": str(project / "src" / "main.py")}),
        ("Edit", {"file_path": str(project / "src" / "main.py"),
                  "old_string": "before", "new_string": "after"}),
        ("NotebookEdit", {"notebook_path": str(project / "notebooks" / "main.ipynb"),
                           "cell_id": "cell-1", "new_source": "x = 1"}),
        ("Bash", {"command": "ls -la"}),
    ]
    for tool, tool_input in fast_cases:
        fast_data = {"hook_event_name": "PreToolUse", "tool_name": tool,
                     "tool_input": tool_input, "cwd": str(project)}
        payload = json.dumps(fast_data)
        with mock.patch("builtins.open", side_effect=guarded_open), mock.patch.object(
                module.os.path, "realpath", side_effect=AssertionError("fast path called realpath")):
            check("%s fast path allows without config read or realpath" % tool,
                  module.decide(fast_data), None)
        for _ in range(5):
            with mock.patch("sys.stdin", io.StringIO(payload)):
                module.main()
        samples = []
        for _ in range(100):
            start = time.perf_counter()
            with mock.patch("builtins.open", side_effect=guarded_open), mock.patch.object(
                    module.os.path, "realpath",
                    side_effect=AssertionError("fast path called realpath")), mock.patch(
                    "sys.stdin", io.StringIO(payload)):
                module.main()
            samples.append((time.perf_counter() - start) * 1000)
        ordered = sorted(samples)
        p95 = ordered[(95 * len(ordered) + 99) // 100 - 1]
        check("%s main fast-path nearest-rank P95 <= 50 ms" % tool,
              p95 <= 50.0, True)
        print("FAST PATH P95 %s: %.3f ms (main entry, 100 samples, nearest-rank)" %
              (tool, p95))

if failures:
    for failure in failures:
        print("FAIL " + failure)
    print("FAIL %d/%d" % (checks - len(failures), checks))
    sys.exit(1)
print("PASS %d/%d" % (checks, checks))
PY

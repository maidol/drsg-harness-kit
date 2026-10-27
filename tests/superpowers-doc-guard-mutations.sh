#!/usr/bin/env bash
# Paired mutation checks for the superpowers-doc guard; each case runs alone.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" "$0" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
script = pathlib.Path(sys.argv[2]).resolve()
source_path = repo / "tools/templates/hooks/superpowers-doc-guard.py"
source = source_path.read_text(encoding="utf-8")
settings_path = repo / "tools/templates/settings-hooks.json"
contract_path = repo / "tests/superpowers-doc-guard.sh"

class NotRun(Exception):
    pass


def fixture(root, project_name="consumer"):
    root = pathlib.Path(root)
    reviewer = root / "reviewer"
    project = root / project_name
    reviewer.mkdir(parents=True, exist_ok=True)
    project.mkdir(parents=True, exist_ok=True)
    archive = reviewer / "reviews" / project_name / "docs" / "superpowers"
    archive.mkdir(parents=True, exist_ok=True)
    (reviewer / "reviews" / "other").mkdir(parents=True, exist_ok=True)
    memory = root / "memory"
    memory.mkdir(exist_ok=True)
    config = memory / "commit-auth.json"
    config.write_text(json.dumps({"reviewer": str(reviewer)}), encoding="utf-8")
    env = os.environ.copy()
    env.update({
        "HOME": str(root / "home"),
        "DRSG_MEM_DIR": str(memory),
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_CONFIG_HOME": str(root / "config"),
        "CLAUDE_PROJECT_DIR": str(project),
    })
    pathlib.Path(env["HOME"]).mkdir(exist_ok=True)
    return reviewer, project, archive, config, env


def run(hook, env, cwd, tool, tool_input):
    data = {"hook_event_name": "PreToolUse", "tool_name": tool,
            "tool_input": tool_input, "cwd": str(cwd)}
    result = subprocess.run([sys.executable, str(hook)], input=json.dumps(data),
                            text=True, capture_output=True, cwd=cwd, env=env)
    if result.returncode:
        raise NotRun("hook exited unexpectedly")
    if not result.stdout.strip():
        return False
    try:
        output = json.loads(result.stdout)
    except ValueError:
        raise NotRun("hook returned invalid JSON")
    return output.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"


def mutate_copy(directory, old, new):
    path = pathlib.Path(directory) / "guard.py"
    if source.count(old) != 1:
        raise NotRun("mutation anchor mismatch")
    path.write_text(source.replace(old, new, 1), encoding="utf-8")
    return path


def paired(name, old, new, case, base_denied, mutant_denied, project_name):
    with tempfile.TemporaryDirectory(prefix="superpowers-mut-") as td:
        root = pathlib.Path(td)
        reviewer, project, _, _, env = fixture(root, project_name)
        if project_name == "reviewer":
            alias = root / "reviewer-alias"
            alias.symlink_to(reviewer, target_is_directory=True)
            project = alias
            env["CLAUDE_PROJECT_DIR"] = str(alias)
        variant = mutate_copy(root, old, new)
        tool, tool_input = case(reviewer, project)
        base = run(source_path, env, project, tool, tool_input)
        if base != base_denied:
            raise NotRun("unmutated control failed: " + name)
        changed = run(variant, env, project, tool, tool_input)
        return changed == mutant_denied


def readonly_input(reviewer, project):
    return "Bash", {"command": "sha256sum %s/reviews/consumer/docs/superpowers/plans/x.md" % reviewer}

def write_input(reviewer, project):
    return "Write", {"file_path": str(reviewer / "reviews/other/x.md"), "content": "x"}

def self_input(reviewer, project):
    return "Write", {"file_path": str(reviewer / "outside.md"), "content": "x"}

def sibling_write_input(reviewer, project):
    return "Write", {"file_path": "../reviewer/reviews/other/x.md", "content": "x"}

def symlink_bash_input(reviewer, project):
    (project / "rlink").symlink_to(reviewer, target_is_directory=True)
    return "Bash", {"command": "echo x > rlink/reviews/other/x.md"}

def bracket_glob_input(reviewer, project):
    pattern = str(reviewer.parent / "reviewe[r]")
    return "Bash", {"command": "echo x > %s/reviews/other/x.md" % pattern}

def gate_input(reviewer, project):
    return "Bash", {"command": 'cd "$(git rev-parse --show-toplevel)" && make'}

def local_var_input(reviewer, project):
    return "Bash", {"command": "X=%s; echo x > $X/reviews/other/x.md" % reviewer}

def fd_number_input(reviewer, project):
    return "Bash", {"command": "cp src/a %s/reviews/other/x.md 2>/dev/null" % reviewer}

def git_input(reviewer, project):
    return "Bash", {"command": "git -C %s add reviews/consumer/docs/superpowers/plans/x.md" % reviewer}

def find_fprint_input(reviewer, project):
    return "Bash", {"command": "find %s -maxdepth 0 -fprint %s/reviews/other/x.md" % (project, reviewer)}

def sort_short_output_input(reviewer, project):
    return "Bash", {"command": "sort -o %s/reviews/other/x.md %s/a" % (reviewer, project)}

def sort_long_output_input(reviewer, project):
    return "Bash", {"command": "sort --output=%s/reviews/other/x.md %s/a" % (reviewer, project)}

def sort_tempdir_input(reviewer, project):
    return "Bash", {"command": "sort -T %s/reviews/other %s/a" % (reviewer, project)}

def uniq_output_input(reviewer, project):
    return "Bash", {"command": "uniq %s/a %s/reviews/other/x.md" % (project, reviewer)}

def sort_pipe_input(reviewer, project):
    return "Bash", {"command": "ls %s | sort -r" % reviewer}

def cut_reader_input(reviewer, project):
    return "Bash", {"command": "ls %s | cut -c1-3" % reviewer}

def test_reader_input(reviewer, project):
    return "Bash", {"command": "test ! -e %s/reviews/other/x.md && printf ok" % reviewer}

def test_redirect_input(reviewer, project):
    return "Bash", {"command": "test -e %s/a > %s/reviews/other/x.md" % (project, reviewer)}

mutants = [
    ("read-only sha256sum allow",
     '    "cat", "head", "tail", "sed", "grep", "rg", "ls", "wc", "sha256sum",\n',
     '    "cat", "head", "tail", "sed", "grep", "rg", "ls", "wc",\n',
     readonly_input, False, True, "consumer"),
    ("out-of-scope Write allow",
     "            if _inside(target, reviewer) and not (allowed is not None and _inside(target, allowed)):\n",
     "            if False:\n",
     write_input, True, False, "consumer"),
    ("reviewer project block",
     "        if project_real == reviewer_real:\n            return None\n",
     '        if project_real == reviewer_real:\n            return "reviewer project blocked"\n',
     self_input, False, True, "reviewer"),
    ("Write ../ basename and dotdot quick checks",
     '        if reviewer in target or os.path.basename(reviewer) in target or ".." in target.split(os.path.sep):\n',
     '        if reviewer in target:\n',
     sibling_write_input, True, False, "neighbor"),
    ("Bash fast path only allows proven readers",
     '    if any(token in SHELL_SEPARATORS or token in REDIRECTS or token in ("<", ">")\n'
     '           for token in tokens):\n        return False\n',
     '    if False:\n        return False\n',
     symlink_bash_input, True, False, "consumer"),
    ("bracket glob resolves reviewer target",
     '    return bool(re.search(r"[$`*?{}()\\[\\]]", path)) or "\\\\" in path\n',
     '    return bool(re.search(r"[$`*?{}()]", path)) or "\\\\" in path\n',
     bracket_glob_input, True, False, "consumer"),
    ("reviewer git write deny",
     '        if (repo_may_be_reviewer\n'
     '                and (subcommand in GIT_WRITERS or subcommand not in GIT_READERS)):\n'
     '            return True\n',
     '        if (repo_may_be_reviewer\n'
     '                and (subcommand in GIT_WRITERS or subcommand not in GIT_READERS)):\n'
     '            return False\n',
     git_input, True, False, "consumer"),
    ("relevance gate lets unrelated commands through",
     "        if not _bash_related(command, cwd, reviewer_real):\n            return None\n",
     "",
     gate_input, False, True, "consumer"),
    ("related command with a variable write is unverifiable",
     "        if _related_unverifiable(command):\n            return only\n",
     "",
     local_var_input, True, False, "consumer"),
    ("fd number is not taken as a cp argument",
     '    command = re.sub(r"(?<![^\\s;&|(])\\d+(?=>)", "", command)\n',
     "",
     fd_number_input, True, False, "consumer"),
    ("find -fprint target is a write",
     'FIND_FILE_ACTIONS = ("-fprint", "-fprint0", "-fprintf", "-fls")\n',
     'FIND_FILE_ACTIONS = ()\n',
     find_fprint_input, True, False, "consumer"),
    ("sort short -o target is a write",
     '                    if char == "o":\n',
     '                    if False:\n',
     sort_short_output_input, True, False, "consumer"),
    ("sort long --output target is a write",
     '                elif "--output".startswith(name):\n',
     '                elif False:\n',
     sort_long_output_input, True, False, "consumer"),
    ("sort -T is unverifiable",
     '                    if char == "T":\n                        return [], True\n',
     '',
     sort_tempdir_input, True, False, "consumer"),
    ("uniq second operand is a write",
     '        return values[1:2], False\n',
     '        return [], False\n',
     uniq_output_input, True, False, "consumer"),
    ("sort and uniq are known commands",
     '                  "rsync", "sed", "sort", "tee", "touch", "truncate", "uniq"}\n',
     '                  "rsync", "sed", "tee", "touch", "truncate"}\n',
     sort_pipe_input, False, True, "consumer"),
    ("cut tr nl are readers",
     '    "cmp", "diff", "stat", "cut", "tr", "nl",\n',
     '    "cmp", "diff", "stat",\n',
     cut_reader_input, False, True, "consumer"),
    ("test and [ are readers",
     '    "test", "[",\n',
     '',
     test_reader_input, False, True, "consumer"),
    ("reader redirection targets are checked",
     '    elif executable in READERS:\n'
     '        return any(not _check_target(target, cwd, reviewer, allowed)\n'
     '                   for target in redirection_targets)\n',
     '    elif executable in READERS:\n'
     '        return False\n',
     test_redirect_input, True, False, "consumer"),
]


def cache_invalidation_pair():
    old = '                and record.get("signature") == list(signature)\n'
    new = '                and True\n'
    with tempfile.TemporaryDirectory(prefix="superpowers-cache-mut-") as td:
        root = pathlib.Path(td)
        reviewer, project, _, config, base_env = fixture(root)
        new_reviewer = root / "reviewer-new"
        new_reviewer.mkdir()
        variant = mutate_copy(root, old, new)
        env_base = base_env.copy()
        env_mutant = base_env.copy()
        env_base["XDG_CACHE_HOME"] = str(root / "cache-base")
        env_mutant["XDG_CACHE_HOME"] = str(root / "cache-mutant")
        initial = {"file_path": str(reviewer / "reviews/consumer/docs/superpowers/x.md")}
        if run(source_path, env_base, project, "Write", initial):
            raise NotRun("baseline cache warm-up failed")
        if run(source_path, env_mutant, project, "Write", initial):
            raise NotRun("mutant cache warm-up control failed")
        config.write_text(json.dumps({"reviewer": str(new_reviewer)}), encoding="utf-8")
        st = config.stat()
        os.utime(config, ns=(st.st_atime_ns, st.st_mtime_ns + 10_000_000))
        target = {"file_path": str(new_reviewer / "reviews/other/x.md")}
        base = run(source_path, env_base, project, "Write", target)
        if not base:
            raise NotRun("changed-config baseline did not use new reviewer")
        mutant = run(variant, env_mutant, project, "Write", target)
        return not mutant


def registration_pair():
    with tempfile.TemporaryDirectory(prefix="superpowers-register-mut-") as td:
        root = pathlib.Path(td)
        template = root / "tools/templates/settings-hooks.json"
        hook = root / "tools/templates/hooks/superpowers-doc-guard.py"
        test = root / "tests/superpowers-doc-guard.sh"
        template.parent.mkdir(parents=True)
        hook.parent.mkdir(parents=True)
        test.parent.mkdir(parents=True)
        shutil.copyfile(source_path, hook)
        shutil.copyfile(contract_path, test)
        shutil.copyfile(settings_path, template)
        env = os.environ.copy()
        env["ONLY"] = "registration"
        control = subprocess.run(["bash", str(contract_path)], text=True,
                                 capture_output=True, env={**env, "ONLY": "registration"})
        data = json.loads(template.read_text(encoding="utf-8"))
        data["PreToolUse"] = [group for group in data.get("PreToolUse", [])
                               if not any("superpowers-doc-guard.py" in entry.get("command", "")
                                          for entry in group.get("hooks", []))]
        template.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        result = subprocess.run(["bash", str(test)], text=True, capture_output=True,
                                env={**env, "ONLY": "registration"})
        fd, log_name = tempfile.mkstemp(prefix="superpowers-doc-guard-registration-",
                                        suffix=".log")
        os.close(fd)
        log_path = pathlib.Path(log_name)
        with log_path.open("w", encoding="utf-8") as stream:
            stream.write("CONTROL exit=%d\n" % control.returncode)
            stream.write(control.stdout)
            stream.write(control.stderr)
            stream.write("MUTANT exit=%d\n" % result.returncode)
            stream.write(result.stdout)
            stream.write(result.stderr)
        print("REGISTRATION MUTATION LOG: %s" % log_path)
        print("--- registration mutant raw output ---")
        print("CONTROL exit=%d" % control.returncode)
        print(control.stdout, end="")
        if control.stderr:
            print(control.stderr, end="", file=sys.stderr)
        print("MUTANT exit=%d" % result.returncode)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        if control.returncode:
            raise NotRun("unmutated registration control failed")
        return result.returncode != 0


def sentinel():
    old = "            if _inside(target, reviewer) and not (allowed is not None and _inside(target, allowed)):\n"
    survived = not paired("sentinel", old, old, write_input, True, False, "consumer")
    if survived:
        print("MUTATION RESULT: SURVIVED")
        sys.exit(1)
    print("MUTATION RESULT: NOT RUN")
    sys.exit(2)

if os.environ.get("MUTATION_SENTINEL") == "1":
    sentinel()

killed = survived = not_run = 0
for name, old, new, case, base_expected, mutant_expected, project_name in mutants:
    try:
        result = paired(name, old, new, case, base_expected, mutant_expected, project_name)
    except NotRun as exc:
        print("NOT RUN mutant: %s (%s)" % (name, exc))
        not_run += 1
        continue
    if result:
        print("KILLED mutant: %s" % name)
        killed += 1
    else:
        print("SURVIVED mutant: %s" % name)
        survived += 1

for name, action in (("cache invalidation", cache_invalidation_pair),
                     ("fixed template registration", registration_pair)):
    try:
        result = action()
    except NotRun as exc:
        print("NOT RUN mutant: %s (%s)" % (name, exc))
        not_run += 1
        continue
    if result:
        print("KILLED mutant: %s" % name)
        killed += 1
    else:
        print("SURVIVED mutant: %s" % name)
        survived += 1

with tempfile.TemporaryDirectory(prefix="superpowers-survivor-") as td:
    output = pathlib.Path(td) / "sentinel.out"
    with open(output, "w", encoding="utf-8") as stream:
        sentinel_run = subprocess.run(["bash", str(script)],
                                      env={**os.environ, "MUTATION_SENTINEL": "1"},
                                      stdout=stream, stderr=subprocess.STDOUT)
    last = output.read_text(encoding="utf-8").splitlines()[-1:]
    if sentinel_run.returncode != 1 or last != ["MUTATION RESULT: SURVIVED"]:
        print("NOT RUN survivor sentinel (wrong exit/result)")
        not_run += 1
    else:
        print("PASS survivor sentinel reports SURVIVED and exits 1")

if not_run:
    print("MUTATION RESULT: NOT RUN")
    sys.exit(2)
if survived:
    print("MUTATION RESULT: SURVIVED")
    sys.exit(1)
if killed != len(mutants) + 2:
    print("MUTATION RESULT: NOT RUN")
    sys.exit(2)
print("MUTATION RESULT: ALL KILLED")
PY

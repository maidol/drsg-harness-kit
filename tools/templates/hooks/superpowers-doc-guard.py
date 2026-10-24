#!/usr/bin/env python3
"""Restrict writes into the reviewer's repository to this project's archive."""
import json
import os
import sys

DENIAL_PREFIX = "Writing to the reviewer repository is restricted"
READERS = {
    "cat", "head", "tail", "sed", "grep", "rg", "ls", "wc", "sha256sum",
    "cmp", "diff", "stat", "cut", "tr", "nl",
}
GIT_READERS = {"diff", "log", "show", "status"}
GIT_WRITERS = {
    "add", "am", "apply", "branch", "checkout", "cherry-pick", "clean",
    "commit", "fetch", "init", "merge", "mv", "pull", "push", "rebase",
    "reset", "restore", "rm", "stash", "switch", "tag", "worktree",
}
STATIC_WRITERS = {"cp", "dd", "find", "install", "ln", "mkdir", "mv", "rm",
                  "rsync", "sed", "sort", "tee", "touch", "truncate", "uniq"}
FIND_FILE_ACTIONS = ("-fprint", "-fprint0", "-fprintf", "-fls")
SHELL_SEPARATORS = {";", "&&", "||", "|", "|&", "&", "\n"}
REDIRECTS = {">", ">>", ">|", "&>", "&>>", "1>", "1>>", "2>", "2>>"}
def _inside(path, root):
    try:
        return os.path.commonpath((path, root)) == root
    except (TypeError, ValueError):
        return False


def _has_symlink_component(path):
    """Return true if an existing component is a symlink or cannot be checked."""
    absolute = os.path.abspath(path)
    current = os.path.sep
    for part in absolute.split(os.path.sep):
        if not part:
            continue
        current = os.path.join(current, part)
        try:
            if os.lstat(current).st_mode & 0o170000 == 0o120000:
                return True
        except FileNotFoundError:
            return False
        except OSError:
            return True
    return False


def _config_path():
    memory_dir = os.environ.get("DRSG_MEM_DIR") or os.path.join(
        os.path.expanduser("~"), ".drsg-memory")
    return os.path.join(memory_dir, "commit-auth.json")


def _cache_path():
    cache_home = os.environ.get("XDG_CACHE_HOME") or os.path.join(
        os.path.expanduser("~"), ".cache")
    return os.path.join(cache_home, "drsg", "superpowers-docs", "reviewer-cache.json")


def _cache_record(path, config_path, signature):
    try:
        with open(path, encoding="utf-8") as stream:
            record = json.load(stream)
        if (isinstance(record, dict) and record.get("config_path") == config_path
                and record.get("signature") == list(signature)
                and isinstance(record.get("reviewer_realpath"), str)):
            return record["reviewer_realpath"]
    except (OSError, ValueError, TypeError):
        pass
    return None


def _write_cache(path, config_path, signature, reviewer):
    import tempfile
    directory = os.path.dirname(path)
    temporary = None
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".reviewer-cache-", dir=directory)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump({"config_path": config_path, "signature": list(signature),
                       "reviewer_realpath": reviewer}, stream, separators=(",", ":"))
            stream.write("\n")
        os.replace(temporary, path)
        temporary = None
    except OSError:
        pass
    finally:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def load_reviewer():
    """Load only `reviewer`, reusing a private cache keyed by config stat."""
    config_path = os.path.abspath(_config_path())
    try:
        st = os.stat(config_path)
    except OSError:
        return None
    signature = (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)
    cached = _cache_record(_cache_path(), config_path, signature)
    if cached:
        return cached
    try:
        with open(config_path, encoding="utf-8") as stream:
            data = json.load(stream)
        candidate = data.get("reviewer") if isinstance(data, dict) else None
        if not isinstance(candidate, str) or not os.path.isabs(candidate):
            return None
        reviewer = os.path.realpath(candidate)
        if not os.path.isdir(reviewer):
            return None
    except (OSError, ValueError, TypeError):
        return None
    _write_cache(_cache_path(), config_path, signature, reviewer)
    return reviewer


def _project_path(data):
    configured = os.environ.get("CLAUDE_PROJECT_DIR")
    event_cwd = data.get("cwd")
    if not isinstance(event_cwd, str) or not event_cwd:
        event_cwd = os.getcwd()
    if not os.path.isabs(event_cwd):
        event_cwd = os.path.abspath(event_cwd)
    if not configured:
        return None, event_cwd
    if not os.path.isabs(configured):
        configured = os.path.abspath(configured)
    # A tool call may run below the project root, never outside it.
    if not _inside(event_cwd, configured):
        return None, event_cwd
    return configured, event_cwd


def _project_realpath(project):
    if not project:
        return None
    return os.path.realpath(project)


def _state_path(project_real):
    config_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    import hashlib
    identity = hashlib.sha256(project_real.encode("utf-8")).hexdigest()
    return os.path.join(config_home, "drsg", "superpowers-docs-state", identity + ".json")


def _state_status(project_real, reviewer):
    path = _state_path(project_real)
    try:
        with open(path, encoding="utf-8") as stream:
            state = json.load(stream)
    except FileNotFoundError:
        return "missing"
    except (OSError, ValueError, TypeError):
        return "invalid"
    # Same schema as tools/superpowers_docs.py _write_state: project, reviewer,
    # allow, enabled, opt_out. An opt-out may predate any reviewer.
    if not isinstance(state, dict) or state.get("project") != project_real:
        return "invalid"
    if state.get("opt_out") is True:
        return "opt-out"
    if state.get("reviewer") != reviewer or state.get("enabled") is not True:
        return "invalid"
    return "enabled"


def _resolve(path, cwd):
    if not isinstance(path, str) or not path:
        raise ValueError("missing target")
    candidate = os.path.abspath(os.path.join(cwd, _expand_shell_path(path)))
    if _has_symlink_component(candidate):
        # Force the slow path for aliases; realpath below resolves every link.
        pass
    return os.path.realpath(candidate)


def _deny(detail="cannot verify the write target"):
    reason = ("%s; only this project's archive is allowed. %s "
              "If only the reviewer can unblock the next step, send a "
              '`kind="handoff"` Event with `summary` beginning `请求协助：` '
              "before ending; this guard never sends it. "
              "To read a reviewer file with a script, first copy it in its own "
              "command (cp <file> /tmp/), then run the script on the copy in a "
              "separate command." %
              (DENIAL_PREFIX, detail))
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def _expand_shell_path(path):
    import re
    pattern = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
    expanded = pattern.sub(lambda match: os.environ.get(match.group(1) or match.group(2), ""), path)
    return os.path.expanduser(expanded)


def _brace_variants(path):
    start = path.find("{")
    end = path.find("}", start + 1) if start >= 0 else -1
    if end < 0:
        return [path]
    choices = path[start + 1:end].split(",")
    if len(choices) < 2 or len(choices) > 64:
        return [path]
    variants = []
    for choice in choices:
        variants.extend(_brace_variants(path[:start] + choice + path[end + 1:]))
        if len(variants) > 256:
            return [path]
    return variants


def _candidate_paths(path, cwd):
    import glob
    candidates = []
    for variant in _brace_variants(path):
        absolute = os.path.abspath(os.path.join(cwd, variant))
        current = [os.path.sep]
        for part in absolute.split(os.path.sep):
            if not part:
                continue
            next_paths = []
            for parent in current:
                if _path_may_be_dynamic(part) and any(char in part for char in "*?["):
                    matches = glob.glob(os.path.join(parent, part))
                    next_paths.extend(matches or [os.path.join(parent, part)])
                else:
                    next_paths.append(os.path.join(parent, part))
            current = next_paths[:256]
        candidates.extend(os.path.realpath(candidate) for candidate in current)
    return candidates


def _check_target(path, cwd, reviewer, allowed):
    expanded = _expand_shell_path(path)
    if any(marker in expanded for marker in ("$(", "`", "<(", ">(")):
        raw = os.path.abspath(os.path.join(cwd, expanded))
        return not (reviewer in expanded or os.path.basename(reviewer) in expanded
                    or _inside(os.path.realpath(cwd), reviewer) or _inside(raw, reviewer))
    try:
        for target in _candidate_paths(expanded, cwd):
            if _inside(target, reviewer) and not (allowed is not None and _inside(target, allowed)):
                return False
    except (OSError, ValueError, TypeError):
        raw = os.path.abspath(os.path.join(cwd, expanded))
        if _inside(raw, reviewer) or reviewer in raw:
            return False
    return True


def _may_reference_reviewer(path, cwd, reviewer):
    expanded = _expand_shell_path(path)
    if reviewer in expanded:
        return True
    if any(marker in expanded for marker in ("$(", "`", "<(", ">(")):
        return reviewer in expanded or os.path.basename(reviewer) in expanded
    return any(_inside(candidate, reviewer)
               for candidate in _candidate_paths(expanded, cwd))


def _tokens(command):
    import re
    import shlex
    command = re.sub(r"(?<![^\s;&|(])\d*>&(?:\d+|-)(?=$|[\s;&|)])", " ", command)
    command = re.sub(r"(?<![^\s;&|(])\d+(?=>)", "", command)
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|<>")
    lexer.whitespace_split = True
    lexer.commenters = ""
    return list(lexer)


def _split_commands(tokens):
    groups, current = [], []
    for token in tokens:
        if token in SHELL_SEPARATORS:
            if current:
                groups.append(current)
                current = []
        else:
            current.append(token)
    if current:
        groups.append(current)
    return groups


def _command_and_args(tokens):
    import re
    assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
    i = 0
    while i < len(tokens) and assignment.match(tokens[i]):
        i += 1
    while i < len(tokens) and tokens[i] in ("!", "time"):
        i += 1
    if i >= len(tokens):
        return "", [], []
    return os.path.basename(tokens[i]), tokens[i + 1:], tokens[:i]


def _git_repos(args, cwd):
    base = cwd
    repos = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "-C" and i + 1 < len(args):
            base = os.path.abspath(os.path.join(base, args[i + 1]))
            repos.append((base, cwd))
            i += 2
        elif arg.startswith("-C") and len(arg) > 2:
            base = os.path.abspath(os.path.join(base, arg[2:]))
            repos.append((base, cwd))
            i += 1
        elif arg in ("--git-dir", "--work-tree") and i + 1 < len(args):
            repos.append((args[i + 1], base))
            i += 2
        elif arg.startswith("--git-dir=") or arg.startswith("--work-tree="):
            repos.append((arg.split("=", 1)[1], base))
            i += 1
        elif arg == "--":
            break
        else:
            i += 1
    if not repos:
        repos.append((base, cwd))
    return repos


def _git_subcommand(args):
    i = 0
    value_options = {"-c", "--config-env", "--exec-path", "--git-dir", "--namespace",
                     "--super-prefix", "--work-tree"}
    while i < len(args):
        arg = args[i]
        if arg in ("-C", "-c", "--config-env", "--exec-path", "--git-dir",
                   "--namespace", "--super-prefix", "--work-tree"):
            i += 2
        elif arg.startswith("-"):
            i += 1
        else:
            return arg
    return ""


def _path_may_be_dynamic(path):
    import re
    return bool(re.search(r"[$`*?{}()\[\]]", path)) or "\\" in path


def _substitution_commands(command):
    commands = []
    i = 0
    while i < len(command):
        if command[i] == "`":
            start = i + 1
            j = start
            escaped = False
            while j < len(command):
                if command[j] == "`" and not escaped:
                    commands.append(command[start:j])
                    i = j + 1
                    break
                escaped = command[j] == "\\" and not escaped
                if command[j] != "\\":
                    escaped = False
                j += 1
            else:
                return commands
            continue
        if command.startswith(("$(", "<(", ">("), i):
            start = i + 2
            depth = 1
            quote = None
            escaped = False
            j = start
            while j < len(command):
                char = command[j]
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif quote:
                    if char == quote:
                        quote = None
                elif char in ("'", '"'):
                    quote = char
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                    if depth == 0:
                        commands.append(command[start:j])
                        i = j + 1
                        break
                j += 1
            else:
                return commands
            continue
        i += 1
    return commands


def _positional(args, skip_value_options=()):
    values = []
    i = 0
    after_separator = False
    while i < len(args):
        arg = args[i]
        if arg == "--":
            after_separator = True
            i += 1
            continue
        if not after_separator and arg.startswith("-"):
            option = arg.split("=", 1)[0]
            if option in skip_value_options and "=" not in arg:
                i += 2
            else:
                i += 1
            continue
        values.append(arg)
        i += 1
    return values


def _target_directory(args):
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("-t", "--target-directory"):
            return (args[i + 1], True) if i + 1 < len(args) else (None, True)
        if arg.startswith("--target-directory="):
            return arg.split("=", 1)[1], True
        if arg.startswith("-t="):
            return arg.split("=", 1)[1], True
        i += 1
    return None, False


def _writer_targets(executable, args, cwd):
    """Return (targets, uncertain) for statically recognizable writer forms."""
    if executable == "tee":
        targets = [arg for arg in args if not arg.startswith("-") and arg != "-"]
        return targets, not targets
    if executable in ("cp", "mv"):
        target_dir, has_target_dir = _target_directory(args)
        values = _positional(args, ("--target-directory", "-t"))
        if has_target_dir:
            if not target_dir or not values:
                return [], True
            targets = [os.path.join(target_dir, os.path.basename(src.rstrip(os.path.sep)))
                       for src in values]
            if executable == "mv":
                targets.extend(values)
            return targets, False
        if len(values) < 2:
            return [], True
        destination = values[-1]
        dest_abs = os.path.abspath(os.path.join(cwd, destination))
        is_dir = destination.endswith(os.path.sep) or os.path.isdir(dest_abs)
        if is_dir:
            return [os.path.join(destination, os.path.basename(src.rstrip(os.path.sep)))
                    for src in values[:-1]], False
        targets = [destination]
        if executable == "mv":
            targets.extend(values[:-1])
        return targets, False
    if executable in ("mkdir", "rm", "touch"):
        values = _positional(args)
        return values, not bool(values)
    if executable == "truncate":
        values = _positional(args, ("-s", "--size", "--size=", "-s="))
        return values, not bool(values)
    if executable == "install":
        values = _positional(args, ("-m", "-o", "-g", "-t", "--mode", "--owner", "--group", "--target-directory"))
        target_dir, has_target_dir = _target_directory(args)
        if has_target_dir:
            if not target_dir or not values:
                return [], True
            return [os.path.join(target_dir, os.path.basename(src)) for src in values], False
        if len(values) < 2:
            return [], True
        return [values[-1]], False
    if executable == "ln":
        values = _positional(args, ("-t", "--target-directory"))
        target_dir, has_target_dir = _target_directory(args)
        if has_target_dir:
            if not target_dir or not values:
                return [], True
            return [os.path.join(target_dir, os.path.basename(src)) for src in values], False
        if len(values) < 2:
            return [], True
        return [values[-1]], False
    if executable == "sed":
        if not any(arg == "-i" or arg.startswith("--in-place") or
                   (arg.startswith("-i") and arg != "-i") for arg in args):
            return [], False
        values = _positional(args, ("-e", "--expression", "-f", "--file"))
        return values[1:], len(values) < 2
    if executable == "find":
        start = []
        files = []
        has_action = False
        i = 0
        while i < len(args):
            arg = args[i]
            if arg in FIND_FILE_ACTIONS:
                # -fprint FILE and its siblings create or truncate FILE.
                if i + 1 >= len(args):
                    return [], True
                files.append(args[i + 1])
                i += 2
                continue
            if arg in ("-delete", "-exec", "-execdir", "-ok", "-okdir"):
                has_action = True
            elif not arg.startswith("-") and not has_action:
                start.append(arg)
            i += 1
        if not has_action:
            return files, False
        return (start or ["."]) + files, False
    if executable == "sort":
        # -o/--output names the output file; -T/--temporary-directory writes
        # temporary files and --compress-program runs a program, so neither
        # can be verified here.
        targets = []
        i = 0
        while i < len(args):
            arg = args[i]
            if arg == "--":
                break
            if arg.startswith("--"):
                name, has_value, value = arg.partition("=")
                if len(name) < 3:
                    pass
                elif "--output".startswith(name):
                    if has_value:
                        targets.append(value)
                    elif i + 1 < len(args):
                        i += 1
                        targets.append(args[i])
                    else:
                        return [], True
                elif ("--temporary-directory".startswith(name)
                      or "--compress-program".startswith(name)):
                    return [], True
            elif arg.startswith("-") and arg != "-":
                for j in range(1, len(arg)):
                    char = arg[j]
                    if char in "kSt":
                        if j == len(arg) - 1:
                            i += 1
                        break
                    if char == "T":
                        return [], True
                    if char == "o":
                        if j < len(arg) - 1:
                            targets.append(arg[j + 1:])
                        elif i + 1 < len(args):
                            i += 1
                            targets.append(args[i])
                        else:
                            return [], True
                        break
            i += 1
        return targets, False
    if executable == "uniq":
        # uniq [INPUT [OUTPUT]] writes its second operand; "-" is an operand.
        values = []
        after_separator = False
        i = 0
        while i < len(args):
            arg = args[i]
            if not after_separator and arg == "--":
                after_separator = True
            elif not after_separator and arg in ("-f", "-s", "-w", "--skip-fields",
                                                 "--skip-chars", "--check-chars"):
                i += 1
            elif after_separator or arg == "-" or not arg.startswith("-"):
                values.append(arg)
            i += 1
        return values[1:2], False
    if executable == "dd":
        destinations = [arg[3:] for arg in args if arg.startswith("of=")]
        return destinations, not bool(destinations)
    if executable == "rsync":
        values = _positional(args)
        return ([values[-1]] if len(values) >= 2 else []), len(values) < 2
    return [], True


def _segment_decision(tokens, cwd, reviewer, allowed):
    """Return True if any operation in the segment is outside the safe subtree."""
    command_tokens = []
    redirection_targets = []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token in REDIRECTS:
            if i + 1 >= len(tokens) or tokens[i + 1] in SHELL_SEPARATORS:
                return True
            target = tokens[i + 1]
            if target in ("&1", "&2"):
                return True
            redirection_targets.append(target)
            i += 2
        elif token in ("<<<", "<<", "<<-"):
            # Here-documents and here-strings feed input; they write no file.
            i += 2
        elif token in (">&", "<>"):
            # Duplications were removed by _tokens; what is left is unparsed.
            return True
        elif token == "<":
            # Input redirection and process substitution do not write a file;
            # substitutions are checked separately by _bash_decision.
            i += 2
        else:
            command_tokens.append(token)
            i += 1

    executable, args, _ = _command_and_args(command_tokens)
    if not executable:
        return any(not _check_target(target, cwd, reviewer, allowed)
                   for target in redirection_targets)

    if executable == "git":
        subcommand = _git_subcommand(args)
        repo_may_be_reviewer = False
        for repo, base in _git_repos(args, cwd):
            if _may_reference_reviewer(repo, base, reviewer):
                repo_may_be_reviewer = True
                continue
            for repo_real in _candidate_paths(_expand_shell_path(repo), base):
                repo_may_be_reviewer |= _inside(repo_real, reviewer)
        if (repo_may_be_reviewer
                and (subcommand in GIT_WRITERS or subcommand not in GIT_READERS)):
            return True
        return any(not _check_target(target, cwd, reviewer, allowed)
                   for target in redirection_targets)

    if executable == "sed":
        targets, uncertain = _writer_targets(executable, args, cwd)
        if not targets and not uncertain:
            return any(not _check_target(target, cwd, reviewer, allowed)
                       for target in redirection_targets)
    elif executable in READERS:
        return any(not _check_target(target, cwd, reviewer, allowed)
                   for target in redirection_targets)
    elif executable in ("echo", "printf", ":"):
        targets, uncertain = [], False
    elif executable in STATIC_WRITERS:
        targets, uncertain = _writer_targets(executable, args, cwd)
    else:
        targets, uncertain = [], False
        if (_inside(os.path.realpath(cwd), reviewer) or
                any(_may_reference_reviewer(arg, cwd, reviewer) for arg in args)):
            uncertain = True
    if uncertain:
        return (_inside(os.path.realpath(cwd), reviewer) or
                any(_may_reference_reviewer(arg, cwd, reviewer) for arg in args))
    targets.extend(redirection_targets)
    return any(not _check_target(target, cwd, reviewer, allowed) for target in targets)


def _bash_decision(command, cwd, reviewer, allowed):
    if _has_symlink_component(cwd):
        cwd = os.path.realpath(cwd)
    for nested in _substitution_commands(command):
        if _bash_decision(nested, cwd, reviewer, allowed):
            return True
    try:
        tokens = _tokens(command)
    except (ValueError, TypeError):
        return True
    segments = _split_commands(tokens)
    current = cwd
    for segment in segments:
        executable, args, _ = _command_and_args(segment)
        if executable in ("cd", "pushd"):
            values = [arg for arg in args if not arg.startswith("-")]
            if len(values) != 1:
                if _inside(os.path.realpath(current), reviewer) or reviewer in command:
                    return True
                current = None
            else:
                value = _expand_shell_path(values[0])
                if _path_may_be_dynamic(value):
                    if _may_reference_reviewer(value, current or cwd, reviewer):
                        return True
                    current = None
                else:
                    try:
                        current = _resolve(value, current or cwd)
                    except (OSError, ValueError, TypeError):
                        return True
            continue
        if current is None:
            if executable not in READERS or any(token in segment for token in REDIRECTS):
                return True
            continue
        if _segment_decision(segment, current, reviewer, allowed):
            return True
    return False


def _strip_heredocs(command):
    """Drop here-document bodies; they are data, not shell words."""
    import re
    kept, pending = [], []
    for line in command.split("\n"):
        if pending:
            if line.lstrip("\t") == pending[0]:
                pending.pop(0)
            continue
        kept.append(line)
        for match in re.finditer(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line):
            pending.append(match.group(2))
    return "\n".join(kept)


RELATED_WORD_LIMIT = 5000


def _bash_related(command, cwd, reviewer):
    """True if any word of the command could name a path in the reviewer repository.

    Unrelated commands are allowed without parsing: whatever they write
    cannot land in the reviewer repository. Every word is checked, including
    quoted strings and here-document bodies, because `bash -c '...'` and
    `bash <<EOF` run them.
    """
    import re
    cwd_real = os.path.realpath(cwd)
    if _inside(cwd_real, reviewer):
        return True
    if reviewer in command or os.path.basename(reviewer) in command:
        return True
    words = set(re.split(r"[\s;&|<>()`'\"=]+", command))
    if len(words) > RELATED_WORD_LIMIT:
        return True
    for word in words:
        if not word:
            continue
        expanded = _expand_shell_path(word)
        if "/" not in expanded:
            # A bare name lives in cwd; only a symlink there can lead elsewhere.
            if os.path.islink(os.path.join(cwd_real, expanded)):
                if _inside(os.path.realpath(os.path.join(cwd_real, expanded)), reviewer):
                    return True
            continue
        try:
            if any(_inside(candidate, reviewer)
                   for candidate in _candidate_paths(expanded, cwd_real)):
                return True
        except (OSError, ValueError, TypeError):
            return True
    return False


def _segment_read_only(segment):
    executable, args, _ = _command_and_args(segment)
    if any(token in REDIRECTS or token in (">", ">>") for token in segment):
        return False
    if executable == "sed":
        return not any(arg == "-i" or arg.startswith("--in-place")
                       or (arg.startswith("-i") and arg != "-i") for arg in args)
    if executable == "git":
        return _git_subcommand(args) in GIT_READERS
    return executable in READERS or executable in ("echo", "printf", ":", "cd", "pushd", "popd")


RELATED_KNOWN = READERS | STATIC_WRITERS | {"echo", "printf", ":", "git", "cd", "pushd", "popd"}


def _related_unverifiable(command):
    """For a command related to the reviewer: True if it cannot be verified.

    Variables, substitutions and programs whose writes the parser cannot see
    are only acceptable when nothing in the command writes.
    """
    import re
    try:
        segments = _split_commands(_tokens(_strip_heredocs(command)))
    except (ValueError, TypeError):
        return True
    read_only = all(_segment_read_only(segment) for segment in segments)
    if re.search(r"[$`]|<\(|>\(", command) and not read_only:
        return True
    for segment in segments:
        executable, _, _ = _command_and_args(segment)
        if executable and executable not in RELATED_KNOWN:
            return True
    return False


def _bash_fast_read_only(command):
    if _substitution_commands(command):
        return False
    try:
        tokens = _tokens(command)
    except (ValueError, TypeError):
        return False
    if any(token in SHELL_SEPARATORS or token in REDIRECTS or token in ("<", ">")
           for token in tokens):
        return False
    if any(char in command for char in "*?[]{}\\"):
        return False
    executable, args, _ = _command_and_args(tokens)
    if executable == "sed" and any(arg == "-i" or arg.startswith("--in-place")
                                    or (arg.startswith("-i") and arg != "-i") for arg in args):
        return False
    if executable in READERS:
        return not any(_path_may_be_dynamic(arg) for arg in args)
    if executable in ("echo", "printf", ":"):
        return not any("`" in arg or "$(" in arg for arg in args)
    return False


def _fast_allow(data, reviewer, project, cwd, tool, tool_input):
    if _has_symlink_component(project) or _has_symlink_component(cwd):
        return False
    project_abs = os.path.abspath(project)
    cwd_abs = os.path.abspath(cwd)
    if not _inside(cwd_abs, project_abs):
        return False
    if _inside(cwd_abs, reviewer):
        return False
    if project_abs == reviewer:
        return True
    if tool in ("Write", "Edit", "NotebookEdit"):
        field = "notebook_path" if tool == "NotebookEdit" else "file_path"
        target = tool_input.get(field)
        if not isinstance(target, str) or not target:
            return False
        if reviewer in target or os.path.basename(reviewer) in target or ".." in target.split(os.path.sep):
            return False
        return not _has_symlink_component(os.path.join(cwd, target))
    if tool == "Bash":
        command = tool_input.get("command")
        return isinstance(command, str) and _bash_fast_read_only(command)
    return False


def decide(data):
    """Return None to allow or a safe denial reason."""
    if not isinstance(data, dict):
        return "invalid hook input"
    tool = data.get("tool_name")
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return "invalid hook input"
    reviewer = load_reviewer()
    if not reviewer:
        return None
    project, cwd = _project_path(data)
    if not cwd:
        return None
    try:
        reviewer_real = reviewer
        if tool not in ("Bash", "Write", "Edit", "NotebookEdit"):
            return None
        if project and _fast_allow(data, reviewer_real, project, cwd, tool, tool_input):
            return None
        project_real = _project_realpath(project) if project else None
        if project_real == reviewer_real:
            return None
        state_invalid = False
        if project_real:
            state = _state_status(project_real, reviewer_real)
            if state == "opt-out":
                return None
            state_invalid = state == "invalid"
        allowed = (os.path.join(reviewer_real, "reviews", os.path.basename(project_real),
                                "docs", "superpowers")
                   if project_real and not state_invalid else None)
        if tool in ("Write", "Edit", "NotebookEdit"):
            field = "notebook_path" if tool == "NotebookEdit" else "file_path"
            target = tool_input.get(field)
            if not isinstance(target, str) or not target:
                return "cannot verify the write target"
            if not _check_target(target, cwd, reviewer_real, allowed):
                return "only %s is allowed" % allowed
            return None
        command = tool_input.get("command")
        if not isinstance(command, str) or not command:
            return "cannot verify the Bash command"
        if not _bash_related(command, cwd, reviewer_real):
            return None
        if _related_unverifiable(command):
            return "only %s is allowed" % allowed
        if _bash_decision(_strip_heredocs(command), cwd, reviewer_real, allowed):
            return "only %s is allowed" % allowed
        return None
    except (OSError, ValueError, TypeError):
        return "cannot safely resolve the write target"


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        _deny("invalid hook input")
        return
    reason = decide(data)
    if reason:
        _deny(reason)


if __name__ == "__main__":
    main()

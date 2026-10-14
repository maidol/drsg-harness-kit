#!/usr/bin/env python3
"""PreToolUse guard for event CLI and user-only lease transfer commands."""
import json
import os
import re
import shlex
import sys


TARGET_TEXT = re.compile(r"event\.py|event-poller\.py")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PYTHON = re.compile(r"^python(?:3(?:\.\d+)?)?$")


class ParseError(ValueError):
    pass


def _matching_paren(text, start):
    depth = 1
    quote = None
    escaped = False
    i = start + 2
    while i < len(text):
        char = text[i]
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if char == '"':
                quote = None
            elif text.startswith("$(", i):
                depth += 1
                i += 1
        elif char in "'\"":
            quote = char
        elif text.startswith("$(", i):
            depth += 1
            i += 1
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("unclosed command substitution")


def _matching_group(text, start):
    depth = 1
    quote = None
    escaped = False
    i = start + 1
    while i < len(text):
        char = text[i]
        if escaped:
            escaped = False
        elif char == "\\" and quote != "'":
            escaped = True
        elif quote == "'":
            if char == "'":
                quote = None
        elif quote == '"':
            if char == '"':
                quote = None
            elif text.startswith("$(", i):
                close = _matching_paren(text, i)
                i = close
        elif char in "'\"":
            quote = char
        elif text.startswith("$(", i):
            close = _matching_paren(text, i)
            i = close
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("unclosed command group")


def _matching_backtick(text, start):
    escaped = False
    i = start + 1
    while i < len(text):
        if escaped:
            escaped = False
        elif text[i] == "\\":
            escaped = True
        elif text[i] == "`":
            return i
        i += 1
    raise ParseError("unclosed backtick substitution")


def _split_segments(text, depth):
    if depth > 8:
        raise ParseError("command substitution nesting limit exceeded")
    segments = []
    nested_take = False
    nested_deny = False
    current = []
    quote = None
    escaped = False
    i = 0

    def flush():
        value = "".join(current).strip()
        current.clear()
        if value:
            segments.append(value)

    while i < len(text):
        char = text[i]
        if escaped:
            current.append(char)
            escaped = False
            i += 1
            continue
        if quote == "'":
            current.append(char)
            if char == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if char == '"':
                current.append(char)
                quote = None
                i += 1
                continue
            if char == "\\":
                current.append(char)
                escaped = True
                i += 1
                continue
            if text.startswith("$(", i):
                close = _matching_paren(text, i)
                sub_take, sub_deny = _analyze(text[i + 2:close], depth + 1, 0)
                nested_take = nested_take or sub_take
                nested_deny = nested_deny or sub_deny
                current.append(text[i:close + 1])
                i = close + 1
                continue
            if char == "`":
                close = _matching_backtick(text, i)
                sub_take, sub_deny = _analyze(text[i + 1:close], depth + 1, 0)
                nested_take = nested_take or sub_take
                nested_deny = nested_deny or sub_deny
                current.append(text[i:close + 1])
                i = close + 1
                continue
            current.append(char)
            i += 1
            continue
        if char == "\\":
            current.append(char)
            escaped = True
            i += 1
        elif char in "'\"":
            current.append(char)
            quote = char
            i += 1
        elif text.startswith("$(", i):
            close = _matching_paren(text, i)
            sub_take, sub_deny = _analyze(text[i + 2:close], depth + 1, 0)
            nested_take = nested_take or sub_take
            nested_deny = nested_deny or sub_deny
            current.append(text[i:close + 1])
            i = close + 1
        elif char == "`":
            close = _matching_backtick(text, i)
            sub_take, sub_deny = _analyze(text[i + 1:close], depth + 1, 0)
            nested_take = nested_take or sub_take
            nested_deny = nested_deny or sub_deny
            current.append(text[i:close + 1])
            i = close + 1
        elif char == "(":
            if not "".join(current).strip():
                close = _matching_group(text, i)
                sub_take, sub_deny = _analyze(text[i + 1:close], depth + 1, 0)
                nested_take = nested_take or sub_take
                nested_deny = nested_deny or sub_deny
                i = close + 1
            else:
                current.append(char)
                i += 1
        elif char in ";|&\n":
            flush()
            if char in "|&" and i + 1 < len(text) and text[i + 1] == char:
                i += 2
            else:
                i += 1
        else:
            current.append(char)
            i += 1
    if quote is not None or escaped:
        raise ParseError("unclosed quote or escape")
    flush()
    return segments, nested_take, nested_deny


def _command_start(argv, shell_c_depth):
    """Return (executable index, possible shell -c script) for known wrappers."""
    i = 0
    while i < len(argv) and ASSIGNMENT.match(argv[i]):
        i += 1
    while i < len(argv):
        name = os.path.basename(argv[i])
        if name == "env":
            i += 1
            while i < len(argv):
                arg = argv[i]
                if arg in ("-i", "--ignore-environment"):
                    i += 1
                elif arg in ("-u", "--unset"):
                    i += 2
                elif arg.startswith("--unset="):
                    i += 1
                elif ASSIGNMENT.match(arg):
                    i += 1
                elif arg == "--":
                    i += 1
                    break
                elif arg.startswith("-"):
                    return None, None
                else:
                    break
            continue
        if name == "command":
            i += 1
            while i < len(argv) and argv[i] in ("-p", "-v", "-V"):
                i += 1
            continue
        if name == "exec":
            i += 1
            while i < len(argv) and argv[i].startswith("-") and argv[i] != "--":
                if argv[i] in ("-a",):
                    i += 2
                else:
                    i += 1
            if i < len(argv) and argv[i] == "--":
                i += 1
            continue
        if name == "nohup":
            i += 1
            continue
        if name == "timeout":
            i += 1
            while i < len(argv) and argv[i].startswith("-"):
                arg = argv[i]
                i += 1
                if arg in ("-k", "--kill-after", "-s", "--signal"):
                    i += 1
            if i < len(argv):
                i += 1  # duration
            continue
        if name == "uv" and i + 1 < len(argv) and argv[i + 1] == "run":
            i += 2
            while i < len(argv) and argv[i].startswith("-"):
                if argv[i] in ("--with", "--with-requirements", "--python", "--directory", "--project"):
                    i += 2
                else:
                    i += 1
            if i < len(argv) and argv[i] == "--":
                i += 1
            continue
        if name in ("bash", "sh") and shell_c_depth < 1:
            i += 1
            while i < len(argv) and argv[i].startswith("-") and argv[i] != "-c":
                i += 1
            if i + 1 < len(argv) and argv[i] == "-c":
                return i, argv[i + 1]
            return None, None
        return i, None
    return None, None


def _analyze_segment(segment, depth, shell_c_depth):
    try:
        argv = shlex.split(segment, posix=True)
    except ValueError as exc:
        raise ParseError(str(exc))
    while argv and argv[0] in ("then", "do", "else", "elif", "time"):
        argv.pop(0)
    if not argv:
        return False, False
    index, shell_script = _command_start(argv, shell_c_depth)
    if shell_script is not None:
        return _analyze(shell_script, depth + 1, shell_c_depth + 1)
    if index is None or index >= len(argv):
        return False, False

    executable = os.path.basename(argv[index])
    args = argv[index + 1:]
    if PYTHON.match(executable):
        while args and args[0].startswith("-"):
            option = args.pop(0)
            if option == "-X":
                if args:
                    args.pop(0)
                else:
                    return False, False
            elif option == "--":
                break
            elif option in ("-u", "-B", "-E", "-I"):
                continue
            else:
                # Unknown interpreter options are not guessed past.
                return False, False
        if not args:
            return False, False
        executable = os.path.basename(args.pop(0))
    if executable == "event-poller.py":
        return "--take" in args, False
    if executable != "event.py":
        return False, False

    subcommand = None
    for arg in args:
        if arg == "--":
            break
        if arg in ("-h", "--help"):
            return False, False
        if not arg.startswith("-"):
            subcommand = arg
            break
    if subcommand not in ("post", "list", "done"):
        return False, False
    for arg in args:
        if arg == "--":
            break
        if arg in ("-h", "--help"):
            return False, False
    return False, True


def _analyze(text, depth=0, shell_c_depth=0):
    segments, take, deny = _split_segments(text, depth)
    for segment in segments:
        segment_take, segment_deny = _analyze_segment(segment, depth, shell_c_depth)
        take = take or segment_take
        deny = deny or segment_deny
    return take, deny


def _denial(take):
    reason = (
        "Only the user may take the Event-owner lease; run ! python3 "
        "~/.drsg-memory/tools/event-poller.py --take in the user shell."
        if take else
        "Running event.py via Bash inside a session is disabled. "
        "Use the MCP tools instead: mcp__drsg-events__event_post, "
        "mcp__drsg-events__event_list (pass project=<dir> for another project), "
        "mcp__drsg-events__event_done."
    )
    out = {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}
    print(json.dumps(out))


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if not isinstance(data, dict) or data.get("tool_name") != "Bash":
        sys.exit(0)
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        sys.exit(0)
    cmd = tool_input.get("command")
    if not isinstance(cmd, str) or not cmd:
        sys.exit(0)
    try:
        take, deny = _analyze(cmd)
    except ParseError:
        if TARGET_TEXT.search(cmd):
            _denial(False)
        sys.exit(0)
    if take or deny:
        _denial(take)
    sys.exit(0)


if __name__ == "__main__":
    main()

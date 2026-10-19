#!/usr/bin/env python3
"""sensitive-file-read-guard.py — PreToolUse hook (Bash|Read|Grep).

Denies tool calls that would print the whole content of a file that may hold
credentials (.mcp.json, ~/.claude.json, .claude/settings*.json, env files,
.netrc, private keys): the content would land in the transcript and be sent to
the model. Structure-only reads stay allowed: `jq` keys or whitelisted fields,
`grep -c/-l/-L/-q`, `ls`, `stat`, sourcing an env file.

This guards against the casual `cat .mcp.json`, not against a determined
bypass (`python -c 'print(open(...).read())'`). The user's own `!` commands do
not go through hooks.

Fail-open: any error or unparseable payload allows the call silently.
Disable at runtime with DRSG_SENSITIVE_READ_GUARD_DISABLED=1.
"""
import json
import os
import re
import shlex
import sys

READERS = {"cat", "head", "tail", "less", "more", "bat", "nl", "tac", "od", "xxd",
           "hexdump", "strings", "base64", "sed", "awk", "gawk", "diff"}
GREPS = {"grep", "egrep", "fgrep", "rg", "ag"}
# Flags after which grep prints no matching lines.
GREP_QUIET_LONG = {"--count", "--files-with-matches", "--files-without-match",
                   "--quiet", "--silent"}
WRAPPERS = {"sudo", "env", "command", "nohup", "time", "exec"}
# Object fields a jq filter may build from an MCP server entry; args, env and
# headers can carry credentials.
JQ_SAFE_FIELDS = {"type", "url", "command"}
JQ_STRUCTURE = {"keys", "keys_unsorted", "length", "type"}
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OPERATORS = ("||", "&&", "|&", "|", ";", "&", "\n")

REASON = (
    "This file may hold credentials (category: %s). Its full content would land "
    "in the transcript and be sent to the model.\n"
    "Read structure only: jq '.mcpServers | keys' .mcp.json / "
    "jq '.mcpServers[] | {type, url}' .mcp.json; check a key exists: "
    "grep -c KEY_NAME <file>.\n"
    "If you really need the content, ask the user to run it with ! in their own shell.\n"
    "该文件可能带凭据，不要整段读取：用 jq 只取键名或不含密钥的字段，用 grep -c 判断键在不在；"
    "确实要看内容，请用户自己用 ! 运行。不要换个命令绕过去。"
)


def category(path):
    """The credential category of `path`, or None when it is not sensitive."""
    if not isinstance(path, str) or not path:
        return None
    path = path.rstrip("/")
    base = os.path.basename(path)
    parts = base.split(".")
    if base.endswith(".pub") or {"example", "sample", "template"} & set(parts[1:]):
        return None
    if base == ".mcp.json":
        return "mcp-config"
    parent = os.path.basename(os.path.dirname(path))
    if base == ".claude.json" or base == "settings.local.json" or (
            parent == ".claude" and base == "settings.json"):
        return "claude-config"
    if base == ".env" or base.startswith(".env.") or base.endswith(".env"):
        return "env"
    if base in (".netrc", ".npmrc", ".pypirc"):
        return "credentials"
    if base.endswith((".pem", ".key")) or base.startswith(("id_rsa", "id_ed25519")):
        return "private-key"
    return None


class ParseError(Exception):
    pass


def _close(text, i, opener, closer):
    """Index of the `closer` matching the `opener` at text[i]."""
    depth, quote, j = 0, None, i
    while j < len(text):
        c = text[j]
        if quote:
            if c == quote:
                quote = None
            elif c == "\\" and quote == '"':
                j += 1
        elif c in "'\"":
            quote = c
        elif c == "\\":
            j += 1
        elif c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise ParseError("unclosed group")


def segments(text, depth=0):
    """Simple commands in `text`: split on | && || ; & and newlines outside
    quotes; $(...), <(...) and backtick bodies are returned as their own
    segments, replaced in the outer one by a placeholder."""
    if depth > 8:
        raise ParseError("nesting limit")
    out, cur, quote, i = [], [], None, 0

    def flush():
        s = "".join(cur).strip()
        cur.clear()
        if s:
            out.append(s)

    while i < len(text):
        c = text[i]
        if quote == "'":
            cur.append(c)
            if c == "'":
                quote = None
            i += 1
            continue
        if c == "\\":
            cur.append(text[i:i + 2])
            i += 2
            continue
        if text.startswith(("$(", "<(", ">("), i):
            end = _close(text, i + 1, "(", ")")
            out.extend(segments(text[i + 2:end], depth + 1))
            cur.append("__SUB__")
            i = end + 1
            continue
        if c == "`":
            end = text.find("`", i + 1)
            if end < 0:
                raise ParseError("unclosed backtick")
            out.extend(segments(text[i + 1:end], depth + 1))
            cur.append("__SUB__")
            i = end + 1
            continue
        if quote == '"':
            cur.append(c)
            if c == '"':
                quote = None
            i += 1
            continue
        if c in "'\"":
            quote = c
            cur.append(c)
            i += 1
            continue
        op = next((o for o in OPERATORS if text.startswith(o, i)), None)
        if op:
            flush()
            i += len(op)
            continue
        cur.append(c)
        i += 1
    if quote:
        raise ParseError("unclosed quote")
    flush()
    return out


def _strip_prefix(argv):
    """Drop leading VAR=value assignments and wrappers such as sudo or env."""
    i = 0
    while i < len(argv):
        a = argv[i]
        if ASSIGNMENT.match(a):
            i += 1
        elif os.path.basename(a) in WRAPPERS:
            i += 1
            while i < len(argv) and argv[i].startswith("-"):
                i += 1
        else:
            break
    return argv[i:]


def _grep_quiet(args):
    for a in args:
        if a in GREP_QUIET_LONG:
            return True
        if re.fullmatch(r"-[A-Za-z]+", a) and set(a[1:]) & set("clLq"):
            return True
    return False


def _jq_structural(flt):
    flt = flt.strip()
    if re.fullmatch(r'(?:has\("[^"]*"\)\s*(?:and|or)?\s*)+', flt):
        return True
    last = flt.split("|")[-1].strip()
    if last in JQ_STRUCTURE:
        return True
    m = re.fullmatch(r"\{\s*([a-z_]+(?:\s*,\s*[a-z_]+)*)\s*\}", last)
    return bool(m) and {f.strip() for f in m.group(1).split(",")} <= JQ_SAFE_FIELDS


def segment_category(seg):
    """The category of a sensitive file this simple command would print, or None."""
    argv = _strip_prefix(shlex.split(seg, posix=True))
    if not argv:
        return None
    cmd = os.path.basename(argv[0])
    args, skip = [], False
    for a in argv[1:]:
        if skip:
            skip = False
        elif re.fullmatch(r"\d*>>?", a):  # `> file`: written, not read
            skip = True
        elif re.match(r"\d*>", a):         # `>file`, `2>&1`
            pass
        elif a.startswith("<"):            # `< file` is read; `<<EOF` is a heredoc
            if not a.startswith("<<") and a.lstrip("<"):
                args.append(a.lstrip("<"))
        else:
            args.append(a)
    positional = [a for a in args if not a.startswith("-")]
    if cmd in GREPS:
        if "-e" not in args and "-f" not in args and positional:
            positional = positional[1:]  # the first one is the pattern
        hits = [category(a) for a in positional if category(a)]
        return hits[0] if hits and not _grep_quiet(args) else None
    if cmd == "jq":
        if "-f" in args or "--from-file" in args or not positional:
            flt, files = None, positional
        else:
            flt, files = positional[0], positional[1:]
        hits = [category(a) for a in files if category(a)]
        if hits and (flt is None or not _jq_structural(flt)):
            return hits[0]
        return None
    if cmd in READERS:
        hits = [category(a) for a in positional if category(a)]
        return hits[0] if hits else None
    return None


def bash_category(command):
    try:
        for seg in segments(command):
            cat = segment_category(seg)
            if cat:
                return cat
        return None
    except (ParseError, ValueError):
        # Unparseable: deny only when a sensitive name and a reader both appear.
        words = re.findall(r"[^\s'\"|;&<>()`$]+", command)
        cats = [category(w) for w in words if category(w)]
        readers = READERS | GREPS | {"jq"}
        if cats and any(os.path.basename(w) in readers for w in words):
            return cats[0]
        return None


def decide(hook):
    tool = hook.get("tool_name")
    inp = hook.get("tool_input")
    if not isinstance(inp, dict):
        return None
    if tool == "Bash":
        return bash_category(inp.get("command") or "")
    if tool == "Read":
        return category(inp.get("file_path"))
    if tool == "Grep":
        if inp.get("output_mode") != "content":
            return None
        return category(inp.get("path")) or category(inp.get("glob"))
    return None


def main():
    if os.environ.get("DRSG_SENSITIVE_READ_GUARD_DISABLED") == "1":
        return
    hook = json.loads(sys.stdin.read())
    if not isinstance(hook, dict):
        return
    cat = decide(hook)
    if cat:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": REASON % cat,
        }}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass

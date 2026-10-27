#!/usr/bin/env python3
"""sensitive-file-read-guard.py — PreToolUse hook (Bash|Read|Grep).

Denies tool calls that would print the whole content of a file that may hold
credentials (.mcp.json, ~/.claude.json, .claude/settings*.json, env files,
.netrc, private keys): the content would land in the transcript and be sent to
the model. Structure-only reads stay allowed: `jq` filters that print only keys,
counts, booleans, whitelisted fields, hook settings, or the permissions,
autoMode and statusLine blocks of a settings file,
`grep -c/-l/-L/-q`, `ls`, `stat`, sourcing an env file. A `jq` whose output is
redirected to a sensitive file or its copy (an edit: `jq ... f > f.new && mv
f.new f`) prints nothing; a copy (`f.new`, `f.bak-1022`) is as sensitive as `f`.

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
# A scratch or backup copy (`settings.local.json.new`, `.mcp.json.bak-1022`)
# holds the same credentials as the file it was made from.
COPY_SUFFIX = re.compile(r"\.(?:new|tmp|bak|orig|old|save)(?:[-.][\w.-]*)?$")
WRAPPERS = {"sudo", "env", "command", "nohup", "time", "exec"}
# Fields a jq filter may print: an MCP server's type/url/command and a hook's
# matcher/command. args, env and headers can carry credentials.
JQ_SAFE_FIELDS = {"type", "url", "command", "matcher"}
# Below the top-level `hooks` of a settings file, after the event name, only
# these fields exist; none of them holds a credential.
JQ_HOOK_FIELDS = {"hooks", "matcher", "type", "command", "timeout", "async",
                  "statusMessage", "asyncRewake"}
# Top-level blocks of a Claude Code settings file that hold no credentials;
# their values may be printed (user decision 2026-10-27, todo-44). Only for
# claude-config files, and only at the top level.
JQ_SETTINGS_SECTIONS = {"permissions", "autoMode", "statusLine"}
# Output is a key name, a count or a type, whatever the input was.
JQ_STRUCTURE = {"keys", "keys_unsorted", "length", "type"}
# Output is a boolean; arguments only have to be understood.
JQ_BOOLEAN = {"has", "in", "contains", "inside", "startswith", "endswith",
              "test", "not", "any", "all", "isempty"}
# Output is the input's values reshaped: as safe as the input and arguments.
JQ_PASS = {"tostring", "tojson", "ascii_downcase", "ascii_upcase", "sort",
           "unique", "reverse", "first", "last", "flatten", "add", "min", "max",
           "ltrimstr", "rtrimstr", "split", "join", "values", "arrays",
           "objects", "strings", "iterables", "scalars", "empty"}
# jq options that take one or two values; --slurpfile/--rawfile read a file.
JQ_ARG1 = {"-L", "--indent"}
JQ_ARG2 = {"--arg", "--argjson", "--slurpfile", "--rawfile"}
# A path element: the entries of an object (`to_entries`), whose `.key` is a key name.
ENTRIES = "<entries>"
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
OPERATORS = ("||", "&&", "|&", "|", ";", "&", "\n")

REASON = (
    "This file may hold credentials (category: %s). Its full content would land "
    "in the transcript and be sent to the model.\n"
    "Read structure only: jq '.mcpServers | keys' .mcp.json / "
    "jq '.mcpServers[] | {type, url}' .mcp.json; check a key exists: "
    "grep -c KEY_NAME <file>.\n"
    "Settings: jq '.hooks | keys' <file> / jq -r '.hooks[][] | .hooks[].command' <file>; "
    "compare without printing: jq -e '.env.NAME == \"value\"' <file>.\n"
    "Run a config read as a command of its own: when it is denied, nothing in the "
    "command runs. To count a key, use grep -c KEY <file>, not cat <file> | grep -c.\n"
    "Editing one: jq '<filter>' <file> > <file>.new && mv <file>.new <file> "
    "(the output goes to the file), or write a script and ask the user to run it with !.\n"
    "If you really need the content, ask the user to run it with ! in their own shell.\n"
    "如果需要审核方才能继续，在本回合结束前发 `kind=\"handoff\"` Event，"
    "`summary` 以 `请求协助：` 开头；不要附上敏感文件内容。\n"
    "该文件可能带凭据，不要整段读取：用 jq 只取键名或不含密钥的字段，用 grep -c 判断键在不在；"
    "确实要看内容，请用户自己用 ! 运行；"
    "读配置单独发一条，不要和别的检查串在一条命令里（被拒时整条都不运行）；"
    "要数某个键出现几次，用 grep -c KEY <file>，不要 cat <file> | grep -c；"
    "要改这类文件，用 jq 输出到新文件再 mv，或写成脚本请用户用 ! 运行。不要换个命令绕过去。"
)


def category(path):
    """The credential category of `path`, or None when it is not sensitive."""
    if not isinstance(path, str) or not path:
        return None
    path = COPY_SUFFIX.sub("", path.rstrip("/"))
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


def _heredoc_word(text, i):
    """The delimiter of the heredoc whose `<<` is at text[i], whether it is
    `<<-` (tabs stripped from the terminator line), and the index after it."""
    j = i + 2
    strip = text.startswith("-", j)
    j += strip
    while j < len(text) and text[j] in " \t":
        j += 1
    if j < len(text) and text[j] in "'\"":
        end = text.find(text[j], j + 1)
        if end < 0:
            raise ParseError("unclosed heredoc delimiter")
        return text[j + 1:end], strip, end + 1
    k = j
    while k < len(text) and text[k] not in " \t\n;|&<>()":
        k += 1
    return text[j:k].replace("\\", ""), strip, k


def _skip_heredocs(text, i, pending):
    """Index after the bodies of the `pending` heredocs, which start at text[i]
    (just after a newline). A body is data, not commands."""
    for word, strip in pending:
        while i < len(text):
            end = text.find("\n", i)
            line = text[i:] if end < 0 else text[i:end]
            i = len(text) if end < 0 else end + 1
            if (line.lstrip("\t") if strip else line) == word:
                break
    pending.clear()
    return i


def segments(text, depth=0):
    """Simple commands in `text`: split on | && || ; & and newlines outside
    quotes; $(...), <(...) and backtick bodies are returned as their own
    segments, replaced in the outer one by a placeholder. Heredoc bodies are
    skipped."""
    if depth > 8:
        raise ParseError("nesting limit")
    out, cur, quote, i = [], [], None, 0
    heredocs = []

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
        if text.startswith("<<", i) and not text.startswith("<<<", i):
            word, strip, end = _heredoc_word(text, i)
            heredocs.append((word, strip))
            cur.append(text[i:end])
            i = end
            continue
        op = next((o for o in OPERATORS if text.startswith(o, i)), None)
        if op:
            flush()
            i += len(op)
            if op == "\n" and heredocs:
                i = _skip_heredocs(text, i, heredocs)
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


class _JqUnsafe(Exception):
    """A jq construct the analysis does not understand: treat as printing values."""


def _jq_string_end(text, i):
    """Index of the quote closing the jq string that opens at text[i]; a
    `\\(...)` interpolation inside it may hold strings of its own."""
    j = i + 1
    while j < len(text):
        if text[j] == '"':
            return j
        if text[j] == "\\":
            j = _jq_paren_end(text, j + 1) + 1 if text.startswith("(", j + 1) else j + 2
        else:
            j += 1
    raise _JqUnsafe()


def _jq_paren_end(text, i):
    """Index of the `)` matching the `(` at text[i], skipping strings."""
    depth, j = 0, i
    while j < len(text):
        c = text[j]
        if c == '"':
            j = _jq_string_end(text, j)
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    raise _JqUnsafe()


def _jq_interp_bodies(lit):
    """The expressions inside the `\\(...)` of a string literal."""
    bodies, j = [], 1
    while j < len(lit) - 1:
        if lit[j] == "\\" and lit.startswith("(", j + 1):
            end = _jq_paren_end(lit, j + 1)
            bodies.append(lit[j + 2:end])
            j = end + 1
        else:
            j += 2 if lit[j] == "\\" else 1
    return bodies


def _jq_tokens(text):
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if c.isspace():
            i += 1
        elif c == '"':
            j = _jq_string_end(text, i)
            lit = text[i:j + 1]
            out.append(("interp" if "\\(" in lit else "str", lit))
            i = j + 1
        elif text.startswith("..", i):
            out.append(("recurse", ".."))
            i += 2
        elif c == ".":
            m = re.match(r"\.([A-Za-z_][A-Za-z0-9_]*)", text[i:])
            if m:
                out.append(("field", m.group(1)))
                i += m.end()
            else:
                out.append(("dot", "."))
                i += 1
        elif c.isdigit():
            m = re.match(r"\d+(?:\.\d+)?", text[i:])
            out.append(("num", m.group(0)))
            i += m.end()
        elif c.isalpha() or c == "_":
            m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", text[i:])
            out.append(("ident", m.group(0)))
            i += m.end()
        elif c == "$" and re.match(r"\$[A-Za-z_]", text[i:]):
            m = re.match(r"\$([A-Za-z_][A-Za-z0-9_]*)", text[i:])
            out.append(("var", m.group(1)))
            i += m.end()
        elif text[i:i + 2] in ("//", "==", "!=", "<=", ">="):
            out.append(("op", text[i:i + 2]))
            i += 2
        elif c in "[]{}(),|:;?+-*/%<>":
            out.append(("op", c))
            i += 1
        else:  # $var, @format, anything else
            raise _JqUnsafe()
    return out


def _jq_path_safe(path):
    """A path that ends in a safe field, or stays among a settings file's hooks."""
    if path is None:
        return False
    if path[:1] == ("hooks",):
        if all(p in JQ_HOOK_FIELDS for p in path[2:] if isinstance(p, str)):
            return True
    named = [p for p in path if isinstance(p, str)]
    return bool(named) and named[-1] in JQ_SAFE_FIELDS


class _JqFilter:
    """Whether a jq filter can print anything but key names, counts, booleans,
    literals and safe fields. Each parse step returns (safe, path): `path` is
    the field path from the file's root when the output is a pure path."""

    def __init__(self, text, variables=(), sections=()):
        self.toks = _jq_tokens(text)
        self.i = 0
        # Names bound by --arg/--argjson: values from the command line, not the file.
        self.vars = set(variables)
        # Top-level blocks whose values may be printed (JQ_SETTINGS_SECTIONS for
        # a settings file, nothing otherwise).
        self.sections = frozenset(sections)

    def peek(self, value=None):
        tok = self.toks[self.i] if self.i < len(self.toks) else (None, None)
        return tok if value is None else tok[1] == value and tok[0] in ("op", "ident")

    def take(self, value=None):
        tok = self.peek()
        if tok[0] is None or (value is not None and tok[1] != value):
            raise _JqUnsafe()
        self.i += 1
        return tok

    def safe(self):
        result = self.pipe((False, ()))
        if self.i != len(self.toks):
            raise _JqUnsafe()
        return result[0]

    def pipe(self, ctx):
        ctx = self.comma(ctx)
        while self.peek("|"):
            self.take()
            ctx = self.comma(ctx)
        return ctx

    def comma(self, ctx):
        safe, path = self.alt(ctx)
        while self.peek(","):
            self.take()
            s, _ = self.alt(ctx)
            safe, path = safe and s, None
        return safe, path

    def alt(self, ctx):
        safe, path = self.boolean(ctx)
        while self.peek("//"):
            self.take()
            s, _ = self.boolean(ctx)
            safe, path = safe and s, None
        return safe, path

    def boolean(self, ctx):
        result = self.arith(ctx)
        while self.peek("and") or self.peek("or") or self.peek()[1] in (
                "==", "!=", "<", "<=", ">", ">="):
            self.take()
            self.arith(ctx)
            result = (True, None)
        return result

    def arith(self, ctx):
        safe, path = self.postfix(ctx)
        while self.peek()[1] in ("+", "-", "*", "/", "%") and self.peek()[0] == "op":
            self.take()
            s, _ = self.postfix(ctx)
            safe, path = safe and s, None
        return safe, path

    def postfix(self, ctx):
        safe, path = self.primary(ctx)
        while True:
            kind, value = self.peek()
            if kind == "field":
                self.take()
                safe, path = self.step(safe, path, value)
            elif kind == "dot" and self.toks[self.i + 1:self.i + 2] and self.toks[self.i + 1][0] == "str":
                self.take()
                safe, path = self.step(safe, path, self.take()[1][1:-1])
            elif value == "[" and kind == "op":
                self.take()
                if self.peek("]"):
                    name = 0
                else:
                    if self.peek()[0] == "str" and self.toks[self.i + 1:self.i + 2] == [("op", "]")]:
                        name = self.take()[1][1:-1]
                    else:
                        # A slice may leave out either end: [7:], [:3].
                        if not self.peek(":"):
                            self.pipe(ctx)
                        if self.peek(":"):
                            self.take()
                            if not self.peek("]"):
                                self.pipe(ctx)
                        name = 0
                self.take("]")
                safe, path = self.step(safe, path, name)
            elif value == "?" and kind == "op":
                self.take()
            else:
                return safe, path

    def step(self, safe, path, name):
        if path is not None and path[-2:] == (ENTRIES, 0):
            if name == "key":
                return True, None
            if name == "value":
                path = path[:-2] + (0,)
                return (_jq_path_safe(path) if path[:1] != (None,) else safe), path
        # A path known from the file's root decides alone: `.hooks[][]` is
        # safe, `.hooks[][] | .env` is not. Below an unknown prefix (output
        # of keys, map, a comma) a safe input stays safe.
        known = path is not None and path[:1] != (None,)
        path = (path if path is not None else (None,)) + (name,)
        if known and path[0] in self.sections:
            return True, path
        if known:
            return _jq_path_safe(path), path
        return safe or _jq_path_safe(path), path

    def primary(self, ctx):
        kind, value = self.take()
        if kind == "field":
            return self.step(ctx[0], ctx[1], value)
        if kind == "dot":
            return ctx
        if kind == "recurse":
            return ctx[0], None
        if kind in ("str", "num"):
            return True, None
        if kind == "interp":
            safe = True
            for body in _jq_interp_bodies(value):
                sub = _JqFilter(body, self.vars, self.sections)
                s, _ = sub.pipe(ctx)
                if sub.i != len(sub.toks):
                    raise _JqUnsafe()
                safe = safe and s
            return safe, None
        if kind == "var":
            if value in self.vars:
                return True, None
            raise _JqUnsafe()
        if value == "-" and kind == "op":
            return self.postfix(ctx)[0], None
        if value == "(" and kind == "op":
            result = self.pipe(ctx)
            self.take(")")
            return result
        if value == "[" and kind == "op":
            if self.peek("]"):
                self.take()
                return True, None
            safe, _ = self.pipe(ctx)
            self.take("]")
            return safe, None
        if value == "{" and kind == "op":
            return self.object(ctx)
        if kind == "ident":
            return self.call(ctx, value)
        raise _JqUnsafe()

    def object(self, ctx):
        safe = True
        while not self.peek("}"):
            kind, value = self.take()
            if kind == "op" and value == "(":
                s, _ = self.pipe(ctx)
                self.take(")")
                safe = safe and s
            elif kind not in ("ident", "str"):
                raise _JqUnsafe()
            if self.peek(":"):
                self.take()
                s, _ = self.alt(ctx)
            elif kind in ("ident", "str"):  # {name} is {name: .name}
                s, _ = self.step(ctx[0], ctx[1], value.strip('"'))
            else:
                raise _JqUnsafe()
            safe = safe and s
            if not self.peek(","):
                break
            self.take()
        self.take("}")
        return safe, None

    def call(self, ctx, name):
        # empty prints nothing, whatever its input.
        if name in ("true", "false", "null", "empty"):
            return True, None
        args = []
        if self.peek("("):
            self.take()
            if name == "map":
                args.append(self.pipe((ctx[0], (ctx[1] if ctx[1] is not None else (None,)) + (0,))))
            else:
                args.append(self.pipe(ctx))
            while self.peek(";"):
                self.take()
                args.append(self.pipe(ctx))
            self.take(")")
        if name in JQ_STRUCTURE or name in JQ_BOOLEAN:
            return True, None
        if name == "select":
            return ctx
        if name == "to_entries" and not args:
            return ctx[0], (ctx[1] if ctx[1] is not None else (None,)) + (ENTRIES,)
        if name == "map":
            return args[0][0] if args else False, None
        if name in JQ_PASS:
            return ctx[0] and all(s for s, _ in args), None
        raise _JqUnsafe()


def _jq_structural(flt, variables=(), sections=()):
    try:
        return _JqFilter(flt, variables, sections).safe()
    except (_JqUnsafe, IndexError, TypeError):
        return False


def segment_category(seg):
    """The category of a sensitive file this simple command would print, or None."""
    argv = _strip_prefix(shlex.split(seg, posix=True))
    if not argv:
        return None
    cmd = os.path.basename(argv[0])
    args, skip, stdout_target, to_file = [], False, False, False
    for a in argv[1:]:
        if skip:
            skip = False
            if stdout_target and category(a):
                to_file = True
        elif re.fullmatch(r"\d*>>?", a):  # `> file`: written, not read
            skip = True
            stdout_target = a.rstrip(">") in ("", "1")
        elif re.match(r"\d*>", a):         # `>file`, `2>&1`, `>&2`
            fd, target = re.match(r"(\d*)>>?(.*)", a).groups()
            if fd in ("", "1") and category(target):
                to_file = True
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
        return _jq_category(args, to_file)
    if cmd in READERS:
        hits = [category(a) for a in positional if category(a)]
        return hits[0] if hits else None
    return None


def _jq_category(args, to_file):
    """The category of a sensitive file this jq prints, or None."""
    variables, files, positional, from_file, i = [], [], [], False, 0
    while i < len(args):
        a = args[i]
        if a in JQ_ARG2:
            if a in ("--slurpfile", "--rawfile"):
                files.extend(args[i + 2:i + 3])  # its variable stays unknown
            else:
                variables.extend(args[i + 1:i + 2])
            i += 3
        elif a in JQ_ARG1:
            i += 2
        else:
            if a in ("-f", "--from-file"):
                from_file = True
            elif not a.startswith("-"):
                positional.append(a)
            i += 1
    if from_file or not positional:
        flt = None
        files += positional
    else:
        flt = positional[0]
        files += positional[1:]
    hits = [category(a) for a in files if category(a)]
    sections = (JQ_SETTINGS_SECTIONS if hits and all(c == "claude-config" for c in hits)
                else ())
    if hits and not to_file and (flt is None or not _jq_structural(flt, variables, sections)):
        return hits[0]
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

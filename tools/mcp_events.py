#!/usr/bin/env python3
"""Cross-agent to-dos as MCP tools — the memory layer's own stdio server.

Posting, listing and closing an `Event` were reachable only through a CLI and a
paragraph of hand-written cypher in every project's CLAUDE.md. An interface you
have to teach with documentation is not an interface: the model had to remember
that the recipient is matched on `p.path`, that the node and its `NOTIFY` edge
must be written in one statement, and that closing needs `key(e)` rather than
`e.key`. Every one of those has silently produced an invisible or unclosed
to-do at least once. Three tools state them once, here.

Deliberately NOT part of `drsg-mcp`. `Event`, `Project` and `NOTIFY` are memory
-layer conventions living on top of a soft-schema graph; the engine does not
know what a Fact is and should not learn what an Event is. Keeping this a
separate process is what lets the database stay a database.

Transport is stdio JSON-RPC, stdlib only, matching the hooks: one more
dependency in the coordination path is one more way for the path to be down
when it is needed.

Usage (install.sh registers this):
  mcp_events.py <project-dir>        # the project this session belongs to
"""
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
PROTOCOL = "2025-06-18"
COMMIT_AUTH_FIELDS = {"tree", "parent", "target_branch", "files", "force_paths", "message"}
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SIGNATURE_RE = re.compile(
    r"(?im)^(?:co-authored-by|signed-off-by|reviewed-by|co-developed-by|authored-by):")
COMMIT_HOOKS = ("pre-commit", "prepare-commit-msg", "commit-msg", "post-commit",
                "reference-transaction", "post-index-change")
ALLOWED_COMMIT_HOOK_SHA256 = {
    "pre-commit": frozenset({
        "5538848d332cf420f7d745ba7b2f4429e9f0dde9604e9ad4df11c3335a5bb3a9",
        "65990fe9d7a89cc7d9681b8e47eecb23efd364860bdce0523f67027e8cd2a66e",
        "3171dd53cf1f216c13436e7da9a44fdbb29111127eb5cf18c684ed2e1ba9ac2d",
    }),
    "commit-msg": frozenset({
        "f4c2c9893aab37c81201cac595bd2c25f3795e3ab5215468e41a98b719b7637c",
    }),
}
# The one project whose commit authorizations this machine accepts. Written by
# the user only; setup never creates it. Missing or malformed: both tools off.
COMMIT_AUTH_CONFIG = os.path.join(os.path.expanduser("~"), ".drsg-memory",
                                  "commit-auth.json")
GUARD_BIN_LINE_RE = re.compile(
    rb'^GUARD_BIN="([^"\r\n]+/completeness-guard\.py)"$', re.M)
GUARD_BIN_FALLBACK_RE = re.compile(
    rb'^if \[ ! -f "([^"\r\n]+/completeness-guard\.py)" \]; then$', re.M)
FORBIDDEN_BIN_LINE_RE = re.compile(
    rb'^FORBIDDEN_BIN="([^"\r\n]+/forbidden-literals-guard\.py)"$', re.M)


def _load_event_module():
    """The CLI's implementation, imported rather than copied.

    `event.py` guards its `main()`, so importing it is free. Sharing the module
    is what keeps `event_done` here and `event.py done` from drifting into two
    different opinions about what "closed" means."""
    spec = importlib.util.spec_from_file_location(
        "drsg_event", os.path.join(HERE, "event.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ev = _load_event_module()


def _load_poller_module():
    """event-poller.py, for event_take: the same lease writer as `--take`."""
    spec = importlib.util.spec_from_file_location(
        "drsg_event_poller", os.path.join(HERE, "event-poller.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

TOOLS = [
    {
        "name": "event_post",
        "description": (
            "Leave a to-do for an agent working in ANOTHER project. Use this "
            "instead of writing a Fact: Facts reach a session by winning a "
            "relevance ranking, so one that loses is never delivered, while an "
            "open Event is injected verbatim and also printed to the "
            "recipient's terminal. The recipient is addressed by its directory "
            "path; the node and its NOTIFY edge are written together, because "
            "an Event without that edge is unreachable by every read path."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "recipient": {"type": "string", "description":
                              "Absolute directory of the receiving project."},
                "summary": {"type": "string", "description":
                            "One line. The first 80 chars reach the terminal."},
                "kind": {"type": "string", "enum": ["handoff", "notice"],
                         "default": "handoff"},
                "ref": {"type": "string", "description":
                        "Optional pointer — a doc path, commit or issue."},
                "reply_to": {"type": "string", "description":
                             "Event key this post is replying to."},
                "symbols": {
                    "type": "array", "items": {"type": "string"},
                    "description":
                        "Code-graph symbol KEYS the recipient should start "
                        "from — at most 3, e.g. "
                        "`dr_strange_llm::preprocess::Plugins::load`. Give "
                        "them whenever the work is about specific code: the "
                        "recipient is shown an imperative graph call instead "
                        "of a sentence that merely hints at one. Keys, not "
                        "prose — anything with a space in it is rejected, and "
                        "a file:line is not an address the graph can use. "
                        "NEVER put them in `summary`, which is truncated to "
                        "80 characters on the way to the terminal. Each key is "
                        "resolved against the recipient's graph before "
                        "anything is written: one that misses or is ambiguous "
                        "REFUSES the post and shows candidates, and one that "
                        "resolves is rewritten to its canonical full key. A "
                        "rough name is therefore fine — `Type::method` usually "
                        "lands in one."},
                "verb": {
                    "type": "string",
                    "enum": ["context", "impact", "trace"],
                    "description":
                        "What the recipient should ask (default context). "
                        "`impact` for what a change breaks — it is the only "
                        "one that groups by distance with counts; `trace` "
                        "needs exactly two symbols, from and to, in that "
                        "order."},
                "plane": {
                    "type": "string",
                    "description":
                        "Plane the symbols live in. Defaults to the "
                        "recipient's repository, then to this one — right for "
                        "work about the recipient's code, and for reporting "
                        "back about yours. Set it when the symbols are in "
                        "neither."},
            },
            "required": ["recipient", "summary"],
        },
    },
    {
        "name": "commit_auth_post",
        "description": (
            "Publish a one-time commit authorization for another project. "
            "The tree is independently recomputed from the parent and exact "
            "file list. This writes Git objects in the recipient repository. "
            "It does not authenticate the user; the user-global exception and "
            "auto-mode classifier still govern whether a commit is authorized. "
            "Runs only in the reviewer project named in "
            "~/.drsg-memory/commit-auth.json."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "recipient": {"type": "string"},
                "tree": {"type": "string"},
                "parent": {"type": "string"},
                "target_branch": {"type": "string"},
                "files": {"type": "array", "items": {"type": "string"}},
                "force_paths": {"type": "array", "items": {"type": "string"}},
                "message": {"type": "string"},
            },
            "required": ["recipient", "tree", "parent", "target_branch", "files",
                         "force_paths", "message"],
        },
    },
    {
        "name": "commit_auth_apply",
        "description": (
            "Apply the commit authorization stored on an open handoff Event. "
            "This tool performs a local git commit; its only input is the Event "
            "key, and it never closes the Event. It accepts only Events sent "
            "by the reviewer project named in ~/.drsg-memory/commit-auth.json. "
            "A classifier denial must not be bypassed with Bash or another tool."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "event_key": {"type": "string"},
            },
            "required": ["event_key"],
        },
    },
    {
        "name": "event_list",
        "description": (
            "To-dos addressed to a project, newest first, with how far each "
            "one got: unseen (posted, never rendered to anyone), seen <age> "
            "ago, or done. Defaults to this project and to open ones."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {"type": "string", "description":
                            "Absolute directory. Defaults to this session's."},
                "status": {"type": "string", "enum": ["open", "done", "all"],
                           "default": "open"},
            },
        },
    },
    {
        "name": "event_done",
        "description": (
            "Close a to-do by its key, and verify it actually closed. Fails "
            "loudly if the key resolved to something that is not an Event or "
            "if the node did not change — closing by hand with `e.key` matches "
            "nothing, reports props_set: 0, and does not error. Refused when "
            "this session is not the project's Event owner (the session the "
            "to-do poller wakes); nothing is written then."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "key": {"type": "string"},
                "force": {"type": "boolean", "default": False, "description":
                          "Close even when this session is not the Event owner. "
                          "Only when the user explicitly asked this session to "
                          "take the Event over."},
            },
            "required": ["key"],
        },
    },
    {
        "name": "event_take",
        "description": (
            "Take this project's Event-owner lease for one of THIS session's "
            "lanes (DRSG_EVENT_LANES; the default lane when it declared none), "
            "away from whichever session holds it. Call it only when the user "
            "explicitly asked this session to take the lane over. Refused for "
            "a lane this session did not declare. The previous owner turns "
            "read-only; Events it was already woken for may be handled twice."),
        "inputSchema": {
            "type": "object",
            "properties": {
                "lane": {"type": "string", "description":
                         "Lane name, or * for the default lane. Omit when the "
                         "session declared exactly one lane (or none)."},
            },
        },
    },
]


def _project_dir():
    return os.path.abspath(os.path.normpath(
        (sys.argv[1] if len(sys.argv) > 1 else None)
        or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()))


def _validate_paths(paths, name, allow_empty=False):
    if not isinstance(paths, list) or (not paths and not allow_empty):
        raise ValueError("%s must be a %slist of relative file paths" % (
            name, "possibly empty " if allow_empty else "non-empty "))
    if any(not isinstance(path, str) or not path or "\x00" in path
           or "\\" in path or path.startswith("/")
           or os.path.normpath(path) != path or path in (".", "..")
           or ".." in path.split("/") or path.startswith(":")
           for path in paths):
        raise ValueError("%s contains an invalid repository path" % name)
    if len(set(paths)) != len(paths):
        raise ValueError("%s contains duplicate paths" % name)
    return paths


def _validate_commit_fields(data):
    if isinstance(data, dict) and "target_branch" not in data:
        raise ValueError("target_branch missing; ask the reviewer to reissue authorization using the new format")
    if not isinstance(data, dict) or set(data) != COMMIT_AUTH_FIELDS:
        raise ValueError("commit authorization fields are incomplete or unexpected")
    for name in ("tree", "parent"):
        if not isinstance(data[name], str) or not SHA_RE.fullmatch(data[name]):
            raise ValueError("%s must be 40 lowercase hex chars" % name)
    branch = data["target_branch"]
    if not isinstance(branch, str) or not branch:
        raise ValueError("target_branch must be a valid branch")
    check_args = ["git", "check-ref-format", "--branch", branch]
    if os.path.isabs(os.environ.get("CLAUDE_PROJECT_DIR", "")):
        check_args[1:1] = ["-C", os.environ["CLAUDE_PROJECT_DIR"]]
    check = subprocess.run(check_args, env=_git_environment(),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True)
    if check.returncode or (check.stdout or "").strip() != branch:
        raise ValueError("target_branch must be a valid branch")
    files = _validate_paths(data["files"], "files")
    force_paths = _validate_paths(data["force_paths"], "force_paths",
                                  allow_empty=True)
    if not set(force_paths).issubset(files):
        raise ValueError("force_paths must be a subset of files")
    message = data["message"]
    if not isinstance(message, str) or not message.strip() or "\x00" in message:
        raise ValueError("message must be a non-empty string")
    if SIGNATURE_RE.search(message):
        raise ValueError("signature trailers are not allowed")
    ev.check_secrets(message, "")
    for path in files:
        ev.check_secrets(path, "")
    return {"tree": data["tree"], "parent": data["parent"],
            "target_branch": branch, "files": list(files),
            "force_paths": list(force_paths), "message": message}


def _git_environment(index_file=None):
    env = os.environ.copy()
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR",
                "GIT_INDEX_FILE", "GIT_PREFIX"):
        env.pop(key, None)
    env["GIT_LITERAL_PATHSPECS"] = "1"
    if index_file:
        env["GIT_INDEX_FILE"] = index_file
    return env


def _redact_git_output(output):
    """Mask recognizable secrets in hook/process output, failing closed."""
    candidates = (os.path.join(HERE, "secret_redact.py"),
                  os.path.join(HERE, "templates", "hooks", "secret_redact.py"))
    for path in candidates:
        if not os.path.exists(path):
            continue
        try:
            spec = importlib.util.spec_from_file_location("secret_redact", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module.redact(output)[0]
        except Exception:
            break
    return "[hook output suppressed: secret redactor unavailable]"


def _git_raw(repo, args, env=None):
    command = ["git", "-C", repo]
    if (env or {}).get("GIT_INDEX_FILE"):
        command.extend(["-c", "core.hooksPath=/dev/null"])
    command.extend(args)
    try:
        result = subprocess.run(command, env=env or _git_environment(),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True)
    except OSError as e:
        raise ValueError("could not run git (%s)" % type(e).__name__) from e
    output = result.stdout or ""
    if result.returncode:
        shown_args = list(args)
        if shown_args and shown_args[0] == "commit":
            shown_args = ["commit", "--cleanup=verbatim", "-m", "<authorized message>"]
        detail = _redact_git_output(output)[:4096]
        raise ValueError("git %s failed (exit %d)%s" % (
            " ".join(shown_args), result.returncode,
            ":\n" + detail if detail else ""))
    return output


def _git(repo, args, env=None):
    return _git_raw(repo, args, env).strip()


def _git_step(repo, args, steps, env=None, prefix="", label=None):
    output = _git(repo, args, env)
    command = label or "git " + " ".join(args)
    steps.append("%s%s: %s" % (prefix, command, output or "ok"))
    return output


def _effective_hooks_dir(repo):
    env = _git_environment()
    result = subprocess.run(
        ["git", "-C", repo, "config", "--path", "--get", "core.hooksPath"],
        env=env, capture_output=True, text=True)
    if result.returncode == 0:
        configured = result.stdout.rstrip("\n")
        if not configured:
            raise ValueError("core.hooksPath is empty; cannot safely inspect active hooks")
        path = configured if os.path.isabs(configured) else os.path.join(repo, configured)
    elif result.returncode == 1:
        path = _git(repo, ["rev-parse", "--git-path", "hooks"], env)
        if not os.path.isabs(path):
            path = os.path.join(repo, path)
    else:
        raise ValueError("cannot determine effective Git hooks directory")
    return os.path.realpath(os.path.abspath(os.path.normpath(path)))


def _normalized_guard_hook_sha(hook_path):
    try:
        with open(hook_path, "rb") as stream:
            content = stream.read()
    except OSError:
        return None
    matches = list(GUARD_BIN_LINE_RE.finditer(content))
    matches_forbidden = list(FORBIDDEN_BIN_LINE_RE.finditer(content))
    if len(matches) == 1 and len(matches_forbidden) == 1:
        guard_path = matches[0].group(1)
        forbidden_path = matches_forbidden[0].group(1)
        if not os.path.isabs(os.fsdecode(guard_path)) or not os.path.isabs(os.fsdecode(forbidden_path)):
            return None
        normalized = content.replace(guard_path, b"@GUARD_BIN@").replace(forbidden_path, b"@FORBIDDEN_BIN@")
        return hashlib.sha256(normalized).hexdigest()
    # Legacy template fallback
    matches_fallback = list(GUARD_BIN_FALLBACK_RE.finditer(content))
    if len(matches_fallback) == 1 and not matches_forbidden:
        guard_path = matches_fallback[0].group(1)
        if not os.path.isabs(os.fsdecode(guard_path)):
            return None
        normalized = content.replace(guard_path, b"@GUARD_BIN@")
        return hashlib.sha256(normalized).hexdigest()
    return None


def _normalized_commit_msg_hook_sha(hook_path):
    try:
        with open(hook_path, "rb") as stream:
            content = stream.read()
    except OSError:
        return None
    matches_forbidden = list(FORBIDDEN_BIN_LINE_RE.finditer(content))
    if len(matches_forbidden) != 1:
        return None
    forbidden_path = matches_forbidden[0].group(1)
    if not os.path.isabs(os.fsdecode(forbidden_path)):
        return None
    normalized = content.replace(forbidden_path, b"@FORBIDDEN_BIN@")
    return hashlib.sha256(normalized).hexdigest()


def _check_commit_hooks(repo):
    """Refuse any effective commit hook not pinned by content hash."""
    hooks_dir = _effective_hooks_dir(repo)
    refused, accepted = [], []
    for name in COMMIT_HOOKS:
        path = os.path.join(hooks_dir, name)
        try:
            info = os.stat(path)  # follows symlinks; Git does too
        except FileNotFoundError:
            continue
        except OSError:
            refused.append((name, os.path.realpath(path)))
            continue
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
            continue
        resolved = os.path.realpath(path)
        try:
            if name == "pre-commit":
                digest = _normalized_guard_hook_sha(resolved)
            elif name == "commit-msg":
                digest = _normalized_commit_msg_hook_sha(resolved)
            else:
                digest = None
            if digest is None:
                with open(resolved, "rb") as stream:
                    digest = hashlib.sha256(stream.read()).hexdigest()
        except OSError:
            refused.append((name, resolved))
            continue
        if digest in ALLOWED_COMMIT_HOOK_SHA256.get(name, ()):
            accepted.append((name, resolved, digest))
        else:
            refused.append((name, resolved))
    if refused:
        details = "; ".join("%s (%s)" % item for item in refused)
        raise ValueError("refused: active Git hook(s) are not allowlisted: %s; "
                         "use the documented manual commit flow" % details)
    return accepted


def _repo_root(path, steps=None):
    if not os.path.isdir(path):
        raise ValueError("recipient is not a directory")
    if steps is None:
        output = _git(path, ["rev-parse", "--show-toplevel"])
    else:
        output = _git_step(path, ["rev-parse", "--show-toplevel"], steps)
    root = os.path.realpath(os.path.abspath(os.path.normpath(output)))
    if root != os.path.realpath(path):
        raise ValueError("recipient must be the git repository root")
    return root


def _check_paths_stay_in_repo(repo, paths):
    root = os.path.realpath(repo)
    for path in paths:
        resolved = os.path.realpath(os.path.join(repo, path))
        if resolved != root and not resolved.startswith(root + os.sep):
            raise ValueError("authorized path escapes the repository")


def _add_paths(repo, paths, force_paths, env, steps=None, temporary=False):
    force = set(force_paths)
    normal = [path for path in paths if path not in force]
    prefix = "GIT_INDEX_FILE=<temporary> " if temporary else ""
    if normal:
        args = ["add", "--"] + normal
        if steps is None:
            _git(repo, args, env)
        else:
            _git_step(repo, args, steps, env, prefix)
    if force_paths:
        args = ["add", "-f", "--"] + force_paths
        if steps is None:
            _git(repo, args, env)
        else:
            _git_step(repo, args, steps, env, prefix)


def _configured_reviewer():
    """Return the reviewer project path from the user's config, or refuse."""
    try:
        with open(COMMIT_AUTH_CONFIG, encoding="utf-8") as stream:
            data = json.load(stream)
    except FileNotFoundError:
        raise ValueError("commit authorization tools are off: %s does not exist; "
                         "see tools/README.md" % COMMIT_AUTH_CONFIG) from None
    except (OSError, ValueError):
        raise ValueError("commit authorization tools are off: %s is not readable JSON"
                         % COMMIT_AUTH_CONFIG) from None
    reviewer = data.get("reviewer") if isinstance(data, dict) else None
    if not isinstance(reviewer, str) or not os.path.isabs(reviewer):
        raise ValueError('commit authorization tools are off: %s must be '
                         '{"reviewer": "<absolute project path>"}' % COMMIT_AUTH_CONFIG)
    return os.path.realpath(reviewer)


def _commit_auth_post(args, proj, token):
    required = {"recipient", "tree", "parent", "target_branch", "files", "force_paths", "message"}
    if not isinstance(args, dict) or set(args) != required:
        raise ValueError("commit_auth_post requires recipient, tree, parent, target_branch, "
                         "files, force_paths, and message only")
    if os.path.realpath(proj) != _configured_reviewer():
        raise ValueError("commit_auth_post may only run in the configured reviewer project")
    recipient = args["recipient"]
    if not isinstance(recipient, str) or not os.path.isabs(recipient):
        raise ValueError("recipient must be an absolute directory path")
    target = os.path.abspath(os.path.normpath(recipient))
    if os.path.realpath(target) == os.path.realpath(proj):
        raise ValueError("recipient must be another project")
    auth = _validate_commit_fields({key: args[key] for key in COMMIT_AUTH_FIELDS})
    pid = ev.project_id(target, token)
    if pid is None:
        raise ValueError("no Project node with path %s" % target)

    steps = []
    repo = _repo_root(target, steps)
    _check_paths_stay_in_repo(repo, auth["files"])
    _git_step(repo, ["cat-file", "-e", auth["parent"] + "^{commit}"], steps,
              label="git cat-file -e parent^{commit}")
    branch_ref = "refs/heads/" + auth["target_branch"]
    branch_tip = _git_step(repo, ["rev-parse", "--verify", branch_ref], steps)
    if branch_tip != auth["parent"]:
        raise ValueError("target branch ref is not at authorized parent")
    with tempfile.TemporaryDirectory(prefix="drsg-commit-auth-") as temp_dir:
        env = _git_environment(os.path.join(temp_dir, "index"))
        _git_step(repo, ["read-tree", auth["parent"]], steps, env,
                  "GIT_INDEX_FILE=<temporary> ")
        _add_paths(repo, auth["files"], auth["force_paths"], env,
                   steps, temporary=True)
        calculated = _git_step(repo, ["write-tree"], steps, env,
                               "GIT_INDEX_FILE=<temporary> ")
    if calculated != auth["tree"]:
        raise ValueError("recomputed tree does not match authorization")
    steps.append("recomputed tree matches authorization")

    summary = "验收通过并授权提交：tree " + auth["tree"][:12]
    ref = "目标分支：%s\nCommit details are stored in structured Event properties." % auth["target_branch"]
    result = ev.post(
        target, pid, summary, "handoff", ref,
        os.path.basename(proj), token, from_path=proj,
        commit_authorization=auth)
    return "posted %s to %s\n%s" % (
        result["key"], target, "\n".join(steps))


def _load_commit_auth(event_key, proj, token, reviewer):
    if not isinstance(event_key, str) or not event_key:
        raise ValueError("event_key must be a non-empty string")
    res = ev.rpc("plane.cypher", {"plane": ev.PLANE,
        "query": "MATCH (e:Event) WHERE key(e) = $key RETURN e",
        "params": {"key": event_key}}, token)
    events = res.get("nodes", [])
    if len(events) != 1 or "Event" not in (events[0].get("labels") or []):
        raise ValueError("event_key must resolve to exactly one Event")
    event = events[0]
    props = event.get("properties") or {}
    if props.get("status") != "open":
        raise ValueError("authorization Event status must be open")
    if props.get("kind") != "handoff":
        raise ValueError("authorization Event kind must be handoff")
    sender = props.get("from_path")
    if not isinstance(sender, str) or os.path.realpath(sender) != reviewer:
        raise ValueError("authorization Event was not sent by the configured reviewer project")
    auth = _validate_commit_fields({
        key: props[key] for key in COMMIT_AUTH_FIELDS if key in props})
    prefix = "验收通过并授权提交：tree " + auth["tree"][:12]
    if not isinstance(props.get("summary"), str) or not props["summary"].startswith(prefix):
        raise ValueError("authorization summary tree prefix mismatch")
    res = ev.rpc("plane.cypher", {"plane": ev.PLANE,
        "query": ("MATCH (p:Project)<-[:NOTIFY]-(e:Event) "
                  "WHERE p.path = $path AND key(e) = $key RETURN e"),
        "params": {"path": proj, "key": event_key}}, token)
    linked = res.get("nodes", [])
    if (len(linked) != 1 or "Event" not in (linked[0].get("labels") or [])
            or linked[0].get("external_key") != event_key):
        raise ValueError("authorization recipient path mismatch or Event has no unique NOTIFY target")
    return auth


def _commit_auth_apply(args, proj, token):
    if not isinstance(args, dict) or set(args) != {"event_key"}:
        raise ValueError("commit_auth_apply accepts event_key only")
    reviewer = _configured_reviewer()
    auth = _load_commit_auth(args["event_key"], proj, token, reviewer)
    steps = []
    repo = _repo_root(proj, steps)
    _check_paths_stay_in_repo(repo, auth["files"])
    current_branch = _git_step(repo, ["branch", "--show-current"], steps)
    if not current_branch:
        raise ValueError("detached HEAD or in-progress rebase; commit authorization requires a branch")
    if current_branch != auth["target_branch"]:
        raise ValueError("current branch does not match target_branch")
    branch_ref = "refs/heads/" + auth["target_branch"]
    ref_tip = _git_step(repo, ["rev-parse", "--verify", branch_ref], steps)
    head = _git_step(repo, ["rev-parse", "HEAD"], steps)
    if ref_tip != auth["parent"]:
        raise ValueError("target branch ref does not match authorized parent")
    if head != auth["parent"]:
        raise ValueError("HEAD does not match authorized parent")
    parent_tree = _git_step(repo, ["rev-parse", auth["parent"] + "^{tree}"], steps)
    accepted_hooks = _check_commit_hooks(repo)
    steps.extend("verified allowlisted hook %s (%s), sha256 %s" % item
                 for item in accepted_hooks)
    index_tree = _git_step(
        repo, ["write-tree"], steps,
        label="git write-tree (formal index before preflight)")
    if index_tree != parent_tree:
        raise ValueError("formal index must match authorized parent tree")
    with tempfile.TemporaryDirectory(prefix="drsg-commit-auth-preflight-") as temp_dir:
        env = _git_environment(os.path.join(temp_dir, "index"))
        _git_step(repo, ["read-tree", auth["parent"]], steps, env,
                  "GIT_INDEX_FILE=<temporary> ")
        _add_paths(repo, auth["files"], auth["force_paths"], env,
                   steps, temporary=True)
        preflight_tree = _git_step(
            repo, ["write-tree"], steps, env, "GIT_INDEX_FILE=<temporary> ")
    if preflight_tree != auth["tree"]:
        raise ValueError("preflight tree mismatch; formal index unchanged")

    head_after = _git_step(repo, ["rev-parse", "HEAD"], steps,
                           label="git rev-parse HEAD after preflight")
    if head_after != auth["parent"]:
        raise ValueError("HEAD changed after preflight")
    index_after = _git_step(repo, ["write-tree"], steps,
                            label="git write-tree (formal index after preflight)")
    if index_after != parent_tree:
        raise ValueError("formal index changed after preflight")
    live_env = _git_environment()
    _add_paths(repo, auth["files"], auth["force_paths"], live_env, steps)
    final_tree = _git_step(repo, ["write-tree"], steps,
                           label="git write-tree (formal index)")
    if final_tree != auth["tree"]:
        raise ValueError("formal index tree mismatch; commit refused")
    # Hooks inherit this environment. Literal pathspecs would break any hook
    # that globs; the kit's own check-docs.py runs `git ls-files "*.md"`.
    commit_env = _git_environment()
    commit_env.pop("GIT_LITERAL_PATHSPECS", None)
    _git(repo, ["commit", "--cleanup=verbatim", "-m", auth["message"]], commit_env)
    steps.append("git commit --cleanup=verbatim -m <authorized message>: completed")
    commit = _git_step(repo, ["rev-parse", "HEAD"], steps)
    committed_parent = _git_step(repo, ["rev-parse", "HEAD^"], steps)
    committed_tree = _git_step(repo, ["rev-parse", "HEAD^{tree}"], steps)
    branch_tip = _git_step(
        repo, ["rev-parse", "refs/heads/" + auth["target_branch"]], steps)
    branch_after = _git_step(repo, ["symbolic-ref", "--short", "HEAD"], steps)
    raw_commit = _git_raw(repo, ["cat-file", "commit", "HEAD"])
    _, separator, committed_message = raw_commit.partition("\n\n")
    message_matches = bool(separator) and committed_message == (
        auth["message"] if auth["message"].endswith("\n")
        else auth["message"] + "\n")
    steps.append("git cat-file commit HEAD message: " +
                 ("matches authorization" if message_matches else "mismatch"))
    mismatches = []
    if committed_parent != auth["parent"]:
        mismatches.append("HEAD^ != authorized parent")
    if committed_tree != auth["tree"]:
        mismatches.append("HEAD^{tree} != authorized tree")
    if branch_tip != commit:
        mismatches.append("target branch ref != new HEAD")
    if branch_after != auth["target_branch"]:
        mismatches.append("checked-out branch != target_branch")
    if not message_matches:
        mismatches.append("commit message != authorized message")
    if mismatches:
        raise RuntimeError("commit %s remains local; verification failed (%s); "
                           "no reset/amend was attempted"
                           % (commit, "; ".join(mismatches)))
    # _load_commit_auth proved the sender is the reviewer, so name it here: the
    # executor must not have to read commit-auth.json to address its receipt.
    steps.append('receipt: post kind="notice" to %s with reply_to=%s'
                 % (reviewer, args["event_key"]))
    return "commit_auth_apply completed\n" + "\n".join(steps)


def call_tool(name, args, token):
    proj = _project_dir()
    if name == "commit_auth_post":
        return _commit_auth_post(args, proj, token)

    if name == "commit_auth_apply":
        return _commit_auth_apply(args, proj, token)

    if name == "event_post":
        target = os.path.abspath(os.path.normpath(args["recipient"]))
        # Both of these are refusals, so they travel as tool errors: a message
        # saying nothing was posted is worthless if the call still reads as a
        # success — the same confusion this whole channel keeps being bitten by.
        if target == proj:
            # A to-do addressed to the sender is the one case the block cannot
            # help with: it arrives where the work already is.
            raise ValueError("%s is this project — an Event is for another "
                             "agent; write a Fact to remember something here."
                             % target)
        pid = ev.project_id(target, token)
        if pid is None:
            raise ValueError("no Project node with path %s — the memory layer "
                             "has never run a session there, so nothing can be "
                             "addressed to it yet." % target)
        # The reply echoes the rendered hint and whether the graph confirmed
        # the address: without it a symbol that resolved to something else —
        # or was never checked — reads exactly like a clean post.
        return ev.report(
            ev.post(target, pid, args["summary"],
                    args.get("kind") or "handoff", args.get("ref") or "",
                    os.path.basename(proj), token,
                    symbols=args.get("symbols"), verb=args.get("verb"),
                    plane=args.get("plane"), from_path=proj,
                    reply_to=args.get("reply_to")),
            target)

    if name == "event_list":
        path = os.path.abspath(os.path.normpath(args.get("project") or proj))
        want = args.get("status") or "open"
        rows = []
        # Open Events are filtered in the query (an old one must not hide
        # behind newer closed ones); history keeps the recent LIST_CAP window.
        events = ev.fetch(path, token, status="open" if want == "open" else None)
        for n in events:
            pr = n.get("properties", {})
            if want != "all" and pr.get("status") != want:
                continue
            rows.append("%-6s %-8s %-14s %s  %s" % (
                pr.get("status", "?"), pr.get("kind", "?"), ev.receipt(pr),
                n.get("external_key", "?"), pr.get("summary", "")))
            if pr.get("reply_to"):
                line = ev.reply_line(pr["reply_to"], events, token)
                if line:
                    rows.append("%-6s %s" % ("", line))
            # The sender's only view of the second line the recipient gets.
            if pr.get("graph_hint"):
                rows.append("%-6s %s" % ("", pr["graph_hint"]))
        return "\n".join(rows) if rows else "no %s events for %s" % (want, path)

    if name == "event_done":
        return ev.close(args["key"], token, project=proj,
                        force=bool(args.get("force")))

    if name == "event_take":
        poller = _load_poller_module()
        lane = args.get("lane")
        if not lane:
            lanes = ev.process_lanes(poller.owner_process()[0])
            if len(lanes) != 1:
                raise ValueError("this session declared lanes %s: name one with lane=<name>"
                                 % ",".join(lanes))
            lane = lanes[0]
        return "\n".join(poller.transfer(os.path.realpath(proj), lane, declared_only=True,
                                          how="event_take on user request"))

    raise ValueError("unknown tool %r" % name)


def respond(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    msg["error" if error else "result"] = error or result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    proj = _project_dir()
    ev.load_env(proj)
    ev.API = os.environ.get("DRSG_API", ev.API)
    ev.PLANE = os.environ.get("DRSG_PLANE", ev.PLANE)
    token = os.environ.get("DRSG_TOKEN", "")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            continue
        method, rid = req.get("method"), req.get("id")
        # Notifications carry no id and must not be answered.
        if rid is None:
            continue

        if method == "initialize":
            respond(rid, {
                # Echo the client's version when it names one: refusing to
                # speak a protocol we are compatible with just to advertise
                # our own is how a working server looks broken.
                "protocolVersion": (req.get("params") or {}).get(
                    "protocolVersion") or PROTOCOL,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "drsg-events", "version": "1.0.0"},
            })
        elif method == "ping":
            respond(rid, {})
        elif method == "tools/list":
            respond(rid, {"tools": TOOLS})
        elif method == "tools/call":
            p = req.get("params") or {}
            if not token:
                respond(rid, {"content": [{"type": "text", "text":
                        "DRSG_TOKEN missing — %s/.drsg/env was not readable"
                        % proj}], "isError": True})
                continue
            try:
                text = call_tool(p.get("name"), p.get("arguments") or {}, token)
                err = False
            except Exception as e:
                # Surfaced as tool output, not as a JSON-RPC error: the model
                # can read this one and fix its call.
                text, err = "%s: %s" % (type(e).__name__, e), True
            respond(rid, {"content": [{"type": "text", "text": text}],
                          "isError": err})
        else:
            respond(rid, error={"code": -32601,
                                "message": "unknown method %r" % method})


if __name__ == "__main__":
    main()

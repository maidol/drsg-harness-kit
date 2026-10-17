#!/usr/bin/env python3
"""SessionStart hook: record this session in dr-strange and inject the
project's compressed memory briefing into Claude's context.

Design (see tools/README.md):
  * Dr-strange native backend allows ONE process per database, so hooks never
    open the DB themselves — they talk to the shared `drsg serve` daemon over
    JSON-RPC (POST /rpc), never the CLI.
  * The API requires `Authorization: Bearer $DRSG_TOKEN` for native clients.
  * Any failure is a soft downgrade: if the daemon is down we emit a bare
    hook output (SessionStart stdout at exit 0 is injected as context, and a
    malformed JSON would break the session). We never block.
  * Memory growth vs context: the injected payload is a *briefing* — a rule
    -compressed, per-kind summary of the project's Facts stored in
    Project.briefing — not the full Fact list. The full Facts stay queryable
    via the MCP tools / per-prompt recall (user_prompt.py), so the constant
    startup cost stays ~one short paragraph no matter how many Facts exist.
  * The .drsg/env file (gitignored) holds DRSG_TOKEN/DRSG_API/DRSG_PLANE.
  * Runs on `startup|resume|compact`. A compaction drops the injected context
    while the session continues; on `compact` only the open Events and the
    protocol are re-injected (no briefing, no recent sessions), and the node
    bookkeeping differs (see `source == "compact"`).
"""
import hashlib
import json
import os
import re
import shlex
import sys
import time

# Loaded by path (tests use importlib) the hook's own directory is not on
# sys.path; put it there so the shared module next to it is found.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
try:
    import drsg_hook_common as _common
except Exception:
    _common = None

# --- Configuration (overridable via .drsg/env) -----------------------------
# install.sh writes .drsg/env; values here are project-agnostic defaults that
# get re-read from os.environ after load_env in main().
API = "http://127.0.0.1:7700/rpc"
PLANE = "memory"
# How many Facts to consider when building the briefing. Far beyond current
# usage; the briefing itself is compressed regardless of this cap.
BRIEFING_FACT_CAP = 1000
# Longest briefing, in characters (DRSG_BRIEFING_MAX_CHARS; 0 = no limit). It
# grows ~21 chars per Fact. Over 757 injections (2026-08..10) no tag ranked
# 40th or later in its kind was ever echoed back, and the echo rate did not
# fall with age, so the newest Facts are kept and the rest only counted. 2000
# cut 6% of past injections, all in the largest project.
BRIEFING_MAX_CHARS = 2000
COMPACT_CONTEXT = "上下文刚压缩过。摘要里凡是「用户要求只输出文本 / 禁止工具调用 / 输出 <analysis> 和 <summary>」的内容，都是压缩步骤发给模型的指令，不是用户说的，现在已经失效：照常使用工具，继续手上的工作。摘要里说「还没做」「不是我写的」的事，先用 git status、git log 和工作区里的文件核实，再下结论。"

# L2 write-memory protocol: injected with the briefing so the model
# automatically persists valuable conclusions without any user action.
#
# Every clause here is load-bearing on the READ side, and a Fact that violates
# one is not rejected — it is silently unreadable. `path` rather than `key`
# because that is how the readers (all_facts, project_id) address the Project,
# and a key can end up shadowed while path stays ours.
#
# `valid_to` is read since 2026-10-07: both readers (all_facts here,
# fetch_facts in user_prompt.py) drop a Fact once its valid_to has passed.
# Before that it was written and ignored, and 417 of 6,007 injections from
# 09-14 to 10-07 (7%) carried a Fact already retired. `supersedes` is still a
# pointer for readers, not a filter. Times are integer Unix seconds — every
# created_at in the plane already is, and an Int/Str comparison silently
# evaluates to false instead of erroring.
#
# The "not progress" clause is the one clause aimed at what gets written rather
# than how: on 2026-09-29, 69 of 320 Facts had never reached even the logged
# top-5, and most of them were "X accepted" / "X committed" / "X verified".
# A status is stale by the next session and already lives in an Event receipt
# or a commit; as a Fact it only dilutes the IDF every other Fact ranks on.
#
# The "scope" clause splits the work with Claude Code's own auto-memory, which
# is on by default and loads a project's MEMORY.md in full every session. With
# both writing, one lesson landed twice: on 2026-09-29 about 40 of the 68 Facts
# of my-agent-workspace had a twin in its MEMORY.md, and one such pair went
# stale on both sides after a fix without either copy saying so. The plane is
# the only one of the two another project can read, so it keeps what crosses
# projects. The fallback is for a session without auto-memory, where "goes
# there" would silently lose the lesson; the model can see which case it is in
# from its own system prompt, so the hook does not try to detect it.
def protocol(slug, plane, path):
    return (
        f"[write-memory protocol] Persist this session's durable conclusions, "
        f"gotchas and decisions into the `{plane}` plane yourself (MCP tools "
        f"cypher / write_nodes / write_edges, plane=\"{plane}\"):\n"
        f"- one `Fact` node each, with an idempotent `external_key` (e.g. "
        f"fact-{slug}-<topic>), a `kind` you choose (setup-experience / "
        "decision / gotcha / workflow), `summary` as a ONE-LINE conclusion (only its "
        "first ~18 chars reach the briefing), `detail` for the rest, "
        "`created_at` as the current Unix time (integer seconds);\n"
        "- not progress: \"X accepted / committed / tests pass\" is a status, "
        "not a conclusion — it goes in the Event receipt or the commit, not a Fact;\n"
        "- never a secret value: an API key, token, password or private key is "
        "written as its variable name or `<hidden>` — nothing checks a Fact on the way in;\n"
        "- scope: a Fact is for what would help work in ANOTHER project. If your "
        "system prompt names an auto-memory directory, a lesson that matters only "
        "inside this project goes there, not in both — two copies drift apart and "
        "nothing reports it; without one, write it here;\n"
        f"- linked with an `ABOUT` edge to the Project matched by "
        f"`p.path = \"{path}\"` (by path, not key; a Fact unreachable that "
        "way is invisible);\n"
        "- replacing an older Fact: set `supersedes`=<old key> on the new one "
        "and `valid_to`=<Unix time> on the old one; never edit or delete the "
        "old Fact."
    )






SECRET_ENV_NAME = re.compile(r"(?:^|_)(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD)(?:_|$)", re.I)


def settings_secret_message(proj_dir):
    """Terminal-only warning when this project's settings hold a plaintext secret.

    Counts permission rules that match secret_redact.RULES (an "always allow"
    on a command with a key in it stores the whole command) and names env
    entries that look like secrets. Never shows a value; without
    secret_redact.py next to this hook there is no warning.
    """
    try:
        from secret_redact import RULES
    except Exception:
        return ""
    rules, names = 0, set()
    for name in ("settings.local.json", "settings.json"):
        try:
            with open(os.path.join(proj_dir, ".claude", name), encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        perms = data.get("permissions")
        if isinstance(perms, dict):
            for key in ("allow", "deny", "ask"):
                entries = perms.get(key)
                if not isinstance(entries, list):
                    continue
                rules += sum(1 for rule in entries if isinstance(rule, str)
                             and any(p.search(rule) for _, p in RULES))
        env = data.get("env")
        if isinstance(env, dict):
            names.update(k for k, v in env.items() if SECRET_ENV_NAME.search(k)
                         and isinstance(v, str) and len(v) >= 8 and not v.startswith("$"))
    parts = []
    if rules:
        parts.append("%d permission rule(s) carry a plaintext secret; delete them" % rules)
    if names:
        parts.append("env %s hold(s) a plaintext value; move it to apiKeyHelper "
                     "or a 0600 env file" % ", ".join(sorted(names)))
    if not parts:
        return ""
    return "drsg: .claude settings hold secrets (values not shown): " + "; ".join(parts) + "."


def hook_drift_message(proj_dir):
    """Human-visible refresh command when installed project hooks differ."""
    try:
        tools_dir = os.path.join(os.environ.get("DRSG_MEM_DIR") or
                                 os.path.expanduser("~/.drsg-memory"), "tools")
        template_dir = os.path.join(tools_dir, "templates", "hooks")
        project_hooks = os.path.join(proj_dir, ".claude", "hooks")
        if not os.path.isdir(project_hooks):
            return ""
        names = sorted(n for n in os.listdir(template_dir) if n.endswith(".py"))
        if not names:
            return ""
        drifted = False
        for name in names:
            try:
                with open(os.path.join(template_dir, name), "rb") as fh:
                    template = fh.read()
            except OSError:
                return ""
            try:
                with open(os.path.join(project_hooks, name), "rb") as fh:
                    installed = fh.read()
            except FileNotFoundError:
                drifted = True
                continue
            except OSError:
                return ""
            if template != installed:
                drifted = True
        if not drifted:
            return ""
        installer = shlex.quote(os.path.join(tools_dir, "install.sh"))
        project = shlex.quote(proj_dir)
        return "DrSG hooks differ from runtime templates. Refresh with: %s %s" % (
            installer, project)
    except Exception:
        return ""


def hook_out(system_message=None, **extra):
    # stdout must contain exactly one JSON object.
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart"}}
    out["hookSpecificOutput"].update(extra)
    # `systemMessage` is top-level, not hook-specific, and it is the only
    # channel that reaches the terminal: additionalContext goes to the model
    # alone. A to-do another project left here was therefore invisible to the
    # person who decides whether it gets done this session.
    if system_message:
        out["systemMessage"] = system_message
    print(json.dumps(out))


def compact_context(source, existing=None):
    if source != "compact":
        return existing
    try:
        return COMPACT_CONTEXT + ("\n\n" + existing if existing else "")
    except Exception:
        return existing


def compact_context_kwargs(source, existing=None):
    context = compact_context(source, existing)
    return {"additionalContext": context} if context is not None else {}


BACKUP_RE = re.compile(r"^backup-\d{8}T\d{12}Z-[0-9a-f]{8}$")
BACKUP_SCAN_LIMIT = 7
BACKUP_MAX_AGE_DAYS = 7


def join_messages(separator, *parts):
    return separator.join(part for part in parts if part)


def serve_start_command():
    mem_dir = os.environ.get("DRSG_MEM_DIR")
    if not mem_dir:
        return "~/.drsg-memory/tools/serve.sh start"
    path = os.path.join(os.path.expanduser(mem_dir), "tools", "serve.sh")
    return shlex.quote(path) + " start"


def daemon_down_messages():
    system = ("⚠ DrSG memory daemon is unreachable. This session has no briefing, "
              "Events, or recall. Restore it with: " + serve_start_command())
    model = ("DrSG memory is unavailable; this session's Event list is not "
             "trustworthy. Restore the daemon before checking open Events.")
    return system, model


def memory_backup_command(action):
    mem_dir = os.environ.get("DRSG_MEM_DIR")
    if not mem_dir:
        tool = "~/.drsg-memory/tools/memory-backup.py"
    else:
        tool = shlex.quote(os.path.join(os.path.expanduser(mem_dir),
                                        "tools", "memory-backup.py"))
    return "python3 " + tool + " " + action


def backup_message(status):
    backup = memory_backup_command("backup")
    drill = memory_backup_command("drill")
    if status is None:
        reason = "no valid backup found"
    else:
        reason = "latest valid backup is %d days ago" % status
    return "⚠ DrSG memory backup: %s. Run: %s; then %s" % (reason, backup, drill)


def backup_max_age_days():
    raw = os.environ.get("DRSG_BACKUP_MAX_AGE_DAYS")
    if raw is None:
        return BACKUP_MAX_AGE_DAYS
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return BACKUP_MAX_AGE_DAYS
    return value if value >= 0 else BACKUP_MAX_AGE_DAYS


def parse_backup_time(value):
    from datetime import datetime, timezone

    if not isinstance(value, str):
        raise ValueError("backup_time is not a string")
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("backup_time has no timezone")
    return parsed.astimezone(timezone.utc)


def backup_expiry_days(backup_time, now=None, max_age=BACKUP_MAX_AGE_DAYS):
    from datetime import datetime, timedelta, timezone

    if now is None:
        now = datetime.now(timezone.utc)
    elif now.tzinfo is None or now.utcoffset() is None:
        now = now.replace(tzinfo=timezone.utc)
    else:
        now = now.astimezone(timezone.utc)
    age = now - backup_time
    if age.total_seconds() < 0 or age <= timedelta(days=max_age):
        return None
    return max(0, int(age.total_seconds() // 86400))


def backup_warning(now=None):
    max_age = backup_max_age_days()
    if max_age == 0:
        return ""
    try:
        import ipaddress
        from urllib.parse import urlsplit

        parsed = urlsplit(API)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            return ""
        hostname = parsed.hostname
        if hostname not in ("localhost", "localhost."):
            try:
                if not ipaddress.ip_address(hostname).is_loopback:
                    return ""
            except ValueError:
                return ""

        mem_dir = os.path.expanduser(os.environ.get("DRSG_MEM_DIR") or "~/.drsg-memory")
        root = os.path.join(mem_dir, "backups")
        if os.path.islink(root):
            return backup_message(None)
        try:
            names = os.listdir(root)
        except FileNotFoundError:
            return backup_message(None)
        except OSError:
            return ""

        candidates = sorted((name for name in names if BACKUP_RE.fullmatch(name)),
                            reverse=True)[:BACKUP_SCAN_LIMIT]
        for name in candidates:
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isdir(path):
                continue
            manifest_path = os.path.join(path, "manifest.json")
            if os.path.islink(manifest_path) or not os.path.isfile(manifest_path):
                continue
            try:
                with open(manifest_path, encoding="utf-8") as fh:
                    manifest = json.load(fh)
                if (not isinstance(manifest, dict) or
                        manifest.get("tool") != "drsg-memory-backup" or
                        manifest.get("schema_version") != 1):
                    continue
                backup_time = parse_backup_time(manifest.get("backup_time"))
                expired_days = backup_expiry_days(backup_time, now, max_age)
            except (OSError, UnicodeError, ValueError, TypeError, AttributeError):
                continue
            if expired_days is None:
                return ""
            return backup_message(expired_days)
        return backup_message(None)
    except Exception:
        return ""




def project_id(proj_dir, token):
    """The Project node for this working directory, addressed by `path`.

    Not by `key(p)`: digest.write bypasses the uniqueness check that
    node.create enforces, so a distillation run can write a second node under
    an existing key and shadow the real one — and deleting that shadow does not
    hand the key back, it just leaves it resolving to nothing. Either way every
    key-filtered read silently returns empty while the data is untouched.
    That has happened, and it took the whole briefing out with it.
    `path` is ours, written here at line ~1 of every session, and no distiller
    invents it. Returns the node id, or None when this project is new."""
    res = rpc("plane.cypher", {"plane": PLANE,
        "query": "MATCH (p:Project) RETURN p", "params": {}}, token)
    for n in res.get("nodes", []):
        if (n.get("properties") or {}).get("path") == proj_dir:
            return n.get("id")
    return None


def all_facts(proj_dir, token):
    """All live Facts ABOUT this project, newest first. Retired ones (their
    valid_to has passed) are dropped here, so the briefing never shows them."""
    res = rpc("plane.cypher", {"plane": PLANE,
        "query": ("MATCH (p:Project)<-[:ABOUT]-(f:Fact) "
                  "WHERE p.path = $path "
                  "RETURN f ORDER BY f.created_at DESC LIMIT %d") % BRIEFING_FACT_CAP,
        "params": {"path": proj_dir}}, token)
    now = time.time()
    return [n for n in res.get("nodes", [])
            if not retired((n.get("properties") or {}).get("valid_to"), now)]




def fact_sig(facts):
    """Which Facts a briefing was built from, as 12 hex chars.

    The count alone stopped being enough once retired Facts drop out:
    replacing one (a new Fact with `supersedes`, `valid_to` on the old) keeps
    the count, and the stale briefing would be reused forever."""
    keys = sorted(str(n.get("external_key") or n.get("id")) for n in facts)
    return hashlib.sha1("\n".join(keys).encode()).hexdigest()[:12]


def open_events(proj_dir, token, limit=3):
    """Coordination events addressed to this project and still open.

    A hard-bounded block, unlike the briefing: an Event is a to-do, and a
    to-do compressed to 18 chars or losing a ranking contest is worse than
    absent. Costs nothing when there are none — the caller only appends the
    block if this returns something, same rule as Recent sessions.

    `status` is filtered in the WHERE clause, before LIMIT: filtered after it,
    20 newer closed Events pushed an open one out and it was never shown. The
    window is wide; `limit` caps what is displayed."""
    try:
        res = rpc("plane.cypher", {"plane": PLANE,
            "query": ("MATCH (p:Project)<-[:NOTIFY]-(e:Event) "
                      "WHERE p.path = $path AND e.status = 'open' "
                      "RETURN e ORDER BY e.created_at DESC LIMIT 200"),
            "params": {"path": proj_dir}}, token)
    except Exception as e:
        print(f"[drsg-memory] open events: {e}", file=sys.stderr)
        return []
    out = []
    for n in res.get("nodes", []):
        pr = n.get("properties", {})
        if pr.get("status") != "open":
            continue
        line = "- [%s from %s] %s" % (pr.get("kind", "notice"),
                                      pr.get("from_project", "?"),
                                      (pr.get("summary") or "")[:80])
        if pr.get("ref"):
            line += f"  (ref: {pr['ref']})"
        key = n.get("external_key", "?")
        line = f"{line}  <{key}>"
        # A second line, rendered by event.py at post time from the Event's
        # `symbols`/`verb` — never written by hand, and never folded into
        # `summary`, which is truncated to 80 chars just above where a symbol
        # key would lose the tail that identifies it. Appended verbatim so this
        # renderer and user_prompt.py's cannot say different things about one
        # to-do.
        if pr.get("graph_hint"):
            line += "\n  " + pr["graph_hint"]
        # `fresh` marks a to-do the graph has no receipt for yet, so the ack
        # below records when it was FIRST delivered rather than most recently.
        out.append({"key": key, "line": line,
                    "fresh": not pr.get("seen_at")})
        if len(out) >= limit:
            break
    return out
























def short_tag(s, n=18):
    """One compressed label per Fact summary: prefer the conclusion side of
    an arrow, cut to n chars. Zero-dependency rule compression."""
    s = (s or "").strip()
    for sep in ("→", " -> ", " => "):
        if sep in s:
            s = s.split(sep, 1)[1].strip()
            break
    # First sentence only, either script's full stop.
    s = s.split("\u3002")[0].split(". ")[0]
    return s if len(s) <= n else s[:n - 1] + "…"


def build_briefing(facts, max_chars=None):
    """Group Facts by kind, one line each: `• <kind> ×n: tag; tag; ...`.

    `facts` arrive newest first. Past `max_chars` (BRIEFING_MAX_CHARS when
    None; 0 = no limit) the oldest are left out and a last line counts them."""
    if max_chars is None:
        max_chars = BRIEFING_MAX_CHARS

    def render(subset):
        by_kind = {}
        for n in subset:
            pr = n.get("properties", {})
            kind = pr.get("kind") or "general"
            by_kind.setdefault(kind, []).append(short_tag(pr.get("summary", "")))
        lines = []
        for kind in sorted(by_kind):
            tags = by_kind[kind]
            lines.append("• %s ×%d: %s" % (kind, len(tags), "; ".join(t for t in tags if t)))
        return "\n".join(lines)

    def capped(keep):
        note = "（另有 %d 条较早的 Fact 未列出）" % (len(facts) - keep)
        text = render(facts[:keep])
        return text + "\n" + note if text else note

    text = render(facts)
    if not max_chars or len(text) <= max_chars:
        return text
    # Binary search for the most Facts that fit: length grows with `keep`, and
    # one render per step keeps a 1000-Fact plane well inside the hook budget.
    lo, hi = 0, len(facts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if len(capped(mid)) <= max_chars:
            lo = mid
        else:
            hi = mid - 1
    return capped(lo)


def ensure_briefing(proj_dir, pid, token):
    """Rebuild Project.briefing when the set of live Facts changed; else reuse it.
    Returns (briefing text, fact count). Addressed by node id (see project_id).

    The count comes back for the telemetry line: a briefing that stops growing
    is the difference between "nothing worth writing happened" and "the write
    path broke", and the text alone cannot tell those apart."""
    try:
        proj = rpc("node.get", {"plane": PLANE, "id": pid}, token)
        props = (proj or {}).get("properties", {})
        stored = props.get("briefing_count")
        stale = True
        try:
            facts = all_facts(proj_dir, token)
            if (stored == len(facts) and props.get("briefing_sig") == fact_sig(facts)
                    and props.get("briefing_cap") == BRIEFING_MAX_CHARS):
                stale = False
        except Exception:
            facts = None  # read failed — not the same as "no facts"
            stale = False  # keep the stored briefing; the next read rebuilds it
        if stale:
            brief = build_briefing(facts) if facts else ""
            rpc("node.update", {"plane": PLANE, "id": pid, "set": {
                "briefing": brief, "briefing_count": len(facts or []),
                "briefing_sig": fact_sig(facts or []),
                "briefing_cap": BRIEFING_MAX_CHARS,
                "briefing_at": int(time.time())}}, token)
        else:
            brief = (proj.get("properties", {}).get("briefing", "") or "")
        return brief, len(facts) if facts is not None else stored
    except Exception as e:
        print(f"[drsg-memory] ensure_briefing failed: {e}", file=sys.stderr)
        return "", None


def heal_text(token):
    """Keep the derived `Fact.text` (summary + detail) current, plane-wide.

    `text` exists because `Fact.summary`'s BM25 index is pinned to the English
    analyzer: `ensure_keyword_index` refuses to change an index's language and
    the API has no drop. A Chinese (jieba) index needs a property of its own,
    and `detail` alone is not it — measured, summary carries most of the
    signal. So `text` is derived and indexed instead.

    It is maintained here, by code, and deliberately absent from the protocol
    above. A field the protocol asks the model to write is a field that gets
    silently omitted — that is where the six empty Fact shells came from. This
    self-heals every session start instead, so an omission cannot degrade
    anything.

    Duplicated on purpose in tools/backfill_text.py, which is
    the standalone repair tool; the hooks are byte-identical copies across
    projects and cannot import from any one repo. Keep `derive` in sync — it is
    two lines.

    Plane-wide, not per-project: every install shares one plane, so whichever
    session starts first heals it for all of them. Returns the repair count.

    Only Facts with no `text` at all are fetched: that is how an omission
    looks, and the full scan it replaced pulled every Fact (1.1 MB at 377)
    on every session start. Facts are replaced, not edited in place, so a
    `text` that exists stays current; tools/backfill_text.py re-derives all.
    """
    # Whole nodes on purpose, unlike orphan_facts below: the update addresses
    # each Fact by node id, the query language has no `id(f)`, and addressing
    # by key instead would miss keyless Facts and hit shadows (see project_id).
    res = rpc("plane.cypher", {"plane": PLANE,
                               "query": "MATCH (f:Fact) WHERE f.text IS NULL RETURN f",
                               "params": {}}, token)
    fixed = 0
    for n in res.get("nodes", []):
        props = n.get("properties") or {}
        s = (props.get("summary") or "").strip()
        d = (props.get("detail") or "").strip()
        want = (s + "\n" + d).strip() if d else s
        if not want or props.get("text") == want:
            continue
        rpc("node.update", {"plane": PLANE, "id": n["id"], "set": {"text": want}}, token)
        fixed += 1
    return fixed


def orphan_facts(token):
    """Facts with no ABOUT edge to a Project — permanently invisible to recall.

    Reported, never repaired. Attaching one means deciding which Project it is
    about, and that is a judgement, not a repair: auto-grafting the 286 L3
    nodes onto whichever Project sorted first would have been worse than
    leaving them unreachable, because then they would have been *injected*.

    The reachability test is the recall query's own shape, deliberately. It
    means "reachable by the code that actually reads memory" — an ABOUT edge
    pointing at something that is not a Project does not count, and must not,
    because recall would not follow it either.

    Returns the orphan keys, newest-looking first is not worth the sort — the
    count is the signal and the keys are for the human who investigates.

    Keys only, not whole nodes. `RETURN f` brought every Fact back with its
    `detail`, twice — about 1 MB per query at 344 Facts, 55–66 ms of every
    session start spent on two sets of strings. `key(f)` is the same value as
    the node's `external_key` (341 of 341 on the live plane, 2026-09-29), and a
    Fact with no key comes back as a `[null]` row and is dropped, as before.
    """
    def keys(query):
        res = rpc("plane.cypher", {"plane": PLANE, "query": query, "params": {}}, token)
        return {row[0] for row in res.get("rows", []) if row and row[0]}

    everything = keys("MATCH (f:Fact) RETURN key(f)")
    reachable = keys("MATCH (p:Project)<-[:ABOUT]-(f:Fact) RETURN key(f)")
    return sorted(everything - reachable)


def _hook_idle_hours(proj_dir, lease):
    """Whole hours since the lease holder's transcript changed, or None if unknown."""
    sid = str(lease.get("session_id") or "")
    if not re.match(r"^[A-Za-z0-9-]+$", sid):
        return None
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    path = os.path.join(root, "projects", re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(proj_dir)),
                        sid + ".jsonl")
    try:
        return int((time.time() - os.path.getmtime(path)) // 3600)
    except OSError:
        return None


if _common is not None:
    rpc = _common.rpc
    load_env = _common.load_env
    telemetry = _common.telemetry
    _proc = _common._proc
    _claude_pid = _common._claude_pid
    _hook_lanes = _common._hook_lanes
    _hook_lease = _common._hook_lease
    _hook_lane_names = _common._hook_lane_names
    _hook_idle = _common._hook_idle
    _lane_owner_line = _common._lane_owner_line
    event_owner = _common.event_owner
    mark_events_shown = _common.mark_events_shown
    ack_events = _common.ack_events
    retired = _common.retired


def main(now=None):
    if _common is None:
        hook_out()
        return
    ts_start = time.time()
    data = json.load(sys.stdin)
    proj_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    load_env(proj_dir)
    drift_message = join_messages("\n", hook_drift_message(proj_dir),
                                  settings_secret_message(proj_dir))
    source = data.get("source", "startup")
    # Re-read config after load_env populated os.environ (install.sh's .drsg/env).
    global API, PLANE, BRIEFING_MAX_CHARS
    API = os.environ.get("DRSG_API", API)
    PLANE = os.environ.get("DRSG_PLANE", PLANE)
    try:
        BRIEFING_MAX_CHARS = max(0, int(os.environ.get("DRSG_BRIEFING_MAX_CHARS", BRIEFING_MAX_CHARS)))
    except ValueError:
        pass  # a malformed value keeps the default rather than failing the hook
    token = os.environ.get("DRSG_TOKEN", "")
    if not token:
        hook_out(system_message=drift_message or None,
                 **compact_context_kwargs(source))
        return
    try:
        rpc("db.stats", {}, token)  # liveness probe
    except Exception:
        system_warning, model_warning = daemon_down_messages()
        context = compact_context_kwargs(source)
        context["additionalContext"] = join_messages(
            "\n\n", context.get("additionalContext", ""), model_warning)
        hook_out(system_message=join_messages("\n", drift_message, system_warning),
                 **context)  # daemon down → don't block the session
        return

    backup_notice = backup_warning(now) if source == "startup" else ""
    sid = data.get("session_id", "")
    slug = os.path.basename(os.path.normpath(proj_dir))
    ts = int(time.time())

    # 1. Idempotently record Project + a fresh Session for this session.
    #    Existence is decided by `path`, not by whether the key is free: after a
    #    key-index accident the key can be unowned while the node is right there
    #    with every Fact still attached, and creating "because the key was free"
    #    is what turns one damaged project into two.
    pid = project_id(proj_dir, token)
    if pid is None:
        try:
            created = rpc("node.create", {"plane": PLANE, "key": slug, "labels": ["Project"],
                                          "properties": {"path": proj_dir}}, token)
            pid = created.get("id")
        except Exception as e:
            print(f"[drsg-memory] project create failed: {e}", file=sys.stderr)
    if source == "compact":
        # A compaction keeps the SAME session_id, so the Session node and its
        # BELONGS_TO edge already exist — creating again would only collide.
        # We still run (matcher includes `compact`) because the point of this
        # hook on a compaction is re-injecting the open Events and the protocol,
        # which the compaction summary drops. Stamp the event and move on.
        try:
            rpc("node.update", {"plane": PLANE, "key": sid,
                                "set": {"compacted_at": ts}}, token)
        except Exception as e:
            print(f"[drsg-memory] compact stamp failed: {e}", file=sys.stderr)
    else:
        try:
            rpc("node.create", {"plane": PLANE, "key": sid, "labels": ["Session"],
                "properties": {"started_at": ts,
                               "source": source,
                               "cwd": data.get("cwd", ""),
                               "project": slug}}, token)
            # Link by id (NodeRef is untagged: a number is an id, a string a key).
            # A dangling key makes edge.create fail outright — the session record
            # would be lost for exactly as long as the key stayed broken.
            rpc("edge.create", {"plane": PLANE, "src": sid, "dst": pid,
                                "type": "BELONGS_TO"}, token)
        except Exception as e:
            print(f"[drsg-memory] record failed: {e}", file=sys.stderr)

    # Derived-field upkeep, before the briefing reads anything. Best-effort:
    # a stale `text` only costs the shadow ranker some accuracy, and nothing
    # here is worth failing a session start over.
    try:
        healed = heal_text(token)
    except Exception as e:
        healed = None
        print(f"[drsg-memory] heal_text failed: {e}", file=sys.stderr)

    # An orphan Fact is written, costs storage, and can never be read. Nothing
    # errors when one is created, so the only way it surfaces is a check like
    # this one. Counted every session; the keys go to stderr (visible when a
    # human looks) rather than into the injected context, which is for memory,
    # not for maintenance chores.
    try:
        orphans = orphan_facts(token)
        if orphans:
            print(f"[drsg-memory] {len(orphans)} Fact(s) with no ABOUT edge to a "
                  f"Project — unreachable by recall: {', '.join(orphans[:5])}"
                  + (" …" if len(orphans) > 5 else ""), file=sys.stderr)
    except Exception as e:
        orphans = None
        print(f"[drsg-memory] orphan_facts failed: {e}", file=sys.stderr)

    # 2. Inject the compressed briefing and recent sessions except after compaction.
    parts = []
    # After a compaction the briefing is not injected, so building it would be
    # RPC round trips thrown away; telemetry records facts=None for compact.
    brief, n_facts = (ensure_briefing(proj_dir, pid, token)
                      if pid and source != "compact" else ("", None))
    if source != "compact" and brief:
        parts.append("Briefing:\n" + brief)
    if source != "compact":
        try:
            res = rpc("plane.cypher", {"plane": PLANE,
                "query": ("MATCH (p:Project)<-[:BELONGS_TO]-(s:Session) "
                          "WHERE p.path = $path "
                          "RETURN s ORDER BY s.started_at DESC LIMIT 3"),
                "params": {"path": proj_dir}}, token)
            # Only sessions that actually say something. Nothing writes
            # Session.summary today, so listing every recent session spent ~10% of
            # the startup injection on three lines of bare timestamps — context the
            # model cannot act on. When a summary does get written the line earns
            # its place again, and the block comes back on its own.
            sess_lines = []
            for n in res.get("nodes", []):
                pr = n.get("properties", {})
                if not pr.get("summary"):
                    continue
                sess_lines.append(f"- session {pr.get('started_at')} "
                                  f"[{pr.get('source', '?')}]: {pr['summary']}")
            if sess_lines:
                parts.append("Recent sessions:\n" + "\n".join(sess_lines))
        except Exception as e:
            print(f"[drsg-memory] recall sessions: {e}", file=sys.stderr)

    # Coordination events left for this project by another agent. Bounded and
    # self-clearing: once the Event is closed the block is gone. Closing is
    # described in-line because not every install has the helper script — the
    # MCP tools are the one interface every session has.
    events = open_events(proj_dir, token)
    ev_block = ""
    user_msg = None
    if events:
        ev_lines = [e["line"] for e in events]
        # Which session acts on them: every session sees the list, one executes it.
        owner = event_owner(proj_dir, sid)
        if owner:
            ev_lines.insert(0, owner)
        ev_block = ("⏳ Open for you (set the Event node's `status` to \"done\" "
                    "once handled):\n" + "\n".join(ev_lines))
        parts.append(ev_block)
        # Same list, second audience. Only Events get a terminal line: the
        # briefing and the protocol are standing context, while a to-do is a
        # decision someone has to make now, and it is the user who decides
        # whether this session is the one that takes it.
        user_msg = ("⏳ drsg memory — open for this project:\n"
                    + "\n".join(ev_lines))
        # Only claim it was shown where the REPL actually renders it. On a
        # resume the message above goes nowhere, and marking it seen would
        # make user_prompt.py stay quiet too — the one path left that can
        # still reach the person. Over-reporting costs a repeated line on a
        # fork; under-reporting loses the to-do entirely.
        if source == "startup":
            mark_events_shown(proj_dir, sid, [e["key"] for e in events])
            # Same predicate, for the same reason: the receipt must mean "a
            # person saw this", and on a resume nothing rendered. Only the
            # ones with no receipt yet, so seen_at stays the FIRST delivery.
            ack_events([e["key"] for e in events if e["fresh"]], sid, token)

    # L2: the write-memory protocol — makes the model the value-judge for what
    # deserves persisting, every turn, automatically (no user action needed).
    proto = protocol(slug, PLANE, proj_dir)
    parts.append(proto)
    ctx = "# dr-strange memory (%s)\n%s" % (slug, "\n\n".join(parts))
    ctx = compact_context(source, ctx)
    # Split the cost the way it is spent. The protocol is a fixed instruction,
    # not memory: counted together with the briefing it hides that most of the
    # startup budget buys no recall at all.
    # `source` distinguishes the startup injection from a re-injection after a
    # compaction — without it one session's two briefing lines are unreadable.
    telemetry(proj_dir, {"event": "briefing", "session": sid, "project": slug,
                         "source": source, "facts": n_facts,
                         "brief_chars": len(brief), "proto_chars": len(proto),
                         "events": len(events), "event_chars": len(ev_block),
                         "total_chars": len(ctx),
                         # None = the repair pass itself failed, 0 = nothing to
                         # repair. A number that stays >0 every session means
                         # something is rewriting summaries behind us.
                         "text_healed": healed,
                         # None = the check itself failed, 0 = none orphaned.
                         # A number that grows means something is writing Facts
                         # without the ABOUT edge again.
                         "orphan_facts": None if orphans is None else len(orphans),
                         "ms": int((time.time() - ts_start) * 1000)})
    user_msg = join_messages("\n", user_msg, drift_message, backup_notice)
    hook_out(system_message=user_msg or None, additionalContext=ctx)


if __name__ == "__main__":
    main()

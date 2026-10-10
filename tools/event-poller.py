#!/usr/bin/env python3
"""Poll this project's open Events without ever calling the model.

Registered as an `asyncRewake` command hook on SessionStart, Stop, StopFailure and
SessionEnd. Claude Code runs an asyncRewake hook in the background and wakes
the model only when it exits with code 2, so every idle round here costs no
model call at all: the loop sleeps, asks the memory daemon over RPC, and stays
silent until there is something the session has not been told about yet.

One project, one poller. Two sessions in the same directory would otherwise
both be woken for the same Event and both act on it. The right to poll is a
*lease* held by a session, not a lock held by a process: the poller has to
exit to wake its model, and a lock that died with it would hand the project to
another session at exactly the moment the first one starts working on the
Event. The lease names the session and its Claude Code process; a waiting
poller takes it over only when that process is gone, so a session that exits
(cleanly or not) is replaced within one tick. The one exception is a background
session (under `claude bg-pty-host`): `/exit` there only detaches it and its
process lives on, so a foreground session takes the lease from it.

  SessionStart / Stop / StopFailure   start this session's poller unless it is running
  SessionEnd            stop it and give the lease back

Silent by design: no .drsg/env, a daemon that is down, a malformed answer —
all of them are logged to the state directory and retried next round, never
surfaced as a wake-up.
"""
import fcntl
import hashlib
import importlib.util
import json
import os
import signal
import sys
import time

INTERVAL = int(os.environ.get("EVENT_POLL_INTERVAL", "900"))   # 15 minutes
TICK = int(os.environ.get("EVENT_POLL_TICK", "60"))             # takeover latency
KICK_STEP = float(os.environ.get("EVENT_POLL_KICK_STEP", "1"))  # seconds between looks at `kick`
LOG_MAX = int(os.environ.get("EVENT_POLL_LOG_MAX", "262144"))   # bytes before poller.log rotates
SEEN_MAX_AGE = 14 * 86400                                       # orphaned seen files, seconds
STATE_ROOT = os.path.join(os.environ.get("DRSG_MEM_DIR") or
                          os.path.expanduser("~/.drsg-memory"), "poller")
HERE = os.path.dirname(os.path.realpath(__file__))
MARK = "event-poller.py"


def log(state, msg):
    try:
        with open(os.path.join(state, "poller.log"), "a", encoding="utf-8") as f:
            f.write("%s %d %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), os.getpid(), msg))
    except OSError:
        pass


def diagnostic(state, branch, sid, pid):
    sid = sid if isinstance(sid, str) and sid else "-"
    log(state, "diag branch=%s sid=%s pid=%s" % (
        branch, sid[:8], pid or "-"))


def rotate(state):
    """Keep poller.log bounded: past LOG_MAX it becomes poller.log.1, replacing
    the previous one, so two files at most and the newest lines always survive.
    Done under the lock, re-checked inside it, so two pollers cannot rotate
    twice and bury the first .1. Not called from log(): that runs inside the
    lock already, and flock does not nest across file descriptors."""
    path = os.path.join(state, "poller.log")
    try:
        if os.path.getsize(path) <= LOG_MAX:
            return
        with Locked(state):
            if os.path.getsize(path) > LOG_MAX:
                os.replace(path, path + ".1")
    except OSError:
        pass


def proc_start(pid):
    """Start time of `pid` in clock ticks, or None when it is gone. Compared
    alongside the pid so that a recycled pid does not keep a dead lease alive."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return int(f.read().rsplit(")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def proc_state(pid):
    """One-letter state of `pid` from /proc/<pid>/stat, "" when it is gone."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return f.read().rsplit(")", 1)[1].split()[0]
    except (OSError, IndexError):
        return ""


def alive(pid, start):
    """The same process (pid + start time), and one that can still act on a
    wake-up. A stopped (T/t) or zombie (Z/X) Claude Code counts as gone: on
    2026-10-06 a session suspended with Ctrl+Z whose terminal was then closed
    (PPid 1, state T) kept the lease for an hour and swallowed a wake-up that
    nobody would ever read."""
    return (bool(pid) and proc_start(pid) == start
            and proc_state(pid) not in ("T", "t", "Z", "X"))


def mtime(path):
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return 0


def wait(kick, since, seconds):
    """Sleep up to `seconds`, returning early once `kick` changes. event.py
    touches it after posting here, so a new Event is looked at within
    KICK_STEP instead of at the next INTERVAL boundary. Only a stat per step:
    the lease and /proc work still happens once per TICK."""
    end = time.time() + seconds
    while time.time() < end:
        if mtime(kick) != since:
            return
        time.sleep(min(KICK_STEP, max(end - time.time(), 0)))


def cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
    except OSError:
        return []


def owner_process():
    """The Claude Code process this hook belongs to: the nearest ancestor whose
    first or second argv names `claude`."""
    if os.environ.get("EVENT_POLL_OWNER_PID"):          # tests only
        pid = int(os.environ["EVENT_POLL_OWNER_PID"])
        return pid, proc_start(pid)
    pid = os.getppid()
    while pid > 1:
        argv = cmdline(pid)
        if any("claude" in os.path.basename(a) for a in argv[:2]):
            return pid, proc_start(pid)
        try:
            with open("/proc/%d/stat" % pid) as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return None, None


def background(pid):
    """True when `pid` runs under `claude bg-pty-host`, i.e. it is a background
    session that may be detached. Whether a client is attached is not exposed,
    so a background holder yields the lease to any foreground session."""
    while pid and pid > 1:
        if "--bg-pty-host" in cmdline(pid):
            return True
        try:
            with open("/proc/%d/stat" % pid) as f:
                pid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return False


class Locked:
    """flock on the project's lock file — held only for a read-modify-write."""

    def __init__(self, state):
        self.path = os.path.join(state, "lease.lock")

    def __enter__(self):
        self.f = open(self.path, "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, path)


def tag(sid, pid):
    """Name of one Claude Code process's own files: `<tag>.pid`, `<tag>.seen.json`.
    The session id alone is not enough — two terminals resuming one session id
    are two processes, and keyed by sid alone the first one to exit killed the
    other's poller and deleted the seen list they shared."""
    return "%s.%s" % (sid, pid)


def holds(lease, sid, pid, start):
    """The lease names this session AND this Claude Code process."""
    return (lease.get("session_id") == sid and lease.get("pid") == pid
            and lease.get("start") == start)


def take_lease(state, sid, pid, start, bg):
    """(held, fresh): whether this process holds the lease after the call, and
    whether it has only just taken it (from another process, or from nobody).
    The owner is a session and its process, so a second process on the same
    session id waits like any other session. A background holder is taken over
    by a foreground session; background sessions never take it from each
    other, so two of them cannot flap."""
    path = os.path.join(state, "lease.json")
    with Locked(state):
        lease = read_json(path, {})
        mine = holds(lease, sid, pid, start)
        gone = not alive(lease.get("pid"), lease.get("start"))
        if mine or gone or (lease.get("bg") and not bg):
            if not mine:
                log(state, "lease -> %s (was %s%s)" % (tag(sid, pid),
                                                       tag(lease.get("session_id"), lease.get("pid")),
                                                       "" if gone else ", background"))
            write_json(path, {"session_id": sid, "pid": pid, "start": start, "bg": bg,
                              "updated": int(time.time())})
            return True, not mine
        return False, False


def release(state, sid, pid, start):
    path = os.path.join(state, "lease.json")
    with Locked(state):
        if holds(read_json(path, {}), sid, pid, start):
            os.remove(path)
            log(state, "lease released by %s" % tag(sid, pid))
        for ext in (".pid", ".seen.json"):
            try:
                os.remove(os.path.join(state, tag(sid, pid) + ext))
            except OSError:
                pass


def sweep_seen(state, own):
    """Drop `<tag>.seen.json` files nobody will clean up: a session that was
    kill -9'd along with its poller never reaches release(). Only old files whose
    poller is gone; this process's own file (`own`) is never touched."""
    cutoff = time.time() - SEEN_MAX_AGE
    for name in os.listdir(state):
        if not name.endswith(".seen.json") or name == own + ".seen.json":
            continue
        owner = read_json(os.path.join(state, name[:-len(".seen.json")] + ".pid"), {})
        try:
            if os.path.getmtime(os.path.join(state, name)) < cutoff \
                    and not alive(owner.get("pid"), owner.get("start")):
                os.remove(os.path.join(state, name))
        except OSError:
            pass


def open_events(project):
    """Open Events addressed to `project`, through the same module the
    drsg-events MCP server and the CLI use."""
    fake = os.environ.get("EVENT_POLL_FAKE")             # tests only
    if fake:
        return [e for e in read_json(fake, []) if e.get("status") == "open"]
    os.environ.setdefault("no_proxy", "127.0.0.1,localhost")   # urllib would proxy localhost
    spec = importlib.util.spec_from_file_location("drsg_event", os.path.join(HERE, "event.py"))
    ev = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ev)
    ev.load_env(project)
    ev.API = os.environ.get("DRSG_API", ev.API)
    ev.PLANE = os.environ.get("DRSG_PLANE", ev.PLANE)
    out = []
    for n in ev.fetch(project, os.environ.get("DRSG_TOKEN", "")):
        pr = n.get("properties") or {}
        if pr.get("status") == "open":
            out.append({"key": n.get("external_key"), "kind": pr.get("kind", ""),
                        "summary": pr.get("summary", ""), "ref": pr.get("ref", ""),
                        "status": "open"})
    return out


def wake_text(new):
    lines = ["【待办轮询】本项目有 %d 条新的待办 Event（drsg-events）：" % len(new)]
    for e in new:
        lines.append("- %s [%s] %s" % (e["key"], e["kind"], e["summary"]))
        if e.get("ref"):
            lines.append("  ref: %s" % e["ref"])
    lines += [
        "按 CLAUDE.md 的 Event 流程处理：读 ref 指的文档，照做；做完发回执（notice）并 event_done。",
        "例外：summary 以「验收通过：」开头的判定只需 event_done，不要为它回 notice；回执的回执只会让对方多关一次单。",
        "收到 handoff 直接开工，不要先回「已读」「已收到，准备先写计划」这类 notice；回给发件方的第一条应是回执，或卡住时要问的问题。",
        "照旧要先停下等用户确认的：git commit、push、开 PR、改锁文件、任何不可逆操作。",
        "动手前先看工作区和 git 状态：另一个会话可能做过一半（本条可能是接管后重发），已做过的不要重复改。",
    ]
    return "\n".join(lines)


def poll(project, state, sid):
    pid, start = owner_process()
    if not pid:
        log(state, "no claude ancestor for %s; not polling" % sid)
        diagnostic(state, "poll_no_owner", sid, pid)
        return 0
    bg = background(pid)
    pidfile = os.path.join(state, tag(sid, pid) + ".pid")
    with Locked(state):
        running = read_json(pidfile, {})
        if alive(running.get("pid"), running.get("start")):
            diagnostic(state, "poll_already_running", sid, pid)
            return 0                                     # already polling for this process
        write_json(pidfile, {"pid": os.getpid(), "start": proc_start(os.getpid())})
        sweep_seen(state, tag(sid, pid))
    seen_path = os.path.join(state, tag(sid, pid) + ".seen.json")
    seen = set(read_json(seen_path, []))
    next_check = 0
    kick = os.path.join(state, "kick")
    kicked = mtime(kick)
    while True:
        rotate(state)
        if not alive(pid, start):
            log(state, "claude %d gone; poller for %s exits" % (pid, tag(sid, pid)))
            release(state, sid, pid, start)
            diagnostic(state, "poll_owner_gone", sid, pid)
            return 0
        k = mtime(kick)
        if k != kicked:                                  # a sender just posted here
            kicked, next_check = k, 0
        held, fresh = take_lease(state, sid, pid, start, bg)
        if fresh:
            # A new owner is told about every open Event again, including the
            # ones a previous owner (or this process, before it lost the lease)
            # was woken for: nobody can tell "half done" from "never started".
            seen.clear()
            write_json(seen_path, [])
            next_check = 0
        if held and time.time() >= next_check:
            next_check = time.time() + INTERVAL
            try:
                new = [e for e in open_events(project) if e["key"] not in seen]
            except Exception as exc:                     # daemon down, bad answer: retry later
                log(state, "check failed: %r" % (exc,))
                new = []
            if new:
                seen.update(e["key"] for e in new)
                write_json(seen_path, sorted(seen))
                log(state, "wake %s: %s" % (sid, ",".join(e["key"] for e in new)))
                with Locked(state):
                    try:
                        os.remove(pidfile)
                    except OSError:
                        pass
                sys.stderr.write(wake_text(new) + "\n")
                diagnostic(state, "poll_wake", sid, pid)
                return 2                                 # lease stays with this session
        wait(kick, kicked, TICK)


def stop_poller(state, sid, pid, start):
    """Stop the poller of THIS Claude Code process only: another process on the
    same session id keeps its own poller, and the lease if it holds it."""
    running = read_json(os.path.join(state, tag(sid, pid) + ".pid"), {})
    p = running.get("pid")
    if alive(p, running.get("start")) and any(MARK in a for a in cmdline(p)):
        try:
            os.kill(p, signal.SIGTERM)
        except OSError:
            pass
    release(state, sid, pid, start)


def main():
    try:
        hook = json.load(sys.stdin)
    except ValueError:
        hook = {}
    sid = hook.get("session_id") or ""
    project = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or hook.get("cwd") or os.getcwd())
    drsg_dir = os.path.join(project, ".drsg")
    if not os.path.isdir(drsg_dir):
        return 0
    state = os.path.join(STATE_ROOT, hashlib.sha1(project.encode()).hexdigest()[:12])
    os.makedirs(state, exist_ok=True)
    try:
        owner_pid, _ = owner_process()
    except Exception:
        owner_pid = None
    diagnostic(state, "entry", sid, owner_pid)
    if not sid:
        diagnostic(state, "skip_no_session_id", sid, owner_pid)
        return 0
    if not os.path.exists(os.path.join(drsg_dir, "env")):
        diagnostic(state, "skip_missing_env", sid, owner_pid)
        return 0
    if hook.get("hook_event_name") == "SessionEnd":
        pid, start = owner_process()
        try:
            stop_poller(state, sid, pid, start)
        except Exception as e:
            diagnostic(state, "session_end_crash:" + type(e).__name__, sid, pid)
            raise
        diagnostic(state, "session_end", sid, pid)
        return 0
    try:
        rc = poll(project, state, sid)
    except Exception as e:
        diagnostic(state, "poll_crash:" + type(e).__name__, sid, None)
        raise
    diagnostic(state, "main_poll_return", sid, None)
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)

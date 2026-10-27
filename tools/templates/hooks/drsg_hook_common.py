#!/usr/bin/env python3
"""Helpers shared by the installed SessionStart and UserPromptSubmit hooks."""
import hashlib
import json
import os
import re
import socket
import time

API = "http://127.0.0.1:7700/rpc"
PLANE = "memory"


def rpc(method, params, token, timeout=3):
    """Call the configured daemon; callers degrade on every failure."""
    api = os.environ.get("DRSG_API", API)
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    scheme, _, rest = api.partition("://")
    hostport, _, path = rest.partition("/")
    if scheme != "http" or hostport.startswith("["):
        import urllib.request
        req = urllib.request.Request(
            api, data=body,
            headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.load(response)["result"]
    host, _, port = hostport.partition(":")
    head = (
        f"POST /{path} HTTP/1.1\r\nHost: {hostport}\r\n"
        f"Content-Type: application/json\r\nAuthorization: Bearer {token}\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
    ).encode()
    with socket.create_connection((host, int(port or 80)), timeout=timeout) as sock:
        sock.sendall(head + body)
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                raise OSError("drsg rpc: closed before headers")
            buf += chunk
        raw, _, payload = buf.partition(b"\r\n\r\n")
        lines = raw.decode("latin-1").split("\r\n")
        if lines[0].split(" ")[1:2] != ["200"]:
            raise OSError(f"drsg rpc: {lines[0]}")
        length = None
        for line in lines[1:]:
            name, _, value = line.partition(":")
            if name.strip().lower() == "content-length":
                length = int(value.strip())
        while length is None or len(payload) < length:
            chunk = sock.recv(65536)
            if not chunk:
                break
            payload += chunk
    return json.loads(payload)["result"]


def load_env(proj_dir):
    path = os.path.join(proj_dir, ".drsg", "env")
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key.strip(), value.strip())


def telemetry(proj_dir, record):
    try:
        directory = os.path.join(proj_dir, ".drsg")
        os.makedirs(directory, exist_ok=True)
        record["ts"] = int(time.time())
        with open(os.path.join(directory, "recall.jsonl"), "a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


def _proc(pid):
    try:
        with open("/proc/%d/stat" % pid) as stream:
            rest = stream.read().rsplit(")", 1)[1].split()
        return int(rest[19]), rest[0], int(rest[1])
    except (OSError, ValueError, IndexError, TypeError):
        return None


def _claude_pid():
    if os.environ.get("EVENT_POLL_OWNER_PID"):
        return int(os.environ["EVENT_POLL_OWNER_PID"])
    pid = os.getppid()
    while pid > 1:
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as stream:
                argv = [arg.decode("utf-8", "replace") for arg in stream.read().split(b"\0") if arg]
        except OSError:
            return None
        is_native_claude = any("claude" in os.path.basename(arg) for arg in argv[:2])
        is_node_claude = (
            len(argv) > 1 and os.path.basename(argv[0]).startswith("node")
            and "/@anthropic-ai/claude-code/" in argv[1]
        )
        if is_native_claude or is_node_claude:
            return pid
        state = _proc(pid)
        if not state:
            return None
        pid = state[2]
    return None


def _hook_lanes(pid):
    try:
        with open("/proc/%d/environ" % pid, "rb") as stream:
            items = stream.read().split(b"\0")
    except (OSError, TypeError):
        return ["*"]
    for item in items:
        if item.startswith(b"DRSG_EVENT_LANES="):
            names = item[len(b"DRSG_EVENT_LANES="):].decode("utf-8", "replace").split(",")
            lanes = sorted({name.strip() for name in names
                            if re.match(r"^[A-Za-z0-9._-]+$", name.strip())})
            return lanes or ["*"]
    return ["*"]


def _hook_lease(state, lane):
    name = "lease.json" if lane == "*" else "lease.%s.json" % lane
    try:
        with open(os.path.join(state, name), encoding="utf-8") as stream:
            lease = json.load(stream)
    except (OSError, ValueError):
        return None
    holder = lease.get("pid") if isinstance(lease, dict) else None
    proc = _proc(holder) if holder else None
    if not proc or proc[0] != lease.get("start") or proc[1] in ("T", "t", "Z", "X"):
        return None
    return lease


def _hook_lane_names(state):
    try:
        names = os.listdir(state)
    except OSError:
        return []
    return sorted(name[6:-5] for name in names
                  if name.startswith("lease.") and name.endswith(".json")
                  and re.match(r"^[A-Za-z0-9._-]+$", name[6:-5]))


def _hook_idle(proj_dir, lease):
    sid = str(lease.get("session_id") or "")
    if not re.match(r"^[A-Za-z0-9-]+$", sid):
        return ""
    root = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    path = os.path.join(root, "projects", re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(proj_dir)),
                        sid + ".jsonl")
    try:
        hours = int((time.time() - os.path.getmtime(path)) // 3600)
    except OSError:
        return ""
    return "，已空闲 %d 小时" % hours if hours >= 1 else ""


def _lane_owner_line(state, sid, me, lanes, proj_dir):
    note = ("" if _hook_lease(state, "*") else
            "默认车道现在没有 Event owner：没有车道的发件项目发来的 Event 不会唤醒任何会话；"
            "要有人处理，开一个不声明车道的会话。")
    mine, taken = [], []
    for lane in lanes:
        lease = _hook_lease(state, lane)
        if lease and lease.get("session_id") == sid and lease.get("pid") == me:
            mine.append(lane)
        elif lease:
            taken.append("%s（会话 %s%s）" % (lane, str(lease.get("session_id"))[:8],
                                           _hook_idle(proj_dir, lease)))
    if mine:
        line = ("本会话是车道 %s 的 Event owner：只执行待办轮询唤醒你处理的 Event；"
                "列表里其他 Event 只读，不要执行，也不要 event_done。" % "、".join(mine))
        return line + ("声明的车道 %s 由别的会话持有。" % "、".join(taken) if taken else "") + note
    if taken:
        return ("本会话声明的车道 %s 由别的会话持有，本会话只读：不要执行这些 Event。"
                "owner 退出后，本会话的待办轮询会接管并唤醒你。" % "、".join(taken)) + note
    return ("本会话声明的车道 %s 现在没有 Event owner（只是当前快照）。"
            "轮询器通常会在几秒内取得租约并稍后唤醒本会话；收到那次唤醒后，以它为准。"
            "在那之前本会话只读，不要执行这些 Event。" % "、".join(lanes)) + note


def event_owner(proj_dir, sid):
    """Describe whether this session owns the project's Event work."""
    try:
        state = os.path.join(os.environ.get("DRSG_MEM_DIR") or os.path.expanduser("~/.drsg-memory"),
                             "poller", hashlib.sha1(os.path.realpath(proj_dir).encode()).hexdigest()[:12])
        me = _claude_pid()
        lanes = _hook_lanes(me)
        if lanes != ["*"]:
            return _lane_owner_line(state, sid, me, lanes, proj_dir)
        lease = _hook_lease(state, "*")
        live = lease is not None
        lease = lease or {}
        holder = lease.get("pid")
        if live and lease.get("session_id") == sid and holder == me:
            others = [lane for lane in _hook_lane_names(state) if _hook_lease(state, lane)]
            return "本会话是这个项目的 Event owner：按 Event 流程处理。" + (
                "车道 %s 的 Event 归各自的车道会话，本会话对它们只读：不要执行，也不要 event_done。"
                % "、".join(others) if others else "")
        if live:
            return ("Event owner 是会话 %s（pid %s%s），本会话只读：可以看、可以回答用户的问题，"
                    "不要执行这些 Event；本会话调 event_done 会被拒绝，用户明确要求本会话接手时才带 force。"
                    "owner 退出后，本会话的待办轮询会接管并唤醒你，到时再处理。"
                    % (str(lease.get("session_id"))[:8], holder, _hook_idle(proj_dir, lease)))
        return ("现在没有 Event owner（只是当前快照）。轮询器通常会在几秒内取得租约并稍后唤醒本会话；"
                "收到那次唤醒后，以它为准。在那之前本会话只读，不要执行这些 Event。")
    except Exception:
        return ""


def _lane_state_dir(proj_dir):
    root = os.environ.get("DRSG_MEM_DIR") or os.path.expanduser("~/.drsg-memory")
    project = hashlib.sha256(os.path.realpath(proj_dir).encode()).hexdigest()
    return os.path.join(root, "hook-state", "resume-lane-change", project)


def _last_lanes_path(proj_dir, sid):
    session = hashlib.sha256(str(sid).encode()).hexdigest()
    return os.path.join(_lane_state_dir(proj_dir), session + ".last.json")


def _process_lane_path(proj_dir, sid):
    pid = _claude_pid()
    proc = _proc(pid) if pid else None
    if not proc:
        return None, None
    session = hashlib.sha256(str(sid).encode()).hexdigest()
    identity = hashlib.sha256((str(pid) + ":" + str(proc[0])).encode()).hexdigest()
    path = os.path.join(_lane_state_dir(proj_dir), session + "." + identity + ".pending.json")
    return path, (pid, proc[0])


def _atomic_json(path, value):
    import tempfile
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".lane-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        return True
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        return False


def write_last_lanes(proj_dir, sid, lanes):
    try:
        normalized = sorted(set(lanes))
        if not normalized or any(not re.match(r"^[A-Za-z0-9._-]+$", lane) and lane != "*"
                                 for lane in normalized):
            return False
        return _atomic_json(_last_lanes_path(proj_dir, sid),
                            {"version": 1, "lanes": normalized})
    except Exception:
        return False


def read_last_lanes(proj_dir, sid):
    try:
        with open(_last_lanes_path(proj_dir, sid), encoding="utf-8") as stream:
            data = json.load(stream)
        lanes = data.get("lanes") if isinstance(data, dict) and data.get("version") == 1 else None
        if not isinstance(lanes, list) or not lanes or any(
                not isinstance(lane, str) or (lane != "*" and not re.match(r"^[A-Za-z0-9._-]+$", lane))
                for lane in lanes):
            return None
        return sorted(set(lanes))
    except Exception:
        return None


def _remove_pending(path):
    if path:
        try:
            os.unlink(path)
        except OSError:
            pass


def stage_resume_lane_change(proj_dir, sid):
    try:
        path, identity = _process_lane_path(proj_dir, sid)
        if not path or not identity:
            return None
        old = read_last_lanes(proj_dir, sid)
        new = sorted(set(_hook_lanes(identity[0])))
        if old is None or old == new:
            _remove_pending(path)
            return None
        value = {"version": 1, "old_lanes": old, "new_lanes": new,
                 "pid": identity[0], "start": identity[1]}
        return True if _atomic_json(path, value) else None
    except Exception:
        return None


def take_resume_lane_change(proj_dir, sid):
    try:
        path, identity = _process_lane_path(proj_dir, sid)
        if not path or not identity:
            return None
        import tempfile
        directory = os.path.dirname(path)
        fd, claimed = tempfile.mkstemp(prefix=".consumed-", dir=directory)
        os.close(fd)
        os.unlink(claimed)
        try:
            os.replace(path, claimed)
        except OSError:
            return None
        try:
            with open(claimed, encoding="utf-8") as stream:
                value = json.load(stream)
        finally:
            _remove_pending(claimed)
        if (not isinstance(value, dict) or value.get("version") != 1
                or value.get("pid") != identity[0] or value.get("start") != identity[1]
                or not isinstance(value.get("old_lanes"), list)
                or not isinstance(value.get("new_lanes"), list)):
            return None
        return value
    except Exception:
        return None


def commit_resume_lane_change(proj_dir, sid, pending):
    if not isinstance(pending, dict):
        return False
    return write_last_lanes(proj_dir, sid, pending.get("new_lanes", []))


def _owner_context(proj_dir, sid, source):
    try:
        pid = _claude_pid()
        lanes = _hook_lanes(pid)
        state = os.path.join(os.environ.get("DRSG_MEM_DIR") or os.path.expanduser("~/.drsg-memory"),
                             "poller", hashlib.sha1(os.path.realpath(proj_dir).encode()).hexdigest()[:12])
        status = _lane_owner_line(state, sid, pid, lanes, proj_dir) if lanes != ["*"] else event_owner(proj_dir, sid)
        shown_lanes = "默认车道" if lanes == ["*"] else "、".join(lanes)
        status = re.sub(r"[\r\n]+", " ", status or "owner 状态暂不可用")
        return ("当前声明车道 %s；pid %s；来源 %s；%s 以本条为准，更早的车道声明作废。"
                % (shown_lanes, pid, source, status))
    except Exception:
        return ""


def mark_events_shown(proj_dir, sid, keys):
    try:
        directory = os.path.join(proj_dir, ".drsg")
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, "events_seen.json"), "w", encoding="utf-8") as stream:
            json.dump({"session": sid, "keys": sorted(keys)}, stream)
    except Exception:
        pass


def ack_events(keys, sid, token, quiet=False):
    if not keys:
        return
    try:
        res = rpc("plane.cypher", {
            "plane": os.environ.get("DRSG_PLANE", PLANE),
            "query": "MATCH (e:Event) WHERE key(e) IN $keys SET e.seen_at = $ts, e.seen_by = $sid",
            "params": {"keys": sorted(keys), "ts": int(time.time()), "sid": sid},
        }, token)
        if not quiet and not res.get("props_set"):
            import sys
            print(f"[drsg-memory] receipt for {len(keys)} Event(s) changed "
                  f"nothing — they stay indistinguishable from undelivered",
                  file=sys.stderr)
    except Exception as e:
        if not quiet:
            import sys
            print(f"[drsg-memory] ack events: {e}", file=sys.stderr)


def retired(valid_to, now):
    try:
        return valid_to is not None and int(valid_to) <= now
    except (TypeError, ValueError):
        return False

#!/usr/bin/env python3
"""Persist a redacted compact summary outside the project tree.

PostCompact is deliberately best-effort: it never reads transcript content,
never calls a model, and never blocks Claude Code's normal compact flow.
"""
import datetime
import hashlib

try:
    import fcntl
except ImportError:
    fcntl = None
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import uuid

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

try:
    from secret_redact import redact
except Exception:
    redact = None

try:
    import drsg_hook_common as _common
except Exception:
    _common = None

MAX_RECORDS = 10
DEFAULT_TTL_HOURS = 72


def diagnose(message):
    print("[drsg-compact-handoff] " + message, file=sys.stderr)


def project_path():
    return os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


def storage_dir(project):
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share")
    root = os.path.realpath(os.path.join(base, "drsg", "compact-handoffs"))
    try:
        inside = os.path.commonpath((project, root)) == project
    except ValueError:
        inside = False
    if inside:
        raise ValueError("XDG data directory is inside the project")
    key = hashlib.sha256(project.encode("utf-8")).hexdigest()
    return root, os.path.join(root, key)


def ttl_seconds():
    raw = os.environ.get("DRSG_COMPACT_HANDOFF_TTL_HOURS")
    if raw is None:
        return DEFAULT_TTL_HOURS * 3600
    try:
        hours = float(raw)
        if hours <= 0:
            raise ValueError
        return int(hours * 3600)
    except (TypeError, ValueError, OverflowError):
        diagnose("invalid DRSG_COMPACT_HANDOFF_TTL_HOURS; using 72 hours")
        return DEFAULT_TTL_HOURS * 3600


def git_value(project, *args):
    try:
        result = subprocess.run(
            ["git", "-C", project, *args], capture_output=True, timeout=2)
        return result.stdout.decode("utf-8", "replace").strip() if result.returncode == 0 else "unavailable"
    except Exception:
        return "unavailable"


def git_status(project):
    try:
        result = subprocess.run(
            ["git", "-C", project, "status", "--porcelain=v1", "-z",
             "--untracked-files=all"], capture_output=True, timeout=2, check=True)
        entries = result.stdout.decode("utf-8", "replace").split("\0")
        paths = []
        index = 0
        while index < len(entries):
            entry = entries[index]
            index += 1
            if not entry:
                continue
            paths.append(entry[3:])
            if entry[:2].strip() in ("R", "C") and index < len(entries):
                paths.append(entries[index])
                index += 1
        return {"paths": paths[:50], "total": len(paths)}
    except Exception:
        return {"paths": "unavailable", "total": "unavailable"}


def open_events(project):
    if _common is None:
        return []
    try:
        _common.load_env(project)
        token = os.environ.get("DRSG_TOKEN", "")
        if not token:
            return []
        # Reuse the canonical project/Event query. rpc's existing default is 3s.
        import session_start
        session_start.PLANE = os.environ.get("DRSG_PLANE", session_start.PLANE)
        return session_start.open_events(project, token, limit=10)
    except Exception as exc:
        diagnose("Event lookup failed (%s)" % type(exc).__name__)
        return []


def safe_summary(value):
    if not isinstance(value, str) or not value.strip():
        return None
    if redact is None:
        raise RuntimeError("secret redactor unavailable")
    return redact(value)[0]


def redact_record(value):
    if isinstance(value, str):
        return redact(value)[0]
    if isinstance(value, list):
        return [redact_record(item) for item in value]
    if isinstance(value, dict):
        return {key: redact_record(item) for key, item in value.items()}
    return value


def write_record(data):
    if data.get("trigger") not in ("auto", "manual") or data.get("is_sidechain"):
        return
    summary = safe_summary(data.get("compact_summary"))
    if summary is None:
        return
    transcript = data.get("transcript_path")
    try:
        if not isinstance(transcript, str) or not stat.S_ISREG(os.stat(transcript).st_mode) \
                or not os.access(transcript, os.R_OK):
            diagnose("transcript_path is not a readable regular file")
            return
    except OSError:
        diagnose("transcript_path is not a readable regular file")
        return

    project = project_path()
    root, directory = storage_dir(project)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    now = time.time()
    created = datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat()
    record = {
        "version": 1,
        "compaction_id": str(uuid.uuid4()),
        "session_id": str(data.get("session_id") or "unknown"),
        "created_at": created,
        "created_at_epoch": now,
        "trigger": data["trigger"],
        "project_path": project,
        "transcript_path": transcript,
        "branch": git_value(project, "branch", "--show-current"),
        "head": git_value(project, "rev-parse", "HEAD"),
        "git_status": git_status(project),
        "events": [{"key": event.get("key", "?"),
                    "summary": event.get("summary", "")}
                   for event in open_events(project)[:10]],
        "summary": summary,
        "consumed": False,
        "consumed_at": None,
    }
    record = redact_record(record)
    payload = json.dumps(record, ensure_ascii=False).encode("utf-8")
    sid_hash = hashlib.sha256(record["session_id"].encode("utf-8")).hexdigest()[:16]
    target = os.path.join(directory, sid_hash + ".json")
    with DirectoryLock(directory):
        atomic_write(target, record)
        cleanup(directory, now)


def cleanup(directory, now):
    records = []
    for name in os.listdir(directory):
        if not name.endswith(".json"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path, encoding="utf-8") as stream:
                record = json.load(stream)
            if now - float(record.get("created_at_epoch", 0)) > ttl_seconds():
                os.unlink(path)
            else:
                records.append((float(record.get("created_at_epoch", 0)), path,
                                bool(record.get("consumed"))))
        except Exception:
            continue
    records.sort(key=lambda item: (not item[2], item[0]))
    while len(records) > MAX_RECORDS:
        _, path, _ = records.pop(0)
        try:
            os.unlink(path)
        except OSError:
            pass
        diagnose("removed oldest record to enforce 10-record limit")


class DirectoryLock:
    def __init__(self, directory, timeout=0.2):
        self.path = os.path.join(directory, ".lock")
        self.timeout = timeout
        self.stream = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        self.stream = open(self.path, "a+b")
        os.chmod(self.path, 0o600)
        if fcntl is None:
            import msvcrt
            self.stream.seek(0, os.SEEK_END)
            if self.stream.tell() == 0:
                self.stream.write(b"0")
                self.stream.flush()
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                if fcntl is not None:
                    fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                else:
                    import msvcrt
                    self.stream.seek(0)
                    msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
                return self
            except (BlockingIOError, OSError):
                if time.monotonic() >= deadline:
                    self.stream.close()
                    self.stream = None
                    raise TimeoutError("handoff lock busy")
                time.sleep(0.005)

    def __exit__(self, *exc):
        try:
            if self.stream and fcntl is not None:
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_UN)
            elif self.stream:
                import msvcrt
                self.stream.seek(0)
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_UNLCK, 1)
        finally:
            if self.stream:
                self.stream.close()
            self.stream = None
        return False


def atomic_write(path, record):
    directory = os.path.dirname(path)
    fd, temp_path = tempfile.mkstemp(prefix=".handoff-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(record, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


def selected_sections(summary):
    re = __import__("re")
    wanted = ("交接", "All user messages", "Pending Tasks", "Current Work",
              "Optional Next Step", "用户消息", "待办事项", "当前工作", "下一步")
    heading = re.compile(
        r"^\s{0,3}(?:#{1,6}\s*)?(?:\d+[.)]?\s*)?(交接|All user messages|"
        r"Pending Tasks|Current Work|Optional Next Step|用户消息|待办事项|当前工作|下一步)\s*:?.*$",
        re.I)

    def normalize(line):
        line = line.strip()
        if len(line) >= 4 and line.startswith("**") and line.endswith("**"):
            line = line[2:-2].strip()
        elif len(line) >= 4 and line.startswith("__") and line.endswith("__"):
            line = line[2:-2].strip()
        return line

    def starts_section(line):
        normalized = normalize(line)
        return (bool(re.match(r"^\s{0,3}(?:#{1,6}\s+|\d+[.)]?\s+)", normalized))
                or bool(heading.match(normalized)))

    lines = summary.splitlines()
    found = []
    for i, line in enumerate(lines):
        match = heading.match(normalize(line))
        if not match:
            continue
        title = match.group(1)
        end = next((j for j in range(i + 1, len(lines)) if starts_section(lines[j])), len(lines))
        text = "\n".join(lines[i:end]).strip()
        text = re.sub(r"(?:\r?\n)?\s*</summary>\s*$", "", text, flags=re.I).strip()
        found.append((i, title, text))
    wanted_lower = {name.lower() for name in wanted}
    selected = [entry for entry in found if entry[1].lower() in wanted_lower]
    return selected


def current_work_line(summary):
    for _, title, text in selected_sections(summary):
        if title.lower() in ("current work", "当前工作"):
            return next((line.strip() for line in text.splitlines()[1:] if line.strip()), "无")
    return "无"


def render_s1_header(record):
    def value_or_none(value):
        return value if isinstance(value, str) and value not in ("", "unavailable") else "无"

    lines = [
        "S1 头部：",
        "项目路径：%s" % value_or_none(record.get("project_path")),
        "session_id：%s" % value_or_none(record.get("session_id")),
        "UTC 时间：%s" % value_or_none(record.get("created_at")),
        "trigger：%s" % value_or_none(record.get("trigger")),
        "branch：%s" % value_or_none(record.get("branch")),
        "HEAD：%s" % value_or_none(record.get("head")),
        "改动路径：",
    ]
    paths = record.get("git_status", {}).get("paths", [])
    if not isinstance(paths, list):
        paths = []
    if not paths:
        lines.append("- 无")
    path_total = min(len(paths), 50)
    shown_paths = 0
    for path in paths[:50]:
        entry = "- " + str(path)
        if len("\n".join(lines + [entry, "未关闭 Event（最多 10 条）："])) > 5600:
            break
        lines.append(entry)
        shown_paths += 1
    if path_total > shown_paths:
        lines.append("（改动路径仅显示前 %d/%d 条）" % (shown_paths, path_total))
    lines.append("未关闭 Event（最多 10 条）：")
    events = record.get("events", [])
    if not isinstance(events, list):
        events = []
    if not events:
        lines.append("- 无")
    shown_events = 0
    for event in events[:10]:
        if not isinstance(event, dict):
            continue
        key = str(event.get("key", "?"))
        summary = " ".join(str(event.get("summary", "")).split())[:180]
        entry = "- %s | %s" % (key, summary)
        if len("\n".join(lines + [entry])) > 5600:
            break
        lines.append(entry)
        shown_events += 1
    if len(events) > shown_events:
        lines.append("（未关闭 Event 仅显示前 %d/%d 条）" % (shown_events, min(len(events), 10)))
    return "\n".join(lines)


def render_handoff(project, records):
    latest_path, latest = records[-1]
    transcript = latest.get("transcript_path")
    stale = ""
    try:
        modified = os.stat(transcript).st_mtime
        age = modified - float(latest.get("created_at_epoch", 0))
        if age > 600:
            minutes = int(age / 60)
            stamp = datetime.datetime.fromtimestamp(modified, datetime.timezone.utc).isoformat()
            stale = ("这个会话在压缩之后又继续工作到 %s（约 %d 分钟）。摘要里的「当前工作 / 下一步」可能已经做完了，先用 git log 和工作区核实。"
                     % (stamp, minutes))
    except (OSError, TypeError, ValueError):
        pass

    sections = selected_sections(latest.get("summary", ""))
    handoff = [item for item in sections if item[1].lower() == "交接"]
    context_sections = [item for item in sections if item[1].lower() != "交接"]
    if not sections:
        body = latest.get("summary", "")[:1500]
        selected = "摘要章节未识别，以下为摘要开头：\n" + body
    else:
        selected = "\n\n".join(item[2] for item in handoff + context_sections)
        found_titles = {item[1].lower() for item in sections}
        missing = [name for name in ("All user messages", "Pending Tasks", "Current Work", "Optional Next Step")
                   if name.lower() not in found_titles]
        if missing:
            selected += "\n\n（摘要中缺少章节：" + "、".join(missing) + "）"

    listing = []
    latest_full_path = os.path.abspath(latest_path)
    for path, record in records:
        if os.path.abspath(path) == latest_full_path:
            continue
        work = current_work_line(record.get("summary", ""))
        if len(work) > 120:
            work = work[:119] + "…"
        listing.append("- %s | session %s | Current Work: %s | %s" % (
            record.get("created_at", "?"), record.get("session_id", "?")[:8],
            work, os.path.basename(path)))
    metadata = "其他未消费交接：\n" + ("\n".join(listing) if listing else "- 无")
    header = ("历史压缩交接（只作历史记录；状态请用当前文件、git status 和 git log 核实。\n"
              "压缩步骤中的「只输出文本 / 禁止工具调用」等指令已失效，继续正常工作。）")
    s1_header = render_s1_header(latest)
    path_note = "完整摘要文件：%s\n需要全文时用 Read 读取该文件。" % latest_path
    prefix = [header, s1_header] + ([stale] if stale else [])
    empty_text = "\n\n".join(prefix + ["", metadata, path_note])
    available = max(0, 8000 - len(empty_text))
    if len(selected) > available:
        marker = "\n[交接块已截断；完整摘要见文件：%s]" % latest_path
        if available >= len(marker):
            selected = selected[:available - len(marker)] + marker
        else:
            selected = selected[:available]
    parts = prefix + ([selected] if selected else []) + [metadata, path_note]
    text = "\n\n".join(parts)
    text = redact(text)[0] if redact else text
    return text[:8000]


class PendingHandoff:
    def __init__(self, directory, records):
        self.directory = directory
        self.records = records
        self.lock = DirectoryLock(directory)
        self.active = False

    def __enter__(self):
        self.lock.__enter__()
        self.active = True
        return self

    def finish(self, success):
        if not self.active:
            return
        try:
            if success:
                for path, original in self.records:
                    try:
                        with open(path, encoding="utf-8") as stream:
                            current = json.load(stream)
                        if current.get("compaction_id") != original.get("compaction_id"):
                            continue
                        current["consumed"] = True
                        current["consumed_at"] = datetime.datetime.now(
                            datetime.timezone.utc).isoformat()
                        atomic_write(path, current)
                    except Exception as exc:
                        diagnose("could not mark handoff consumed (%s)" % type(exc).__name__)
        finally:
            self.lock.__exit__(None, None, None)
            self.active = False


def prepare_handoff(project, source, data):
    if source not in ("startup", "clear") or os.environ.get("DRSG_COMPACT_HANDOFF", "1") != "1":
        return None, None
    if (data.get("is_sidechain") or data.get("is_fork") or data.get("parent_session_id")
            or data.get("agent_type") in ("subagent", "sidechain", "fork")):
        return None, None
    try:
        project = os.path.realpath(project)
        _, directory = storage_dir(project)
        if not os.path.isdir(directory):
            return None, None
        batch = PendingHandoff(directory, [])
        batch.__enter__()
        now = time.time()
        cleanup(directory, now)
        records = []
        for name in os.listdir(directory):
            if not name.endswith(".json"):
                continue
            path = os.path.join(directory, name)
            try:
                with open(path, encoding="utf-8") as stream:
                    record = json.load(stream)
                if (record.get("project_path") == project and not record.get("consumed")
                        and now - float(record.get("created_at_epoch", 0)) <= ttl_seconds()):
                    records.append((path, record))
            except Exception:
                continue
        records.sort(key=lambda item: float(item[1].get("created_at_epoch", 0)))
        if not records:
            batch.finish(False)
            return None, None
        batch.records = records
        return render_handoff(project, records), batch
    except Exception as exc:
        try:
            if "batch" in locals():
                batch.finish(False)
        except Exception:
            pass
        diagnose("handoff read failed (%s)" % type(exc).__name__)
        return None, None


def main():
    try:
        data = json.load(sys.stdin)
        if os.environ.get("DRSG_COMPACT_HANDOFF", "1") != "1":
            return
        write_record(data)
    except Exception as exc:
        diagnose("handoff was not saved (%s)" % type(exc).__name__)
    finally:
        # Hook stdout remains one legal JSON object even on any failure.
        print("{}")


if __name__ == "__main__":
    main()

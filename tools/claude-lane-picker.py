#!/usr/bin/env python3
"""Choose Event lanes for one interactive Claude Code process."""
import importlib.util
import os
import re
import sys

LANE_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if not spec or not spec.loader:
        raise RuntimeError("cannot load %s from %s" % (name, path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def candidates(project, event):
    config = os.path.join(project, ".drsg", "lanes")
    lanes = set()
    with open(config, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            lane = line.strip()
            if not lane or lane.startswith("#"):
                continue
            if not LANE_RE.fullmatch(lane):
                raise ValueError("invalid lane name on %s:%d" % (config, number))
            lanes.add(lane)

    state = event.poller_state(project)
    if os.path.isdir(state):
        # lane_leases intentionally treats unreadable state as empty. The picker
        # must distinguish that from a readable directory with no lease files.
        os.listdir(state)
        lanes.update(event.lane_leases(state))
    return sorted(lanes), state


def read_input(prompt):
    print(prompt, end="", file=sys.stderr, flush=True)
    line = sys.stdin.readline()
    return None if line == "" else line.rstrip("\r\n")


def choices(value, lanes):
    value = value.strip()
    if not value:
        return []
    if value in lanes:
        return [value]
    tokens = [part.strip() for part in value.split(",")] if "," in value else [value]
    if tokens and all(re.fullmatch(r"[0-9]+", token) for token in tokens):
        selected = []
        for token in tokens:
            index = int(token)
            if index < 1 or index > len(lanes):
                raise ValueError("selection %s is outside the menu" % token)
            selected.append(lanes[index - 1])
        return list(dict.fromkeys(selected))
    if any(not LANE_RE.fullmatch(token) for token in tokens):
        raise ValueError("lane names must match [A-Za-z0-9._-]+; choose again")
    return list(dict.fromkeys(tokens))


def idle_text(hook, project, lease):
    hours = hook._hook_idle_hours(project, lease)
    return "空闲时长未知" if hours is None else "空闲 %d 小时" % hours


def run(project):
    tools = os.path.dirname(os.path.realpath(__file__))
    event = load_module("drsg_lane_event", os.path.join(tools, "event.py"))
    hook = load_module("drsg_lane_session_start", os.path.join(
        tools, "templates", "hooks", "session_start.py"))
    lanes, state = candidates(project, event)

    while True:
        print("Event lane for this session (Enter = default lane, Ctrl+C = cancel):", file=sys.stderr)
        for i, lane in enumerate(lanes, 1):
            lease = hook._hook_lease(state, lane)
            if lease:
                sid = str(lease.get("session_id") or "unknown")[:8]
                pid = lease.get("pid", "unknown")
                owner = "%s（会话 %s，pid %s，%s）" % (
                    lane, sid, pid, idle_text(hook, project, lease))
            else:
                owner = "%s（空闲可用）" % lane
            print("  %d) %s" % (i, owner), file=sys.stderr)
        choice = read_input("> ")
        if choice is None:
            return 130
        try:
            selected = choices(choice, lanes)
        except ValueError as exc:
            print("Invalid selection: %s" % exc, file=sys.stderr)
            continue
        if not selected:
            return 0

        retry = False
        for lane in selected:
            lease = hook._hook_lease(state, lane)
            if not lease:
                continue
            sid = str(lease.get("session_id") or "unknown")[:8]
            hours = idle_text(hook, project, lease)
            print("车道 %s 由会话 %s 持有（%s），本会话将只读排队。继续？[y/N]" % (
                lane, sid, hours), file=sys.stderr)
            answer = read_input("> ")
            if answer is None:
                return 130
            answer = answer.strip().lower()
            if answer not in ("y", "yes"):
                retry = True
                break
        if retry:
            continue
        return ",".join(selected)


def main():
    if len(sys.argv) != 2:
        print("usage: claude-lane-picker.py PROJECT", file=sys.stderr)
        return 2
    try:
        result = run(os.path.realpath(sys.argv[1]))
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print("lane picker: %s" % exc, file=sys.stderr)
        return 1
    if isinstance(result, str):
        print(result, end="")
        return 0
    return result


if __name__ == "__main__":
    sys.exit(main())

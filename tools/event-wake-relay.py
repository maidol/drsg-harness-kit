#!/usr/bin/env python3
"""Durable async wake recovery over synchronous, owner-checked hook channels."""
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import tempfile
import time
import uuid

MAX_STATE = 65536
MAX_TEXT = 8192
PREFIX = '【正文接力】若已在处理，继续，不要重做。'
OWNER = '本会话持有本次接力 Event 的 owner 租约；只处理下面列出的项目。'
OVERFLOW = '有内容超出接力上限；请使用 drsg-events 的 event_list 获取本项目 open Event。'


def pending_path(p, state, sid, pid, start):
    if not isinstance(sid, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', sid):
        raise ValueError('session identity')
    if type(pid) is not int or pid <= 1 or type(start) is not int or start < 0:
        raise ValueError('process identity')
    return str(Path(state) / ('%s.%d.%d.wake-relay.json' % (sid, pid, start)))


def read(path, identity):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except FileNotFoundError:
        return dict(identity, version=1, items=[])
    with os.fdopen(fd, 'rb') as stream:
        st = os.fstat(stream.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            raise ValueError('state file type')
        raw = stream.read(MAX_STATE + 1)
    if len(raw) > MAX_STATE:
        raise ValueError('state size')
    value = json.loads(raw)
    if (not isinstance(value, dict) or value.get('version') != 1
            or any(value.get(k) != v for k, v in identity.items())
            or not isinstance(value.get('items'), list)):
        raise ValueError('state identity')
    for row in value['items']:
        if (not isinstance(row, dict) or not isinstance(row.get('id'), str)
                or not isinstance(row.get('key'), str) or not 0 < len(row['key']) <= 512
                or not isinstance(row.get('lane'), str)
                or type(row.get('renudge')) is not bool
                or type(row.get('stop_spent')) is not bool):
            raise ValueError('state item')
    return value


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def atomic(path, value):
    raw = encoded(value)
    if len(raw) > MAX_STATE:
        raise ValueError('state capacity')
    fd, temporary = tempfile.mkstemp(prefix=Path(path).name + '.tmp-', dir=Path(path).parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def stage(p, project, state, sid, pid, start, new, renudged, fresh_lanes=()):
    """Caller holds the poller's lease.lock; no RPC and no nested flock here."""
    path = pending_path(p, state, sid, pid, start)
    identity = dict(project=os.path.realpath(project), sid=sid, pid=pid, start=start)
    value = read(path, identity)
    value['items'] = [row for row in value['items'] if row['lane'] not in fresh_lanes]
    accepted = [[], []]
    for index, events in enumerate((new, renudged)):
        for event in events:
            key = event.get('key')
            if not isinstance(key, str) or not 0 < len(key) <= 512:
                continue
            lane = p.lane_of(state, event)
            old = next((r for r in value['items'] if r['key'] == key
                        and r['renudge'] == bool(index) and r['lane'] == lane), None)
            row = dict(id=uuid.uuid4().hex, key=key, lane=lane,
                       renudge=bool(index), stop_spent=False,
                       minutes=event.get('re_nudge_minutes', 0))
            if old is None:
                value['items'].append(row)
                if len(encoded(value)) > MAX_STATE:
                    value['items'].pop()
                    continue
            accepted[index].append(event)
    if accepted[0] or accepted[1]:
        atomic(path, value)
    return tuple(accepted)


@contextlib.contextmanager
def locked(state, deadline):
    fd = os.open(str(Path(state) / 'lease.lock'),
                 os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError('lock file type')
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError('lease lock deadline')
                time.sleep(.01)
        yield
    finally:
        os.close(fd)


def fetch_events(p, project, keys, deadline):
    import urllib.request
    ev = p.event_module()
    ev.load_env(project)
    api = os.environ.get('DRSG_API', ev.API)
    plane = os.environ.get('DRSG_PLANE', ev.PLANE)
    token = os.environ.get('DRSG_TOKEN', '')
    query = ("MATCH (p:Project)<-[:NOTIFY]-(e:Event) WHERE p.path = $path "
             "AND e.status = 'open' AND key(e) IN $keys RETURN e")
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'plane.cypher',
                       'params': {'plane': plane, 'query': query,
                                  'params': {'path': project, 'keys': keys}}}).encode()
    request = urllib.request.Request(api, data=body, headers={
        'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token})
    timeout = min(1.0, deadline - time.monotonic())
    if timeout <= 0:
        raise TimeoutError('RPC deadline')
    with ev.drsg_rpc._urlopen(request, timeout) as response:
        raw = response.read(1048577)
    if len(raw) > 1048576:
        raise ValueError('RPC size')
    result = json.loads(raw)
    if result.get('error') or not isinstance(result.get('result'), dict):
        raise ValueError('RPC result')
    nodes = result['result'].get('nodes')
    if not isinstance(nodes, list):
        raise ValueError('RPC nodes')
    out = []
    for node in nodes:
        pr = node.get('properties', {})
        if pr.get('status') != 'open':
            continue
        row = dict(pr, key=node.get('external_key'))
        if row['key'] in keys:
            out.append(row)
    if len({r['key'] for r in out}) != len(out):
        raise ValueError('duplicate Event key')
    return out


def render(p, rows):
    lines = [PREFIX, OWNER]
    for row, event in rows:
        lines.extend(p.wake_text([event]).splitlines()[1:-1])
        if row['renudge']:
            lines.append('  ↻ 再提醒（已等待 %d 分钟）' % row.get('minutes', 0))
    lines.append(p.wake_text([]).splitlines()[-1])
    return '\n'.join(lines)


def deliver(p, hook, project, state, pid, start, fetch=fetch_events, output=None):
    event_name = hook.get('hook_event_name')
    if event_name not in ('Stop', 'PostToolUse', 'UserPromptSubmit'):
        return
    sid = hook.get('session_id')
    path = pending_path(p, state, sid, pid, start)
    identity = dict(project=os.path.realpath(project), sid=sid, pid=pid, start=start)
    initial = read(path, identity)
    if not initial['items'] or (event_name == 'Stop'
            and all(row['stop_spent'] for row in initial['items'])):
        return
    deadline = time.monotonic() + 1.5
    requested = {r['key'] for r in initial['items']}
    events = fetch(p, project, list(requested), deadline)
    current = {e['key']: e for e in events if e.get('status') == 'open'}
    with locked(state, deadline):
        value = read(path, identity)
        lanes = p.event_module().process_lanes(pid)
        rows, closed = [], set()
        for row in value['items']:
            if row['key'] not in requested:
                continue  # A producer added it after the RPC snapshot.
            event = current.get(row['key'])
            if event is None:
                closed.add(row['id'])
                continue
            lane = p.lane_of(state, event)
            lease = p.read_json(str(Path(state) / p.event_module().lease_name(lane)), {})
            if (not p.alive(pid, start) or lane not in lanes or lane != row['lane']
                    or not p.holds(lease, sid, pid, start)):
                continue
            if event_name == 'Stop' and row['stop_spent']:
                continue
            rows.append((row, event))
        value['items'] = [r for r in value['items'] if r['id'] not in closed]
        if not rows:
            if closed:
                atomic(path, value)
            return
        selected, complete = [], set()
        for row, event in rows:
            if len(render(p, selected + [(row, event)])) <= MAX_TEXT - 512:
                selected.append((row, event))
                complete.add(row['id'])
        text = render(p, selected) if selected else '\n'.join((PREFIX, OWNER))
        if len(selected) != len(rows):
            text += '\n' + OVERFLOW
        if event_name == 'Stop':
            for row, _ in rows:
                row['stop_spent'] = True
            atomic(path, value)  # Budget reservation is not an emitted receipt.
        if event_name == 'Stop':
            payload = {'decision': 'block', 'reason': text}
        else:
            payload = {'hookSpecificOutput': {'hookEventName': event_name,
                                              'additionalContext': text}}
        target = sys.stdout if output is None else output
        serialized = json.dumps(payload, ensure_ascii=False) + '\n'
        if target.write(serialized) != len(serialized):
            raise OSError('short hook output')
        target.flush()
        value['items'] = [r for r in value['items'] if r['id'] not in complete]
        atomic(path, value)  # Success only after output and flush.


def cleanup(p, state, sid, pid, start):
    path = Path(pending_path(p, state, sid, pid, start))
    for candidate in [path] + list(path.parent.glob(path.name + '.tmp-*')):
        try:
            candidate.unlink()
        except OSError:
            pass


def sweep(p, state, own):
    cutoff = time.time() - p.SEEN_MAX_AGE
    for path in Path(state).glob('*.wake-relay.json'):
        try:
            if path.stat().st_mtime >= cutoff:
                continue
            value = read(str(path), {})
            expected = pending_path(p, state, value['sid'], value['pid'], value['start'])
            if str(path) == expected and not p.alive(value['pid'], value['start']):
                cleanup(p, state, value['sid'], value['pid'], value['start'])
        except (OSError, ValueError, KeyError, TypeError):
            pass


def load_poller():
    spec = importlib.util.spec_from_file_location('relay_poller',
        Path(__file__).with_name('event-poller.py'))
    p = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(p)
    return p


def expired(*args):
    raise TimeoutError('hook deadline')


def main():
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, 2)
    try:
        hook = json.load(sys.stdin)
        if not isinstance(hook, dict):
            return
        project = os.path.realpath(os.environ.get('CLAUDE_PROJECT_DIR')
                                   or hook.get('cwd') or os.getcwd())
        p = load_poller()
        state = str(Path(p.STATE_ROOT) / p.hashlib.sha1(project.encode()).hexdigest()[:12])
        if not Path(project, '.drsg', 'env').is_file() or not Path(state).is_dir():
            return
        pid, start = p.owner_process()
        deliver(p, hook, project, state, pid, start)
    except Exception:
        pass  # A recovery extra must not block user work or print credentials.
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == '__main__':
    main()

"""Native fixture bootstrap; every delivery uses the production relay main."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def modules():
    return (load('production_fixture_poller', ROOT / 'tools/event-poller.py'),
            load('production_fixture_relay', ROOT / 'tools/event-wake-relay.py'))


def stage_after_empty_request(root):
    identity = json.loads((root / 'native-owner.json').read_text())
    p, relay = modules()
    event = {'key': 'event-synthetic-52', 'kind': 'handoff',
             'summary': 'SYNTHETIC_RELAY_BODY synthetic task', 'ref': 'synthetic-plan',
             'from_project': 'synthetic-sender', 'status': 'open'}
    with p.Locked(identity['state']):
        relay.stage(p, str(root / 'project'), identity['state'], identity['sid'],
                    identity['pid'], identity['start'], [event], [])


def main():
    root, mode, phase = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    p, relay = modules()
    raw = sys.stdin.read()
    hook = json.loads(raw)
    with (root / 'hooks.jsonl').open('a') as out:
        out.write(json.dumps({'event': hook.get('hook_event_name'), 'phase': phase,
                              'active': hook.get('stop_hook_active')}) + '\n')
    if phase != 'wake':
        stream = sys.stdout
        class TransportTrace:
            waiting = False
            def write(self, value):
                count = stream.write(value)
                self.waiting = count == len(value)
                return count
            def flush(self):
                stream.flush()
                if self.waiting:
                    self.waiting = False
                    with (root / 'hooks.jsonl').open('a') as out:
                        out.write(json.dumps({'phase': phase, 'emitted': True,
                                              'active': hook.get('stop_hook_active')}) + '\n')
        sys.stdin = io.StringIO(raw)
        sys.stdout = TransportTrace()
        relay.main()
        return
    pid, start = p.owner_process()
    project = str(root / 'project')
    state = str(root / 'memory' / 'poller' / p.hashlib.sha1(project.encode()).hexdigest()[:12])
    Path(state).mkdir(parents=True, exist_ok=True)
    identity = dict(sid=hook['session_id'], pid=pid, start=start, state=state)
    (root / 'native-owner.json').write_text(json.dumps(identity))
    p.write_json(str(Path(state) / 'lease.json'),
                 dict(session_id=identity['sid'], pid=pid, start=start))
    deadline = time.monotonic() + 12
    while not (root / 'release').exists():
        if time.monotonic() >= deadline:
            return
        time.sleep(.002)
    if os.environ.get('TODO52_NORMAL_ASYNC') == '1':
        stage_after_empty_request(root)
        sys.stderr.write('SYNTHETIC_TODO52_WAKE\n' + p.wake_text([{
            'key': 'event-synthetic-52', 'kind': 'handoff',
            'summary': 'SYNTHETIC_RELAY_BODY synthetic task', 'ref': 'synthetic-plan'}]) + '\n')
        sys.stderr.flush()
    (root / 'flushed').touch()
    sys.exit(2)  # Empty-output injection unless the normal preservation control is selected.


if __name__ == '__main__':
    main()

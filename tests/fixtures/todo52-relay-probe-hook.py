"""Synthetic transport gate only; no project or Event state is read."""
import json
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
mode = sys.argv[2]
phase = sys.argv[3]
hook = json.load(sys.stdin)
active = hook.get('stop_hook_active')
with (root / 'hooks.jsonl').open('a') as out:
    out.write(json.dumps({'event': hook.get('hook_event_name'), 'phase': phase,
                          'active': active}) + '\n')
if phase == 'wake':
    deadline = time.monotonic() + 12
    while not (root / 'release').exists():
        if time.monotonic() > deadline:
            sys.exit(0)
        time.sleep(.002)
    # Inject missing async text deterministically; natural-race evidence is separate.
    sys.stderr.flush()
    (root / 'flushed').touch()
    sys.exit(2)
if (root / 'emitted').exists():
    sys.exit(0)
text = ('SYNTHETIC_RELAY_BODY key=event-synthetic-52 kind=handoff '
        'summary=synthetic-task ref=synthetic-plan owner=synthetic-lane '
        'Already handling this Event? Continue; do not restart it.')
if mode == 'stop' and phase == 'Stop' and active is True:
    print(json.dumps({'decision': 'block', 'reason': text}))
    sys.stdout.flush()
    (root / 'emitted').touch()
elif mode == 'tool' and phase == 'PostToolUse':
    print(json.dumps({'hookSpecificOutput': {'hookEventName': phase,
                                           'additionalContext': text}}))
    sys.stdout.flush()
    (root / 'emitted').touch()

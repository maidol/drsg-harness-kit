"""Native fixture self-check: killed, survived and not_run are distinct."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--control', choices=('survivor', 'broken'))
args = parser.parse_args()
here = Path(__file__).resolve().parent
source = (here / 'fixtures/todo52-relay-probe-hook.py').read_text()
driver = here / 'fixtures/todo52-relay-probe.py'
mutations = [
    ('skip-active-stop', 'stop',
     "if mode == 'stop' and phase == 'Stop' and active is True:",
     "if mode == 'stop' and active is True:\n    sys.exit(0)\nif mode == 'stop' and phase == 'Stop' and active is True:"),
    ('terminal-not-model', 'tool',
     "{'hookSpecificOutput': {'hookEventName': phase,\n                                           'additionalContext': text}}",
     "{'systemMessage': text}"),
]
if args.control:
    mutations = [('control-' + args.control, 'stop', '', '')]
counts = {'killed': 0, 'survived': 0, 'not_run': 0}
with tempfile.TemporaryDirectory(prefix='todo52-native-mutations-') as temp:
    for name, mode, old, new in mutations:
        text = source
        if args.control == 'broken':
            text = 'def invalid(\n'
        elif not args.control:
            assert text.count(old) == 1, name
            text = text.replace(old, new)
        target = Path(temp) / (name + '.py')
        target.write_text(text)
        try:
            compile(text, str(target), 'exec')
        except SyntaxError:
            verdict = 'not_run'
        else:
            result = subprocess.run([sys.executable, '-I', str(driver), mode,
                                     '--hook', str(target)], capture_output=True,
                                    text=True, timeout=40)
            expected = 'AssertionError: relay body absent from native model request'
            if result.returncode == 0:
                verdict = 'survived'
            elif result.returncode == 1 and expected in result.stderr:
                verdict = 'killed'
            else:
                verdict = 'not_run'
        counts[verdict] += 1
        print(json.dumps({'mutation': name, 'verdict': verdict}))
print(json.dumps(counts))
sys.exit(2 if counts['not_run'] else 1 if counts['survived'] else 0)

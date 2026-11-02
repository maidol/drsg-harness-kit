"""One targeted test per mutation, with explicit survivor and not-run controls."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RELAY = 'tools/event-wake-relay.py'
CASES = 'tests/event_wake_relay_cases.py'
CONTRACTS = 'tests/event_wake_relay_contracts.py'
MUTATIONS = [
    ('active-stop-skip', RELAY, "    sid = hook.get('session_id')\n",
     "    if hook.get('stop_hook_active'):\n        return\n    sid = hook.get('session_id')\n", CASES, 'RelayCases.test_active_stop_once'),
    ('terminal-only', RELAY, "'additionalContext': text", "'systemMessage': text", CASES, 'RelayCases.test_output_and_dedup'),
    ('no-lease-gate', RELAY, 'or not p.holds(lease, sid, pid, start)', 'or False', CASES, 'RelayCases.test_owner_lease_gate'),
    ('no-lane-gate', RELAY, 'lane not in lanes', 'False', CASES, 'RelayCases.test_lane_gate'),
    ('no-alive-gate', RELAY, 'not p.alive(pid, start)', 'False', CASES, 'RelayCases.test_dead_owner_gate'),
    ('no-staged-lane-gate', RELAY, "lane != row['lane']", 'False', CASES, 'RelayCases.test_staged_lane_must_still_match'),
    ('repeat-stop', RELAY, "            if event_name == 'Stop' and row['stop_spent']:\n",
     '            if False:\n', CASES, 'RelayCases.test_stop_budget_rechecked_after_rpc'),
    ('early-success', RELAY, '        target = sys.stdout if output is None else output\n',
     "        value['items'] = [r for r in value['items'] if r['id'] not in complete]\n        atomic(path, value)\n        target = sys.stdout if output is None else output\n", CASES, 'RelayCases.test_short_write_preserves_pending'),
    ('daemon-stale-fallback', RELAY, '    events = fetch(p, project, list(requested), deadline)\n',
     "    try:\n        events = fetch(p, project, list(requested), deadline)\n    except OSError:\n        events = [dict(key=r['key'], kind='handoff', summary='stale', status='open') for r in initial['items']]\n", CASES, 'RelayCases.test_rpc_failure_preserves_pending'),
    ('no-dedup', RELAY, "        value['items'] = [r for r in value['items'] if r['id'] not in complete]\n        atomic(path, value)  # Success only after output and flush.\n",
     '        atomic(path, value)  # Incorrectly retain emitted records.\n', CASES, 'RelayCases.test_output_and_dedup'),
    ('no-stage-before-seen', 'tools/event-poller.py',
     '                            new, renudged = relay_module().stage(_relay_context(),\n                                project, state, sid, pid, start, new, renudged, fresh_lanes)\n',
     '                            pass  # Incorrectly consume seen without pending.\n', CASES, 'RelayCases.test_real_poll_stages_before_wake'),
    ('async-only', 'setup.sh', '    for event in ("PostToolUse", "Stop", "UserPromptSubmit"):\n',
     '    for event in ():\n', CONTRACTS, 'Contracts.test_setup_registration_and_preservation'),
]
for field in ('project', 'sid', 'pid', 'start'):
    MUTATIONS.append(('no-header-' + field, RELAY,
        'any(value.get(k) != v for k, v in identity.items())',
        'any(value.get(k) != v for k, v in identity.items() if k != %r)' % field,
        CASES, 'RelayCases.test_header_identity_fields'))


def run_one(entry, control=None):
    label, path, old, new, tests, case = entry
    with tempfile.TemporaryDirectory(prefix='relay-mutation-') as temporary:
        root = Path(temporary)
        # setup tests require the real bundle; no source is taken from reviews/.
        shutil.copytree(ROOT / 'tools', root / 'tools', ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copytree(ROOT / 'claude', root / 'claude')
        (root / 'tests').mkdir()
        for source in (CASES, CONTRACTS, 'setup.sh'):
            shutil.copy2(ROOT / source, root / source)
        target = root / path
        text = target.read_text()
        if text.count(old) != 1:
            return label, 'not_run', 'anchor count'
        if control == 'broken':
            target.write_text('def broken(:\n')
        elif control != 'survivor':
            target.write_text(text.replace(old, new))
        if path.endswith('.py'):
            try:
                compile(target.read_text(), str(target), 'exec')
            except SyntaxError:
                return label, 'not_run', 'compile failure'
        env = dict(os.environ, RELAY_MUTATION_TRACE='1')
        try:
            result = subprocess.run([sys.executable, '-I', str(root / tests), case],
                cwd=root, env=env, capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            return label, 'not_run', 'timeout'
        output = result.stdout + result.stderr
        ready = 'CASE_READY:' + ('runTest' if tests == CONTRACTS else case.split('.')[-1]) in output
        ran = re.search(r'Ran 1 test\b', output)
        if not ready or not ran or 'skipped=' in output:
            return label, 'not_run', 'test body not established'
        if result.returncode == 0:
            return label, 'survived', 'test passed'
        # Assertion failures and explicit behavior errors count only after setUp.
        if 'FAILED (' in output and not any(x in output for x in (
                'ModuleNotFoundError', 'ImportError', 'SyntaxError', 'NameError')):
            return label, 'killed', 'target behavior failed'
        return label, 'not_run', 'unexpected runner failure'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--control', choices=('survivor', 'broken'))
    args = parser.parse_args()
    entries = MUTATIONS[:1] if args.control else MUTATIONS
    results = [run_one(entry, args.control) for entry in entries]
    for label, outcome, reason in results:
        print(json.dumps(dict(mutation=label, outcome=outcome, reason=reason)))
    counts = {name: sum(outcome == name for _, outcome, _ in results)
              for name in ('killed', 'survived', 'not_run')}
    print(json.dumps(counts, sort_keys=True))
    return 2 if counts['not_run'] else 1 if counts['survived'] else 0


if __name__ == '__main__':
    sys.exit(main())

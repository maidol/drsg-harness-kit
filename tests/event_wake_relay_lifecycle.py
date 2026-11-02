"""Process crash, lane/claim and cleanup boundaries, using only synthetic state."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('relay_lifecycle_cases', ROOT / 'tests/event_wake_relay_cases.py')
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.f = cases.RelayCases()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)

    def test_crash_after_output_before_receipt(self):
        f = self.f
        f.stage(); f.hook['hook_event_name'] = 'Stop'
        output = Path(f.temp.name) / 'child-output.json'
        child = os.fork()
        if child == 0:
            try:
                stream = output.open('w')
                class CrashAfterFlush:
                    def write(self, value):
                        return stream.write(value)
                    def flush(self):
                        stream.flush()
                        os._exit(91)
                f.r.deliver(f.p, f.hook, f.project, f.state, f.pid, f.start,
                            fetch=lambda *a: [f.event], output=CrashAfterFlush())
            finally:
                os._exit(92)
        _, status = os.waitpid(child, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 91)
        self.assertEqual(json.loads(output.read_text())['decision'], 'block')
        self.assertTrue(f.state_data()['items'][0]['stop_spent'])
        f.deliver(fetch=lambda *a: self.fail('crashed Stop must not loop'))
        self.assertEqual(f.output.getvalue(), '')
        f.hook['hook_event_name'] = 'PostToolUse'; f.deliver()
        self.assertTrue(f.output.getvalue()); self.assertEqual(f.state_data()['items'], [])

    def test_multiple_lanes_respect_claim_and_current_owner(self):
        f = self.f
        f.lanes = ['alpha', 'beta']
        ev = f.p.event_module()
        for lane, sid in (('alpha', f.sid), ('beta', 'other-session')):
            f.p.write_json(str(Path(f.state) / ev.lease_name(lane)),
                           dict(session_id=sid, pid=f.pid, start=f.start))
        events = [dict(f.event, key='event-' + lane, from_project=lane) for lane in f.lanes]
        f.p.write_json(str(Path(f.state) / 'claims.json'), {'event-alpha': 'alpha', 'event-beta': 'beta'})
        f.stage(new=events); f.deliver(events=events)
        lines = json.loads(f.output.getvalue())['hookSpecificOutput']['additionalContext'].splitlines()
        self.assertIn('- event-alpha [handoff] synthetic task', lines)
        self.assertNotIn('- event-beta [handoff] synthetic task', lines)
        self.assertEqual([r['key'] for r in f.state_data()['items']], ['event-beta'])
        f.p.write_json(str(Path(f.state) / ev.lease_name('beta')),
                       dict(session_id=f.sid, pid=f.pid, start=f.start))
        f.output = io.StringIO(); f.deliver(events=events)
        self.assertIn('- event-beta [handoff] synthetic task',
            json.loads(f.output.getvalue())['hookSpecificOutput']['additionalContext'].splitlines())
        self.assertEqual(f.state_data()['items'], [])

    def test_claim_moved_after_rpc_is_not_authorized(self):
        f = self.f
        f.stage()
        def fetch(*args):
            ev = f.p.event_module()
            f.p.write_json(str(Path(f.state) / ev.lease_name('other')),
                           dict(session_id='other-session', pid=f.pid, start=f.start))
            f.p.write_json(str(Path(f.state) / 'claims.json'), {f.event['key']: 'other'})
            return [f.event]
        f.deliver(fetch=fetch)
        self.assertEqual(f.output.getvalue(), '')
        self.assertEqual(len(f.state_data()['items']), 1)

    def test_sweep_only_old_dead_instance(self):
        f = self.f
        f.stage()
        old_start = f.start + 1
        old_path = f.r.pending_path(f.p, f.state, f.sid, f.pid, old_start)
        value = f.state_data(); value['start'] = old_start
        f.r.atomic(old_path, value)
        past = time.time() - f.p.SEEN_MAX_AGE - 1
        os.utime(old_path, (past, past)); os.utime(f.path, (past, past))
        unrelated = Path(f.state) / 'unrelated.txt'; unrelated.write_text('retain')
        f.r.sweep(f.p, f.state, f.p.tag(f.sid, f.pid))
        # A reused PID does not protect an expired, dead start-time identity.
        self.assertFalse(Path(old_path).exists())
        self.assertTrue(Path(f.path).exists()); self.assertTrue(unrelated.exists())

    def test_real_main_rejects_missing_identity_and_unsupported_event(self):
        f = self.f
        Path(f.project, '.drsg', 'env').write_text('DRSG_PLANE=synthetic\n')
        f.p.STATE_ROOT = str(Path(f.state).parent / 'poller')
        hashed = Path(f.p.STATE_ROOT) / f.p.hashlib.sha1(f.project.encode()).hexdigest()[:12]
        hashed.mkdir(parents=True)
        f.p.owner_process = lambda: (f.pid, f.start)
        for hook in ({'hook_event_name': 'Stop'}, {'session_id': f.sid, 'hook_event_name': 'StopFailure'}):
            output = io.StringIO()
            with mock.patch.dict(os.environ, {'CLAUDE_PROJECT_DIR': f.project}, clear=True), \
                    mock.patch.object(f.r, 'load_poller', return_value=f.p), \
                    mock.patch.object(sys, 'stdin', io.StringIO(json.dumps(hook))), \
                    mock.patch.object(sys, 'stdout', output):
                f.r.main()
            self.assertEqual(output.getvalue(), '')

    def test_real_alarm_bounds_stalled_hook(self):
        f = self.f
        output = io.StringIO()
        def stalled():
            time.sleep(5)
            self.fail('alarm did not interrupt')
        started = time.monotonic()
        with mock.patch.object(f.r, 'load_poller', side_effect=stalled), \
                mock.patch.object(sys, 'stdin', io.StringIO('{}')), \
                mock.patch.object(sys, 'stdout', output):
            f.r.main()
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(output.getvalue(), '')


if __name__ == '__main__':
    unittest.main()

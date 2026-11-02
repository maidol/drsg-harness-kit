"""Synthetic state and transport tests; never connect to a real daemon."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class RelayCases(unittest.TestCase):
    def setUp(self):
        source = ROOT / 'tools/event-wake-relay.py'
        self.assertTrue(source.is_file(), 'durable relay implementation missing')
        self.r = load('relay_cases_impl', source)
        self.p = load('relay_cases_poller', ROOT / 'tools/event-poller.py')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.project = str(Path(self.temp.name) / 'project')
        Path(self.project, '.drsg').mkdir(parents=True)
        self.state = str(Path(self.temp.name) / 'state')
        Path(self.state).mkdir()
        self.sid, self.pid = 'synthetic-session', os.getpid()
        self.start = self.p.proc_start(self.pid)
        self.lanes = ['*']
        self.p.event_module().process_lanes = lambda pid: self.lanes
        self.lease()
        self.event = {'key': 'event-synthetic-52', 'kind': 'handoff',
                      'summary': 'synthetic task', 'ref': 'synthetic-plan',
                      'from_project': 'synthetic-sender', 'status': 'open'}
        self.hook = {'hook_event_name': 'PostToolUse', 'session_id': self.sid}
        self.output = io.StringIO()
        self.path = self.r.pending_path(self.p, self.state, self.sid, self.pid, self.start)
        if os.environ.get('RELAY_MUTATION_TRACE') == '1':
            print('CASE_READY:' + self._testMethodName, flush=True)

    def lease(self, **extra):
        value = {'session_id': self.sid, 'pid': self.pid, 'start': self.start}
        value.update(extra)
        self.p.write_json(str(Path(self.state) / 'lease.json'), value)

    def stage(self, new=None, renudged=None):
        return self.r.stage(self.p, self.project, self.state, self.sid,
                            self.pid, self.start, [self.event] if new is None else new,
                            [] if renudged is None else renudged)

    def deliver(self, events=None, fetch=None):
        fetch = fetch or (lambda *args: [self.event] if events is None else events)
        return self.r.deliver(self.p, self.hook, self.project, self.state,
                              self.pid, self.start, fetch=fetch, output=self.output)

    def state_data(self):
        return json.loads(Path(self.path).read_text())

    def save(self, data):
        Path(self.path).write_text(json.dumps(data))

    def test_stage_before_delivery(self):
        new, renudged = self.stage()
        self.assertEqual([e['key'] for e in new], [self.event['key']])
        self.assertEqual(renudged, [])
        self.assertEqual(len(self.state_data()['items']), 1)
        self.assertNotIn('summary', Path(self.path).read_text())
        self.assertEqual(Path(self.path).stat().st_mode & 0o777, 0o600)

    def test_output_and_dedup(self):
        self.stage()
        self.deliver()
        out = json.loads(self.output.getvalue())
        lines = out['hookSpecificOutput']['additionalContext'].splitlines()
        self.assertEqual(lines[0], '【正文接力】若已在处理，继续，不要重做。')
        self.assertIn('- event-synthetic-52 [handoff] synthetic task', lines)
        self.assertIn('  ref: synthetic-plan', lines)
        self.assertIn('本会话持有本次接力 Event 的 owner 租约；只处理下面列出的项目。', lines)
        self.assertEqual(out['hookSpecificOutput']['hookEventName'], 'PostToolUse')
        self.assertEqual(self.state_data()['items'], [])
        self.output.seek(0); self.output.truncate()
        self.deliver(fetch=lambda *a: self.fail('no RPC when empty'))
        self.assertEqual(self.output.getvalue(), '')

    def test_active_stop_once(self):
        self.stage()
        self.hook.update(hook_event_name='Stop', stop_hook_active=True)
        self.deliver()
        self.assertEqual(json.loads(self.output.getvalue())['decision'], 'block')
        self.output.seek(0); self.output.truncate()
        self.deliver()
        self.assertEqual(self.output.getvalue(), '')

    def test_prompt_channel(self):
        self.stage()
        self.hook['hook_event_name'] = 'UserPromptSubmit'
        self.deliver()
        self.assertEqual(json.loads(self.output.getvalue())['hookSpecificOutput']['hookEventName'], 'UserPromptSubmit')

    def test_closed_not_replayed(self):
        self.stage()
        self.deliver(events=[])
        self.assertEqual(self.output.getvalue(), '')
        self.assertEqual(self.state_data()['items'], [])

    def test_rpc_failure_preserves_pending(self):
        self.stage()
        def failed(*args):
            raise OSError('synthetic failure')
        with self.assertRaises(OSError):
            self.deliver(fetch=failed)
        self.assertEqual(len(self.state_data()['items']), 1)
        self.assertEqual(self.output.getvalue(), '')

    def test_owner_lease_gate(self):
        self.stage()
        self.lease(session_id='other-session')
        self.deliver()
        self.assertEqual(self.output.getvalue(), '')
        self.assertEqual(len(self.state_data()['items']), 1)

    def test_lane_gate(self):
        self.stage()
        self.lanes = ['other-lane']
        self.deliver()
        self.assertEqual(self.output.getvalue(), '')

    def test_staged_lane_must_still_match(self):
        self.stage()
        value = self.state_data(); value['items'][0]['lane'] = 'other-lane'
        self.save(value)
        self.deliver()
        self.assertEqual(self.output.getvalue(), '')

    def test_dead_owner_gate(self):
        self.stage()
        with mock.patch.object(self.p, 'alive', return_value=False):
            self.deliver()
        self.assertEqual(self.output.getvalue(), '')

    def test_header_identity_fields(self):
        self.stage()
        original = self.state_data()
        for field in ('project', 'sid', 'pid', 'start'):
            with self.subTest(field=field):
                altered = dict(original)
                altered[field] = 'wrong'
                self.save(altered)
                with self.assertRaises(ValueError):
                    self.deliver()
                self.assertEqual(self.output.getvalue(), '')

    def test_stop_failure_budget_and_retry(self):
        self.stage()
        self.hook.update(hook_event_name='Stop', stop_hook_active=True)
        class Broken(io.StringIO):
            def flush(self):
                raise OSError('synthetic flush failure')
        self.output = Broken()
        with self.assertRaises(OSError):
            self.deliver()
        self.assertTrue(self.state_data()['items'][0]['stop_spent'])
        self.output = io.StringIO()
        self.deliver()
        self.assertEqual(self.output.getvalue(), '')
        self.hook['hook_event_name'] = 'PostToolUse'
        self.deliver()
        self.assertTrue(self.output.getvalue())
        self.assertEqual(self.state_data()['items'], [])

    def test_commit_failure_does_not_repeat_stop(self):
        self.stage()
        self.hook.update(hook_event_name='Stop', stop_hook_active=True)
        original = self.r.atomic
        calls = []
        def fail_second(*args):
            calls.append(1)
            if len(calls) == 2:
                raise OSError('synthetic commit failure')
            return original(*args)
        with mock.patch.object(self.r, 'atomic', side_effect=fail_second):
            with self.assertRaises(OSError):
                self.deliver()
        self.assertEqual(len(self.state_data()['items']), 1)
        self.output.seek(0); self.output.truncate()
        self.deliver()
        self.assertEqual(self.output.getvalue(), '')

    def test_staging_failure_is_not_success(self):
        with mock.patch.object(self.r, 'atomic', side_effect=OSError('synthetic')):
            with self.assertRaises(OSError):
                self.stage()
        self.assertFalse(Path(self.path).exists())

    def test_renudge_is_separate_generation(self):
        self.stage(); self.deliver()
        event = dict(self.event, re_nudge_minutes=30)
        self.stage(new=[], renudged=[event])
        self.output.seek(0); self.output.truncate()
        self.deliver()
        self.assertIn('再提醒', self.output.getvalue())

    def test_capacity_preserves_old_items(self):
        self.stage()
        before = self.state_data()['items'][0]['id']
        with mock.patch.object(self.r, 'MAX_STATE', len(Path(self.path).read_bytes()) + 10):
            new, _ = self.stage(new=[dict(self.event, key='other-event')])
        self.assertEqual(new, [])
        self.assertEqual(self.state_data()['items'][0]['id'], before)

    def test_oversized_text_is_bounded_not_complete(self):
        self.stage()
        self.deliver(events=[dict(self.event, summary='x' * 20000)])
        out = json.loads(self.output.getvalue())['hookSpecificOutput']['additionalContext']
        self.assertLessEqual(len(out), self.r.MAX_TEXT)
        self.assertIn('event_list', out)
        self.assertEqual(len(self.state_data()['items']), 1)

    def test_no_pending_no_rpc(self):
        self.deliver(fetch=lambda *a: self.fail('unexpected RPC'))
        self.assertEqual(self.output.getvalue(), '')

    def test_same_generation_does_not_reset_stop_budget(self):
        self.stage()
        value = self.state_data(); value['items'][0]['stop_spent'] = True
        self.save(value)
        self.stage()
        self.assertTrue(self.state_data()['items'][0]['stop_spent'])

    def test_recheck_after_rpc(self):
        self.stage()
        def fetch(*args):
            self.lease(session_id='other-session')
            return [self.event]
        self.deliver(fetch=fetch)
        self.assertEqual(self.output.getvalue(), '')

    def test_rows_added_during_rpc_are_not_closed(self):
        self.stage()
        def fetch(*args):
            self.stage(new=[dict(self.event, key='later-event')])
            return []
        self.deliver(fetch=fetch)
        self.assertEqual([r['key'] for r in self.state_data()['items']], ['later-event'])

    def test_short_write_preserves_pending(self):
        self.stage()
        class Short(io.StringIO):
            def write(self, value):
                return 1
        self.output = Short()
        with self.assertRaises(OSError):
            self.deliver()
        self.assertEqual(len(self.state_data()['items']), 1)

    def test_renudge_minutes_are_not_hardcoded(self):
        event = dict(self.event, re_nudge_minutes=7)
        self.stage(new=[], renudged=[event])
        self.deliver()
        text = json.loads(self.output.getvalue())['hookSpecificOutput']['additionalContext']
        self.assertIn('  ↻ 再提醒（已等待 7 分钟）', text.splitlines())

    def test_real_poll_stages_before_wake(self):
        self.p.owner_process = lambda: (self.pid, self.start)
        self.p.background = lambda pid: False
        self.p.open_events = lambda project: [self.event]
        self.p.MIN_POLL_LIFETIME = 0
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(self.p.poll(self.project, self.state, self.sid), 2)
        self.assertEqual(self.state_data()['items'][0]['key'], self.event['key'])

    def test_poll_staging_failure_does_not_consume_seen(self):
        self.p.owner_process = lambda: (self.pid, self.start)
        self.p.background = lambda pid: False
        self.p.open_events = lambda project: [self.event]
        self.p.MIN_POLL_LIFETIME = 0
        with mock.patch.object(self.p, 'relay_module', return_value=self.r), \
                mock.patch.object(self.r, 'atomic', side_effect=OSError('synthetic')), \
                mock.patch.object(self.p, 'wait', side_effect=RuntimeError('end fixture')):
            with self.assertRaisesRegex(RuntimeError, 'end fixture'):
                self.p.poll(self.project, self.state, self.sid)
        path = Path(self.state) / (self.p.tag(self.sid, self.pid) + '.seen.json')
        value = self.p.seen_state(self.p.read_json(str(path), []))[0]
        self.assertNotIn(self.event['key'], value['events'])

    def test_seen_write_failure_retains_pending(self):
        self.p.owner_process = lambda: (self.pid, self.start)
        self.p.background = lambda pid: False
        self.p.open_events = lambda project: [self.event]
        self.p.MIN_POLL_LIFETIME = 0
        original = self.p.write_json
        def failing(path, value):
            if path.endswith('.seen.json'):
                raise OSError('synthetic seen failure')
            return original(path, value)
        with mock.patch.object(self.p, 'write_json', side_effect=failing):
            with self.assertRaises(OSError):
                self.p.poll(self.project, self.state, self.sid)
        self.assertEqual(len(self.state_data()['items']), 1)

    def test_cleanup_does_not_remove_other_start(self):
        self.stage()
        other = self.r.pending_path(self.p, self.state, self.sid, self.pid, self.start + 1)
        Path(other).write_text('synthetic other generation')
        self.r.cleanup(self.p, self.state, self.sid, self.pid, self.start)
        self.assertFalse(Path(self.path).exists())
        self.assertTrue(Path(other).exists())

    def test_symlink_state_is_rejected(self):
        target = Path(self.temp.name) / 'unrelated'
        target.write_text('do not read or replace')
        Path(self.path).symlink_to(target)
        with self.assertRaises(OSError):
            self.stage()
        self.assertEqual(target.read_text(), 'do not read or replace')

    def test_stop_budget_write_failure_emits_nothing(self):
        self.stage()
        self.hook.update(hook_event_name='Stop', stop_hook_active=True)
        with mock.patch.object(self.r, 'atomic', side_effect=OSError('synthetic')):
            with self.assertRaises(OSError):
                self.deliver()
        self.assertEqual(self.output.getvalue(), '')
        self.assertFalse(self.state_data()['items'][0]['stop_spent'])

    def test_corrupt_state_does_not_replay_history(self):
        Path(self.path).write_text('[]')
        with self.assertRaises(ValueError):
            self.stage()
        self.assertEqual(Path(self.path).read_text(), '[]')

    def test_spent_stop_has_no_rpc(self):
        self.stage()
        value = self.state_data(); value['items'][0]['stop_spent'] = True
        self.save(value)
        self.hook['hook_event_name'] = 'Stop'
        self.deliver(fetch=lambda *a: self.fail('spent Stop must not fetch'))

    def test_stop_budget_rechecked_after_rpc(self):
        self.stage()
        self.hook['hook_event_name'] = 'Stop'
        def fetch(*args):
            value = self.state_data(); value['items'][0]['stop_spent'] = True
            self.save(value)
            return [self.event]
        self.deliver(fetch=fetch)
        self.assertEqual(self.output.getvalue(), '')

    def test_lock_deadline_is_bounded(self):
        import fcntl
        import time
        with open(Path(self.state) / 'lease.lock', 'a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            with self.assertRaises(TimeoutError):
                with self.r.locked(self.state, time.monotonic() - 1):
                    self.fail('contended lock acquired')

    def test_concurrent_hooks_emit_once(self):
        import threading
        self.stage()
        barrier = threading.Barrier(2)
        outputs = [io.StringIO(), io.StringIO()]
        errors = []
        def fetch(*args):
            barrier.wait(timeout=2)
            return [self.event]
        def worker(output):
            try:
                self.r.deliver(self.p, self.hook, self.project, self.state,
                    self.pid, self.start, fetch=fetch, output=output)
            except BaseException as exc:
                errors.append(type(exc).__name__)
        threads = [threading.Thread(target=worker, args=(o,)) for o in outputs]
        for thread in threads: thread.start()
        for thread in threads: thread.join(timeout=3)
        self.assertFalse(any(t.is_alive() for t in threads))
        self.assertEqual(errors, [])
        self.assertEqual(sum(bool(o.getvalue()) for o in outputs), 1)

if __name__ == '__main__':
    unittest.main()

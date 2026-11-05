#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / 'tools/templates/hooks/event_retry_guard.py'
spec = importlib.util.spec_from_file_location('event_retry_guard_test', PATH)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class TestRetryGuard(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = self.temp.name
        self.request = {'session_id': 'synthetic-session', 'prompt_id': 'synthetic-prompt',
            'cwd': '/synthetic/project', 'tool_name': 'mcp__drsg-events__event_post',
            'tool_input': {'recipient': '/synthetic/reviewer', 'summary': 'PRIVATE-SENTINEL',
                           'supersedes': 'incoming'}, 'hook_event_name': 'PostToolUseFailure',
            'error': 'Error: EVENT_POST_ERROR ' + json.dumps({'version': 1, 'posted': False,
                'retryable': False, 'errors': [{'field': 'supersedes', 'code': 'invalid_reference'}]})}

    def invoke(self, **changes):
        data = dict(self.request)
        data.update(changes)
        return guard.handle(data, self.root)

    def test_same_bad_request_is_denied_and_stops(self):
        self.assertEqual(self.invoke(), {})
        result = self.invoke(hook_event_name='PreToolUse')
        self.assertIs(result.get('continue'), False)
        self.assertEqual(result['hookSpecificOutput']['permissionDecision'], 'deny')
        self.assertNotIn('PRIVATE-SENTINEL', json.dumps(result))

    def test_corrected_fields_other_recipient_session_and_prompt_are_not_denied(self):
        self.invoke()
        for changes in ({'supersedes': ''}, {'recipient': '/synthetic/another'}):
            args = dict(self.request['tool_input'], **changes)
            self.assertEqual(self.invoke(hook_event_name='PreToolUse', tool_input=args), {})
        self.assertEqual(self.invoke(hook_event_name='PreToolUse', session_id='another'), {})
        self.assertEqual(self.invoke(hook_event_name='PreToolUse', prompt_id='another'), {})

    def test_changing_body_does_not_erase_same_invalid_reference(self):
        self.invoke()
        args = dict(self.request['tool_input'], summary='changed body', ref='changed ref')
        self.assertIs(self.invoke(hook_event_name='PreToolUse', tool_input=args).get('continue'), False)

    def test_non_parameter_and_partial_delivery_errors_are_ignored(self):
        for error in ('network unavailable', 'permission denied',
                      'EVENT_POST_ERROR ' + json.dumps({'version': 1, 'posted': 'unknown',
                          'errors': [{'field': 'supersedes', 'code': 'invalid_reference'}]})):
            self.assertEqual(self.invoke(error=error), {})
            self.assertEqual(self.invoke(hook_event_name='PreToolUse'), {})

    def test_delivery_outcomes_stop_blind_resends_but_not_read_only_checks(self):
        for posted in (True, 'unknown'):
            with self.subTest(posted=posted):
                root = str(Path(self.root) / str(posted))
                data = dict(self.request, error='EVENT_POST_STATUS ' + json.dumps({'version': 1, 'posted': posted}))
                guard.handle(data, root)
                args = dict(self.request['tool_input'])
                del args['supersedes']
                data.update(hook_event_name='PreToolUse', tool_input=args)
                result = guard.handle(data, root)
                self.assertIs(result.get('continue'), False)
                self.assertEqual(result['stopReason'], 'Event request stopped: previous delivery is known or uncertain; reconcile with event_list before sending again.')
                data['tool_name'] = 'mcp__drsg-events__event_list'
                self.assertEqual(guard.handle(data, root), {})

    def test_state_bounds_expiry_and_capacity_are_explicit(self):
        for number in range(40):
            args = dict(self.request['tool_input'], supersedes='bad-' + str(number))
            self.invoke(tool_input=args)
        files = list((Path(self.root) / 'event-retry').glob('*.json'))
        self.assertEqual(len(files), 1)
        state = json.loads(files[0].read_text())
        self.assertEqual(len(state['blocked']), 32)
        self.assertLessEqual(files[0].stat().st_size, 8192)
        from unittest.mock import patch
        with patch.object(guard.time, 'time', return_value=state['time'] + guard.TTL + 1):
            self.assertEqual(self.invoke(hook_event_name='PreToolUse'), {})
        directory = Path(self.root) / 'full' / 'event-retry'
        directory.mkdir(parents=True)
        for number in range(128):
            (directory / (format(number, '064x') + '.json')).write_text('{}')
        with self.assertRaisesRegex(OSError, 'session state capacity'):
            guard.handle(self.request, str(directory.parent))
        self.assertEqual(len(list(directory.glob('*.json'))), 128)

    def test_state_has_hashes_not_payload_values(self):
        self.invoke()
        text = ''.join(p.read_text() for p in Path(self.root).rglob('*.json'))
        for value in ('PRIVATE-SENTINEL', 'incoming', 'synthetic-session', '/synthetic/reviewer'):
            self.assertNotIn(value, text)

    def test_tools_are_isolated(self):
        self.invoke()
        self.assertEqual(self.invoke(hook_event_name='PreToolUse', tool_name='mcp__other__event_post'), {})

    def test_extra_argument_correction_recovers(self):
        data = dict(self.request, tool_name='mcp__drsg-events__event_reply',
            tool_input={'event_key': 'incoming', 'summary': 'synthetic', 'supersedes': 'incoming'},
            error='EVENT_POST_ERROR ' + json.dumps({'version': 1, 'posted': False,
                'errors': [{'field': 'arguments', 'code': 'unexpected_field'}]}))
        self.assertEqual(guard.handle(data, self.root), {})
        data['hook_event_name'] = 'PreToolUse'
        self.assertIs(guard.handle(data, self.root).get('continue'), False)
        del data['tool_input']['supersedes']
        self.assertEqual(guard.handle(data, self.root), {})

    def test_symlink_state_never_overwrites_target(self):
        directory = Path(self.root) / 'event-retry'
        directory.mkdir()
        target = Path(self.root) / 'protected'
        target.write_text('PRIVATE-SENTINEL')
        name = guard.digest([self.request['session_id'], self.request['cwd']]) + '.json'
        (directory / name).symlink_to(target)
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(target.read_text(), 'PRIVATE-SENTINEL')

    def test_symlink_or_unavailable_state_warns_without_opening_target(self):
        blocker = Path(self.root) / 'not-a-directory'
        blocker.write_text('PRIVATE-SENTINEL')
        import os
        env = dict(os.environ, DRSG_MEM_DIR=str(blocker))
        result = subprocess.run([sys.executable, '-I', str(PATH)], input=json.dumps(self.request),
                                text=True, capture_output=True, env=env)
        self.assertEqual(result.returncode, 0)
        self.assertIn('systemMessage', json.loads(result.stdout))
        self.assertNotIn('PRIVATE-SENTINEL', result.stdout + result.stderr)
        self.assertEqual(blocker.read_text(), 'PRIVATE-SENTINEL')


if __name__ == '__main__':
    unittest.main(verbosity=2)

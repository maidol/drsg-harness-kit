"""Hermetic production contracts: registration, RPC, generations and formatting."""
import copy
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('relay_fixture_cases', ROOT / 'tests/event_wake_relay_cases.py')
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)


EXPECTED_GUIDANCE = "按 Event 流程处理：handoff 直接处理；收到审核方发来的、无需后续执行的普通通过判定 notice（如 summary 以「验收通过：」开头），只关闭该判定 Event，不回“已收到”回执；收到交付方回执或评审请求时，按 ref 审阅，对原发送方发出判定后关闭该交付 Event；要求返工/继续执行或带提交授权的 handoff 不适用普通通过 notice 的只关闭规则，仍按相应流程处理；commit/push/PR 等仍先等用户确认。"
MAX_TEXT = 8192
RENDER_RESERVE = 512


class Contracts(unittest.TestCase):
    def setUp(self):
        self.f = cases.RelayCases()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)

    def test_fresh_lease_is_new_generation(self):
        f = self.f
        self.assertIn('fresh_lanes', inspect.signature(f.r.stage).parameters)
        f.stage()
        value = f.state_data()
        old = value['items'][0]['id']
        value['items'][0]['stop_spent'] = True
        f.save(value)
        f.r.stage(f.p, f.project, f.state, f.sid, f.pid, f.start, [f.event], [],
                  fresh_lanes={'*'})
        self.assertNotEqual(f.state_data()['items'][0]['id'], old)
        f.hook['hook_event_name'] = 'Stop'
        f.deliver()
        self.assertEqual(json.loads(f.output.getvalue())['decision'], 'block')

    def test_other_lane_fresh_does_not_reset_budget(self):
        f = self.f
        self.assertIn('fresh_lanes', inspect.signature(f.r.stage).parameters)
        f.stage()
        value = f.state_data(); value['items'][0]['stop_spent'] = True
        f.save(value)
        f.r.stage(f.p, f.project, f.state, f.sid, f.pid, f.start, [f.event], [],
                  fresh_lanes={'other'})
        self.assertTrue(f.state_data()['items'][0]['stop_spent'])

    def test_seen_alone_is_not_pending(self):
        f = self.f
        Path(f.state, f.p.tag(f.sid, f.pid) + '.seen.json').write_text(
            json.dumps({'version': 1, 'events': {f.event['key']: {'first_wake': None}}}))
        f.deliver(fetch=lambda *a: self.fail('seen is not pending'))
        self.assertEqual(f.output.getvalue(), '')

    def test_reply_and_unicode_are_actual_lines(self):
        f = self.f
        event = dict(f.event, kind='notice', summary='合成 "任务"\n第二行',
                     ref='合成计划', reply_to='synthetic-parent', reply_summary='父单')
        f.stage(new=[event]); f.deliver(events=[event])
        lines = json.loads(f.output.getvalue())['hookSpecificOutput']['additionalContext'].splitlines()
        self.assertIn('- event-synthetic-52 [notice] 合成 "任务"', lines)
        self.assertIn('第二行', lines)
        self.assertIn('  ref: 合成计划', lines)
        self.assertIn('  ↳ 回复你发出的 synthetic-parent：父单', lines)
        self.assertEqual(lines[-1], EXPECTED_GUIDANCE)

    def test_delivery_keeps_exact_guidance_and_event_lines(self):
        f = self.f
        event = dict(f.event, kind='notice', summary='synthetic delivery',
                     ref='synthetic-plan')
        f.stage(new=[event])
        f.deliver(events=[event])
        text = json.loads(f.output.getvalue())['hookSpecificOutput']['additionalContext']
        self.assertEqual(text.splitlines(), [
            f.r.PREFIX,
            f.r.OWNER,
            '- event-synthetic-52 [notice] synthetic delivery',
            '  ref: synthetic-plan',
            EXPECTED_GUIDANCE,
        ])
        self.assertEqual(text.splitlines()[-1], EXPECTED_GUIDANCE)

    def test_guidance_fitting_text_stays_within_fixed_budget(self):
        f = self.f
        self.assertEqual(f.r.MAX_TEXT, MAX_TEXT)
        base_event = dict(f.event, summary='')
        base_render = f.r.render(f.p, [({'renudge': False}, base_event)])
        fitted_length = MAX_TEXT - 600
        fitting_event = dict(base_event, summary='x' * (fitted_length - len(base_render)))
        fitted_text = f.r.render(f.p, [({'renudge': False}, fitting_event)])
        self.assertEqual(len(fitted_text), fitted_length)
        self.assertLessEqual(len(fitted_text), MAX_TEXT - RENDER_RESERVE)
        self.assertEqual(fitted_text.splitlines()[-1], EXPECTED_GUIDANCE)

        f.stage(new=[fitting_event])
        f.deliver(events=[fitting_event])
        delivered = json.loads(f.output.getvalue())['hookSpecificOutput']['additionalContext']
        self.assertEqual(delivered, fitted_text)
        self.assertEqual(f.state_data()['items'], [])

    def test_guidance_reserve_boundary_stays_pending(self):
        f = self.f
        base_event = dict(f.event, summary='')
        base_render = f.r.render(f.p, [({'renudge': False}, base_event)])
        selected_limit = MAX_TEXT - RENDER_RESERVE
        boundary_event = dict(f.event, summary='x' * (selected_limit + 1 - len(base_render)))
        rendered = f.r.render(f.p, [({'renudge': False}, boundary_event)])
        self.assertEqual(len(rendered), selected_limit + 1)
        self.assertGreater(len(rendered), MAX_TEXT - RENDER_RESERVE)
        self.assertLessEqual(len(rendered), MAX_TEXT)

        f.stage(new=[boundary_event])
        f.deliver(events=[boundary_event])
        overflow_text = json.loads(f.output.getvalue())['hookSpecificOutput']['additionalContext']
        self.assertEqual(overflow_text, '\n'.join((f.r.PREFIX, f.r.OWNER, f.r.OVERFLOW)))
        self.assertEqual([row['key'] for row in f.state_data()['items']], [f.event['key']])

    def test_guidance_total_limit_is_fixed_at_8192(self):
        f = self.f
        self.assertEqual(f.r.MAX_TEXT, MAX_TEXT)
        base_event = dict(f.event, summary='')
        base_render = f.r.render(f.p, [({'renudge': False}, base_event)])
        oversized = dict(f.event, summary='x' * (MAX_TEXT + 1 - len(base_render)))
        oversized_render = f.r.render(f.p, [({'renudge': False}, oversized)])
        self.assertEqual(len(oversized_render), MAX_TEXT + 1)

        f.stage(new=[oversized])
        f.deliver(events=[oversized])
        overflow_text = json.loads(f.output.getvalue())['hookSpecificOutput']['additionalContext']
        self.assertEqual(overflow_text, '\n'.join((f.r.PREFIX, f.r.OWNER, f.r.OVERFLOW)))
        self.assertEqual([row['key'] for row in f.state_data()['items']], [f.event['key']])

    def fetch(self, result):
        f = self.f
        ev = f.p.event_module()
        requests = []
        def opened(request, timeout):
            requests.append((json.loads(request.data), timeout))
            return io.BytesIO(result)
        with mock.patch.dict(os.environ, {'DRSG_API': 'http://127.0.0.1:1/rpc',
                'DRSG_PLANE': 'synthetic', 'DRSG_TOKEN': 'synthetic'}, clear=True), \
                mock.patch.object(ev.drsg_rpc, '_urlopen', side_effect=opened):
            out = f.r.fetch_events(f.p, f.project, [f.event['key']], time.monotonic() + 1)
        return out, requests

    def test_rpc_contract(self):
        f = self.f
        result = {'result': {'nodes': [{'external_key': f.event['key'], 'properties': f.event}]}}
        out, requests = self.fetch(json.dumps(result).encode())
        self.assertEqual(out, [f.event])
        body, timeout = requests[0]
        self.assertEqual(body['method'], 'plane.cypher')
        self.assertEqual(body['params']['params'], {'path': f.project, 'keys': [f.event['key']]})
        self.assertIn("e.status = 'open'", body['params']['query'])
        self.assertGreater(timeout, 0); self.assertLessEqual(timeout, 1)

    def test_rpc_bad_result_is_not_closed(self):
        for data in (b'{', b'{"error":{"message":"synthetic"}}', b'{"result":{}}', b'x' * 1048577):
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                self.fetch(data)

    def test_rpc_duplicate_keys_rejected(self):
        f = self.f
        node = {'external_key': f.event['key'], 'properties': f.event}
        with self.assertRaisesRegex(ValueError, 'duplicate Event key'):
            self.fetch(json.dumps({'result': {'nodes': [node, node]}}).encode())

    def test_atomic_capacity_gate(self):
        f = self.f
        f.stage(); before = Path(f.path).read_bytes()
        with self.assertRaisesRegex(ValueError, 'state capacity'):
            f.r.atomic(f.path, {'oversized': 'x' * 65536})
        self.assertEqual(Path(f.path).read_bytes(), before)

    def test_setup_registration_and_preservation(self):
        f = self.f
        root = Path(f.temp.name)
        home, config, memory = [root / name for name in ('home', 'config', 'memory')]
        config.mkdir(); home.mkdir()
        settings = config / 'settings.json'
        settings.write_text(json.dumps({'hooks': {'Stop': [{'matcher': '*', 'hooks': [
            {'type': 'command', 'command': 'true', 'timeout': 1}]}]}}))
        env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': str(home),
               'CLAUDE_CONFIG_DIR': str(config), 'DRSG_MEM_DIR': str(memory),
               'XDG_CONFIG_HOME': str(root / 'xdg')}
        tools = root / 'tools with spaces'
        command = ['bash', str(ROOT / 'setup.sh'), '--no-skills', '--tools-dir', str(tools)]
        for _ in range(2):
            run = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=30)
            self.assertEqual(run.returncode, 0, 'synthetic setup failed; inspect fixture locally')
        data = json.loads(settings.read_text())
        for event in ('PostToolUse', 'Stop', 'UserPromptSubmit'):
            matches = [(g, h) for g in data['hooks'][event] for h in g['hooks']
                       if 'event-wake-relay.py' in h['command']]
            self.assertEqual(len(matches), 1)
            group, hook = matches[0]
            self.assertEqual(group['matcher'], '*')
            self.assertEqual(shlex.split(hook['command']), ['python3', str(tools / 'event-wake-relay.py')])
            self.assertEqual(hook['type'], 'command'); self.assertEqual(hook['timeout'], 3)
            self.assertNotIn('asyncRewake', hook); self.assertNotIn('async', hook)
        self.assertTrue(any(h['command'] == 'true' for g in data['hooks']['Stop'] for h in g['hooks']))
        for event in ('SessionStart', 'Stop', 'StopFailure'):
            self.assertTrue(any(h.get('asyncRewake') for g in data['hooks'][event]
                                for h in g['hooks'] if 'event-poller.py' in h['command']))
        # The old opt-out is no-registration, not removal of existing hooks.
        config2 = root / 'disabled'; config2.mkdir()
        env['CLAUDE_CONFIG_DIR'] = str(config2)
        run = subprocess.run(command + ['--no-event-poller'], cwd=ROOT, env=env,
                             capture_output=True, timeout=30)
        self.assertEqual(run.returncode, 0)
        disabled = json.loads((config2 / 'settings.json').read_text())
        self.assertFalse(any('event-wake-relay.py' in h['command']
            for groups in disabled['hooks'].values() for g in groups for h in g['hooks']))

    def test_audit_each_registration_gate(self):
        f = self.f
        audit = cases.load('relay_audit', ROOT / 'tools/audit_deployment.py')
        root = Path(f.temp.name)
        config, repo, tools = [root / name for name in ('config', 'repo', 'tools')]
        for path in (config, repo, tools): path.mkdir()
        expected = 'python3 ' + shlex.quote(str(tools / 'event-wake-relay.py'))
        hooks = {event: [{'matcher': '*', 'hooks': [
            {'type': 'command', 'command': expected, 'timeout': 3}]}]
            for event in ('Stop', 'PostToolUse', 'UserPromptSubmit')}
        settings = config / 'settings.json'
        def issues(value):
            settings.write_text(json.dumps({'hooks': value})); settings.chmod(0o600)
            result = audit.check_layer2(str(repo), str(config), str(tools))
            return [line for line in result['details'] if 'Global Event relay' in line]
        self.assertEqual(issues(hooks), [])
        for event in hooks:
            for defect in ('missing', 'duplicate', 'matcher', 'timeout', 'asyncRewake', 'async', 'path'):
                altered = copy.deepcopy(hooks)
                group = altered[event][0]; hook = group['hooks'][0]
                if defect == 'missing': group['hooks'].clear()
                elif defect == 'duplicate': group['hooks'].append(dict(hook))
                elif defect == 'matcher': group['matcher'] = 'Read'
                elif defect == 'timeout': hook['timeout'] = 30
                elif defect in ('asyncRewake', 'async'): hook[defect] = True
                else: hook['command'] = 'python3 /different/event-wake-relay.py'
                with self.subTest(event=event, defect=defect):
                    self.assertEqual(issues(altered), [
                        'Global Event relay %s hook missing or misconfigured in settings.json' % event])


if __name__ == '__main__':
    unittest.main()

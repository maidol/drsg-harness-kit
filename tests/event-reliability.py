#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mcp_reliability_test', ROOT / 'tools/mcp_events.py')
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)
ev = mcp.ev
SENDER, TARGET, THIRD = '/synthetic/executor', '/synthetic/reviewer', '/synthetic/third'


class Graph:
    def __init__(self):
        self.events, self.notify, self.writes = {}, {}, []
        self.events['incoming'] = {'labels': ['Event'], 'properties': {
            'from_project': 'reviewer', 'from_path': TARGET, 'status': 'done'}}
        self.notify['incoming'] = SENDER
        self.events['mine'] = {'labels': ['Event'], 'properties': {
            'from_project': 'executor', 'from_path': SENDER, 'status': 'open'}}
        self.notify['mine'] = TARGET
        self.update_mode, self.node_mode, self.edge_mode = 'ok', 'ok', 'ok'

    def rpc(self, method, params, token):
        if method == 'plane.cypher':
            query, bound = params['query'], params.get('params', {})
            if query == 'MATCH (p:Project) RETURN p':
                return {'nodes': [{'id': 1, 'properties': {'path': TARGET}}]}
            if 'key(e) = $key' in query:
                key = bound['key']
                path = bound.get('path', bound.get('sender_path'))
                node = self.events.get(key)
                return {'nodes': [node] if node and (path is None or self.notify[key] == path) else []}
            if 'WHERE p.path = $path' in query:
                return {'nodes': []}
            raise BaseException('unexpected query')
        if method == 'node.create':
            self.writes.append((method, params))
            return {'id': 101} if self.node_mode == 'ok' else None
        if method == 'edge.create':
            self.writes.append((method, params))
            return {'id': 102} if self.edge_mode == 'ok' else None
        if method == 'node.delete':
            self.writes.append((method, params))
            return {'deleted': True}
        if method == 'node.update':
            self.writes.append((method, params))
            if self.update_mode == 'raise':
                raise RuntimeError('synthetic outage')
            node = self.events[params['key']]
            node['properties'].update(params['set'])
            return node
        raise BaseException('unexpected RPC method')


class TestProtocol(unittest.TestCase):
    def setUp(self):
        self.graph = Graph()
        for obj, name, value in ((mcp, '_project_dir', lambda: SENDER),
                                 (ev, 'rpc', self.graph.rpc), (ev, 'kick', lambda target: None),
                                 (ev, 'load_env', lambda project: None)):
            helper = patch.object(obj, name, value)
            helper.start()
            self.addCleanup(helper.stop)

    def frame(self, name, args):
        request = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                   'params': {'name': name, 'arguments': args}}
        captured = io.StringIO()
        with patch.dict(os.environ, {'DRSG_TOKEN': 'synthetic-fixture'}), \
                patch.object(sys, 'stdin', io.StringIO(json.dumps(request) + '\n')), \
                contextlib.redirect_stdout(captured):
            mcp.main()
        return json.loads(captured.getvalue())['result']

    def post_args(self, **changes):
        result = {'recipient': TARGET, 'summary': 'synthetic receipt'}
        result.update(changes)
        return result

    def test_error_frame_reports_both_fields_before_writes(self):
        result = self.frame('event_post', self.post_args(reply_to='missing', supersedes='incoming'))
        self.assertTrue(result['isError'])
        text = result['content'][0]['text']
        self.assertTrue(text.startswith('EVENT_POST_ERROR '), text)
        data = json.loads(text[len('EVENT_POST_ERROR '):])
        self.assertIs(data['posted'], False)
        self.assertFalse(data['retryable'])
        self.assertEqual([r['field'] for r in data['errors']], ['reply_to', 'supersedes'])
        self.assertEqual(self.graph.writes, [])

    def test_reply_uses_incoming_sender_and_never_closes_it(self):
        result = mcp.call_tool('event_reply', {'event_key': 'incoming', 'summary': 'synthetic receipt'}, 'fixture')
        self.assertTrue(result.startswith('posted '))
        self.assertEqual([m for m, _ in self.graph.writes], ['node.create', 'edge.create'])
        props = self.graph.writes[0][1]['properties']
        self.assertEqual(props['reply_to'], 'incoming')
        self.assertEqual(props['kind'], 'notice')
        self.assertNotIn('supersedes', props)
        self.assertNotIn('symbols', props)
        self.assertEqual(self.graph.events['incoming']['properties']['status'], 'done')

    def test_reply_rejects_own_missing_and_inconsistent_sources(self):
        for key in ('mine', 'absent'):
            with self.subTest(key=key):
                result = self.frame('event_reply', {'event_key': key, 'summary': 'synthetic'})
                self.assertTrue(result['isError'])
                self.assertEqual(self.graph.writes, [])
        self.graph.events['incoming']['properties']['from_project'] = 'third'
        result = self.frame('event_reply', {'event_key': 'incoming', 'summary': 'synthetic'})
        self.assertTrue(result['isError'])
        self.assertEqual(self.graph.writes, [])

    def test_reply_rejects_extra_fields_not_silently_discarded(self):
        for field in ('supersedes', 'recipient', 'symbols'):
            with self.subTest(field=field):
                result = self.frame('event_reply', {'event_key': 'incoming', 'summary': 'synthetic', field: 'mine'})
                self.assertTrue(result['isError'])
                self.assertIn('unexpected_field', result['content'][0]['text'])
                self.assertEqual(self.graph.writes, [])

    def test_valid_explicit_supersede_and_reply_remain_distinct(self):
        result = mcp.call_tool('event_post', self.post_args(reply_to='incoming', supersedes='mine'), 'fixture')
        self.assertIn('superseded mine: done', result)
        self.assertEqual(self.graph.events['mine']['properties']['status'], 'done')
        self.assertEqual(self.graph.events['incoming']['properties']['status'], 'done')

    def test_invalid_supersedes_is_not_silently_dropped(self):
        result = self.frame('event_post', self.post_args(reply_to='incoming', supersedes='incoming'))
        self.assertTrue(result['isError'])
        self.assertIn('supersedes', result['content'][0]['text'])
        self.assertEqual(self.graph.writes, [])

    def test_empty_optional_fields_remain_absent(self):
        mcp.call_tool('event_post', self.post_args(reply_to='', supersedes='', symbols=[]), 'fixture')
        props = self.graph.writes[0][1]['properties']
        self.assertNotIn('reply_to', props)
        self.assertNotIn('supersedes', props)

    def test_partial_delivery_is_not_an_unposted_error(self):
        self.graph.update_mode = 'raise'
        result = self.frame('event_post', self.post_args(supersedes='mine'))
        self.assertTrue(result['isError'])
        text = result['content'][0]['text']
        self.assertTrue(text.startswith('EVENT_POST_STATUS '), text)
        data = json.loads(text[len('EVENT_POST_STATUS '):])
        self.assertIs(data['posted'], True)
        self.assertFalse(data['retryable'])
        self.assertIn('key', data)
        self.assertEqual(data['unclosed'], 'mine')
        self.assertEqual(self.graph.events['mine']['properties']['status'], 'open')

    def test_missing_node_or_notify_never_claims_success(self):
        for field in ('node_mode', 'edge_mode'):
            with self.subTest(field=field):
                self.graph = Graph()
                setattr(self.graph, field, 'empty')
                with patch.object(ev, 'rpc', self.graph.rpc):
                    result = self.frame('event_post', self.post_args(supersedes='mine'))
                self.assertTrue(result['isError'])
                self.assertTrue(result['content'][0]['text'].startswith('EVENT_POST_STATUS '))
                self.assertEqual(self.graph.events['mine']['properties']['status'], 'open')
                calls = [name for name, _ in self.graph.writes]
                self.assertEqual(calls, ['node.create'] if field == 'node_mode' else ['node.create', 'edge.create', 'node.delete'])

    def test_rpc_failure_is_not_classified_as_bad_arguments(self):
        with patch.object(ev, 'rpc', side_effect=RuntimeError('SENSITIVE-SENTINEL')):
            result = self.frame('event_post', self.post_args(reply_to='incoming'))
        text = result['content'][0]['text']
        self.assertTrue(text.startswith('EVENT_POST_STATUS '), text)
        self.assertNotIn('SENSITIVE-SENTINEL', text)
        self.assertEqual(json.loads(text[len('EVENT_POST_STATUS '):])['posted'], 'unknown')

    def test_missing_and_ambiguous_symbols_remain_rejected(self):
        error = ev.AddressRejected('synthetic symbol failure', [{'symbol': 'new_symbol', 'why': 'missing', 'candidates': []}])
        with patch.object(ev, 'verify_symbols', side_effect=error), \
                patch.object(ev, 'telemetry', lambda *args: None):
            result = self.frame('event_post', self.post_args(symbols=['new_symbol'], plane='synthetic'))
        self.assertTrue(result['isError'])
        self.assertIn('invalid_symbols', result['content'][0]['text'])
        self.assertEqual(self.graph.writes, [])

    def test_wrong_types_are_not_coerced_into_absent_fields(self):
        for field, value in (('supersedes', False), ('reply_to', 0), ('summary', []), ('kind', 'unexpected')):
            with self.subTest(field=field):
                result = self.frame('event_post', self.post_args(**{field: value}))
                text = result['content'][0]['text']
                self.assertTrue(result['isError'])
                self.assertTrue(text.startswith('EVENT_POST_ERROR '), text)
                data = json.loads(text[len('EVENT_POST_ERROR '):])
                self.assertIs(data['posted'], False)
                self.assertEqual(data['errors'][0]['field'], field)
                self.assertEqual(data['errors'][0]['code'], 'invalid_argument')
                self.assertEqual(self.graph.writes, [])

    def test_hook_template_registers_both_phases(self):
        template = json.loads((ROOT / 'tools/templates/settings-hooks.json').read_text())
        expected = {'matcher': 'mcp__drsg-events__event_post|mcp__drsg-events__event_reply',
            'hooks': [{'type': 'command', 'command': '${CLAUDE_PROJECT_DIR}/.claude/hooks/event_retry_guard.py', 'timeout': 3}]}
        for phase in ('PreToolUse', 'PostToolUseFailure'):
            with self.subTest(phase=phase):
                self.assertEqual([row for row in template.get(phase, []) if row.get('matcher') == expected['matcher']], [expected])

    def test_schema_keeps_reply_small(self):
        entry = next(t for t in mcp.TOOLS if t['name'] == 'event_reply')
        self.assertEqual(set(entry['inputSchema']['properties']), {'event_key', 'summary', 'kind', 'ref'})
        self.assertFalse(entry['inputSchema']['additionalProperties'])


if __name__ == '__main__':
    unittest.main(verbosity=2)

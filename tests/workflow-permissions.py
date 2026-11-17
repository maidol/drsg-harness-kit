#!/usr/bin/env python3
"""Default workflow permissions, using synthetic files and no live services."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get('WORKFLOW_PERMISSIONS_SCRIPT', ROOT / 'tools/workflow_permissions.py'))
TOOLS = ('event_list', 'event_post', 'event_reply', 'event_done', 'event_take',
         'commit_auth_post', 'commit_auth_apply')
EXPECTED = ['mcp__drsg-events__' + name for name in TOOLS]
TMP_RULE = 'Edit(//tmp/**)'
TMP_TEXT = (
    '(drsg-harness-kit temporary-workspace) For a user-requested task, creating, reading and '
    'editing this task\'s temporary scripts, intermediate files, logs and results under /tmp '
    'is authorized without a separate confirmation of the output path. For sources the user '
    'has already authorized reading and analyzing, saving non-sensitive aggregate statistics '
    'and necessary locator metadata under /tmp is also authorized; do not include source '
    'bodies, tool arguments, credentials or personal data values. This does not authorize '
    'reading otherwise unauthorized sensitive sources, copying raw sensitive content, '
    'overwriting or deleting other tasks\' files, or following symlinks outside /tmp. '
    'A script located in /tmp is not automatically trusted to execute: its source and all '
    'effects, including network access, production operations, deployment, publishing and '
    'writes outside /tmp, remain subject to the existing rules. No blanket shell or '
    'interpreter permission is granted.')


class Permissions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='workflow-permissions-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.project = self.base / 'project'
        self.local = self.project / '.claude/settings.local.json'
        self.user = self.base / 'config/settings.json'
        self.local.parent.mkdir(parents=True)
        self.user.parent.mkdir()
        self.env = {**os.environ, 'HOME': str(self.base / 'home'),
                    'CLAUDE_CONFIG_DIR': str(self.user.parent),
                    'DRSG_MEM_DIR': str(self.base / 'memory'),
                    'XDG_CONFIG_HOME': str(self.base / 'xdg'), 'DRSG_EVENT_LANES': ''}

    def run_cli(self, action='apply', user=False):
        args = ['--user'] if user else ['--project', str(self.project)]
        return subprocess.run([sys.executable, '-I', str(SCRIPT), action, *args],
                              env=self.env, cwd=self.base, text=True, capture_output=True)

    def module(self):
        spec = importlib.util.spec_from_file_location('workflow_permissions', SCRIPT)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_fresh_project(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.local.read_text())['permissions']['allow'], EXPECTED)

    def test_project_merge(self):
        self.local.write_text(json.dumps({'permissions': {'allow': ['Read', EXPECTED[2]]},
                                         'hooks': {}, 'custom': {'keep': True}}))
        self.local.chmod(0o640)
        out = self.run_cli()
        self.assertEqual(out.returncode, 0, out.stderr)
        data = json.loads(self.local.read_text())
        self.assertEqual(data['permissions']['allow'], ['Read', EXPECTED[2]] +
                         [x for x in EXPECTED if x != EXPECTED[2]])
        self.assertEqual(data['custom'], {'keep': True})
        self.assertEqual(self.local.stat().st_mode & 0o777, 0o640)
        before = self.local.read_bytes(), self.local.stat().st_mtime_ns
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual((self.local.read_bytes(), self.local.stat().st_mtime_ns), before)
        self.assertEqual(self.run_cli('check').returncode, 0)

    def test_user_merge(self):
        data = {'autoMode': {'allow': ['$defaults', 'custom'], 'hard_deny': ['keep']},
                'permissions': {'allow': ['Read'], 'deny': ['Edit(//etc/**)']}, 'theme': 'dark'}
        self.user.write_text(json.dumps(data))
        self.user.chmod(0o600)
        out = self.run_cli(user=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        data['permissions']['allow'].append(TMP_RULE)
        data['autoMode']['allow'].append(TMP_TEXT)
        self.assertEqual(json.loads(self.user.read_text()), data)
        before = self.user.read_bytes(), self.user.stat().st_mtime_ns
        self.assertEqual(self.run_cli(user=True).returncode, 0)
        self.assertEqual((self.user.read_bytes(), self.user.stat().st_mtime_ns), before)
        self.assertEqual(self.run_cli('check', user=True).returncode, 0)

    def test_fresh_user_and_existing_empty_defaults(self):
        self.assertEqual(self.run_cli(user=True).returncode, 0)
        self.assertEqual(json.loads(self.user.read_text())['autoMode']['allow'], ['$defaults', TMP_TEXT])
        self.assertEqual(self.user.stat().st_mode & 0o777, 0o600)
        self.user.write_text('{"autoMode":{"allow":[]}}')
        self.assertEqual(self.run_cli(user=True).returncode, 0)
        self.assertEqual(json.loads(self.user.read_text())['autoMode']['allow'], [TMP_TEXT])

    def test_check_is_read_only_and_reports_every_missing_rule(self):
        self.local.write_text('{}')
        before = self.local.read_bytes(), self.local.stat().st_mtime_ns
        result = self.run_cli('check')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(), ['missing: ' + x for x in EXPECTED])
        self.assertEqual((self.local.read_bytes(), self.local.stat().st_mtime_ns), before)

    def test_conflicts_preserved_and_reported(self):
        for scope in ['ask', 'deny']:
            for rule in [EXPECTED[2], 'mcp__drsg-events__*', 'mcp__drsg-events', '*']:
                with self.subTest(scope=scope, rule=rule):
                    self.local.write_text(json.dumps({'permissions': {scope: [rule]}}))
                    result = self.run_cli()
                    self.assertEqual(result.returncode, 1)
                    self.assertIn('conflict: ' + scope + ' ' + EXPECTED[2], result.stdout.splitlines())
                    data = json.loads(self.local.read_text())
                    self.assertEqual(data['permissions'][scope], [rule])
                    self.assertEqual(data['permissions']['allow'], EXPECTED)
                    self.assertEqual(self.run_cli('check').returncode, 1)

    def test_tmp_conflict_and_stale_text(self):
        self.user.write_text(json.dumps({'permissions': {'ask': ['Edit']},
                            'autoMode': {'allow': ['custom', '(drsg-harness-kit temporary-workspace) old']}}))
        self.assertEqual(self.run_cli('check', user=True).returncode, 1)
        result = self.run_cli(user=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('conflict: ask ' + TMP_RULE, result.stdout.splitlines())
        self.assertEqual(json.loads(self.user.read_text())['autoMode']['allow'], ['custom', TMP_TEXT])

    def test_invalid_settings_unchanged(self):
        for value in ['[]', 'null', '{', '{"permissions":null}', '{"permissions":{"allow":"bad"}}',
                      '{"permissions":{"deny":[false]}}', '{"autoMode":null}',
                      '{"autoMode":{"allow":null}}', '{"autoMode":{"soft_deny":{}}}']:
            with self.subTest(value=value):
                self.user.write_text(value)
                result = self.run_cli(user=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.user.read_text(), value)
                self.assertEqual(result.stderr.splitlines(), ['workflow permissions: invalid settings'])

    def test_symlink_unchanged(self):
        target = self.base / 'other.json'
        target.write_text('{}')
        self.local.symlink_to(target)
        self.assertEqual(self.run_cli().returncode, 2)
        self.assertTrue(self.local.is_symlink())
        self.assertEqual(target.read_text(), '{}')

    def test_atomic_failure(self):
        mod = self.module()
        self.local.write_text('{}')
        with patch.object(mod.os, 'replace', side_effect=OSError('synthetic')):
            with self.assertRaises(OSError):
                mod.apply(self.local, user=False)
        self.assertEqual(self.local.read_text(), '{}')
        self.assertEqual(sorted(x.name for x in self.local.parent.iterdir()), ['settings.local.json'])

    def test_exact_constants_and_no_future_tool(self):
        mod = self.module()
        self.assertEqual(list(mod.EVENT_ALLOW), EXPECTED)
        self.assertEqual(mod.TMP_ALLOW, TMP_RULE)
        self.assertEqual(mod.TMP_POLICY, TMP_TEXT)
        self.assertNotIn('mcp__drsg-events__future_tool', mod.EVENT_ALLOW)

    def audit(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        self.addCleanup(sys.path.remove, str(ROOT / 'tools'))
        import audit_deployment
        return audit_deployment

    def test_audit_project_wiring(self):
        audit = self.audit()
        with patch.dict(os.environ, self.env):
            result = audit.check_layer4(str(self.project))
            self.assertIn('missing: ' + EXPECTED[2], result['details'])
            self.assertEqual(self.run_cli().returncode, 0)
            result = audit.check_layer4(str(self.project))
            self.assertFalse(any(x.startswith('missing: mcp__') for x in result['details']))

    def test_audit_user_wiring(self):
        audit = self.audit()
        result = audit.check_layer2(str(self.base), str(self.user.parent))
        self.assertIn('missing: ' + TMP_RULE, result['details'])
        self.assertEqual(self.run_cli(user=True).returncode, 0)
        result = audit.check_layer2(str(self.base), str(self.user.parent))
        self.assertNotIn('missing: ' + TMP_RULE, result['details'])
        self.assertNotIn('missing or stale: temporary-workspace autoMode policy', result['details'])

    def test_install_entrypoints(self):
        pairs = [('setup.sh', 'python3 "$TOOLS/workflow_permissions.py" apply --user'),
                 ('tools/install.sh', 'python3 "$SCRIPT_DIR/workflow_permissions.py" apply --project "$PROJECT_DIR"')]
        for source, command in pairs:
            with self.subTest(source=source):
                lines = (ROOT / source).read_text().splitlines()
                self.assertEqual(lines.count(command), 1)
                result = subprocess.run(['bash', '-eu', '-c', command], cwd=self.base,
                    env={**self.env, 'TOOLS': str(ROOT / 'tools'), 'SCRIPT_DIR': str(ROOT / 'tools'),
                         'PROJECT_DIR': str(self.project)}, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_cli('check').returncode, 0)
        self.assertEqual(self.run_cli('check', user=True).returncode, 0)

    def test_individual_project_drift(self):
        mod = self.module()
        for rule in EXPECTED:
            with self.subTest(rule=rule):
                data = {'permissions': {'allow': [x for x in EXPECTED if x != rule]}}
                self.assertEqual(mod.issues(data), ['missing: ' + rule])
                data['permissions']['allow'] = EXPECTED + [rule]
                self.assertEqual(mod.issues(data), ['duplicate: ' + rule])
                data['permissions']['allow'] = EXPECTED
                data['permissions']['deny'] = [rule]
                self.assertEqual(mod.issues(data), ['conflict: deny ' + rule])

    def test_individual_user_drift(self):
        mod = self.module()
        data = {'permissions': {'allow': [TMP_RULE]}, 'autoMode': {'allow': [TMP_TEXT]}}
        self.assertEqual(mod.issues(data, user=True), [])
        data['permissions']['allow'] = []
        self.assertEqual(mod.issues(data, user=True), ['missing: ' + TMP_RULE])
        data['permissions']['allow'] = [TMP_RULE]
        data['autoMode']['allow'] = []
        self.assertEqual(mod.issues(data, user=True),
                         ['missing or stale: temporary-workspace autoMode policy'])

    def test_invalid_nonwriting_field(self):
        self.user.write_text('{"permissions":{"deny":[false]}}')
        before = self.user.read_bytes()
        result = self.run_cli(user=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.user.read_bytes(), before)

    def test_duplicate_rules_repaired(self):
        self.local.write_text(json.dumps({'permissions': {'allow': EXPECTED + EXPECTED}}))
        self.assertEqual(self.run_cli('check').returncode, 1)
        self.assertEqual(self.run_cli().returncode, 0)
        self.assertEqual(json.loads(self.local.read_text())['permissions']['allow'], EXPECTED)


if __name__ == '__main__':
    unittest.main()

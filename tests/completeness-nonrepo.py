"""Synthetic repository-preflight contract tests; no daemon or user data."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

GUARD = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location('guard', GUARD)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
WARNING = 'WARN: completeness-guard skipped: --repo is not inside a Git repository.'
EMPTY = {'exit_code': 0, 'blockers': [], 'advisories': [], 'new_names_count': 0, 'declared': False}


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                        LC_ALL='C', LANGUAGE='C', HOME=str(self.root),
                        DRSG_EVENT_LANES='synthetic', EVENT_POLL_OWNER_PID='0')

    def cli(self, directory, *args):
        return subprocess.run([sys.executable, '-I', str(GUARD), '--repo', str(directory), *args],
                              cwd=self.root, env=self.env, capture_output=True, text=True)

    def invoke(self, outcome, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.dict(os.environ, self.env, clear=True))
            stack.enter_context(mock.patch.object(sys, 'argv', [str(GUARD), '--repo', str(self.root), *args]))
            runner = stack.enter_context(mock.patch.object(guard.subprocess, 'run', side_effect=outcome if isinstance(outcome, Exception) else None, return_value=outcome))
            for name in ('load_config', 'get_default_base', 'get_diff', 'get_diff_files'):
                stack.enter_context(mock.patch.object(guard, name, side_effect=AssertionError('followup called: ' + name)))
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            with self.assertRaises(SystemExit) as stopped:
                guard.main()
        return stopped.exception.code, out.getvalue(), err.getvalue(), runner

    def test_nonrepo_plain(self):
        result = self.cli(self.root)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, WARNING + '\n', ''))

    def test_nonrepo_json(self):
        result = self.cli(self.root, '--json', '--base', 'HEAD', '--staged')
        expected = {**EMPTY, 'advisories': [WARNING]}
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, '')
        self.assertEqual(result.stdout, json.dumps(expected, indent=2, ensure_ascii=False) + '\n')

    def test_no_followup_and_fixed_locale(self):
        outcome = subprocess.CompletedProcess([], 128, '', 'fatal: not a git repository (or any of the parent directories): .git\n')
        with mock.patch.dict(self.env, {'LC_ALL': 'synthetic_locale', 'LANGUAGE': 'synthetic_language'}):
            rc, out, err, runner = self.invoke(outcome)
        self.assertEqual((rc, out, err), (0, WARNING + '\n', ''))
        runner.assert_called_once()
        self.assertEqual(runner.call_args.args[0], ['git', '-C', str(self.root), 'rev-parse', '--git-dir'])
        self.assertEqual(runner.call_args.kwargs['env']['LC_ALL'], 'C')
        self.assertEqual(runner.call_args.kwargs['env']['LANGUAGE'], 'C')

    def test_other_git_errors(self):
        for message in ('fatal: detected dubious ownership in repository\n',
                        "fatal: not a git repository: '/synthetic/missing'\n"):
            with self.subTest(message=message):
                rc, out, err, runner = self.invoke(subprocess.CompletedProcess([], 128, '', message))
                self.assertEqual((rc, out, err), (1, '', message))
                runner.assert_called_once()

    def test_missing_git(self):
        rc, out, err, runner = self.invoke(FileNotFoundError('synthetic git missing'))
        self.assertEqual((rc, out, err), (1, '', 'ERROR: completeness-guard: synthetic git missing\n'))
        runner.assert_called_once()

    def test_no_diagnostic_git_error(self):
        rc, out, err, runner = self.invoke(subprocess.CompletedProcess([], 7, '', ''))
        self.assertEqual((rc, out, err), (1, '', 'ERROR: completeness-guard: repository check failed (exit 7).\n'))
        runner.assert_called_once()

    def test_valid_gitfile_and_subdirectory(self):
        project = self.root / 'project'
        commands = [
            ['git', 'init', '-q', '-b', 'main', '--separate-git-dir', str(self.root / 'metadata'), str(project)],
            ['git', '-C', str(project), 'add', 'README.md'],
            ['git', '-C', str(project), '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
             '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'fixture'],
        ]
        subprocess.run(commands[0], env=self.env, capture_output=True, text=True, check=True)
        (project / 'README.md').write_text('# fixture\n')
        for command in commands[1:]:
            subprocess.run(command, env=self.env, capture_output=True, text=True, check=True)
        self.assertTrue((project / '.git').is_file())
        child = project / 'nested'
        child.mkdir()
        for directory in (project, child):
            with self.subTest(directory=directory.name):
                result = self.cli(directory, '--base', 'HEAD', '--json')
                self.assertEqual((result.returncode, result.stderr), (0, ''))
                self.assertEqual(result.stdout, json.dumps(EMPTY, indent=2, ensure_ascii=False) + '\n')

    def test_bad_positional_argument(self):
        result = self.cli(self.root, 'unexpected-positional')
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr.splitlines()[-1], 'completeness-guard.py: error: unrecognized arguments: unexpected-positional')


if __name__ == '__main__':
    unittest.main()

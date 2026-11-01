#!/usr/bin/env bash
# Isolated apiKeyHelper contracts; no real settings, credentials, or gateways.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="${MODEL_AUTH_TOOLS:-$HERE/../tools}"
python3 - "$TOOLS" "$@" <<'PY'
import http.server
import json
import os
from pathlib import Path
import pty
import shlex
import subprocess
import sys
import tempfile
import termios
import threading
import time
import unittest

TOOLS = Path(sys.argv.pop(1)).resolve()
PROMPT = [
    "Model discovery: apiKeyHelper (project-local) runs a shell command with your user permissions.",
    "Review that settings file first; its command and output are hidden here.",
    "Run it once for this model query? [y/N]",
]
MENU = [
    "Model for this session (Enter = default from settings, Ctrl+C = cancel):",
    "  1) gateway/current[1m]",
    "  2) gateway/small",
]
STATIC = [MENU[0], "  1) opus", "  2) sonnet", "  3) haiku", "  4) fable"]


class Auth(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.project = self.root / "project"
        self.bin = self.root / "bin"
        for path in (self.home / ".claude", self.project / ".claude", self.bin):
            path.mkdir(parents=True)
        self.calls = []
        calls = self.calls

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                calls.append((self.path, self.headers.get("x-api-key"), self.headers.get("Authorization")))
                if self.path.startswith("/redirect/"):
                    self.send_response(302)
                    self.send_header("Location", "http://localhost:%d/sink" % self.server.server_port)
                    self.end_headers()
                    return
                if self.path.startswith("/deny/"):
                    self.send_response(401)
                    self.end_headers()
                    return
                if self.headers.get("x-api-key") != "fixture-helper" and self.headers.get("Authorization") != "Bearer fixture-token":
                    self.send_response(403)
                    self.end_headers()
                    return
                body = json.dumps({"data": [
                    {"id": "gateway/current", "max_input_tokens": 1000000},
                    {"id": "gateway/small"},
                ]}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    if self.path.startswith("/slow/"):
                        for i in range(4):
                            time.sleep(0.45)
                            self.wfile.write(body[len(body) * i // 4:len(body) * (i + 1) // 4])
                            self.wfile.flush()
                    else:
                        self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d" % self.server.server_port
        self.env = {
            "PATH": str(self.bin) + os.pathsep + str(Path(sys.executable).parent) + os.pathsep + os.defpath,
            "HOME": str(self.home), "LANG": "C.UTF-8",
            "CLAUDE_PICK_FORCE_TTY": "1", "CLAUDE_PICK_LANES": "0",
            "DRSG_EVENT_LANES": "fixture-lane",
        }
        fake = self.bin / "claude"
        fake.write_text('#!/bin/sh\nprintf "ARGS:%s\\n" "$*"\n')
        fake.chmod(0o755)
        self.marker = self.root / "helper-ran"
        self.command = "printf ran >> %s; printf 'fixture-helper\\n'" % shlex.quote(str(self.marker))
        self.settings()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def settings(self, helper=None, scope="local", **env):
        paths = {
            "user": self.home / ".claude/settings.json",
            "project": self.project / ".claude/settings.json",
            "local": self.project / ".claude/settings.local.json",
        }
        paths[scope].write_text(json.dumps({
            "apiKeyHelper": self.command if helper is None else helper,
            "env": {"ANTHROPIC_BASE_URL": self.url, **env},
        }))

    def pick(self, answer="y\n1\n", args=(), terminal=False):
        command = ["bash", "-c", '. "$1"; shift; claude "$@"', "_", str(TOOLS / "claude-model-picker.sh"), *args]
        start = time.monotonic()
        if terminal:
            master, slave = pty.openpty()
            attrs = termios.tcgetattr(slave)
            attrs[3] &= ~termios.ECHO
            termios.tcsetattr(slave, termios.TCSANOW, attrs)
            env = dict(self.env)
            env.pop("CLAUDE_PICK_FORCE_TTY", None)
            try:
                process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                                           cwd=self.project, env=env, text=True)
                os.write(master, answer.encode())
                _, stderr = process.communicate(timeout=5)
                stdout = os.read(master, 4096).decode().replace("\r\n", "\n")
                result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            finally:
                os.close(master)
                os.close(slave)
        else:
            result = subprocess.run(command, input=answer, capture_output=True, text=True,
                                    cwd=self.project, env=self.env, timeout=5)
        self.elapsed = time.monotonic() - start
        return result

    def test_accept_and_menu_input(self):
        result = self.pick("y\n2\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "ARGS:--model gateway/small\n")
        self.assertEqual(result.stderr.splitlines(), PROMPT + MENU)
        self.assertEqual(self.marker.read_text(), "ran")
        self.assertEqual(self.calls, [("/v1/models", "fixture-helper", "Bearer fixture-helper")])

    def test_real_terminal(self):
        result = self.pick("y\n2\n", terminal=True)
        self.assertEqual(result.stdout, "ARGS:--model gateway/small\n")
        self.assertEqual(result.stderr.splitlines(), PROMPT + MENU + ["> "])

    def test_reject_and_no_persisted_consent(self):
        for answer in ("n\n2\n", "\n2\n", "yes\n2\n", "x" * 30 + "\n2\n"):
            result = self.pick(answer)
            self.assertEqual(result.stdout, "ARGS:--model sonnet\n")
            self.assertEqual(result.stderr.splitlines(), PROMPT + STATIC)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.calls, [])
        self.assertEqual(self.pick().stderr.splitlines(), PROMPT + MENU)
        self.assertEqual(self.pick("n\n1\n").stderr.splitlines(), PROMPT + STATIC)
        self.assertEqual(self.marker.read_text(), "ran")

    def test_eof(self):
        for answer in ("", "y"):
            result = self.pick(answer)
            self.assertEqual(result.returncode, 130)
            self.assertFalse(self.marker.exists())
            self.assertEqual(self.calls, [])

    def test_noninteractive_and_bypasses(self):
        for args in (("--model", "haiku"), ("-p", "hi"), ("mcp", "list")):
            self.assertEqual(self.pick("", args=args).stderr, "")
        for key, value in (("CLAUDE_PICK_MODELS", "manual"), ("CLAUDE_PICK_MODEL", "0")):
            self.env[key] = value
            self.assertNotIn(PROMPT[0], self.pick("1\n").stderr.splitlines())
            del self.env[key]
        del self.env["CLAUDE_PICK_FORCE_TTY"]
        self.assertEqual(self.pick("1\n").stderr, "")
        direct = subprocess.run([sys.executable, str(TOOLS / "claude-model-discovery.py")],
                                cwd=self.project, env=self.env, input="y\n", capture_output=True, text=True, timeout=3)
        self.assertEqual((direct.returncode, direct.stdout, direct.stderr), (1, "", ""))
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.calls, [])

    def test_explicit_credentials_precede_helper(self):
        for values, headers in (
            ({"ANTHROPIC_API_KEY": "fixture-helper", "ANTHROPIC_AUTH_TOKEN": "fixture-token"}, ("fixture-helper", None)),
            ({"ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": "fixture-token"}, (None, "Bearer fixture-token")),
        ):
            self.settings(**values)
            result = self.pick("1\n")
            self.assertEqual(result.stderr.splitlines(), MENU)
            self.assertEqual(self.calls[-1][1:], headers)
        self.assertFalse(self.marker.exists())

    def test_scope_precedence_and_config_dir(self):
        for scope, label in (("user", "user"), ("project", "project"), ("local", "project-local")):
            self.settings(scope=scope)
            if scope != "local":
                (self.project / ".claude/settings.local.json").unlink(missing_ok=True)
            self.assertEqual(self.pick().stderr.splitlines()[0], PROMPT[0].replace("project-local", label))
        self.settings(helper=17)
        count = len(self.calls)
        result = self.pick("1\n")
        self.assertEqual(result.stderr.splitlines(), STATIC)
        self.assertEqual(self.marker.read_text(), "ranranran")
        self.assertEqual(len(self.calls), count)
        (self.project / ".claude/settings.local.json").unlink()
        (self.project / ".claude/settings.json").unlink()
        config = self.root / "config"
        config.mkdir()
        (config / "settings.json").write_text((self.home / ".claude/settings.json").read_text())
        self.env["CLAUDE_CONFIG_DIR"] = str(config)
        self.assertEqual(self.pick().stderr.splitlines()[0], PROMPT[0].replace("project-local", "user"))

    def test_invalid_and_absent_gateway_do_not_run_helper(self):
        for url in ("", "file:///tmp", "http://fixture@127.0.0.1"):
            self.settings(ANTHROPIC_BASE_URL=url)
            self.assertEqual(self.pick("1\n").stderr.splitlines(), STATIC)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.calls, [])

    def test_bad_output_and_exit(self):
        for command in ("printf ''", "printf 'fixture-helper'; exit 7", "printf 'one\\ntwo\\n'",
                        "printf 'with space'", "printf '\\033bad'", "printf '\\377'",
                        "printf 'fixture-helper\\r'", "printf 'fixture-helper\\n\\n'",
                        "printf 'fixture-helper\\nextra: injected'"):
            self.settings(helper=command)
            result = self.pick("y\n1\n")
            self.assertEqual(result.stdout, "ARGS:--model opus\n")
            self.assertEqual(result.stderr.splitlines(), PROMPT + STATIC)
        self.assertEqual(self.calls, [])

    def test_output_limit(self):
        command = "%s -c %s" % (shlex.quote(sys.executable), shlex.quote("import os; os.write(1, b'x' * 4097)"))
        self.settings(helper=command)
        result = self.pick()
        self.assertEqual(result.stderr.splitlines(), PROMPT + STATIC)
        self.assertEqual(self.calls, [])
        self.assertLess(self.elapsed, 2.8)

    def test_timeout_cleans_background_group(self):
        child = self.root / "child-done"
        self.settings(helper="(sleep 1.5; printf leaked > %s) & wait" % shlex.quote(str(child)))
        result = self.pick()
        self.assertEqual(result.stderr.splitlines(), PROMPT + STATIC)
        self.assertEqual(self.calls, [])
        self.assertLess(self.elapsed, 2.8)
        time.sleep(0.7)
        self.assertFalse(child.exists())

    def test_shared_deadline(self):
        self.settings(helper="sleep 0.6; printf fixture-helper", ANTHROPIC_BASE_URL=self.url + "/slow")
        result = self.pick()
        self.assertEqual(result.stderr.splitlines(), PROMPT + STATIC)
        self.assertLess(self.elapsed, 2.8)
        self.assertEqual(len(self.calls), 1)

    def test_failure_and_redirect_never_forward_credentials(self):
        for suffix in ("/deny", "/redirect"):
            self.settings(ANTHROPIC_BASE_URL=self.url + suffix)
            result = self.pick()
            self.assertEqual(result.stderr.splitlines(), PROMPT + STATIC)
        self.assertEqual([row[0] for row in self.calls], ["/deny/v1/models", "/redirect/v1/models"])

    def test_discovery_interrupt_starts_nothing(self):
        fake = self.bin / "python3"
        fake.write_text("#!/bin/sh\nexit 130\n")
        fake.chmod(0o755)
        result = self.pick("1\n")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (130, "", ""))
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.calls, [])

    def test_confirmation_wait_not_in_machine_budget(self):
        command = ["bash", "-c", '. "$1"; claude', "_", str(TOOLS / "claude-model-picker.sh")]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   cwd=self.project, env=self.env, text=True)
        prefix = [process.stderr.readline().rstrip("\n") for _ in PROMPT]
        time.sleep(2.1)
        stdout, stderr = process.communicate("y\n1\n", timeout=4)
        self.assertEqual(stdout, "ARGS:--model gateway/current[1m]\n")
        self.assertEqual(prefix + stderr.splitlines(), PROMPT + MENU)

    def test_helper_cannot_consume_menu_input(self):
        self.settings(helper="read ignored; printf fixture-helper")
        self.assertEqual(self.pick("y\n2\n").stdout, "ARGS:--model gateway/small\n")

    def test_crlf_output(self):
        self.settings(helper="printf 'fixture-helper\\r\\n'")
        self.assertEqual(self.pick().stdout, "ARGS:--model gateway/current[1m]\n")

    def test_cwd_and_merged_environment(self):
        self.settings(helper='test "$PWD" = %s && test "$HELPER_FIXTURE" = ready && printf fixture-helper' % shlex.quote(str(self.project)),
                      HELPER_FIXTURE="ready")
        result = self.pick("Y\n1\n")
        self.assertEqual(result.stdout, "ARGS:--model gateway/current[1m]\n")
        self.assertEqual(result.stderr.splitlines(), PROMPT + MENU)


unittest.main(verbosity=2)
PY

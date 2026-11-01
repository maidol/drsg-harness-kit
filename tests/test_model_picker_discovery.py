import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "claude_model_discovery", ROOT / "tools/claude-model-discovery.py"
)
DISCOVERY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DISCOVERY)


class Response:
    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return b'{"data":[{"id":"gateway/gpt6","display_name":"GPT 6","max_input_tokens":1000000}]}'


class Opener:
    def __init__(self):
        self.request = None

    def open(self, request, timeout):
        self.request = request
        return Response()


class TestDiscovery(unittest.TestCase):
    def test_capacity_integer_boundaries(self):
        valid = [1, 256000, 999999, 1000000, 2147483647]
        for value in valid:
            with self.subTest(value=value):
                self.assertEqual(DISCOVERY._valid_input_capacity(value), value)
        for value in [True, False, 0, -1, 2147483648, 1.0, "1000000", [], {}]:
            with self.subTest(value=value):
                self.assertIsNone(DISCOVERY._valid_input_capacity(value))

    def test_duplicate_conflict_both_orders(self):
        rows = [
            {"id": "gateway/dupe", "display_name": "Dupe", "max_input_tokens": 256000},
            {"id": "gateway/dupe", "display_name": "Dupe", "max_input_tokens": 1000000},
        ]
        expected = [("gateway/dupe", "Dupe [输入上限未知]")]
        self.assertEqual(DISCOVERY._normalize_models(rows), expected)
        self.assertEqual(DISCOVERY._normalize_models(rows[::-1]), expected)

    def test_same_id_valid_and_missing_keeps_valid_capacity(self):
        rows = [
            {"id": "gateway/known", "display_name": "Known", "max_input_tokens": 1000000},
            {"id": "gateway/known", "display_name": "Known"},
        ]
        self.assertEqual(DISCOVERY._normalize_models(rows), [
            ("gateway/known[1m]", "Known [输入上限 1,000,000]")
        ])

    def test_different_id_route_collision_with_missing_capacity_is_unknown(self):
        rows = [
            {"id": "gateway/collision", "display_name": "Collision", "max_input_tokens": 1000000},
            {"id": "gateway/collision[1m]", "display_name": "Collision"},
        ]
        expected = [("gateway/collision[1m]", "Collision [输入上限未知]")]
        self.assertEqual(DISCOVERY._normalize_models(rows), expected)
        self.assertEqual(DISCOVERY._normalize_models(rows[::-1]), expected)

    def test_c1_and_format_names_fall_back(self):
        rows = [
            {"id": "gateway/c1", "display_name": "bad\u0085name", "max_input_tokens": 256000},
            {"id": "gateway/bidi", "display_name": "bad‮name", "max_input_tokens": 256000},
        ]
        self.assertEqual(DISCOVERY._normalize_models(rows), [
            ("gateway/c1", "gateway/c1 [输入上限 256,000]"),
            ("gateway/bidi", "gateway/bidi [输入上限 256,000]"),
        ])

    def test_truncation_keeps_complete_utf8_and_capacity_suffix(self):
        name = "界" * 100
        [(route_id, label)] = DISCOVERY._normalize_models([
            {"id": "gateway/long", "display_name": name, "max_input_tokens": 1000000}
        ])
        self.assertEqual(route_id, "gateway/long[1m]")
        self.assertTrue(label.endswith(" [输入上限 1,000,000]"))
        self.assertLessEqual(len(label.encode("utf-8")), 160)
        label.removesuffix(" [输入上限 1,000,000]").encode("utf-8").decode("utf-8")

    def test_duplicate_labels_get_stable_short_route_ids(self):
        rows = [
            {"id": "gateway/a/one", "display_name": "Same", "max_input_tokens": 256000},
            {"id": "gateway/b/two", "display_name": "Same", "max_input_tokens": 256000},
        ]
        self.assertEqual(DISCOVERY._normalize_models(rows), [
            ("gateway/a/one", "Same [输入上限 256,000] (#1)"),
            ("gateway/b/two", "Same [输入上限 256,000] (#2)"),
        ])

    def test_duplicate_labels_unique_for_shared_tail_and_truncated_name(self):
        name = "Same" + "界" * 100
        rows = [
            {"id": "gateway/a/abcdefghijklmnop", "display_name": name,
             "max_input_tokens": 256000},
            {"id": "gateway/b/abcdefghijklmnop", "display_name": name,
             "max_input_tokens": 256000},
        ]
        prefix = "Same" + "界" * 35
        expected = {
            "gateway/a/abcdefghijklmnop": prefix + " [输入上限 256,000] (#1)",
            "gateway/b/abcdefghijklmnop": prefix + " [输入上限 256,000] (#2)",
        }
        for ordered_rows in (rows, rows[::-1]):
            actual = dict(DISCOVERY._normalize_models(ordered_rows))
            self.assertEqual(actual, expected)
            self.assertEqual(len(set(actual.values())), 2)
            self.assertTrue(all(len(label.encode("utf-8")) <= 160 for label in actual.values()))

    def test_json_surrogate_name_falls_back_without_dropping_rows(self):
        rows = json.loads(r'{"data":[{"id":"gateway/healthy","display_name":"Healthy","max_input_tokens":256000},{"id":"gateway/surrogate","display_name":"bad\ud800name","max_input_tokens":1000000}]}')["data"]
        self.assertEqual(DISCOVERY._normalize_models(rows), [
            ("gateway/healthy", "Healthy [输入上限 256,000]"),
            ("gateway/surrogate[1m]", "gateway/surrogate [输入上限 1,000,000]"),
        ])

    def test_max_tokens_is_not_input_capacity(self):
        self.assertEqual(DISCOVERY._normalize_models([
            {"id": "gateway/output-only", "display_name": "Output", "max_tokens": 1000000}
        ]), [("gateway/output-only", "Output [输入上限未知]")])

    def test_route_suffix_contract_is_independent(self):
        DISCOVERY._started_at = time.monotonic()
        opener = Opener()
        with mock.patch.object(DISCOVERY, "_opener_for", return_value=opener):
            result = DISCOVERY._read_models({"ANTHROPIC_API_KEY": "fixture-key"}, "http://localhost")
        self.assertEqual(result[0][0], "gateway/gpt6[1m]")

    def test_label_is_not_route_id(self):
        DISCOVERY._started_at = time.monotonic()
        opener = Opener()
        with mock.patch.object(DISCOVERY, "_opener_for", return_value=opener):
            result = DISCOVERY._read_models({"ANTHROPIC_API_KEY": "fixture-key"}, "http://localhost")
        self.assertEqual(result, [("gateway/gpt6[1m]", "GPT 6 [输入上限 1,000,000]")])

    def test_exact_client_user_agent(self):
        DISCOVERY._started_at = time.monotonic()
        opener = Opener()
        with mock.patch.object(DISCOVERY, "_opener_for", return_value=opener):
            DISCOVERY._read_models({"ANTHROPIC_API_KEY": "fixture-key"}, "http://localhost")
        self.assertEqual(opener.request.get_header("User-agent"), "claude-model-discovery/1")

    def test_ccr_menu_keeps_surrogate_row_and_separates_label_from_route(self):
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                user_agent = self.headers.get("User-Agent", "")
                requests.append(user_agent)
                if user_agent == "claude-model-discovery/1":
                    rows = [
                        {"id": "gateway/gpt6", "display_name": "GPT 6", "max_input_tokens": 1000000},
                        {"id": "gateway/surrogate", "display_name": "bad\ud800name", "max_input_tokens": 256000},
                    ]
                else:
                    rows = [{"id": "gateway/gpt6"}]
                body = json.dumps({"data": rows}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                home = root / "home"
                project = root / "project"
                bindir = root / "bin"
                (project / ".claude").mkdir(parents=True)
                bindir.mkdir()
                fake_claude = bindir / "claude"
                fake_claude.write_text("#!/bin/sh\nprintf 'ARGS:%s\\n' \"$*\"\n")
                fake_claude.chmod(0o755)
                url = "http://127.0.0.1:%d" % server.server_port
                (project / ".claude/settings.local.json").write_text(json.dumps({
                    "env": {"ANTHROPIC_BASE_URL": url, "ANTHROPIC_API_KEY": "fixture-key"}
                }))
                command = ["bash", "-c", '. "$1"; claude', "_", str(ROOT / "tools/claude-model-picker.sh")]
                env = {
                    "HOME": str(home), "PATH": str(bindir) + os.pathsep + os.defpath,
                    "LANG": "C.UTF-8", "CLAUDE_PICK_FORCE_TTY": "1",
                    "CLAUDE_PICK_LANES": "0",
                }
                result = subprocess.run(command, input="2\n", text=True, capture_output=True,
                                        cwd=project, env=env, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                menu = result.stderr.splitlines()
                self.assertIn("  1) GPT 6 [输入上限 1,000,000]", menu)
                self.assertIn("  2) gateway/surrogate [输入上限 256,000]", menu)
                self.assertEqual(result.stdout, "ARGS:--model gateway/surrogate\n")
                self.assertEqual(requests, ["claude-model-discovery/1"])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()

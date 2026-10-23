#!/usr/bin/env bash
# Contract tests for the shared Superpowers documentation setup module.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import hashlib
import importlib
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

repo = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(repo / "tools"))
superpowers_docs = importlib.import_module("superpowers_docs")


class SuperpowersDocsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.reviewer = self.root / "reviewer"
        self.reviewer.mkdir()
        self.project = self.root / "projects" / "alpha"
        self.project.mkdir(parents=True)
        self.env = {name: os.environ.get(name) for name in
                    ("XDG_CONFIG_HOME", "HOME", "DRSG_MEM_DIR", "DRSG_API", "DRSG_PLANE")}
        self.home = self.root / "home"
        self.home.mkdir()
        os.environ["HOME"] = str(self.home)
        self.config = self.home / ".drsg-memory" / "commit-auth.json"
        self.config.parent.mkdir()
        os.environ["DRSG_MEM_DIR"] = str(self.config.parent)
        self.config.write_text(json.dumps({"reviewer": str(self.reviewer), "ignored": "secret"}))
        self.xdg = self.root / "xdg"
        self.xdg.mkdir()
        os.environ["XDG_CONFIG_HOME"] = str(self.xdg)

    def tearDown(self):
        for name, value in self.env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def run_setup(self, *args):
        env = os.environ.copy()
        env["DRSG_API"] = "http://127.0.0.1:1/rpc"
        return subprocess.run(["bash", str(repo / "setup.sh"),
                               *[str(arg) for arg in args]],
                              capture_output=True, text=True, env=env,
                              timeout=15, check=False)

    def test_configured_reviewer_reads_only_absolute_existing_reviewer_and_realpaths(self):
        alias = self.root / "reviewer-link"
        alias.symlink_to(self.reviewer, target_is_directory=True)
        self.config.write_text(json.dumps({"reviewer": str(alias), "other": "must-not-be-used"}))
        self.assertEqual(superpowers_docs.configured_reviewer(str(self.config)), str(self.reviewer))

    def test_invalid_or_missing_reviewer_configuration_is_inactive(self):
        self.assertIsNone(superpowers_docs.configured_reviewer(str(self.root / "missing.json")))
        for data in ("not json", "{}", json.dumps({"reviewer": "relative/path"}),
                     json.dumps({"reviewer": str(self.root / "missing-dir")})):
            self.config.write_text(data)
            before = hashlib.sha256(self.config.read_bytes()).digest()
            with self.subTest(data=data):
                self.assertIsNone(superpowers_docs.configured_reviewer(str(self.config)))
                self.assertEqual(hashlib.sha256(self.config.read_bytes()).digest(), before)

    def test_project_slug_rejects_realpath_basename_collision(self):
        same_path = self.root / "alias-alpha"
        same_path.symlink_to(self.project, target_is_directory=True)
        self.assertEqual(superpowers_docs.project_slug(str(self.project), [str(same_path)]), "alpha")
        other = self.root / "other" / "alpha"
        other.mkdir(parents=True)
        self.assertIsNone(superpowers_docs.project_slug(str(self.project), [str(other)]))

    def test_project_symlink_and_dotdot_paths_resolve_to_the_same_identity(self):
        alias = self.root / "alpha-project-link"
        alias.symlink_to(self.project, target_is_directory=True)
        dotted = str(self.project.parent / "unused" / ".." / "alpha")
        self.assertEqual(superpowers_docs.project_slug(str(alias), [dotted]), "alpha")

    def test_known_project_conflict_fails_closed_without_writing_project_files(self):
        other = self.root / "elsewhere" / "alpha"
        other.mkdir(parents=True)
        result = superpowers_docs.install_project(str(self.project),
                                                  [str(self.project), str(other)])
        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "project-name-conflict")
        self.assertFalse((self.project / "CLAUDE.md").exists())
        self.assertFalse((self.project / ".claude/settings.local.json").exists())
        self.assertFalse((self.reviewer / "reviews/alpha").exists())

    def test_registry_failure_warns_but_continues_with_current_project(self):
        os.environ["DRSG_API"] = "http://127.0.0.1:1/rpc"
        result = superpowers_docs.install_project(str(self.project), None)
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["warning"], result)
        self.assertEqual(result["reason"], "registry-unavailable")

    def test_nul_project_list_detects_a_basename_collision(self):
        other = self.root / "other" / "alpha"
        other.mkdir(parents=True)
        projects = self.root / "projects.nul"
        projects.write_bytes((str(self.project) + "\0").encode() +
                             (str(other) + "\0").encode())
        result = superpowers_docs.install_project(str(self.project), str(projects))
        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "project-name-conflict")

    def test_render_block_uses_expanded_paths_and_independent_markers(self):
        block = superpowers_docs.render_block(str(self.reviewer), "alpha")
        self.assertIn("<!-- drsg-memory:superpowers-docs:begin -->", block)
        self.assertIn("<!-- drsg-memory:superpowers-docs:end -->", block)
        self.assertIn(str(self.reviewer / "reviews/alpha/docs/superpowers/specs/"), block)
        self.assertIn(str(self.reviewer / "reviews/alpha/docs/superpowers/plans/"), block)
        self.assertIn("旧文件不迁移", block)
        self.assertIn("优先于", block)

    def test_managed_block_append_refresh_and_remove_preserve_outside_bytes(self):
        path = self.project / "CLAUDE.md"
        path.write_bytes(b"before\n")
        first = superpowers_docs.render_block(str(self.reviewer), "alpha")
        self.assertTrue(superpowers_docs.update_managed_block(str(path), first))
        original = path.read_bytes()
        path.write_bytes(original + b"\n\nafter\n")
        original = path.read_bytes()
        self.assertTrue(superpowers_docs.update_managed_block(str(path), first))
        self.assertEqual(path.read_bytes(), original)
        moved = self.root / "reviewer-moved"
        moved.mkdir()
        second = superpowers_docs.render_block(str(moved), "alpha")
        self.assertTrue(superpowers_docs.update_managed_block(str(path), second))
        self.assertTrue(path.read_bytes().startswith(b"before\n"))
        self.assertTrue(path.read_bytes().endswith(b"\n\n\nafter\n"))
        self.assertIn(str(moved / "reviews/alpha/docs/superpowers/plans/"), path.read_text())
        self.assertTrue(superpowers_docs.update_managed_block(str(path), None))
        self.assertEqual(path.read_bytes(), b"before\n\n\nafter\n")

    def test_malformed_managed_markers_are_left_untouched(self):
        path = self.project / "CLAUDE.md"
        content = b"before\n<!-- drsg-memory:superpowers-docs:begin -->\nmanual\n"
        path.write_bytes(content)
        self.assertFalse(superpowers_docs.update_managed_block(
            str(path), superpowers_docs.render_block(str(self.reviewer), "alpha")))
        self.assertEqual(path.read_bytes(), content)

    def test_install_is_idempotent_preserves_user_permissions_and_records_private_ownership(self):
        settings = self.project / ".claude" / "settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"permissions": {
            "additionalDirectories": ["/user/dir"], "allow": ["Bash(echo user)"]},
            "hooks": {"SessionStart": [{"hooks": [{"command": "user-hook"}]}]}}))
        settings.chmod(0o640)
        result = superpowers_docs.install_project(str(self.project), [str(self.project)])
        self.assertTrue(result["ok"], result)
        first = settings.read_bytes()
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        self.assertEqual(settings.read_bytes(), first)
        data = json.loads(first)
        allowed = str(self.reviewer / "reviews/alpha/docs/superpowers")
        self.assertEqual(data["permissions"]["additionalDirectories"], ["/user/dir", allowed])
        self.assertEqual(data["permissions"]["allow"], ["Bash(echo user)"])
        self.assertIn("SessionStart", data["hooks"])
        self.assertEqual(stat.S_IMODE(settings.stat().st_mode), 0o640)
        self.assertTrue((self.reviewer / "reviews/alpha/docs/superpowers/specs").is_dir())
        self.assertTrue((self.reviewer / "reviews/alpha/docs/superpowers/plans").is_dir())
        record = self.xdg / "drsg/superpowers-docs-state" / (
            hashlib.sha256(os.path.realpath(self.project).encode()).hexdigest() + ".json")
        self.assertTrue(record.is_file())
        self.assertEqual(stat.S_IMODE(record.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(record.parent.stat().st_mode), 0o700)
        self.assertEqual(json.loads(record.read_text())["project"], os.path.realpath(self.project))
        self.assertEqual(json.loads(record.read_text())["allow"], allowed)

    def test_reviewer_change_removes_only_proven_old_allow(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"permissions": {"additionalDirectories": ["/user/dir"]}}))
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        moved = self.root / "reviewer-moved"
        moved.mkdir()
        self.config.write_text(json.dumps({"reviewer": str(moved)}))
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        values = json.loads(settings.read_text())["permissions"]["additionalDirectories"]
        self.assertEqual(values, ["/user/dir", str(moved / "reviews/alpha/docs/superpowers")])

    def test_missing_state_never_deletes_unowned_additional_directory(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        own = str(self.reviewer / "reviews/alpha/docs/superpowers")
        settings.write_text(json.dumps({"permissions": {"additionalDirectories": [own, "/user/dir"]}}))
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        self.assertEqual(json.loads(settings.read_text())["permissions"]["additionalDirectories"], [own, "/user/dir"])

    def test_mismatched_state_warns_and_never_deletes_unowned_allow(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"permissions": {
            "additionalDirectories": ["/user/old", "/user/dir"]}}))
        state_dir = self.xdg / "drsg/superpowers-docs-state"
        state_dir.mkdir(parents=True)
        state_path = state_dir / (hashlib.sha256(
            os.path.realpath(self.project).encode()).hexdigest() + ".json")
        state_path.write_text(json.dumps({"project": str(self.root / "wrong"),
                                         "reviewer": str(self.reviewer),
                                         "allow": "/user/old", "enabled": True}))
        result = superpowers_docs.install_project(str(self.project), [str(self.project)])
        self.assertTrue(result["warning"], result)
        values = json.loads(settings.read_text())["permissions"]["additionalDirectories"]
        self.assertIn("/user/old", values)
        self.assertIn("/user/dir", values)

    def test_inspect_reports_missing_state_without_exposing_config_contents(self):
        result = superpowers_docs.inspect_project(str(self.project), [str(self.project)])
        self.assertTrue(result["active"])
        self.assertTrue(result["warning"])
        self.assertEqual(result["reason"], "state-missing")
        self.assertNotIn("ignored", json.dumps(result))

    def test_settings_shape_failure_preserves_bytes(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        for content in (b"[]", b'{"permissions": []}', b'{"permissions": {"additionalDirectories": "bad"}'):
            settings.write_bytes(content)
            result = superpowers_docs.install_project(str(self.project), [str(self.project)])
            with self.subTest(content=content):
                self.assertFalse(result["settings_ok"])
                self.assertEqual(settings.read_bytes(), content)

    def test_hooks_merge_preserves_user_registration_and_adds_templates(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [
            {"command": "user-hook"}]}]}}))
        template = repo / "tools/templates/settings-hooks.json"
        result = superpowers_docs.install_project(str(self.project), [str(self.project)],
                                                  hooks_template=str(template))
        self.assertTrue(result["settings_ok"], result)
        hooks = json.loads(settings.read_text())["hooks"]
        commands = [hook.get("command") for groups in hooks.values() for group in groups
                    for hook in group.get("hooks", [])]
        self.assertIn("user-hook", commands)
        with template.open(encoding="utf-8") as stream:
            expected = json.load(stream)
        for groups in expected.values():
            for group in groups:
                self.assertIn(group["hooks"][0]["command"], commands)

    def test_invalid_settings_skip_hooks_and_leave_original_bytes(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        original = b"{invalid settings"
        settings.write_bytes(original)
        result = superpowers_docs.install_project(
            str(self.project), [str(self.project)],
            hooks_template=str(repo / "tools/templates/settings-hooks.json"))
        self.assertFalse(result["settings_ok"])
        self.assertEqual(settings.read_bytes(), original)
        self.assertFalse((self.project / "CLAUDE.md").exists())

    def test_settings_replace_failure_keeps_original_and_cleans_temporary_file(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        original = b'{"permissions": {"additionalDirectories": ["/user/dir"]}}\n'
        settings.write_bytes(original)
        template = str(repo / "tools/templates/settings-hooks.json")
        with mock.patch.object(superpowers_docs.os, "replace", side_effect=OSError("injected")):
            result = superpowers_docs.install_project(str(self.project), [str(self.project)],
                                                      hooks_template=template)
        self.assertFalse(result["settings_ok"])
        self.assertEqual(settings.read_bytes(), original)
        self.assertEqual(list(settings.parent.glob(".settings.local.json.*")), [])

    def test_settings_json_failure_preserves_bytes_and_warns_without_failure(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        content = b"{invalid settings"
        settings.write_bytes(content)
        result = superpowers_docs.install_project(str(self.project), [str(self.project)])
        self.assertFalse(result["settings_ok"])
        self.assertTrue(result["warning"])
        self.assertEqual(settings.read_bytes(), content)

    def test_opt_out_with_invalid_settings_removes_rule_and_retries_owned_allow_later(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"permissions": {"additionalDirectories": []}}))
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        original_allow = json.loads(settings.read_text())["permissions"]["additionalDirectories"][0]
        settings.write_bytes(b"{invalid settings")

        result = superpowers_docs.set_opt_out(str(self.project), True)
        self.assertFalse(result["settings_ok"])
        self.assertTrue(result["warning"])
        self.assertEqual(settings.read_bytes(), b"{invalid settings")
        self.assertNotIn("superpowers-docs:begin", (self.project / "CLAUDE.md").read_text())
        state, issue = superpowers_docs._read_state(str(self.project))
        self.assertIsNone(issue)
        self.assertTrue(state["opt_out"])
        self.assertEqual(state["allow"], original_allow)

        settings.write_text(json.dumps({"permissions": {"additionalDirectories": [original_allow]}}))
        self.assertTrue(superpowers_docs.set_opt_out(str(self.project), True)["ok"])
        self.assertEqual(json.loads(settings.read_text())["permissions"]["additionalDirectories"], [])

    def test_opt_out_removes_managed_rule_and_allow_but_keeps_archive_files(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"hooks": {"PreToolUse": [{"matcher": "Bash|Write"}]},
                                       "permissions": {"additionalDirectories": ["/user/dir"]}}))
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        archive = self.reviewer / "reviews/alpha/docs/superpowers/old-plan.md"
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_text("keep")
        self.assertTrue(superpowers_docs.set_opt_out(str(self.project), True)["ok"])
        still_opted_out = superpowers_docs.install_project(str(self.project), [str(self.project)])
        self.assertEqual(still_opted_out["reason"], "opted-out")
        self.assertNotIn("superpowers-docs:begin", (self.project / "CLAUDE.md").read_text())
        self.assertEqual(superpowers_docs.inspect_project(str(self.project), [str(self.project)])["reason"],
                         "opted-out")
        first_opt_out = settings.read_bytes()
        self.assertTrue(superpowers_docs.set_opt_out(str(self.project), True)["ok"])
        self.assertEqual(settings.read_bytes(), first_opt_out)
        self.assertEqual(json.loads(settings.read_text())["permissions"]["additionalDirectories"], ["/user/dir"])
        self.assertNotIn("superpowers-docs:begin", (self.project / "CLAUDE.md").read_text())
        self.assertTrue(archive.is_file())
        self.assertTrue(superpowers_docs.set_opt_out(str(self.project), False)["ok"])
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        self.assertIn("superpowers-docs:begin", (self.project / "CLAUDE.md").read_text())

    def test_setup_cli_opt_out_and_restore_are_standalone_and_preserve_archive(self):
        settings = self.project / ".claude/settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"permissions": {"additionalDirectories": ["/user/dir"]},
                                       "hooks": {"PreToolUse": [{"hooks": [{"command": "guard"}]}]}}))
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])
        archive_file = self.reviewer / "reviews/alpha/docs/superpowers/old.md"
        archive_file.write_text("keep")

        disabled = self.run_setup("--no-superpowers-docs", self.project)
        self.assertEqual(disabled.returncode, 0, disabled.stderr)
        self.assertNotIn("superpowers-docs:begin", (self.project / "CLAUDE.md").read_text())
        data = json.loads(settings.read_text())
        self.assertEqual(data["permissions"]["additionalDirectories"], ["/user/dir"])
        self.assertEqual(data["hooks"]["PreToolUse"][0]["hooks"][0]["command"], "guard")
        self.assertTrue(archive_file.is_file())

        restored = self.run_setup("--superpowers-docs", self.project)
        self.assertEqual(restored.returncode, 0, restored.stderr)
        self.assertIn("superpowers-docs:begin", (self.project / "CLAUDE.md").read_text())
        values = json.loads(settings.read_text())["permissions"]["additionalDirectories"]
        self.assertEqual(values, ["/user/dir", str(self.reviewer / "reviews/alpha/docs/superpowers")])

    def test_setup_rejects_all_projects_combined_with_superpowers_mode(self):
        result = self.run_setup("--all-projects", "--no-superpowers-docs", self.project)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Superpowers documentation options are standalone", result.stderr)

    def test_missing_reviewer_configuration_installs_no_rule_allow_or_state(self):
        self.config.unlink()
        result = superpowers_docs.install_project(str(self.project), [str(self.project)])
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["reason"], "reviewer-inactive")
        self.assertFalse((self.project / "CLAUDE.md").exists())
        self.assertFalse((self.project / ".claude/settings.local.json").exists())
        self.assertFalse((self.reviewer / "reviews").exists())
        self.assertFalse((self.xdg / "drsg").exists())

    def test_guard_reads_installer_state_end_to_end(self):
        hook = repo / "tools/templates/hooks/superpowers-doc-guard.py"
        self.assertTrue(superpowers_docs.install_project(str(self.project), [str(self.project)])["ok"])

        def decision(path):
            data = {"hook_event_name": "PreToolUse", "tool_name": "Write",
                    "tool_input": {"file_path": str(path), "content": "x"},
                    "cwd": str(self.project)}
            env = os.environ.copy()
            env["CLAUDE_PROJECT_DIR"] = str(self.project)
            run = subprocess.run([sys.executable, str(hook)], input=json.dumps(data),
                                 capture_output=True, text=True, env=env,
                                 cwd=self.project, timeout=15, check=False)
            self.assertEqual(run.returncode, 0, run.stderr)
            return "deny" if '"deny"' in run.stdout else "allow"

        self.assertEqual(decision(self.reviewer / "reviews/alpha/docs/superpowers/plans/x.md"), "allow")
        self.assertEqual(decision(self.reviewer / "reviews/beta/x.md"), "deny")
        self.assertTrue(superpowers_docs.set_opt_out(str(self.project), True)["ok"])
        self.assertEqual(decision(self.reviewer / "reviews/beta/x.md"), "allow")

    def test_reviewer_project_gets_own_rule_but_no_additional_directory(self):
        settings = self.reviewer / ".claude/settings.local.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"permissions": {"additionalDirectories": ["/user/dir"]}}))
        self.assertTrue(superpowers_docs.install_project(str(self.reviewer), [str(self.reviewer)])["ok"])
        self.assertIn(str(self.reviewer / "reviews/reviewer/docs/superpowers/specs/"),
                      (self.reviewer / "CLAUDE.md").read_text())
        self.assertEqual(json.loads(settings.read_text())["permissions"]["additionalDirectories"], ["/user/dir"])


suite = unittest.defaultTestLoader.loadTestsFromTestCase(SuperpowersDocsTests)
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
PY

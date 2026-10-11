#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import hashlib
import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

repo = sys.argv[1]
tools = os.path.join(repo, "tools")
os.environ["CLAUDE_PROJECT_DIR"] = repo
os.environ["DRSG_TOKEN"] = "fake-token"
sys.argv = [os.path.join(tools, "mcp_events.py"), repo]


def load(name):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(tools, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mcp_events = load("mcp_events")


def strip_git_args(argv):
    offset = 5 if argv[3:5] == ["-c", "core.hooksPath=/dev/null"] else 3
    return argv[offset:]


def _test_git_env(index_dir):
    env = os.environ.copy()
    env["GIT_LITERAL_PATHSPECS"] = "1"
    env["GIT_INDEX_FILE"] = os.path.join(index_dir, "index")
    return env


class CommitAuthTests(unittest.TestCase):
    def make_git_repo(self, path):
        os.makedirs(path)
        subprocess.run(["git", "-C", path, "init", "-q", "-b", "main"], check=True)
        subprocess.run(["git", "-C", path, "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", path, "config", "user.email", "test@example.invalid"], check=True)
        return path

    def setUp(self):
        self.old_git_config_global = os.environ.get("GIT_CONFIG_GLOBAL")
        self.old_git_config_nosystem = os.environ.get("GIT_CONFIG_NOSYSTEM")
        os.environ["GIT_CONFIG_GLOBAL"] = os.devnull
        os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
        self.addCleanup(self.restore_git_config)
        self.mcp = mcp_events
        self.ev = mcp_events.ev
        self.original_rpc = self.ev.rpc
        self.original_kick = self.ev.kick
        self.addCleanup(setattr, self.ev, "rpc", self.original_rpc)
        self.addCleanup(setattr, self.ev, "kick", self.original_kick)
        config_dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, config_dir)
        self.reviewer_config = os.path.join(config_dir, "commit-auth.json")
        pathlib.Path(self.reviewer_config).write_text(
            '{"reviewer": "%s"}' % repo, encoding="utf-8")
        self.addCleanup(setattr, self.mcp, "COMMIT_AUTH_CONFIG",
                        getattr(self.mcp, "COMMIT_AUTH_CONFIG", None))
        self.mcp.COMMIT_AUTH_CONFIG = self.reviewer_config

    def restore_git_config(self):
        if self.old_git_config_global is None:
            os.environ.pop("GIT_CONFIG_GLOBAL", None)
        else:
            os.environ["GIT_CONFIG_GLOBAL"] = self.old_git_config_global
        if self.old_git_config_nosystem is None:
            os.environ.pop("GIT_CONFIG_NOSYSTEM", None)
        else:
            os.environ["GIT_CONFIG_NOSYSTEM"] = self.old_git_config_nosystem

    def auth_event(self, **changes):
        props = {
            "kind": "handoff",
            "status": "open",
            "tree": "a" * 40,
            "parent": "b" * 40,
            "target_branch": "main",
            "files": ["change.txt"],
            "force_paths": [],
            "message": "docs: test commit authorization",
            "from_path": repo,
        }
        props["summary"] = "验收通过并授权提交：tree " + props["tree"][:12]
        props.update(changes)
        return {"labels": ["Event"], "external_key": "evt-test",
                "properties": props}

    def stub_auth_graph(self, event=None, projects=None):
        event = event or self.auth_event()
        projects = projects or [{
            "labels": ["Project"],
            "properties": {"path": repo},
        }]
        calls = []

        def rpc(method, params, token):
            calls.append((method, params))
            if method == "plane.cypher":
                query = params["query"]
                if "MATCH (e:Event)" in query:
                    return {"nodes": [event]}
                if "MATCH (p:Project)<-[:NOTIFY]-(e:Event)" in query:
                    path = params["params"]["path"]
                    return {"nodes": [event] if any(
                        (project.get("properties") or {}).get("path") == path
                        for project in projects) else []}
            raise AssertionError("unexpected graph call: %s" % method)

        self.ev.rpc = rpc
        return calls

    def test_active_hook_inventory_uses_only_effective_hooks_path(self):
        with tempfile.TemporaryDirectory() as temp:
            target = self.make_git_repo(os.path.join(temp, "repo"))
            default_hooks = os.path.join(target, ".git", "hooks")
            os.makedirs(default_hooks, exist_ok=True)
            bad = os.path.join(default_hooks, "pre-commit")
            pathlib.Path(bad).write_text("#!/bin/sh\\nexit 1\\n")
            os.chmod(bad, 0o755)
            custom = os.path.join(temp, "custom-hooks")
            os.makedirs(custom)
            known = os.path.join(custom, "pre-commit")
            shutil.copy(os.path.join(repo, ".githooks", "pre-commit"), known)
            os.chmod(known, 0o755)
            subprocess.run(["git", "-C", target, "config", "core.hooksPath",
                            "../custom-hooks"], check=True)
            self.mcp._check_commit_hooks(target)
            subprocess.run(["git", "-C", target, "config", "core.hooksPath",
                            default_hooks], check=True)
            self.assertEqual(self.mcp._effective_hooks_dir(target),
                             os.path.realpath(default_hooks))
            hook_stat = os.stat(bad)
            self.assertTrue(hook_stat.st_mode & 0o111)
            digest = hashlib.sha256(pathlib.Path(bad).read_bytes()).hexdigest()
            self.assertNotIn(digest, self.mcp.ALLOWED_COMMIT_HOOK_SHA256["pre-commit"])
            with self.assertRaisesRegex(ValueError, "pre-commit"):
                self.mcp._check_commit_hooks(target)

    def test_commit_hook_allowlist_handles_default_dir_symlinks_and_inactive_files(self):
        with tempfile.TemporaryDirectory() as temp:
            target = self.make_git_repo(os.path.join(temp, "repo"))
            hooks = os.path.join(target, ".git", "hooks")
            os.makedirs(hooks, exist_ok=True)
            ignored = os.path.join(hooks, "pre-commit")
            pathlib.Path(ignored).write_text("#!/bin/sh\\nexit 1\\n")
            os.chmod(ignored, 0o644)
            pathlib.Path(os.path.join(hooks, "commit-msg.sample")).write_text(
                "#!/bin/sh\\nexit 1\\n")
            os.chmod(os.path.join(hooks, "commit-msg.sample"), 0o755)
            self.mcp._check_commit_hooks(target)
            executable = os.path.join(hooks, "post-commit")
            pathlib.Path(executable).write_text("#!/bin/sh\\nexit 0\\n")
            os.chmod(executable, 0o755)
            with self.assertRaisesRegex(ValueError, "post-commit"):
                self.mcp._check_commit_hooks(target)

    def test_commit_hook_inventory_resolves_symlinks_and_allows_known_hook_hash(self):
        with tempfile.TemporaryDirectory() as temp:
            target = self.make_git_repo(os.path.join(temp, "repo"))
            hooks = os.path.join(temp, "hooks")
            os.makedirs(hooks, exist_ok=True)
            real = os.path.join(temp, "real-hook")
            pathlib.Path(real).write_text("#!/bin/sh\\nexit 0\\n")
            os.chmod(real, 0o755)
            os.symlink(real, os.path.join(hooks, "pre-commit"))
            subprocess.run(["git", "-C", target, "config", "core.hooksPath", hooks], check=True)
            with self.assertRaisesRegex(ValueError, "pre-commit.*real-hook"):
                self.mcp._check_commit_hooks(target)

            os.unlink(os.path.join(hooks, "pre-commit"))
            canonical = os.path.join(hooks, "pre-commit")
            shutil.copy(os.path.join(repo, ".githooks", "pre-commit"), canonical)
            os.chmod(canonical, 0o755)
            self.mcp._check_commit_hooks(target)

    def test_installed_guard_hook_hash_is_path_normalized_and_pinned(self):
        installer = os.path.join(tools, "install-precommit-guard.sh")
        with tempfile.TemporaryDirectory() as temp:
            for number in ("one", "two"):
                target = self.make_git_repo(os.path.join(temp, "repo-" + number))
                tool_dir = os.path.join(temp, "tool-dir-" + number)
                result = subprocess.run(["bash", installer, target, tool_dir],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.mcp._check_commit_hooks(target)
                hook = os.path.join(target, ".git", "hooks", "pre-commit")
                self.assertEqual(self.mcp._normalized_guard_hook_sha(hook),
                                 "65990fe9d7a89cc7d9681b8e47eecb23efd364860bdce0523f67027e8cd2a66e")
                with open(hook, "ab") as stream:
                    stream.write(b"# one byte mutation\\n")
                with self.assertRaisesRegex(ValueError, "pre-commit"):
                    self.mcp._check_commit_hooks(target)

    def test_only_effective_core_hooks_path_is_scanned(self):
        with tempfile.TemporaryDirectory() as temp:
            target = self.make_git_repo(os.path.join(temp, "repo"))
            default_hook = os.path.join(target, ".git", "hooks", "pre-commit")
            pathlib.Path(default_hook).write_text("#!/bin/sh\\nexit 1\\n")
            os.chmod(default_hook, 0o755)
            custom_dir = os.path.join(target, "custom hooks")
            os.makedirs(custom_dir)
            custom_hook = os.path.join(custom_dir, "pre-commit")
            shutil.copy(os.path.join(repo, ".githooks", "pre-commit"), custom_hook)
            os.chmod(custom_hook, 0o755)
            subprocess.run(["git", "-C", target, "config", "core.hooksPath",
                            "custom hooks"], check=True)
            self.mcp._check_commit_hooks(target)
            subprocess.run(["git", "-C", target, "config", "--unset",
                            "core.hooksPath"], check=True)
            with self.assertRaisesRegex(ValueError, "pre-commit"):
                self.mcp._check_commit_hooks(target)

    def test_default_hook_directory_ignores_non_executable_and_sample(self):
        with tempfile.TemporaryDirectory() as temp:
            target = self.make_git_repo(os.path.join(temp, "repo"))
            hooks = os.path.join(target, ".git", "hooks")
            nonexec = os.path.join(hooks, "pre-commit")
            pathlib.Path(nonexec).write_text("#!/bin/sh\\nexit 1\\n")
            os.chmod(nonexec, 0o644)
            sample = os.path.join(hooks, "commit-msg.sample")
            pathlib.Path(sample).write_text("#!/bin/sh\\nexit 1\\n")
            os.chmod(sample, 0o755)
            self.mcp._check_commit_hooks(target)

    def test_hook_symlink_is_checked_by_target_content(self):
        with tempfile.TemporaryDirectory() as temp:
            target = self.make_git_repo(os.path.join(temp, "repo"))
            hooks = os.path.join(temp, "hooks")
            os.makedirs(hooks)
            real = os.path.join(temp, "real-hook")
            pathlib.Path(real).write_text("#!/bin/sh\\nexit 0\\n")
            os.chmod(real, 0o755)
            os.symlink(real, os.path.join(hooks, "pre-commit"))
            subprocess.run(["git", "-C", target, "config", "core.hooksPath", hooks],
                           check=True)
            with self.assertRaisesRegex(ValueError, "pre-commit.*real-hook"):
                self.mcp._check_commit_hooks(target)

    def test_checked_in_precommit_sha_is_allowlisted(self):
        with tempfile.TemporaryDirectory() as temp:
            target = self.make_git_repo(os.path.join(temp, "repo"))
            hook_dir = os.path.join(target, ".githooks")
            os.makedirs(hook_dir)
            hook = os.path.join(hook_dir, "pre-commit")
            shutil.copy(os.path.join(repo, ".githooks", "pre-commit"), hook)
            os.chmod(hook, 0o755)
            subprocess.run(["git", "-C", target, "config", "core.hooksPath", ".githooks"],
                           check=True)
            self.assertEqual(hashlib.sha256(pathlib.Path(hook).read_bytes()).hexdigest(),
                             "5538848d332cf420f7d745ba7b2f4429e9f0dde9604e9ad4df11c3335a5bb3a9")
            self.mcp._check_commit_hooks(target)
            pathlib.Path(hook).write_bytes(pathlib.Path(hook).read_bytes() + b"# changed\\n")
            with self.assertRaisesRegex(ValueError, "pre-commit"):
                self.mcp._check_commit_hooks(target)

    def test_installed_guard_hook_is_normalized_and_allowlisted(self):
        installer = os.path.join(tools, "install-precommit-guard.sh")
        normalized = []
        with tempfile.TemporaryDirectory() as temp:
            for name in ("first", "second"):
                target = self.make_git_repo(os.path.join(temp, "repo-" + name))
                tool_dir = os.path.join(temp, "runtime-" + name, "tools")
                result = subprocess.run(["bash", installer, target, tool_dir],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                hook = os.path.join(target, ".git", "hooks", "pre-commit")
                digest = self.mcp._normalized_guard_hook_sha(hook)
                normalized.append(digest)
                self.assertEqual(digest,
                    "65990fe9d7a89cc7d9681b8e47eecb23efd364860bdce0523f67027e8cd2a66e")
                self.mcp._check_commit_hooks(target)
                pathlib.Path(hook).write_bytes(pathlib.Path(hook).read_bytes() + b"# changed\\n")
                with self.assertRaisesRegex(ValueError, "pre-commit"):
                    self.mcp._check_commit_hooks(target)
        self.assertEqual(normalized[0], normalized[1])

    def git(self, repo_path, *args, env=None):
        return subprocess.run(["git", "-C", repo_path, *args], env=env,
                              check=True, capture_output=True, text=True).stdout.strip()

    def temp_commit_repo(self, root):
        path = os.path.join(root, "repo")
        self.make_git_repo(path)
        pathlib.Path(path, "base.txt").write_text("base\\n")
        self.git(path, "add", "--", "base.txt")
        self.git(path, "commit", "-m", "base")
        pathlib.Path(path, "change.txt").write_text("authorized change\\n")
        parent = self.git(path, "rev-parse", "HEAD")
        with tempfile.TemporaryDirectory() as index_dir:
            env = _test_git_env(index_dir)
            self.git(path, "read-tree", parent, env=env)
            self.git(path, "add", "--", "change.txt", env=env)
            tree = self.git(path, "write-tree", env=env)
        return path, parent, tree

    def set_apply_event(self, path, parent, tree, message="feat: authorized test",
                        files=None, force_paths=None):
        event = self.auth_event(parent=parent, tree=tree,
                                summary="验收通过并授权提交：tree " + tree[:12],
                                files=files or ["change.txt"],
                                force_paths=force_paths or [], message=message)
        projects = [{"labels": ["Project"],
                     "properties": {"path": path}}]
        self.stub_auth_graph(event, projects)
        old_argv = sys.argv
        sys.argv = [old_argv[0], path]
        self.addCleanup(setattr, sys, "argv", old_argv)
        return event

    def test_apply_refuses_untrusted_active_hook_before_formal_index_change(self):
        with tempfile.TemporaryDirectory() as temp:
            path, parent, tree = self.temp_commit_repo(temp)
            parent_tree = self.git(path, "rev-parse", parent + "^{tree}")
            self.assertEqual(self.git(path, "write-tree"), parent_tree)
            self.set_apply_event(path, parent, tree)
            hooks = os.path.join(path, ".git", "hooks")
            hook = os.path.join(hooks, "pre-commit")
            marker = os.path.join(temp, "hook-ran")
            pathlib.Path(hook).write_text("#!/bin/sh" + chr(10) +
                                          "touch " + marker + chr(10))
            os.chmod(hook, 0o755)
            before_index = self.git(path, "write-tree")
            with self.assertRaisesRegex(ValueError, "not allowlisted.*pre-commit"):
                self.mcp.call_tool("commit_auth_apply", {
                    "event_key": "evt-test"}, "fake-token")
            self.assertEqual(self.git(path, "write-tree"), before_index)
            self.assertEqual(self.git(path, "rev-parse", "HEAD"), parent)
            self.assertFalse(os.path.exists(marker))

    def test_apply_rejects_post_index_change_hook_before_it_runs(self):
        with tempfile.TemporaryDirectory() as temp:
            path, parent, tree = self.temp_commit_repo(temp)
            self.set_apply_event(path, parent, tree)
            hooks = os.path.join(path, ".git", "hooks")
            hook = os.path.join(hooks, "post-index-change")
            marker = os.path.join(temp, "post-index-change-ran")
            pathlib.Path(hook).write_text("#!/bin/sh" + chr(10) +
                                          "touch " + marker + chr(10))
            os.chmod(hook, 0o755)
            before_index = self.git(path, "write-tree")
            with self.assertRaisesRegex(ValueError, "not allowlisted.*post-index-change"):
                self.mcp.call_tool("commit_auth_apply", {
                    "event_key": "evt-test"}, "fake-token")
            self.assertFalse(os.path.exists(marker))
            self.assertEqual(self.git(path, "write-tree"), before_index)
            self.assertEqual(self.git(path, "rev-parse", "HEAD"), parent)

    def test_precommit_failure_preserves_output_and_does_not_create_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            path = self.make_git_repo(os.path.join(temp, "repo"))
            pathlib.Path(path, ".completeness.json").write_text(
                '{"require_code_block": false}' + chr(10))
            pathlib.Path(path, "README.md").write_text("# Test" + chr(10))
            self.git(path, "add", "--", ".completeness.json", "README.md")
            self.git(path, "commit", "-m", "base")
            parent = self.git(path, "rev-parse", "HEAD")
            file_path = "change.sh"
            pathlib.Path(path, file_path).write_text(
                "#!/usr/bin/env bash" + chr(10) +
                'case "$1" in' + chr(10) +
                "  --hidden-flag) ;;" + chr(10) + "esac" + chr(10))
            tool_dir = os.path.join(temp, "runtime", "tools")
            result = subprocess.run(["bash", os.path.join(tools, "install-precommit-guard.sh"),
                                     path, tool_dir], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            with tempfile.TemporaryDirectory() as index_dir:
                env = _test_git_env(index_dir)
                self.git(path, "read-tree", parent, env=env)
                self.git(path, "add", "--", file_path, env=env)
                tree = self.git(path, "write-tree", env=env)
            message = "feat: add an undocumented option"
            self.set_apply_event(path, parent, tree, message, files=[file_path])
            with self.assertRaisesRegex(ValueError, "COV|documentation|doc") as raised:
                self.mcp.call_tool("commit_auth_apply", {
                    "event_key": "evt-test"}, "fake-token")
            self.assertEqual(self.git(path, "rev-parse", "HEAD"), parent)
            self.assertIn("--hidden-flag", str(raised.exception))

    def test_apply_verifies_parent_tree_and_exact_message_after_commit(self):
        with tempfile.TemporaryDirectory() as temp:
            path, parent, tree = self.temp_commit_repo(temp)
            parent_tree = self.git(path, "rev-parse", parent + "^{tree}")
            self.assertEqual(self.git(path, "write-tree"), parent_tree)
            message = "feat: exact authorized message"
            self.set_apply_event(path, parent, tree, message)
            result = self.mcp.call_tool("commit_auth_apply", {
                "event_key": "evt-test"}, "fake-token")
            self.assertIn("git rev-parse HEAD^:", result)
            self.assertIn("git rev-parse HEAD^{tree}:", result)
            self.assertIn("git cat-file commit HEAD message:", result)
            self.assertEqual(self.git(path, "rev-parse", "HEAD^"), parent)
            self.assertEqual(self.git(path, "rev-parse", "HEAD^{tree}"), tree)
            raw = subprocess.run(["git", "-C", path, "cat-file", "commit", "HEAD"],
                                 check=True, capture_output=True, text=True).stdout
            body = raw.split("\n\n", 1)[1]
            self.assertEqual(body, message + "\n")
            self.assertEqual(self.git(path, "status", "--porcelain"), "")

    def test_commit_auth_tools_have_narrow_schemas(self):
        tools_by_name = {tool["name"]: tool for tool in mcp_events.TOOLS}
        post = tools_by_name["commit_auth_post"]["inputSchema"]
        self.assertEqual(set(post["properties"]), {
            "recipient", "tree", "parent", "target_branch", "files", "force_paths", "message"})
        self.assertEqual(set(post["required"]), set(post["properties"]))
        apply = tools_by_name["commit_auth_apply"]["inputSchema"]
        self.assertEqual(set(apply["properties"]), {"event_key"})
        self.assertEqual(apply["required"], ["event_key"])

    def test_apply_rejects_untrusted_arguments_before_graph_read(self):
        calls = self.stub_auth_graph()
        with self.assertRaisesRegex(ValueError, "event_key only"):
            self.mcp.call_tool("commit_auth_apply", {
                "event_key": "evt-test", "tree": "a" * 40}, "fake-token")
        self.assertEqual(calls, [])

    def test_apply_rejects_closed_or_mismatched_authorization_event(self):
        legacy = self.auth_event()
        del legacy["properties"]["target_branch"]
        missing = self.auth_event()
        del missing["properties"]["force_paths"]
        cases = [
            (self.auth_event(status="done"), repo, "status must be open"),
            (self.auth_event(kind="notice"), repo, "kind must be handoff"),
            (self.auth_event(summary="验收通过并授权提交：tree " + "c" * 12),
             repo, "summary tree prefix mismatch"),
            (legacy, repo, "target_branch missing; ask the reviewer to reissue"),
            (missing, repo, "commit authorization fields are incomplete"),
            (self.auth_event(), os.path.join(repo, "other-project"),
             "recipient path mismatch"),
        ]
        for event, path, error in cases:
            with self.subTest(status=event["properties"]["status"],
                              kind=event["properties"]["kind"], path=path):
                self.stub_auth_graph(event, [{
                    "labels": ["Project"], "properties": {"path": path}}])
                with self.assertRaisesRegex(ValueError, error):
                    self.mcp.call_tool("commit_auth_apply", {
                        "event_key": "evt-test"}, "fake-token")

    def test_apply_rejects_wrong_branch_and_detached_head_before_index_change(self):
        for mode, expected_error in (("other", "current branch does not match target_branch"),
                                     ("detached", "detached HEAD")):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                path, parent, tree = self.temp_commit_repo(temp)
                self.set_apply_event(path, parent, tree)
                if mode == "other":
                    self.git(path, "branch", "other")
                    self.git(path, "checkout", "other")
                else:
                    self.git(path, "checkout", "--detach", parent)
                before = self.git(path, "write-tree")
                with self.assertRaisesRegex(ValueError, expected_error):
                    self.mcp.call_tool("commit_auth_apply", {
                        "event_key": "evt-test"}, "fake-token")
                self.assertEqual(self.git(path, "write-tree"), before)
                self.assertEqual(self.git(path, "rev-parse", "HEAD"), parent)

    def test_commit_auth_post_accepts_non_default_valid_target_branch(self):
        with tempfile.TemporaryDirectory() as target:
            created = []
            def rpc(method, params, token):
                if method == "plane.cypher":
                    return {"nodes": [{"id": 2, "labels": ["Project"],
                                       "properties": {"path": target}}]}
                if method == "node.create":
                    created.append(params)
                    return {"id": 1}
                if method == "edge.create":
                    return {"id": 2}
                raise AssertionError("unexpected graph method: %s" % method)
            self.ev.rpc = rpc
            self.ev.kick = lambda path: None
            auth = {"recipient": target, "tree": "a" * 40, "parent": "b" * 40,
                    "target_branch": "feature/local", "files": ["change.txt"],
                    "force_paths": [], "message": "docs: target branch"}

            def run(argv, **kwargs):
                git_args = strip_git_args(argv)
                if git_args == ["check-ref-format", "--branch", "feature/local"]:
                    output = "feature/local\n"
                elif git_args == ["rev-parse", "--show-toplevel"]:
                    output = target + "\n"
                elif git_args == ["cat-file", "-e", "b" * 40 + "^{commit}"]:
                    output = ""
                elif git_args == ["rev-parse", "--verify", "refs/heads/feature/local"]:
                    output = "b" * 40 + "\n"
                elif git_args == ["read-tree", "b" * 40]:
                    output = ""
                elif git_args == ["add", "--", "change.txt"]:
                    output = ""
                elif git_args == ["write-tree"]:
                    output = "a" * 40 + "\n"
                else:
                    output = ""
                return type("Result", (), {"returncode": 0, "stdout": output,
                                            "stderr": ""})()

            with patch("subprocess.run", side_effect=run):
                result = self.mcp.call_tool("commit_auth_post", auth, "fake-token")
            self.assertIn("posted", result)
            self.assertIn("目标分支：feature/local", created[0]["properties"]["ref"])
            self.assertEqual(created[0]["properties"]["target_branch"], "feature/local")

    def test_commit_auth_post_rejects_branch_ref_not_at_authorized_parent(self):
        with tempfile.TemporaryDirectory() as target:
            calls = []
            self.ev.rpc = lambda method, params, token: (
                calls.append(method) or {"nodes": [{"id": 2,
                    "labels": ["Project"], "properties": {"path": target}}]})
            args = {"recipient": target, "tree": "a" * 40,
                    "parent": "b" * 40, "target_branch": "main",
                    "files": ["change.txt"], "force_paths": [],
                    "message": "docs: test branch mismatch"}

            def run(argv, **kwargs):
                args = strip_git_args(argv)
                if args == ["rev-parse", "--show-toplevel"]:
                    output = target + "\n"
                elif args == ["check-ref-format", "--branch", "main"]:
                    output = "main\n"
                elif args == ["cat-file", "-e", "b" * 40 + "^{commit}"]:
                    output = ""
                elif args == ["rev-parse", "--verify", "refs/heads/main"]:
                    output = "c" * 40 + "\n"
                else:
                    output = ""
                return type("Result", (), {"returncode": 0, "stdout": output,
                                            "stderr": ""})()

            with patch("subprocess.run", side_effect=run):
                with self.assertRaisesRegex(ValueError, "branch ref.*parent"):
                    self.mcp.call_tool("commit_auth_post", args, "fake-token")
            self.assertEqual(calls, ["plane.cypher"])

    def test_commit_auth_post_rejects_invalid_force_paths_before_side_effects(self):
        calls = []
        self.ev.rpc = lambda method, params, token: calls.append(method)
        args = {
            "recipient": os.path.join(repo, "target"),
            "tree": "a" * 40,
            "parent": "b" * 40,
            "target_branch": "main",
            "files": ["change.txt"],
            "force_paths": ["ignored.txt"],
            "message": "docs: test commit authorization",
        }
        with self.assertRaisesRegex(ValueError, "force_paths must be a subset"):
            self.mcp.call_tool("commit_auth_post", args, "fake-token")
        self.assertEqual(calls, [])

    def test_commit_auth_post_suppresses_recipient_post_index_change_hook(self):
        with tempfile.TemporaryDirectory() as temp:
            target, parent, tree = self.temp_commit_repo(temp)
            hooks = os.path.join(target, ".git", "hooks")
            hook = os.path.join(hooks, "post-index-change")
            marker = os.path.join(temp, "post-index-change-ran")
            pathlib.Path(hook).write_text("#!/bin/sh" + chr(10) +
                                          "touch " + marker + chr(10))
            os.chmod(hook, 0o755)
            created = []

            def rpc(method, params, token):
                if method == "plane.cypher":
                    return {"nodes": [{"id": 2, "labels": ["Project"],
                                       "properties": {"path": target}}]}
                if method == "node.create":
                    created.append(params)
                    return {"id": 1}
                if method == "edge.create":
                    return {"id": 2}
                raise AssertionError("unexpected graph method: %s" % method)

            self.ev.rpc = rpc
            self.ev.kick = lambda path: None
            auth = {"recipient": target, "tree": tree, "parent": parent,
                    "target_branch": "main", "files": ["change.txt"],
                    "force_paths": [], "message": "docs: safe temporary index"}
            self.mcp.call_tool("commit_auth_post", auth, "fake-token")
            self.assertFalse(os.path.exists(marker))
            self.assertEqual(created[0]["properties"]["tree"], tree)

    def test_preflight_tree_mismatch_does_not_touch_real_index(self):
        self.stub_auth_graph(self.auth_event(target_branch="main"))
        git_calls = []

        def run(args, **kwargs):
            env = kwargs.get("env") or {}
            git_calls.append((args, env))
            git_args = strip_git_args(args)
            if git_args == ["check-ref-format", "--branch", "main"]:
                stdout = "main\n"
            elif git_args == ["rev-parse", "--show-toplevel"]:
                stdout = repo + "\n"
            elif git_args == ["rev-parse", "HEAD"]:
                stdout = "b" * 40 + "\n"
            elif git_args == ["branch", "--show-current"]:
                stdout = "main\n"
            elif git_args == ["rev-parse", "--verify", "refs/heads/main"]:
                stdout = "b" * 40 + "\n"
            elif git_args == ["rev-parse", "b" * 40 + "^{tree}"]:
                stdout = "d" * 40 + "\n"
            elif git_args == ["write-tree"]:
                stdout = ("c" * 40 if env.get("GIT_INDEX_FILE") else
                          "d" * 40) + "\n"
            elif git_args == ["config", "--path", "--get", "core.hooksPath"]:
                return type("Result", (), {"returncode": 1, "stdout": "",
                                            "stderr": ""})()
            else:
                stdout = ""
            return type("Result", (), {"returncode": 0, "stdout": stdout,
                                        "stderr": ""})()

        with patch("subprocess.run", side_effect=run):
            with self.assertRaisesRegex(ValueError, "preflight tree mismatch"):
                self.mcp.call_tool("commit_auth_apply", {
                    "event_key": "evt-test"}, "fake-token")
        index_writes = {"add", "read-tree", "update-index", "reset"}
        self.assertTrue(all(env.get("GIT_INDEX_FILE")
                            for args, env in git_calls
                            if strip_git_args(args)[:1] and
                            strip_git_args(args)[0] in index_writes))

    def test_commit_auth_post_rejects_bad_sha_and_signature_before_graph_read(self):
        calls = []
        self.ev.rpc = lambda method, params, token: calls.append(method)
        base = {
            "recipient": os.path.join(repo, "target"),
            "tree": "a" * 40,
            "parent": "b" * 40,
            "target_branch": "main",
            "files": ["change.txt"],
            "force_paths": [],
            "message": "docs: test commit authorization",
        }
        cases = [
            ({"tree": "not-a-sha"}, "tree must be 40 lowercase hex chars"),
            ({"target_branch": "bad branch"}, "target_branch must be a valid branch"),
            ({"message": "docs: test\nCo-Authored-By: Example"},
             "signature trailers are not allowed"),
        ]
        for update, error in cases:
            args = dict(base)
            args.update(update)
            with self.subTest(update=update), self.assertRaisesRegex(ValueError, error):
                self.mcp.call_tool("commit_auth_post", args, "fake-token")
        self.assertEqual(calls, [])

    def test_commit_auth_post_recomputes_tree_and_persists_structured_event(self):
        with tempfile.TemporaryDirectory() as target:
            graph_calls = []
            created = []

            def rpc(method, params, token):
                graph_calls.append(method)
                if method == "plane.cypher":
                    return {"nodes": [{"id": 2, "labels": ["Project"],
                                       "properties": {"path": target}}]}
                if method == "node.create":
                    created.append(params)
                    return {"id": 1}
                if method == "edge.create":
                    return {"id": 2}
                raise AssertionError("unexpected graph call: %s" % method)

            self.ev.rpc = rpc
            self.ev.kick = lambda path: None
            auth = {
                "tree": "a" * 40,
                "parent": "b" * 40,
                "target_branch": "main",
                "files": ["change.txt", "ignored.txt"],
                "force_paths": ["ignored.txt"],
                "message": "docs: test commit authorization",
            }
            git_calls = []

            def run(args, **kwargs):
                env = kwargs.get("env") or {}
                git_calls.append((args, env))
                git_args = strip_git_args(args)
                stdout = target + "\n" if git_args == ["rev-parse", "--show-toplevel"] else ""
                if git_args == ["check-ref-format", "--branch", "main"]:
                    stdout = "main\n"
                elif git_args == ["rev-parse", "--verify", "refs/heads/main"]:
                    stdout = auth["parent"] + "\n"
                elif git_args == ["write-tree"]:
                    stdout = auth["tree"] + "\n"
                return type("Result", (), {"returncode": 0, "stdout": stdout,
                                            "stderr": ""})()

            with patch("subprocess.run", side_effect=run):
                result = self.mcp.call_tool("commit_auth_post", {
                    "recipient": target, **auth}, "fake-token")
            self.assertIn("git write-tree", result)
            self.assertEqual(graph_calls, ["plane.cypher", "node.create", "edge.create"])
            props = created[0]["properties"]
            for field, value in auth.items():
                self.assertEqual(props[field], value)
            self.assertIn("目标分支：main", created[0]["properties"]["ref"])
            add_calls = [(strip_git_args(args), env) for args, env in git_calls
                         if strip_git_args(args)[:1] == ["add"]]
            self.assertIn((["add", "--", "change.txt"], add_calls[0][1]), add_calls)
            self.assertIn((["add", "-f", "--", "ignored.txt"], add_calls[1][1]), add_calls)
            self.assertTrue(all(env.get("GIT_INDEX_FILE") for _, env in add_calls))

    def test_post_tree_mismatch_does_not_publish_event(self):
        with tempfile.TemporaryDirectory() as target:
            graph_calls = []

            def rpc(method, params, token):
                graph_calls.append(method)
                if method == "plane.cypher":
                    return {"nodes": [{"id": 2, "labels": ["Project"],
                                       "properties": {"path": target}}]}
                raise AssertionError("Event write must not happen on mismatch")

            self.ev.rpc = rpc
            auth = {
                "tree": "a" * 40,
                "parent": "b" * 40,
                "target_branch": "main",
                "files": ["change.txt"],
                "force_paths": [],
                "message": "docs: test commit authorization",
            }

            def run(args, **kwargs):
                git_args = strip_git_args(args)
                stdout = target + "\n" if git_args == ["rev-parse", "--show-toplevel"] else ""
                if git_args == ["check-ref-format", "--branch", "main"]:
                    stdout = "main\n"
                elif git_args == ["rev-parse", "--verify", "refs/heads/main"]:
                    stdout = "b" * 40 + "\n"
                elif git_args == ["cat-file", "-e", "b" * 40 + "^{commit}"]:
                    stdout = ""
                elif git_args == ["write-tree"]:
                    stdout = "c" * 40 + "\n"
                return type("Result", (), {"returncode": 0, "stdout": stdout,
                                            "stderr": ""})()

            with patch("subprocess.run", side_effect=run):
                with self.assertRaisesRegex(ValueError, "recomputed tree"):
                    self.mcp.call_tool("commit_auth_post", {
                        "recipient": target, **auth}, "fake-token")
            self.assertEqual(graph_calls, ["plane.cypher"])

    def test_apply_uses_event_authorization_once_without_closing_event(self):
        with tempfile.TemporaryDirectory() as target:
            auth = self.auth_event()["properties"]
            projects = [{"labels": ["Project"],
                         "properties": {"path": target}}]
            graph_calls = self.stub_auth_graph(self.auth_event(), projects)
            old_argv = sys.argv
            sys.argv = [old_argv[0], target]
            self.addCleanup(setattr, sys, "argv", old_argv)
            state = {"committed": False, "staged": False, "commits": 0}

            def run(args, **kwargs):
                env = kwargs.get("env") or {}
                git_args = strip_git_args(args)
                if git_args == ["check-ref-format", "--branch", "main"]:
                    stdout = "main\n"
                elif git_args == ["config", "--path", "--get", "core.hooksPath"]:
                    return type("Result", (), {"returncode": 1, "stdout": "",
                                                "stderr": ""})()
                elif git_args == ["rev-parse", "--show-toplevel"]:
                    stdout = target + "\n"
                elif git_args == ["rev-parse", "--git-path", "hooks"]:
                    stdout = ".git/hooks\n"
                elif git_args == ["rev-parse", "HEAD"]:
                    stdout = ("c" * 40 if state["committed"] else auth["parent"]) + "\n"
                elif git_args == ["branch", "--show-current"]:
                    stdout = "main\n"
                elif git_args in (["rev-parse", "refs/heads/main"],
                                  ["rev-parse", "--verify", "refs/heads/main"]):
                    stdout = ("c" * 40 if state["committed"] else auth["parent"]) + "\n"
                elif git_args == ["rev-parse", auth["parent"] + "^{tree}"]:
                    stdout = "d" * 40 + "\n"
                elif git_args == ["rev-parse", "HEAD^"]:
                    stdout = auth["parent"] + "\n"
                elif git_args == ["rev-parse", "HEAD^{tree}"]:
                    stdout = auth["tree"] + "\n"
                elif git_args == ["cat-file", "commit", "HEAD"]:
                    stdout = "tree %s\nparent %s\nauthor A <a@b> 1 +0000\ncommitter A <a@b> 1 +0000\n\n%s\n" % (auth["tree"], auth["parent"], auth["message"])
                elif git_args == ["write-tree"]:
                    staged = state["staged"] and not env.get("GIT_INDEX_FILE")
                    formal = auth["tree"] if staged else "d" * 40
                    stdout = (auth["tree"] if env.get("GIT_INDEX_FILE") else formal) + "\n"
                elif git_args == ["symbolic-ref", "--short", "HEAD"]:
                    stdout = "main\n"
                elif git_args[:1] == ["commit"]:
                    self.assertEqual(git_args, ["commit", "--cleanup=verbatim", "-m", auth["message"]])
                    # Key check only: a failing assertNotIn on env would print every value.
                    self.assertFalse("GIT_LITERAL_PATHSPECS" in env,
                                     "commit must not pass GIT_LITERAL_PATHSPECS to hooks")
                    state["committed"] = True
                    state["commits"] += 1
                    stdout = ""
                elif git_args[:1] == ["add"]:
                    if not env.get("GIT_INDEX_FILE"):
                        state["staged"] = True
                    stdout = ""
                else:
                    stdout = ""
                return type("Result", (), {"returncode": 0, "stdout": stdout,
                                            "stderr": ""})()

            with patch("subprocess.run", side_effect=run):
                result = self.mcp.call_tool("commit_auth_apply", {
                    "event_key": "evt-test"}, "fake-token")
                self.assertIn("HEAD^{tree}", result)
                # The executor learns where the receipt goes without reading the config.
                self.assertIn('receipt: post kind="notice" to %s with reply_to=evt-test'
                              % os.path.realpath(repo), result)
                with self.assertRaisesRegex(ValueError, "target branch ref does not match authorized parent"):
                    self.mcp.call_tool("commit_auth_apply", {
                        "event_key": "evt-test"}, "fake-token")
            self.assertEqual(state["commits"], 1)
            self.assertEqual([method for method, _ in graph_calls],
                             ["plane.cypher", "plane.cypher"] * 2)

    def post_args(self, target):
        return {"recipient": target, "tree": "a" * 40, "parent": "b" * 40,
                "target_branch": "main", "files": ["change.txt"],
                "force_paths": [], "message": "docs: test commit authorization"}

    def test_commit_auth_tools_are_off_without_reviewer_config(self):
        for content in (None, "not json", '{"reviewer": "relative/path"}', "[]"):
            with self.subTest(content=content):
                if content is None:
                    os.remove(self.reviewer_config)
                else:
                    pathlib.Path(self.reviewer_config).write_text(content, encoding="utf-8")
                calls = self.stub_auth_graph()
                with patch("subprocess.run", side_effect=AssertionError("git must not run")):
                    with self.assertRaisesRegex(ValueError, "commit authorization tools are off"):
                        self.mcp.call_tool("commit_auth_apply", {
                            "event_key": "evt-test"}, "fake-token")
                    with self.assertRaisesRegex(ValueError, "commit authorization tools are off"):
                        self.mcp.call_tool("commit_auth_post", self.post_args(
                            os.path.join(repo, "other")), "fake-token")
                self.assertEqual(calls, [])

    def test_commit_auth_post_refuses_outside_reviewer_project(self):
        with tempfile.TemporaryDirectory() as other:
            pathlib.Path(self.reviewer_config).write_text(
                '{"reviewer": "%s"}' % other, encoding="utf-8")
            calls = self.stub_auth_graph()
            with patch("subprocess.run", side_effect=AssertionError("git must not run")):
                with self.assertRaisesRegex(ValueError, "only run in the configured reviewer project"):
                    self.mcp.call_tool("commit_auth_post", self.post_args(other), "fake-token")
            self.assertEqual(calls, [])

    def test_apply_refuses_authorization_not_sent_by_reviewer(self):
        missing = self.auth_event()
        del missing["properties"]["from_path"]
        for event in (self.auth_event(from_path=os.path.join(repo, "other-project")),
                      missing):
            with self.subTest(from_path=event["properties"].get("from_path")):
                self.stub_auth_graph(event)
                with patch("subprocess.run", side_effect=AssertionError("git must not run")):
                    with self.assertRaisesRegex(ValueError, "not sent by the configured reviewer"):
                        self.mcp.call_tool("commit_auth_apply", {
                            "event_key": "evt-test"}, "fake-token")

    def test_event_post_stores_commit_fields_before_notify_edge(self):
        ev = mcp_events.ev
        calls = []
        ev.rpc = lambda method, params, token: (
            calls.append((method, params.copy())) or
            ({"id": 1} if method == "node.create" else {"id": 2}))
        ev.kick = lambda target: None
        authorization = {
            "tree": "a" * 40,
            "parent": "b" * 40,
            "target_branch": "main",
            "files": ["change.txt"],
            "force_paths": [],
            "message": "docs: test commit authorization",
        }
        ev.post(os.path.join(repo, "target"), 2,
                "验收通过并授权提交：tree " + "a" * 12,
                "handoff", "", "source", "fake-token",
                commit_authorization=authorization)
        self.assertEqual([method for method, _ in calls],
                         ["node.create", "edge.create"])
        props = calls[0][1]["properties"]
        for field, value in authorization.items():
            self.assertEqual(props[field], value)
        self.assertEqual(calls[1][1]["type"], "NOTIFY")


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0]])
PY

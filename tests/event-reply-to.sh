#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

repo = sys.argv[1]
tools = os.path.join(repo, "tools")
sender = os.path.join(repo, "sender")
recipient = os.path.join(repo, "recipient")
os.makedirs(sender, exist_ok=True)
os.makedirs(recipient, exist_ok=True)
os.environ["CLAUDE_PROJECT_DIR"] = sender
os.environ["DRSG_TOKEN"] = "fake-token"
sys.argv = [os.path.join(tools, "mcp_events.py"), sender]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mcp_events = load("mcp_events", os.path.join(tools, "mcp_events.py"))
event_cli = load("event_cli", os.path.join(tools, "event.py"))
poller = load("event_poller", os.path.join(tools, "event-poller.py"))


class FakeGraph:
    def __init__(self):
        self.projects = [
            {"id": 1, "labels": ["Project"],
             "properties": {"path": sender}},
            {"id": 2, "labels": ["Project"],
             "properties": {"path": recipient}},
            {"id": 3, "labels": ["Project"],
             "properties": {"path": os.path.join(repo, "third-party")}},
        ]
        self.events = {}
        self.notify = {}
        self.created = []
        self.pending = {}
        self.calls = []

    def add_event(self, key, props, notify_path, labels=None):
        self.events[key] = {"external_key": key,
                            "labels": labels or ["Event"],
                            "properties": dict(props)}
        self.notify[key] = notify_path

    def rpc(self, method, params, token):
        self.calls.append((method, params))
        if method == "plane.cypher":
            query = params["query"]
            bound = params.get("params", {})
            if query == "MATCH (p:Project) RETURN p":
                return {"nodes": self.projects}
            if "key(e) = $key" in query and "$sender_path" in query:
                key = bound["key"]
                event = self.events.get(key)
                if event and self.notify.get(key) == bound["sender_path"]:
                    return {"nodes": [event]}
                return {"nodes": []}
            if "key(e) = $key" in query and "$path" in query and "RETURN e" in query:
                key = bound["key"]
                event = self.events.get(key)
                if event and self.notify.get(key) == bound["path"]:
                    return {"nodes": [event]}
                return {"nodes": []}
            if query == "MATCH (e:Event) WHERE key(e) = $key RETURN e":
                event = self.events.get(bound["key"])
                return {"nodes": [event] if event else []}
            if "WHERE p.path = $path" in query and "RETURN e" in query:
                return {"nodes": [self.events[k] for k in self.events
                                  if self.notify.get(k) == bound["path"]]}
            raise AssertionError("unexpected query: %s" % query)
        if method == "node.create":
            self.created.append(params)
            self.pending[params["key"]] = params["properties"]
            return {"id": 100 + len(self.created)}
        if method == "edge.create":
            key = params["src"]
            target = next(p["properties"]["path"] for p in self.projects
                          if p["id"] == params["dst"])
            self.events[key] = {"external_key": key, "labels": ["Event"],
                                "properties": self.pending.pop(key)}
            self.notify[key] = target
            return {"id": 200 + len(self.events)}
        raise AssertionError("unexpected RPC method: %s" % method)


class ReplyToTests(unittest.TestCase):
    def setUp(self):
        self.graph = FakeGraph()
        self.mcp = mcp_events
        self.ev = mcp_events.ev
        self.old_rpc, self.old_kick = self.ev.rpc, self.ev.kick
        self.ev.rpc = self.graph.rpc
        self.ev.kick = lambda path: None
        event_cli.rpc = self.graph.rpc
        event_cli.kick = lambda path: None
        sys.argv = [os.path.join(tools, "mcp_events.py"), sender]
        self.addCleanup(setattr, self.ev, "rpc", self.old_rpc)
        self.addCleanup(setattr, self.ev, "kick", self.old_kick)

    def source_event(self, key="evt-source", **changes):
        props = {
            "kind": "handoff", "status": "open",
            "summary": "A long original summary that will be clipped after forty characters.",
            "from_project": os.path.basename(recipient),
            "from_path": recipient,
        }
        props.update(changes)
        self.graph.add_event(key, props, sender)
        return key

    def test_mcp_schema_and_valid_reply_properties(self):
        schema = next(t["inputSchema"] for t in self.mcp.TOOLS
                      if t["name"] == "event_post")
        self.assertIn("reply_to", schema["properties"])
        self.assertNotIn("reply_to", schema["required"])
        source = self.source_event()
        self.mcp.call_tool("event_post", {
            "recipient": recipient, "summary": "验收通过：done",
            "kind": "notice", "reply_to": source}, "fake-token")
        props = self.graph.created[-1]["properties"]
        self.assertEqual(props["reply_to"], source)
        self.assertEqual(props["from_path"], sender)
        self.assertEqual(props["from_project"], os.path.basename(sender))
        self.assertEqual(props["summary"], "验收通过：done")
        self.assertNotIn(source, props["summary"])
        self.assertEqual(self.graph.events[source]["properties"]["status"], "open")

    def test_event_post_without_reply_keeps_summary_and_stores_sender_path(self):
        self.mcp.call_tool("event_post", {
            "recipient": recipient, "summary": "plain summary"}, "fake-token")
        props = self.graph.created[-1]["properties"]
        self.assertEqual(props["summary"], "plain summary")
        self.assertEqual(props["from_project"], os.path.basename(sender))
        self.assertEqual(props["from_path"], sender)
        self.assertNotIn("reply_to", props)

    def test_invalid_reply_targets_refuse_before_event_creation(self):
        cases = [
            ("missing", "不存在"),
            ("legacy", "reply_to 指向的 Event 是旧格式（没有 from_path），无法核对来源；请去掉 reply_to 重发，正文里写明在回复哪一条。"),
            ("not-event", "不是 Event"),
            ("wrong-source", "发件方"),
            ("third-party", "未发给当前项目"),
        ]
        self.graph.add_event("legacy", {
            "kind": "handoff", "status": "open",
            "summary": "old", "from_project": os.path.basename(recipient)}, sender)
        self.graph.add_event("not-event", {
            "kind": "handoff", "status": "open", "summary": "not event",
            "from_project": os.path.basename(recipient), "from_path": recipient},
            sender, labels=["Project"])
        self.graph.add_event("wrong-source", {
            "kind": "handoff", "status": "open", "summary": "wrong",
            "from_project": "someone-else", "from_path": os.path.join(repo, "else")}, sender)
        self.graph.add_event("third-party", {
            "kind": "handoff", "status": "open", "summary": "third",
            "from_project": os.path.basename(recipient), "from_path": recipient},
            os.path.join(repo, "third-party"))
        for key, phrase in cases:
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, phrase):
                    self.mcp.call_tool("event_post", {
                        "recipient": recipient, "summary": "reply",
                        "reply_to": key}, "fake-token")
        self.assertEqual(self.graph.created, [])

    def test_cli_accepts_reply_to(self):
        source = self.source_event("evt-cli")
        old_project_id = event_cli.project_id
        event_cli.project_id = lambda path, token: next(
            p["id"] for p in self.graph.projects
            if p["properties"]["path"] == path)
        self.addCleanup(setattr, event_cli, "project_id", old_project_id)
        captured = io.StringIO()
        argv = ["event.py", "post", recipient, "reply", "--reply-to", source]
        with contextlib.redirect_stdout(captured), patch("os.getcwd", return_value=sender):
            old = sys.argv
            sys.argv = argv
            try:
                try:
                    event_cli.main()
                except SystemExit as exc:
                    self.fail("event.py rejected --reply-to (exit %s)" % exc.code)
            finally:
                sys.argv = old
        self.assertEqual(self.graph.created[-1]["properties"]["reply_to"], source)
        self.assertIn("posted", captured.getvalue())

    def test_open_events_prepares_reply_line_for_wakeup(self):
        original = {"external_key": "evt-source", "labels": ["Event"],
                    "properties": {"summary": "source summary"}}
        current = {"external_key": "evt-current", "labels": ["Event"],
                   "properties": {"kind": "handoff", "status": "open",
                                  "summary": "reply", "reply_to": "evt-source"}}
        fake_ev = types.SimpleNamespace(
            API="", PLANE="memory",
            load_env=lambda path: None,
            fetch=lambda path, token: [current],
            reply_line=lambda key, events, token: "↳ 回复你发出的 evt-source：source summary",
        )
        loader = types.SimpleNamespace(exec_module=lambda module: None)
        with patch.dict(os.environ, {"EVENT_POLL_FAKE": "", "DRSG_TOKEN": "fake-token"}), \
             patch.object(poller.importlib.util, "spec_from_file_location",
                          return_value=types.SimpleNamespace(loader=loader)), \
             patch.object(poller.importlib.util, "module_from_spec", return_value=fake_ev):
            opened = poller.open_events(recipient)
        self.assertEqual(opened[0]["reply_line"],
                         "↳ 回复你发出的 evt-source：source summary")
        self.assertIn(opened[0]["reply_line"], poller.wake_text(opened))

    def test_wake_text_adds_reply_line_and_keeps_plain_event_output(self):
        plain = [{"key": "plain", "kind": "notice", "summary": "plain text"}]
        baseline = (
            "【待办轮询】本项目有 1 条新的待办 Event（drsg-events）：\n"
            "- plain [notice] plain text\n"
            "按 CLAUDE.md 的 Event 流程处理：读 ref 指的文档，照做；做完发回执（notice）并 event_done。\n"
            "例外：summary 以「验收通过：」开头的判定只需 event_done，不要为它回 notice；回执的回执只会让对方多关一次单。\n"
            "收到 handoff 直接开工，不要先回「已读」「已收到，准备先写计划」这类 notice；回给发件方的第一条应是回执，或卡住时要问的问题。\n"
            "照旧要先停下等用户确认的：git commit、push、开 PR、改锁文件、任何不可逆操作。\n"
            "动手前先看工作区和 git 状态：另一个会话可能做过一半（本条可能是接管后重发），已做过的不要重复改。"
        )
        self.assertEqual(poller.wake_text(plain), baseline)
        reply = [{"key": "reply", "kind": "notice", "summary": "done",
                  "reply_to": "evt-source", "reply_summary": "S" * 50}]
        output = poller.wake_text(reply)
        self.assertIn("↳ 回复你发出的 evt-source：" + "S" * 40, output)
        self.assertEqual(output.count("↳ 回复你发出的"), 1)

    def test_plain_event_list_output_remains_unchanged(self):
        self.graph.add_event("evt-plain", {
            "kind": "notice", "status": "open", "summary": "plain",
            "from_project": "other", "created_at": 1}, recipient)
        expected = "open   notice   unseen         evt-plain  plain"
        actual = self.mcp.call_tool("event_list", {
            "project": recipient, "status": "open"}, "fake-token")
        self.assertEqual(actual, expected)
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            event_cli.cmd_list(types.SimpleNamespace(project=recipient), "fake-token")
        self.assertEqual(captured.getvalue(),
                         "open      notice   unseen         evt-plain  plain\n")

    def test_event_lists_add_reply_line_but_leave_plain_rows_unchanged(self):
        source = self.source_event("evt-list-source")
        reply_props = {"kind": "notice", "status": "open", "summary": "done",
                       "from_project": os.path.basename(sender), "from_path": recipient,
                       "reply_to": source, "created_at": 2}
        self.graph.add_event("evt-list-reply", reply_props, recipient)
        self.graph.add_event("evt-list-plain", {
            "kind": "notice", "status": "open", "summary": "plain",
            "from_project": "other", "created_at": 1}, recipient)
        result = self.mcp.call_tool("event_list", {
            "project": recipient, "status": "open"}, "fake-token")
        self.assertIn("↳ 回复你发出的 evt-list-source：A long original summary that will be", result)
        self.assertIn("evt-list-plain  plain", result)
        old_argv = sys.argv
        sys.argv = ["event.py", "list", recipient]
        captured = io.StringIO()
        try:
            with contextlib.redirect_stdout(captured):
                event_cli.cmd_list(types.SimpleNamespace(project=recipient), "fake-token")
        finally:
            sys.argv = old_argv
        cli_result = captured.getvalue()
        self.assertIn("↳ 回复你发出的 evt-list-source：A long original summary that will be", cli_result)
        self.assertIn("evt-list-plain", cli_result)
        self.assertEqual(self.graph.events[source]["properties"]["status"], "open")


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0]])
PY

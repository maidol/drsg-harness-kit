#!/usr/bin/env bash
# event_post supersedes: posting a follow-up closes the sender's own earlier
# open Event to the same recipient. ONLY=<test name> runs one case;
# EVENT_TOOLS_DIR points at a copy of tools/ (the mutation runner uses it).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "${EVENT_TOOLS_DIR:-$REPO/tools}" "${ONLY:-}" <<'PY'
import contextlib
import importlib.util
import io
import os
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

tools, only = sys.argv[1], sys.argv[2]
work = tempfile.mkdtemp()
sender = os.path.realpath(os.path.join(work, "sender"))
recipient = os.path.realpath(os.path.join(work, "recipient"))
third = os.path.realpath(os.path.join(work, "third-party"))
for d in (sender, recipient, third):
    os.makedirs(d)
os.environ["CLAUDE_PROJECT_DIR"] = sender
os.environ["DRSG_TOKEN"] = "fake-token"
os.environ["DRSG_MEM_DIR"] = os.path.join(work, "mem")
sys.argv = [os.path.join(tools, "mcp_events.py"), sender]

spec = importlib.util.spec_from_file_location("mcp_events", os.path.join(tools, "mcp_events.py"))
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)
ev = mcp.ev


class FakeGraph:
    def __init__(self):
        self.projects = [
            {"id": 1, "labels": ["Project"], "properties": {"path": sender}},
            {"id": 2, "labels": ["Project"], "properties": {"path": recipient}},
            {"id": 3, "labels": ["Project"], "properties": {"path": third}},
        ]
        self.events, self.notify, self.pending = {}, {}, {}
        self.created, self.updates = [], []
        self.update_mode = "ok"

    def add_event(self, key, props, notify_path):
        self.events[key] = {"external_key": key, "labels": ["Event"],
                            "properties": dict(props)}
        self.notify[key] = notify_path

    def rpc(self, method, params, token):
        if method == "plane.cypher":
            query, bound = params["query"], params.get("params", {})
            if query == "MATCH (p:Project) RETURN p":
                return {"nodes": self.projects}
            if "key(e) = $key" in query and ("$path" in query or "$sender_path" in query):
                event = self.events.get(bound["key"])
                where = bound.get("path", bound.get("sender_path"))
                if event and self.notify.get(bound["key"]) == where:
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
        if method == "node.update":
            self.updates.append(params)
            if self.update_mode == "raise":
                raise RuntimeError("daemon unavailable")
            event = self.events[params["key"]]
            if self.update_mode != "stale":
                event["properties"].update(params["set"])
            return {"labels": event["labels"], "properties": dict(event["properties"])}
        raise AssertionError("unexpected RPC method: %s" % method)


class SupersedesTests(unittest.TestCase):
    def setUp(self):
        self.graph = FakeGraph()
        for name, value in (("rpc", self.graph.rpc), ("kick", lambda path: None)):
            self.addCleanup(setattr, ev, name, getattr(ev, name))
            setattr(ev, name, value)

    def old(self, key="evt-old", **changes):
        props = {"kind": "handoff", "status": "open", "summary": "first dispatch",
                 "from_project": os.path.basename(sender), "from_path": sender,
                 "created_at": 1}
        props.update(changes)
        notify = props.pop("notify", recipient)
        self.graph.add_event(key, props, notify)
        return key

    def post(self, **extra):
        args = {"recipient": recipient, "summary": "现在继续", "kind": "handoff"}
        args.update(extra)
        return mcp.call_tool("event_post", args, "fake-token")

    def new_key(self):
        return self.graph.created[-1]["key"]

    def assert_refused(self, phrase, key, status="open"):
        with self.assertRaisesRegex(ValueError, phrase):
            self.post(supersedes=key)
        self.assertEqual(self.graph.created, [])
        self.assertEqual(self.graph.updates, [])
        if key in self.graph.events:
            self.assertEqual(self.graph.events[key]["properties"]["status"], status)

    def test_valid_supersede(self):
        old = self.old()
        out = self.post(supersedes=old)
        new = self.new_key()
        self.assertEqual(self.graph.created[-1]["properties"]["supersedes"], old)
        props = self.graph.events[old]["properties"]
        self.assertEqual(props["status"], "done")
        self.assertEqual(props["superseded_by"], new)
        self.assertIsInstance(props["done_at"], int)
        self.assertIn("posted %s to %s" % (new, recipient), out)
        self.assertIn("superseded %s: done" % old, out)

    def test_reply_to_and_supersedes_together(self):
        old = self.old()
        self.graph.add_event("evt-their-notice", {
            "kind": "notice", "status": "open", "summary": "blocked",
            "from_project": os.path.basename(recipient), "from_path": recipient}, sender)
        self.post(supersedes=old, reply_to="evt-their-notice")
        props = self.graph.created[-1]["properties"]
        self.assertEqual(props["supersedes"], old)
        self.assertEqual(props["reply_to"], "evt-their-notice")
        self.assertEqual(self.graph.events[old]["properties"]["status"], "done")

    def test_refuse_missing(self):
        self.assert_refused("supersedes 目标 Event 不存在或不是 Event", "evt-nowhere")

    def test_refuse_other_recipient(self):
        old = self.old(notify=third)
        self.assert_refused("supersedes 目标 Event 不是发给 recipient 的", old)

    def test_refuse_not_sender(self):
        old = self.old(from_project="third-party", from_path=third)
        self.assert_refused("supersedes 目标 Event 不是本项目发出的", old)

    def test_refuse_legacy(self):
        old = self.old()
        del self.graph.events[old]["properties"]["from_path"]
        self.assert_refused("supersedes 指向的 Event 是旧格式", old)

    def test_refuse_done(self):
        old = self.old(status="done")
        self.assert_refused("supersedes 目标 Event 已经是 'done'", old, status="done")

    def test_close_failure_keeps_new_event(self):
        old = self.old()
        self.graph.update_mode = "raise"
        with self.assertRaises(RuntimeError) as caught:
            self.post(supersedes=old)
        new = self.new_key()
        self.assertIn(new, self.graph.events)
        self.assertEqual(self.graph.notify[new], recipient)
        self.assertIn("新单 %s 已发出；旧单 %s 没关上" % (new, old), str(caught.exception))
        self.assertIn("daemon unavailable", str(caught.exception))
        self.assertEqual(self.graph.events[old]["properties"]["status"], "open")

    def test_readback_mismatch_reports(self):
        old = self.old()
        self.graph.update_mode = "stale"
        with self.assertRaises(RuntimeError) as caught:
            self.post(supersedes=old)
        self.assertIn("新单 %s 已发出；旧单 %s 没关上（读回 status='open'）"
                      % (self.new_key(), old), str(caught.exception))

    def test_owner_lease_not_consulted(self):
        old = self.old()

        def refuse(*args, **kwargs):
            raise AssertionError("owner_refusal must not run for supersedes")
        with patch.object(ev, "owner_refusal", refuse):
            self.post(supersedes=old)
        self.assertEqual(self.graph.events[old]["properties"]["status"], "done")

    def test_cli_supersedes(self):
        old = self.old()
        captured = io.StringIO()
        argv = ["event.py", "post", recipient, "现在继续", "--supersedes", old]
        with contextlib.redirect_stdout(captured), \
             patch("os.getcwd", return_value=sender), \
             patch.object(sys, "argv", argv), \
             patch.object(ev, "load_env", lambda path: None):
            try:
                ev.main()
            except SystemExit as exc:
                self.fail("event.py post --supersedes failed: %s" % exc.code)
        self.assertEqual(self.graph.created[-1]["properties"]["supersedes"], old)
        self.assertEqual(self.graph.events[old]["properties"]["status"], "done")
        self.assertIn("superseded %s: done" % old, captured.getvalue())

    def test_without_supersedes_unchanged(self):
        old = self.old()
        out = self.post()
        self.assertNotIn("supersedes", self.graph.created[-1]["properties"])
        self.assertEqual(self.graph.updates, [])
        self.assertEqual(self.graph.events[old]["properties"]["status"], "open")
        self.assertEqual(out, "posted %s to %s" % (self.new_key(), recipient))

    def test_list_shows_superseded_line(self):
        old = self.old()
        self.post(supersedes=old)
        line = "↳ 取代 %s" % old
        listed = mcp.call_tool("event_list", {"project": recipient, "status": "all"},
                               "fake-token")
        self.assertEqual(listed.count(line), 1)
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            ev.cmd_list(types.SimpleNamespace(project=recipient), "fake-token")
        self.assertEqual(captured.getvalue().count(line), 1)

    def test_recipient_late_close_is_harmless(self):
        old = self.old()
        self.post(supersedes=old)
        self.assertEqual(ev.close(old, "fake-token", force=True), "%s done" % old)
        self.assertEqual(self.graph.events[old]["properties"]["status"], "done")


names = ["SupersedesTests." + only] if only else []
result = unittest.main(verbosity=2, argv=[sys.argv[0]] + names, exit=False).result
ran, bad = result.testsRun, len(result.failures) + len(result.errors)
print("PASS %d/%d" % (ran - bad, ran))
sys.exit(0 if ran and not bad else 1)
PY

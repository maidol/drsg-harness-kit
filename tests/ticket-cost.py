#!/usr/bin/env python3
import builtins
import contextlib
import io
import itertools
import json
import os
import pathlib
import runpy
from fractions import Fraction
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "tools" / "ticket-cost.py"
API = runpy.run_path(str(CLI))


def row(timestamp, project, message):
    return {"timestamp": timestamp, "type": "assistant", "_project": project, "message": message}


def usage_call(timestamp, message_id, input_tokens):
    return row(timestamp, "reviewer", {"id": message_id, "model": "synthetic-model", "usage": {
        "input_tokens": input_tokens, "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0, "output_tokens": 0,
    }, "content": [{"type": "text", "text": "PROMPT-SENTINEL"}]})


def event_call(timestamp, sender, target, key, kind, reply_to=None, summary="work",
        tool="mcp__drsg-events__event_post"):
    tool_id = f"tool-{key}"
    inputs = {"recipient": target, "kind": kind, "summary": summary}
    if reply_to:
        inputs["reply_to"] = reply_to
    call = row(timestamp, sender, {"content": [{"type": "tool_use", "id": tool_id,
        "name": tool, "input": inputs}]})
    result = {"timestamp": timestamp, "type": "user", "_project": sender,
        "message": {"content": [{"type": "tool_result", "tool_use_id": tool_id,
            "content": f"posted {key} to {target}"}]}}
    return call, result


def make_transcript(path, project, messages):
    rows = []
    for item in messages:
        if isinstance(item, tuple):
            rows.extend(item)
        else:
            item["_project"] = project
            rows.append(item)
    path.write_text("".join(json.dumps(item) + "\n" for item in rows), encoding="utf-8")


def without_cost_summary(lines):
    return [line for line in lines
        if not line.startswith(("Business:", "Time coverage:", "Coverage:", "Comparability:"))]


class TestDedup(unittest.TestCase):
    def record(self, project, message_id, output):
        return {"project": project, "message_id": message_id, "timestamp": 10,
            "model": "synthetic-model", "usage": {
                "input_tokens": 41, "cache_creation_input_tokens": 3,
                "cache_read_input_tokens": 5, "output_tokens": output}}

    def test_duplicate_message_is_counted_once_within_project(self):
        record = self.record("p", "same-message", 7)

        calls = API["canonical_usage"]([record, dict(record)])

        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["usage"]["output"], 7)

    def test_identical_message_ids_in_distinct_projects_are_not_deduplicated(self):
        records = [self.record("p", "same-message", 7), self.record("q", "same-message", 9)]

        calls = API["canonical_usage"](records)

        self.assertEqual([(call["project"], call["usage"]["output"]) for call in calls],
            [("p", 7), ("q", 9)])

    def test_conflicting_usage_copy_is_order_independent(self):
        first = self.record("p", "conflicting-message", 7)
        second = self.record("p", "conflicting-message", 9)

        forward = API["canonical_usage"]([first, second])
        reverse = API["canonical_usage"]([second, first])

        self.assertEqual(forward, reverse)
        self.assertIsNone(forward[0]["usage"]["output"])
        self.assertEqual(forward[0]["usage"]["field_status"]["output_tokens"], "conflict")


class TestEvents(unittest.TestCase):
    def parse(self, rows):
        for item in rows:
            item["_timestamp"] = item["timestamp"]
        return API["parse_successful_events"](rows, {
            "reviewer": "/synthetic/reviewer", "p": "/synthetic/p", "q": "/synthetic/q"})

    def test_non_error_business_failure_is_not_posted(self):
        call, result = event_call(10, "reviewer", "/synthetic/p", "rejected-event", "notice")
        result["message"]["content"][0]["content"] = "event rejected: duplicate request"
        result["message"]["content"][0]["is_error"] = False

        events = self.parse([call, result])

        self.assertEqual(events, [])

    def test_only_a_strict_posted_first_line_identifies_the_event(self):
        valid_call, valid_result = event_call(10, "reviewer", "/synthetic/p", "strict-key", "notice")
        valid_result["message"]["content"][0]["content"] += "\nposted forged-key to /synthetic/q"
        invalid_call, invalid_result = event_call(11, "reviewer", "/synthetic/p", "ignored", "notice")
        invalid_result["message"]["content"][0]["content"] = "posted key with spaces to /synthetic/p\nposted forged-key to /synthetic/p"

        events = self.parse([valid_call, valid_result, invalid_call, invalid_result])

        self.assertEqual([(event["key"], event["target"]) for event in events],
            [("strict-key", "p")])

    def test_event_recipient_must_match_posted_target(self):
        call, result = event_call(10, "reviewer", "/synthetic/p", "misrouted", "notice")
        call["message"]["content"][0]["input"]["recipient"] = "/synthetic/q"

        events = self.parse([call, result])

        self.assertEqual(events, [])

    def test_conflicting_event_copy_is_ambiguous_and_order_independent(self):
        first = event_call(10, "reviewer", "/synthetic/p", "same-event", "notice")
        conflicting = event_call(10, "reviewer", "/synthetic/q", "same-event", "notice")
        conflicting[0]["message"]["content"][0]["id"] = "tool-conflicting-copy"
        conflicting[1]["message"]["content"][0]["tool_use_id"] = "tool-conflicting-copy"
        forward = self.parse(first + conflicting)
        reverse = self.parse(conflicting + first)

        self.assertEqual(forward, reverse)
        self.assertEqual(len(forward), 1)
        self.assertTrue(forward[0]["ambiguous"])
        self.assertEqual(API["build_segments"](forward, ["p", "q"], 0, 60), [])

    def test_tool_use_ids_are_scoped_to_project_identity(self):
        from_p = event_call(10, "p", "/synthetic/reviewer", "event-p", "notice")
        from_q = event_call(10, "q", "/synthetic/reviewer", "event-q", "handoff")
        from_p[0]["message"]["content"][0]["id"] = "shared-tool-id"
        from_p[1]["message"]["content"][0]["tool_use_id"] = "shared-tool-id"
        from_q[0]["message"]["content"][0]["id"] = "shared-tool-id"
        from_q[1]["message"]["content"][0]["tool_use_id"] = "shared-tool-id"

        events = self.parse(from_p + from_q)

        self.assertEqual([(event["sender"], event["key"]) for event in events],
            [("p", "event-p"), ("q", "event-q")])

    def test_identical_event_copies_are_normalized(self):
        first = event_call(10, "reviewer", "/synthetic/p", "same-event", "notice")
        duplicate = event_call(10, "reviewer", "/synthetic/p", "same-event", "notice")

        events = self.parse(first + duplicate)

        self.assertEqual(len(events), 1)
        self.assertNotIn("ambiguous", events[0])
        self.assertEqual(events[0]["key"], "same-event")

    def test_same_tool_use_id_conflicting_target_remains_ambiguous(self):
        first = event_call(10, "reviewer", "/synthetic/p", "same-event", "notice")
        conflicting = event_call(10, "reviewer", "/synthetic/q", "same-event", "notice")

        forward = self.parse(first + conflicting)
        reverse = self.parse(conflicting + first)

        self.assertEqual(forward, reverse)
        self.assertEqual(len(forward), 1)
        self.assertTrue(forward[0]["ambiguous"])
        self.assertEqual(API["build_segments"](forward, ["p", "q"], 0, 60), [])

    def test_success_result_omission_false_and_advice_are_equivalent(self):
        first = event_call(10, "reviewer", "/synthetic/p", "same-event", "notice")
        false_copy = event_call(10, "reviewer", "/synthetic/p", "same-event", "notice")
        false_copy[1]["message"]["content"][0]["is_error"] = False
        advice_copy = event_call(10, "reviewer", "/synthetic/p", "same-event", "notice")
        advice_copy[1]["message"]["content"][0]["content"] += "\nadvice: synthetic graph hint"

        events = self.parse(first + false_copy + advice_copy)

        self.assertEqual(len(events), 1)
        self.assertNotIn("ambiguous", events[0])
        self.assertEqual(events[0]["key"], "same-event")

    def test_real_cli_equivalent_copies_match_control_and_error_conflicts_stay_ambiguous(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)

            def run_case(name, pairs):
                transcript, report = root / f"{name}.jsonl", root / f"{name}.json"
                make_transcript(transcript, "reviewer", [item for pair in pairs for item in pair])
                command = [sys.executable, "-I", str(CLI),
                    "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                    "--transcript", f"reviewer={transcript}",
                    "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                    "--json-out", str(report)]
                environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                    XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
                environment.pop("EVENT_POLL_OWNER_PID", None)
                result = subprocess.run(command, cwd=root, env=environment, text=True, capture_output=True)
                return result, json.loads(report.read_text(encoding="utf-8"))

            call, result = event_call(0, "reviewer", "/synthetic/p", "root", "notice")
            control_result, control = run_case("control", [(call, result)])
            self.assertEqual(control_result.returncode, 0, control_result.stderr)
            self.assertEqual((control["scan"]["status"], len(control["segments"])), ("complete", 1))

            false_call, false_result = event_call(0, "reviewer", "/synthetic/p", "root", "notice")
            false_result["message"]["content"][0]["is_error"] = False
            false_copy_result, false_copy = run_case("false-copy", [
                (call, result), (false_call, false_result)])
            self.assertEqual(false_copy_result.returncode, 0, false_copy_result.stderr)
            self.assertEqual(false_copy["scan"]["status"], control["scan"]["status"])
            self.assertEqual(false_copy["segments"], control["segments"])

            advice_call, advice_result = event_call(0, "reviewer", "/synthetic/p", "root", "notice")
            advice_result["message"]["content"][0]["content"] += "\nadvice: synthetic graph hint"
            advice_copy_result, advice_copy = run_case("advice-copy", [
                (call, result), (advice_call, advice_result)])
            self.assertEqual(advice_copy_result.returncode, 0, advice_copy_result.stderr)
            self.assertEqual(advice_copy["segments"], control["segments"])

            error_result = event_call(0, "reviewer", "/synthetic/p", "root", "notice")[1]
            error_result["message"]["content"][0]["is_error"] = True
            conflict_result, conflict = run_case("error-conflict", [(call, result), (call, error_result)])
            self.assertEqual(conflict_result.returncode, 0, conflict_result.stderr)
            self.assertEqual((conflict["scan"]["status"], conflict["segments"]), ("no_samples", []))

    def test_error_and_missing_tool_results_are_not_events(self):
        failed_call, failed_result = event_call(10, "reviewer", "/synthetic/p", "failed", "notice")
        failed_result["message"]["content"][0]["is_error"] = True
        missing_call, _ = event_call(11, "reviewer", "/synthetic/p", "missing", "notice")

        events = self.parse([failed_call, failed_result, missing_call])

        self.assertEqual(events, [])

    def test_commit_authorization_without_observable_link_leaves_work_open(self):
        root = event_call(0, "reviewer", "/synthetic/p", "root", "notice")
        tool_id = "tool-auth"
        auth_call = row(20, "reviewer", {"content": [{"type": "tool_use", "id": tool_id,
            "name": "mcp__drsg-events__commit_auth_post", "input": {
                "recipient": "/synthetic/p", "tree": "a" * 40, "parent": "b" * 40,
                "target_branch": "main", "files": ["src/example.py"], "force_paths": [],
                "message": "fix: synthetic"}}]})
        auth_result = {"timestamp": 20, "type": "user", "_project": "reviewer",
            "message": {"content": [{"type": "tool_result", "tool_use_id": tool_id,
                "content": "posted auth to /synthetic/p"}]}}

        events = self.parse([*root, auth_call, auth_result])
        segments = API["build_segments"](events, ["p"], 0, 60)

        self.assertEqual(len(events), 2)
        authorization = next(event for event in events if event["key"] == "auth")
        self.assertIsNone(authorization["reply_to"])
        self.assertIsNone(authorization["supersedes"])
        self.assertEqual((authorization["auth_tree"], authorization["auth_parent"],
            authorization["auth_files"]), ("a" * 40, "b" * 40, ("src/example.py",)))
        self.assertEqual([(segment["end"], segment["status"], segment["rounds"])
            for segment in segments], [(None, "right_censored", 0)])
        serialized = json.dumps(API["build_report"]([], segments, 0, 60))
        for private in ("a" * 40, "b" * 40, "src/example.py"):
            self.assertNotIn(private, serialized)


class TestSegments(unittest.TestCase):
    def event(self, key, sender, target, timestamp, kind="notice", reply_to=None, summary="work"):
        return {"key": key, "sender": sender, "target": target, "timestamp": timestamp,
            "kind": kind, "reply_to": reply_to, "supersedes": None,
            "summary_prefix": summary.split(":", 1)[0]}

    def test_executor_handoff_can_start_linked_segment_after_long_wait(self):
        events = [
            self.event("executor-root", "p", "reviewer", 0, "handoff"),
            self.event("reviewer-pass", "reviewer", "p", 50_000, "notice", "executor-root", "验收通过：done"),
        ]

        segments = API["build_segments"](events, ["p"], 0, 60_000)

        self.assertEqual(len(segments), 1)
        self.assertEqual((segments[0]["start"], segments[0]["end"], segments[0]["status"]),
            (0, 50_000, "complete"))
        self.assertEqual((segments[0]["rework_count"], segments[0]["rounds"], segments[0]["first_pass"]),
            (0, 1, True))

    def test_unmatched_terminal_does_not_close_another_root(self):
        events = [
            self.event("root-a", "reviewer", "p", 0),
            self.event("root-b", "reviewer", "p", 5),
            self.event("pass-a", "reviewer", "p", 20, reply_to="root-a", summary="验收通过：done"),
            self.event("unmatched-pass", "reviewer", "p", 30, summary="验收通过：late"),
        ]

        segments = API["build_segments"](events, ["p"], 0, 60)

        self.assertEqual([segment["root_key"] for segment in segments], ["root-a", "root-b"])
        by_root = {segment["root_key"]: segment for segment in segments}
        self.assertEqual(by_root["root-a"]["end"], 20)
        self.assertIsNone(by_root["root-b"]["end"])
        self.assertEqual(by_root["root-b"]["status"], "right_censored")
        self.assertEqual(by_root["root-a"]["origin_status"], "origin_candidate")
        self.assertEqual(by_root["root-b"]["origin_status"], "origin_ambiguous")

    def test_segment_lifecycle_indexes_events_instead_of_rescanning_every_root(self):
        class CountedEvents(list):
            visits = 0

            def __iter__(self):
                for item in super().__iter__():
                    self.visits += 1
                    yield item

        events = CountedEvents([self.event(f"root-{index}", "reviewer", "p", index)
            for index in range(8)] + [self.event(f"pass-{index}", "reviewer", "p", 100 + index,
                reply_to=f"root-{index}", summary="验收通过：done") for index in range(8)])

        segments = API["build_segments"](events, ["p"], 0, 200)

        self.assertEqual(len(segments), 8)
        self.assertLessEqual(events.visits, 5 * len(events))
        self.assertEqual([segment["origin_status"] for segment in segments],
            ["origin_candidate"] * 8)

    def test_unlinked_start_after_visible_close_is_an_origin_candidate(self):
        events = [
            self.event("root-a", "reviewer", "p", 0),
            self.event("pass-a", "reviewer", "p", 10, reply_to="root-a", summary="验收通过：done"),
            self.event("root-b", "reviewer", "p", 15),
        ]

        segments = API["build_segments"](events, ["p"], 0, 60)

        by_root = {segment["root_key"]: segment for segment in segments}
        self.assertEqual(by_root["root-b"]["origin_status"], "origin_candidate")
        self.assertEqual(by_root["root-b"]["status"], "right_censored")

    def test_wait_longer_than_48_hours_is_not_truncated(self):
        events = [
            self.event("root", "reviewer", "p", 0),
            self.event("pass", "reviewer", "p", 172801, reply_to="root", summary="验收通过：done"),
        ]

        segments = API["build_segments"](events, ["p"], 0, 180000)

        self.assertEqual((segments[0]["end"], segments[0]["status"]), (172801, "complete"))

    def test_late_and_repeated_terminals_only_close_their_linked_root_once(self):
        events = [
            self.event("root-a", "reviewer", "p", 0),
            self.event("root-b", "reviewer", "p", 10),
            self.event("pass-a", "reviewer", "p", 20, reply_to="root-a", summary="验收通过：done"),
            self.event("pass-b", "reviewer", "p", 30, reply_to="root-b", summary="验收通过：done"),
            self.event("late-pass-a", "reviewer", "p", 40, reply_to="root-a", summary="验收通过：late"),
            self.event("repeat-pass-b", "reviewer", "p", 50, reply_to="root-b", summary="验收通过：repeat"),
        ]

        segments = API["build_segments"](events, ["p"], 0, 60)

        by_root = {segment["root_key"]: segment for segment in segments}
        self.assertEqual((by_root["root-a"]["end"], by_root["root-a"]["rounds"]), (20, 1))
        self.assertEqual((by_root["root-b"]["end"], by_root["root-b"]["rounds"]), (30, 1))

    def test_explicit_out_of_window_predecessor_creates_left_censored_segment(self):
        terminal = self.event("late-pass", "reviewer", "p", 20, kind="notice",
            reply_to="root-before-window", summary="验收通过：done")

        segments = API["build_segments"]([terminal], ["p"], 0, 60)

        self.assertEqual(len(segments), 1)
        segment = segments[0]
        self.assertEqual((segment["status"], segment["start"], segment.get("observed_from")),
            ("left_censored", 0, 0))
        self.assertIsNone(segment["first_pass"])
        self.assertIsNone(segment["rework_count"])
        self.assertIsNone(segment["rounds"])

    def test_event_keys_and_missing_predecessors_are_scoped_to_project(self):
        events = [
            self.event("shared", "q", "reviewer", 0, "handoff"),
            self.event("pass-p", "reviewer", "p", 20, reply_to="shared", summary="验收通过：done"),
        ]

        segments = API["build_segments"](events, ["p", "q"], 0, 60)

        by_project = {segment["project"]: segment for segment in segments}
        self.assertEqual(by_project["p"]["status"], "left_censored")
        self.assertEqual(by_project["q"]["status"], "right_censored")

    def test_executor_to_executor_event_is_not_a_reviewer_work_segment(self):
        events = [self.event("cross-project", "p", "q", 10)]

        segments = API["build_segments"](events, ["p", "q"], 0, 60)

        self.assertEqual(segments, [])

    def test_distinct_same_project_roots_remain_separate(self):
        events = [
            self.event("root-a", "reviewer", "p", 0),
            self.event("root-b", "reviewer", "p", 5),
            self.event("pass-a", "reviewer", "p", 20, reply_to="root-a", summary="验收通过：done"),
            self.event("pass-b", "reviewer", "p", 30, reply_to="root-b", summary="验收通过：done"),
        ]

        segments = API["build_segments"](events, ["p"], 0, 60)

        self.assertEqual([(segment["root_key"], segment["start"], segment["end"])
            for segment in segments], [("root-a", 0, 20), ("root-b", 5, 30)])

    def test_commit_authorization_without_linkage_does_not_close_segment(self):
        authorization = self.event("auth-a", "reviewer", "p", 20, kind=None,
            summary="")
        authorization["tool"] = "mcp__drsg-events__commit_auth_post"
        events = [self.event("root-a", "reviewer", "p", 0), authorization]

        segments = API["build_segments"](events, ["p"], 0, 60)

        self.assertEqual([(segment["end"], segment["status"], segment["rounds"])
            for segment in segments], [(None, "right_censored", 0)])

    def test_uniquely_linked_commit_authorization_closes_segment(self):
        authorization = self.event("auth-a", "reviewer", "p", 20, kind=None, summary="")
        authorization.update(tool="mcp__drsg-events__commit_auth_post", reply_to="root-a")
        events = [self.event("root-a", "reviewer", "p", 0), authorization]

        segments = API["build_segments"](events, ["p"], 0, 60)

        self.assertEqual([(segment["end"], segment["status"], segment["rounds"],
            segment["first_pass"]) for segment in segments], [(20, "complete", 1, True)])

    def test_unmatched_terminal_is_reported_without_closing_a_segment(self):
        events = [self.event("root-a", "reviewer", "p", 0),
            self.event("unmatched-pass", "reviewer", "p", 20, summary="验收通过：late")]
        diagnostics = {}

        segments = API["build_segments"](events, ["p"], 0, 60, diagnostics)
        report = API["build_report"]([], segments, 0, 60,
            {"unmatched_terminal_count": diagnostics["unmatched_terminal_count"]})

        self.assertEqual([(segment["end"], segment["status"]) for segment in segments],
            [(None, "right_censored")])
        self.assertEqual(report["totals"]["business"]["unmatched_terminal_count"], 1)
        self.assertIn("Business: complete=0; first-pass=0/0; unmatched-terminal=1",
            API["render_text"](report))

    def test_shared_authorization_fingerprint_is_unmatched(self):
        fingerprint = {"auth_tree": "a" * 40, "auth_parent": "b" * 40,
            "auth_files": ("tools/ticket-cost.py",)}
        roots = [self.event("root-a", "reviewer", "p", 0),
            self.event("root-b", "reviewer", "p", 5)]
        work_a = self.event("work-a", "p", "reviewer", 10, "handoff", reply_to="root-a")
        work_b = self.event("work-b", "p", "reviewer", 11, "handoff", reply_to="root-b")
        work_a.update(fingerprint)
        work_b.update(fingerprint)
        authorization = self.event("auth", "reviewer", "p", 20, kind=None, summary="")
        authorization.update(fingerprint, tool="mcp__drsg-events__commit_auth_post")
        diagnostics = {}

        segments = API["build_segments"]([*roots, work_a, work_b, authorization],
            ["p"], 0, 60, diagnostics)

        self.assertEqual([segment["end"] for segment in segments], [None, None])
        self.assertEqual(diagnostics["unmatched_terminal_count"], 1)

    def test_unique_authorization_fingerprint_closes_its_linked_segment(self):
        fingerprint = {"auth_tree": "a" * 40, "auth_parent": "b" * 40,
            "auth_files": ("tools/ticket-cost.py",)}
        work = self.event("work-a", "p", "reviewer", 10, "handoff", reply_to="root-a")
        work.update(fingerprint)
        authorization = self.event("auth-a", "reviewer", "p", 20, kind=None, summary="")
        authorization.update(fingerprint, tool="mcp__drsg-events__commit_auth_post")
        events = [self.event("root-a", "reviewer", "p", 0), work, authorization]

        segments = API["build_segments"](events, ["p"], 0, 60)

        self.assertEqual([(segment["end"], segment["status"]) for segment in segments],
            [(20, "complete")])

    def test_other_executor_cannot_close_a_segment(self):
        events = [self.event("root", "reviewer", "p", 0),
            self.event("foreign-pass", "q", "p", 20, reply_to="root",
                summary="验收通过：not from reviewer")]

        segments = API["build_segments"](events, ["p", "q"], 0, 60)

        self.assertEqual([(segment["end"], segment["status"])
            for segment in segments], [(None, "right_censored")])

    def test_other_executor_cannot_create_rework(self):
        events = [self.event("root", "reviewer", "p", 0),
            self.event("foreign-reject", "q", "p", 10, reply_to="root",
                summary="验收不通过：not from reviewer"),
            self.event("pass", "reviewer", "p", 20, reply_to="root", summary="验收通过：done")]

        segments = API["build_segments"](events, ["p", "q"], 0, 60)

        self.assertEqual([(segment["rework_count"], segment["rounds"], segment["first_pass"])
            for segment in segments], [(0, 1, True)])

    def test_same_executor_overlapping_segments_are_marked(self):
        events = [self.event("root-a", "reviewer", "p", 0),
            self.event("root-b", "reviewer", "p", 5),
            self.event("pass-a", "reviewer", "p", 20, reply_to="root-a", summary="验收通过：a"),
            self.event("pass-b", "reviewer", "p", 30, reply_to="root-b", summary="验收通过：b")]

        segments = API["build_segments"](events, ["p"], 0, 60)

        self.assertEqual([segment.get("overlap_status") for segment in segments],
            ["same_project_overlap", "same_project_overlap"])


class TestReport(unittest.TestCase):
    def test_empty_segment_role_and_bucket_are_null_but_reported_zero_stays_zero(self):
        calls = [{"project": "p", "message_id": "zero", "timestamp": 5,
            "model": "model-a", "usage": {"total_input": 0, "uncached_input": 0, "output": 0}}]
        segment = {"segment_id": "zero", "project": "p", "start": 0, "end": 10,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

        report = API["build_report"](calls, [segment], 0, 20)

        detail = report["segments"][0]
        self.assertEqual(detail["usage"]["output"]["executor"], {
            "value": 0, "known_count": 1, "eligible_count": 1, "unknown_reason_counts": {}})
        self.assertEqual(detail["usage"]["output"]["reviewer"], {
            "value": None, "known_count": 0, "eligible_count": 0, "unknown_reason_counts": {}})
        self.assertEqual(report["buckets"]["outside_unattributed"]["output"], {
            "value": None, "known_count": 0, "eligible_count": 0, "unknown_reason_counts": {}})

    def test_segment_reports_combined_usage_and_primary_executor_model(self):
        calls = [
            {"project": "reviewer", "message_id": "review", "timestamp": 5,
                "model": "review-model", "usage": {"total_input": 12,
                    "uncached_input": 10, "output": 2}},
            {"project": "p", "message_id": "execute", "timestamp": 10,
                "model": "executor-model", "usage": {"total_input": 5,
                    "uncached_input": 4, "output": 1}},
        ]
        segment = {"segment_id": "combined", "project": "p", "start": 0, "end": 20,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

        report = API["build_report"](calls, [segment], 0, 60)

        detail = report["segments"][0]
        combined = detail["usage"]["total_input"]["combined"]
        self.assertEqual((combined["value"], combined["known_count"], combined["eligible_count"]),
            (17, 2, 2))
        self.assertEqual((detail["primary_model"], detail["actual_models"]),
            ("executor-model", ["executor-model"]))

    def test_totals_separate_complete_time_samples_from_censored_segments(self):
        segments = [
            {"segment_id": "complete", "project": "p", "start": 0, "end": 10,
                "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True},
            {"segment_id": "open", "project": "p", "start": 10, "end": None,
                "status": "right_censored", "rework_count": 0, "rounds": 0, "first_pass": None},
        ]

        report = API["build_report"]([], segments, 0, 20)

        self.assertEqual(report["totals"]["time"]["wall_clock_seconds"], {
            "value": None, "known_value": 10, "known_count": 1, "eligible_count": 2,
            "unknown_reason_counts": {"right_censored": 1}})
        self.assertEqual(report["totals"]["time"]["active_seconds"]["reviewer"]["value"], 0)

    def test_left_censored_segment_keeps_only_its_observed_interval(self):
        segment = {"segment_id": "left", "project": "p", "start": 0, "end": 20,
            "status": "left_censored", "left_censored": True, "observed_from": 0,
            "observed_until": 20, "origin_status": "origin_ambiguous", "rework_count": None,
            "rounds": None, "first_pass": None}

        report = API["build_report"]([], [segment], 0, 60)

        self.assertIsNone(report["segments"][0]["start"])
        self.assertIsNone(report["segments"][0]["wall_clock_seconds"])
        self.assertEqual(report["segments"][0]["observed_interval"], {
            "from": "1970-01-01T00:00:00Z", "until": "1970-01-01T00:00:20Z"})
        self.assertEqual(report["segments"][0]["origin_status"], "origin_ambiguous")
        self.assertEqual(report["totals"]["business"]["first_pass_denominator"], 0)

    def test_segment_reports_wall_clock_and_business_coverage_separately(self):
        call = {"project": "p", "message_id": "private-id", "timestamp": 10,
            "model": "synthetic-model", "usage": {"total_input": 49,
                "uncached_input": 44, "output": 7}}
        segments = [
            {"segment_id": "complete", "project": "p", "start": 10, "end": 35,
                "status": "complete", "rework_count": 1, "rounds": 2, "first_pass": False},
            {"segment_id": "open", "project": "p", "start": 40, "end": None,
                "status": "right_censored", "rework_count": 0, "rounds": 0, "first_pass": None},
        ]

        report = API["build_report"]([call], segments, 0, 60)

        self.assertEqual([item.get("wall_clock_seconds") for item in report["segments"]], [25, None])
        self.assertEqual(report["totals"]["business"], {
            "complete_count": 1, "first_pass_numerator": 0, "first_pass_denominator": 1,
            "unmatched_terminal_count": 0})
        self.assertEqual(report["segments"][0]["calls"]["executor"], 1)
        self.assertEqual(report["totals"].get("attribution"), {
            "reviewer": {"known_count": 0, "eligible_count": 0, "bucket_reason_counts": {}},
            "executor": {"known_count": 1, "eligible_count": 1, "bucket_reason_counts": {}}})


class TestGroups(unittest.TestCase):
    def test_groups_use_each_actual_model_once_per_project_and_week(self):
        calls = [
            {"project": "p", "message_id": "private-a", "timestamp": 5,
                "model": "model-a", "usage": {"total_input": 49, "uncached_input": 44, "output": 7}},
            {"project": "p", "message_id": "private-b", "timestamp": 10,
                "model": "model-b", "usage": {"total_input": 49, "uncached_input": 44, "output": 9}},
        ]
        segment = {"segment_id": "segment-001", "project": "p", "start": 0, "end": 20,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

        report = API["build_report"](calls, [segment], 0, 60)

        self.assertEqual([(group["week_start"], group["project"], group["model"],
            group["total_input"]["value"], group["output"]["value"], group["wall_clock_seconds"],
            group["output"]["sample_count"], group["output"]["mean"], group["output"]["median"])
            for group in report["groups"]], [
                ("1969-12-29", "p", "model-a", 49, 7, None, 1, 7, 7),
                ("1969-12-29", "p", "model-b", 49, 9, None, 1, 9, 9)])
        model_usage = report["segments"][0]["model_usage"]
        self.assertEqual([(item["model"], item["calls"]["executor"],
            item["usage"]["output"]["executor"]["value"]) for item in model_usage], [
                ("model-a", 1, 7), ("model-b", 1, 9)])
        for group in report["groups"]:
            self.assertEqual(group["business"], {
                "complete_count": 1, "first_pass_numerator": 1, "first_pass_denominator": 1})
            self.assertEqual(group["wall_clock"], {"value": None, "known_count": 0,
                "eligible_count": 1, "unknown_reason_counts": {"not_attributed_by_model": 1}})
            self.assertEqual(group["integrity"], {
                "integrity_unknown_count": 1, "eligible_count": 1})
            self.assertEqual(group["attribution"], {"status": "segment_attributed_only",
                "known_count": 1, "eligible_count": 1})

    def test_cross_utc_week_unknown_model_groups_recompute_from_segments(self):
        calls = [
            {"project": "p", "message_id": "before-monday", "timestamp": 5,
                "model": None, "usage": {"total_input": 10, "uncached_input": 8, "output": 2}},
            {"project": "p", "message_id": "at-monday", "timestamp": 345599,
                "model": None, "usage": {"total_input": 20, "uncached_input": 16, "output": 4}},
        ]
        segments = [
            {"segment_id": "sunday", "project": "p", "start": 0, "end": 345599,
                "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True},
            {"segment_id": "monday", "project": "p", "start": 345599, "end": 345600,
                "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True},
        ]

        report = API["build_report"](calls, segments, 0, 400000)

        self.assertEqual([(group["week_start"], group["model"], group["total_input"]["value"],
            group["total_input"]["sample_count"]) for group in report["groups"]], [
                ("1969-12-29", None, 10, 1), ("1970-01-05", None, 20, 1)])
        detail_values = [segment["usage"]["total_input"]["executor"]["value"]
            for segment in report["segments"]]
        self.assertEqual(sum(detail_values), sum(group["total_input"]["value"]
            for group in report["groups"]))
        self.assertTrue(all(segment["primary_model"] is None for segment in report["segments"]))

    def test_group_statistics_use_independent_complete_segment_samples(self):
        calls = [
            {"project": "p", "message_id": "sample-a", "timestamp": 5, "model": "model-a",
                "usage": {"total_input": 10, "uncached_input": 8, "output": 3}},
            {"project": "p", "message_id": "sample-b", "timestamp": 25, "model": "model-a",
                "usage": {"total_input": 20, "uncached_input": 16, "output": 9}},
        ]
        segments = [
            {"segment_id": "segment-a", "project": "p", "start": 0, "end": 10, "status": "complete",
                "rework_count": 0, "rounds": 1, "first_pass": True},
            {"segment_id": "segment-b", "project": "p", "start": 20, "end": 30, "status": "complete",
                "rework_count": 0, "rounds": 1, "first_pass": True},
        ]

        report = API["build_report"](calls, segments, 0, 60)

        self.assertEqual(len(report["groups"]), 1)
        output = report["groups"][0]["output"]
        self.assertEqual((output["value"], output["sample_count"], output["mean"], output["median"]),
            (12, 2, 6, 6))

    def test_time_unknown_propagates_to_segment_model_and_group_rows(self):
        usage = {"total_input": 12, "uncached_input": 10, "output": 2}
        calls = [
            {"project": "p", "message_id": "conflicted", "timestamp": None,
                "timestamp_status": "conflict", "model": "model-a", "usage": dict(usage)},
            {"project": "p", "message_id": "known", "timestamp": 10,
                "timestamp_status": "reported", "model": "model-a", "usage": dict(usage)},
        ]
        segment = {"segment_id": "segment-001", "project": "p", "start": 0, "end": 20,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

        report = API["build_report"](calls, [segment], 0, 60)

        metric = report["segments"][0]["usage"]["total_input"]["executor"]
        self.assertEqual((metric["value"], metric["known_value"], metric["eligible_count"]),
            (None, 12, None))
        model_metric = report["segments"][0]["model_usage"][0]["usage"]["total_input"]["executor"]
        self.assertEqual((model_metric["value"], model_metric.get("known_value"),
            model_metric["eligible_count"], model_metric["unknown_reason_counts"]),
            (None, 12, None, {"time_unknown": None}))
        group_metric = report["groups"][0]["total_input"]
        self.assertEqual((group_metric["value"], group_metric.get("known_value"),
            group_metric["eligible_count"], group_metric["unknown_reason_counts"],
            group_metric["sample_count"]),
            (None, 12, None, {"time_unknown": None}, 0))

    def test_long_context_model_labels_remain_distinct_in_segment_details(self):
        calls = [
            {"project": "p", "message_id": "model-a", "timestamp": 5,
                "model": "model-a[1m]", "usage": {"total_input": 10, "uncached_input": 8, "output": 2}},
            {"project": "p", "message_id": "model-b", "timestamp": 6,
                "model": "model-b[1m]", "usage": {"total_input": 20, "uncached_input": 16, "output": 4}},
        ]
        segment = {"segment_id": "segment-001", "project": "p", "start": 0, "end": 10,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

        report = API["build_report"](calls, [segment], 0, 60)

        self.assertEqual([(item["model"], item["usage"]["total_input"]["executor"]["value"])
            for item in report["segments"][0]["model_usage"]], [
                ("model-a[1m]", 10), ("model-b[1m]", 20)])
        self.assertEqual(report["segments"][0]["actual_models"], ["model-a[1m]", "model-b[1m]"])

    def test_business_rollups_include_complete_segments_without_usage(self):
        segment = {"segment_id": "segment-001", "project": "p", "start": 0, "end": 20,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

        report = API["build_report"]([], [segment], 0, 60)

        self.assertEqual(report["groups"], [])
        self.assertIn("rollups", report)
        self.assertEqual(len(report["rollups"]["weekly"]), 1)
        weekly = report["rollups"]["weekly"][0]
        self.assertEqual((weekly["week_start"], weekly["business"]),
            ("1969-12-29", {"complete_count": 1, "first_pass_numerator": 1,
                "first_pass_denominator": 1}))
        self.assertEqual(weekly["time"]["wall_clock_seconds"], {
            "value": 20, "known_value": 20, "known_count": 1, "eligible_count": 1,
            "unknown_reason_counts": {}, "sample_count": 1, "mean": 20, "median": 20})
        self.assertEqual(report["rollups"]["projects"][0]["time"]["wall_clock_seconds"]["value"], 20)

    def test_time_rollups_do_not_repeat_a_segment_for_each_model(self):
        calls = [
            {"project": "p", "message_id": "model-a", "timestamp": 5,
                "model": "model-a", "usage": {"total_input": 10, "uncached_input": 8, "output": 2}},
            {"project": "p", "message_id": "model-b", "timestamp": 6,
                "model": "model-b", "usage": {"total_input": 20, "uncached_input": 16, "output": 4}},
        ]
        segment = {"segment_id": "segment-001", "project": "p", "start": 0, "end": 20,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

        report = API["build_report"](calls, [segment], 0, 60)

        self.assertEqual(len(report["groups"]), 2)
        self.assertIn("rollups", report)
        self.assertEqual(len(report["rollups"]["weekly"]), 1)
        self.assertEqual(report["rollups"]["weekly"][0]["time"]["wall_clock_seconds"]["value"], 20)


class TestLimits(unittest.TestCase):
    def test_total_byte_limit_accepts_equality_and_rejects_plus_one_at_production_default(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            globals_dict = API["main"].__globals__
            old_read, old_event_call_ids = globals_dict["_read"], globals_dict["_event_call_ids"]
            globals_dict["_read"] = lambda *args: ([], [], 0, 0)
            globals_dict["_event_call_ids"] = lambda *args: set()
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
            try:
                for size, expected_code in ((1024 ** 3, 0), (1024 ** 3 + 1, 2)):
                    with self.subTest(total_bytes=size):
                        with transcript.open("wb") as stream:
                            stream.truncate(size)
                        report.unlink(missing_ok=True)
                        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                            result = API["main"](arguments)
                        self.assertEqual(result, expected_code)
                        self.assertEqual(report.exists(), expected_code == 0)
            finally:
                globals_dict["_read"] = old_read
                globals_dict["_event_call_ids"] = old_event_call_ids

    def test_selected_byte_limit_accepts_equality_and_rejects_plus_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            globals_dict = API["main"].__globals__
            old_limit = globals_dict["MAX_TOTAL_BYTES"]
            globals_dict["MAX_TOTAL_BYTES"] = 10
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
            try:
                for size, expected_code in ((10, 1), (11, 2)):
                    with self.subTest(input_bytes=size):
                        transcript.write_bytes(b"x" * size)
                        report.unlink(missing_ok=True)
                        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                            result = API["main"](arguments)
                        self.assertEqual(result, expected_code)
                        self.assertEqual(report.exists(), expected_code == 1)
            finally:
                globals_dict["MAX_TOTAL_BYTES"] = old_limit

    def test_segment_model_product_accepts_one_million_and_rejects_more(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T05:33:20Z", "--json-out", str(report)]
            event_rows = []
            for index in range(10_000):
                root_key = f"root-{index}"
                event_rows.extend(event_call(2 * index, "reviewer", "/synthetic/p",
                    root_key, "notice"))
                event_rows.extend(event_call(2 * index + 1, "reviewer", "/synthetic/p",
                    f"pass-{index}", "notice", root_key, "验收通过：synthetic"))
            for model_count, expected_code in ((100, 0), (101, 2)):
                with self.subTest(segment_model_candidates=10_000 * model_count):
                    calls = [usage_call(1, f"call-{index}", 1) for index in range(model_count)]
                    for index, call in enumerate(calls):
                        call["message"]["model"] = f"model-{index}"
                    make_transcript(transcript, "reviewer", [*event_rows, *calls])
                    report.unlink(missing_ok=True)
                    result = subprocess.run([sys.executable, "-I", str(CLI), *arguments],
                        cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    self.assertEqual(report.exists(), expected_code == 0)

    def test_event_limit_accepts_twenty_thousand_and_rejects_plus_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
            for event_count, expected_code in ((20_000, 0), (20_001, 2)):
                with self.subTest(event_count=event_count):
                    rows = [row for index in range(event_count)
                        for row in event_call(0, "reviewer", "/synthetic/p",
                            f"event-{index}", "message")]
                    make_transcript(transcript, "reviewer", rows)
                    report.unlink(missing_ok=True)
                    result = subprocess.run([sys.executable, "-I", str(CLI), *arguments],
                        cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    self.assertEqual(report.exists(), expected_code == 0)

    def test_file_count_limit_accepts_two_hundred_and_rejects_plus_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript_paths = []
            for index in range(201):
                path = root / f"source-{index}.jsonl"
                path.write_text("", encoding="utf-8")
                transcript_paths.append(path)
            report = root / "report.json"
            for file_count, expected_code in ((200, 0), (201, 2)):
                with self.subTest(files=file_count):
                    transcript_args = [item for path in transcript_paths[:file_count]
                        for item in ("--transcript", f"reviewer={path}")]
                    command = [sys.executable, "-I", str(CLI),
                        "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                        *transcript_args, "--since", "1970-01-01T00:00:00Z",
                        "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
                    report.unlink(missing_ok=True)
                    result = subprocess.run(command, cwd=root,
                        env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    if expected_code:
                        self.assertEqual(result.stderr, "error: resource_limit\n")
                        self.assertFalse(report.exists())
                    else:
                        data = json.loads(report.read_text(encoding="utf-8"))
                        self.assertEqual(data["sources"]["selected_file_count"], 200)

    def test_default_concurrency_limit_accepts_128_and_rejects_129(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:01:00Z", "--json-out", str(report)]
            for concurrency, expected_code in ((128, 0), (129, 2)):
                with self.subTest(concurrency=concurrency):
                    rows = []
                    for index in range(concurrency):
                        rows.extend(event_call(0, "reviewer", "/synthetic/p",
                            f"root-{index}", "notice"))
                    for index in range(concurrency):
                        rows.extend(event_call(1, "reviewer", "/synthetic/p",
                            f"followup-{index}", "handoff", f"root-{index}"))
                    make_transcript(transcript, "reviewer", rows)
                    report.unlink(missing_ok=True)
                    result = subprocess.run([sys.executable, "-I", str(CLI), *arguments],
                        cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    self.assertEqual(report.exists(), expected_code == 0)

    def test_concurrency_limit_fails_closed_without_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            events = [event_call(0, "reviewer", "/synthetic/p", "root-a", "notice"),
                event_call(5, "reviewer", "/synthetic/p", "root-b", "notice"),
                event_call(20, "reviewer", "/synthetic/p", "pass-a", "notice", "root-a", "验收通过：a"),
                event_call(30, "reviewer", "/synthetic/p", "pass-b", "notice", "root-b", "验收通过：b")]
            make_transcript(transcript, "reviewer", events)
            globals_dict = API["main"].__globals__
            old_limit = globals_dict["MAX_CONCURRENCY"]
            globals_dict["MAX_CONCURRENCY"] = 1
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:01:00Z", "--json-out", str(report)]
            try:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    result = API["main"](arguments)
                self.assertEqual(result, 2)
                self.assertFalse(report.exists())
            finally:
                globals_dict["MAX_CONCURRENCY"] = old_limit

    def test_default_unique_call_limit_accepts_one_hundred_thousand_and_rejects_plus_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
            for call_count, expected_code in ((100_000, 0), (100_001, 2)):
                with self.subTest(call_count=call_count):
                    with transcript.open("w", encoding="utf-8") as stream:
                        for index in range(call_count):
                            stream.write(json.dumps(usage_call(0, f"call-{index}", 1)) + "\n")
                    report.unlink(missing_ok=True)
                    result = subprocess.run([sys.executable, "-I", str(CLI), *arguments],
                        cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    self.assertEqual(report.exists(), expected_code == 0)

    def test_unique_call_limit_fails_closed_without_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            make_transcript(transcript, "reviewer", [
                usage_call(0, "private-a", 1), usage_call(0, "private-b", 1)])
            globals_dict = API["main"].__globals__
            old_limit = globals_dict.get("MAX_CALLS")
            globals_dict["MAX_CALLS"] = 1
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
            try:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    result = API["main"](arguments)
                self.assertEqual(result, 2)
                self.assertFalse(report.exists())
            finally:
                if old_limit is None:
                    globals_dict.pop("MAX_CALLS", None)
                else:
                    globals_dict["MAX_CALLS"] = old_limit

    def test_project_count_limit_accepts_sixteen_and_rejects_seventeen(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            transcript.write_text("", encoding="utf-8")
            for executor_count, expected_code in ((16, 0), (17, 2)):
                with self.subTest(executors=executor_count):
                    project_args = [item for index in range(executor_count)
                        for item in ("--project", f"p{index}=/synthetic/p{index}")]
                    command = [sys.executable, "-I", str(CLI), "--project",
                        "reviewer=/synthetic/reviewer", *project_args,
                        "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                        "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
                    report.unlink(missing_ok=True)
                    result = subprocess.run(command, cwd=root,
                        env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    if expected_code:
                        self.assertEqual(result.stderr, "error: resource_limit\n")
                        self.assertFalse(report.exists())
                    else:
                        self.assertTrue(report.is_file())

    def test_model_limit_accepts_five_hundred_and_rejects_plus_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:20:00Z", "--json-out", str(report)]
            for count, expected_code in ((500, 0), (501, 2)):
                with self.subTest(model_count=count):
                    rows = [usage_call(index, f"call-{index}", 1) for index in range(count)]
                    for index, item in enumerate(rows):
                        item["message"]["model"] = f"synthetic-model-{index}"
                    make_transcript(transcript, "reviewer", rows)
                    report.unlink(missing_ok=True)
                    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                        result = API["main"](arguments)
                    self.assertEqual(result, expected_code)
                    self.assertEqual(report.exists(), expected_code == 0)

    def test_default_output_row_limit_accepts_one_hundred_thousand_and_rejects_plus_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            reviewer_file, executor_file, report = (root / name for name in (
                "reviewer.jsonl", "p.jsonl", "report.json"))
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={reviewer_file}", "--transcript", f"p={executor_file}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T06:00:00Z",
                "--json-out", str(report)]
            for overflow, expected_code in ((False, 0), (True, 2)):
                with self.subTest(output_overflow=overflow):
                    with reviewer_file.open("w", encoding="utf-8") as reviewer_stream:
                        for index in range(10_000):
                            for event in event_call(2 * index, "reviewer", "/synthetic/p",
                                    f"root-{index}", "notice"):
                                reviewer_stream.write(json.dumps(event) + "\n")
                            for event in event_call(2 * index + 1, "reviewer", "/synthetic/p",
                                    f"pass-{index}", "notice", f"root-{index}", "验收通过：done"):
                                reviewer_stream.write(json.dumps(event) + "\n")
                    with executor_file.open("w", encoding="utf-8") as executor_stream:
                        for index in range(10_000):
                            for model_index in range(9):
                                if model_index == 8 and index < 14:
                                    continue
                                call = usage_call(2 * index, f"call-{index}-{model_index}", 1)
                                call["message"]["model"] = f"model-{model_index}"
                                executor_stream.write(json.dumps(call) + "\n")
                        if overflow:
                            extra = usage_call(0, "overflow-call", 1)
                            extra["message"]["model"] = "model-8"
                            executor_stream.write(json.dumps(extra) + "\n")
                    report.unlink(missing_ok=True)
                    result = subprocess.run([sys.executable, "-I", str(CLI), *arguments],
                        cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    self.assertEqual(report.exists(), expected_code == 0)
                    if not overflow:
                        data = json.loads(report.read_text(encoding="utf-8"))
                        output_rows = (len(data["segments"]) + len(data["groups"])
                            + len(data["rollups"]["weekly"]) + len(data["rollups"]["projects"])
                            + len(data["buckets"])
                            + sum(len(segment["model_usage"]) for segment in data["segments"]))
                        self.assertEqual(output_rows, 100_000)

    def test_output_row_limit_counts_sparse_segment_model_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            project_path = "/synthetic/p"
            rows = [*event_call(0, "reviewer", project_path, "root", "notice"),
                *event_call(10, "reviewer", project_path, "pass", "notice", "root", "验收通过：done"),
                usage_call(5, "executor-call", 1)]
            make_transcript(transcript, "reviewer", rows)
            globals_dict = API["main"].__globals__
            old_limit = globals_dict["MAX_OUTPUT_ROWS"]
            globals_dict["MAX_OUTPUT_ROWS"] = 5
            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", f"p={project_path}",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:00:20Z", "--json-out", str(report)]
            try:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    result = API["main"](arguments)
                self.assertEqual(result, 2)
                self.assertFalse(report.exists())
            finally:
                globals_dict["MAX_OUTPUT_ROWS"] = old_limit

    def test_production_scale_workload_stays_under_rss_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report, wrapper = (root / name for name in (
                "selected.jsonl", "report.json", "measure.py"))
            with transcript.open("w", encoding="utf-8") as stream:
                for index in range(100_000):
                    stream.write(json.dumps(usage_call(0, f"call-{index}", 1)) + "\n")
                for index in range(10_000):
                    root_key = f"root-{index}"
                    events = [*event_call(2 * index, "reviewer", "/synthetic/p",
                            root_key, "notice"),
                        *event_call(2 * index + 1, "reviewer", "/synthetic/p",
                            f"pass-{index}", "notice", root_key, "验收通过：synthetic")]
                    for event in events:
                        stream.write(json.dumps(event) + "\n")
            wrapper.write_text(
                "import resource, subprocess, sys\n"
                "result = subprocess.run([sys.executable, '-I', *sys.argv[1:]], capture_output=True)\n"
                "print(f'child_max_rss_kib={resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss}')\n"
                "sys.stdout.buffer.write(result.stdout)\n"
                "sys.stderr.buffer.write(result.stderr)\n"
                "raise SystemExit(result.returncode)\n", encoding="utf-8")
            command = [sys.executable, "-I", str(wrapper), str(CLI),
                "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T05:33:20Z", "--json-out", str(report)]
            environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "alternate-home"),
                XDG_CONFIG_HOME=str(root / "alternate-xdg"), DRSG_EVENT_LANES="alternate-lane",
                EVENT_POLL_OWNER_PID="424242")
            result = subprocess.run(command, cwd=root,
                env=environment, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            rss_line = next(line for line in result.stdout.splitlines()
                if line.startswith("child_max_rss_kib="))
            peak_rss_kib = int(rss_line.split("=", 1)[1])
            print(f"production_scale_max_rss_kib={peak_rss_kib}")
            self.assertLessEqual(peak_rss_kib, 512 * 1024)
            data = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual((len(data["segments"]), data["totals"]["integrity"]["eligible_count"]),
                (10_000, 100_000))

    def test_transcript_line_limit_accepts_equality_and_rejects_plus_one(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            limit = 4 * 1024 * 1024
            prefix = b'{"timestamp":0,"type":"user","message":{}}'
            command = [sys.executable, "-I", str(CLI),
                "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:00:01Z",
                "--json-out", str(report)]

            for size, expected_code in ((limit, 0), (limit + 1, 2)):
                with self.subTest(line_bytes=size):
                    transcript.write_bytes(prefix + b" " * (size - len(prefix)) + b"\n")
                    report.unlink(missing_ok=True)
                    result = subprocess.run(command, cwd=root,
                        env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)
                    self.assertEqual(result.returncode, expected_code, result.stderr)
                    if expected_code:
                        self.assertEqual(result.stderr, "error: resource_limit\n")
                        self.assertFalse(report.exists())
                    else:
                        self.assertTrue(report.is_file())


class TestTimeProxies(unittest.TestCase):
    def call(self, project, message_id, timestamp):
        return {"project": project, "message_id": message_id, "timestamp": timestamp,
            "model": "synthetic-model", "usage": {"total_input": 1, "uncached_input": 1, "output": 1}}

    def segment(self, segment_id, project, start, end):
        return {"segment_id": segment_id, "project": project, "start": start, "end": end,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

    def test_activity_is_clipped_to_half_open_segment_and_outside_bucket(self):
        calls = [self.call("p", "before", 0), self.call("p", "after", 100)]
        segments = [self.segment("segment-001", "p", 10, 70)]

        report = API["build_report"](calls, segments, 0, 100)

        self.assertEqual(report["segments"][0].get("active_seconds"), {"reviewer": 0, "executor": 60})
        self.assertEqual(report["buckets"]["outside_unattributed"].get("active_seconds"),
            {"reviewer": 0, "executor": 40})

    def test_activity_counts_equal_300_second_gap_but_not_301(self):
        calls = [self.call("reviewer", "same-time-a", 0), self.call("reviewer", "same-time-b", 0),
            self.call("reviewer", "at-limit", 300), self.call("reviewer", "over-limit", 601)]
        segments = [self.segment("segment-001", "p", 0, 1_000)]

        report = API["build_report"](calls, segments, 0, 1_000)

        self.assertEqual(report["segments"][0].get("active_seconds"), {"reviewer": 300, "executor": 0})

    def test_reviewer_activity_is_split_across_unique_parallel_projects(self):
        calls = [self.call("reviewer", "review-1", 0), self.call("reviewer", "review-2", 10)]
        segments = [self.segment("segment-001", "p", 0, 20), self.segment("segment-002", "q", 0, 20)]

        report = API["build_report"](calls, segments, 0, 20)

        self.assertEqual([row.get("active_seconds") for row in report["segments"]], [
            {"reviewer": 5, "executor": 0}, {"reviewer": 5, "executor": 0}])

    def test_review_activity_conserves_with_project_overlap_mask(self):
        calls = [self.call("reviewer", "review-1", 0), self.call("reviewer", "review-2", 10)]
        segments = [self.segment("a", "p", 0, 20), self.segment("b", "p", 0, 20),
            self.segment("c", "q", 0, 20)]

        result = API["time_proxies"](calls, segments, 0, 20)

        self.assertEqual(result["segment_seconds"]["c"]["reviewer"], Fraction(10, 3))
        self.assertEqual(result["buckets"]["overlap_unattributed"]["reviewer"], Fraction(20, 3))
        self.assertEqual(result["segment_seconds"]["c"]["reviewer"] +
            result["buckets"]["overlap_unattributed"]["reviewer"], 10)

    def test_interval_work_does_not_rescan_every_segment(self):
        class CountedSegments(list):
            visits = 0

            def __iter__(self):
                for segment in super().__iter__():
                    self.visits += 1
                    yield segment

        calls = [self.call("reviewer", f"review-{timestamp}", timestamp)
            for timestamp in range(0, 201, 10)]
        segments = CountedSegments([self.segment(f"segment-{index}", f"p{index}", 0, 300)
            for index in range(8)])

        result = API["time_proxies"](calls, segments, 0, 300)

        self.assertEqual(sum(item["reviewer"] for item in result["segment_seconds"].values()), 200)
        self.assertLessEqual(segments.visits, 2 * len(segments) + 1)


class TestAllocation(unittest.TestCase):
    def test_origin_ambiguous_segment_does_not_receive_task_cost(self):
        calls = [{"project": "p", "message_id": "ambiguous", "timestamp": 5,
            "model": "model-a", "usage": {"total_input": 10, "uncached_input": 8, "output": 2}}]
        segment = {"segment_id": "ambiguous", "project": "p", "start": 0, "end": None,
            "status": "right_censored", "origin_status": "origin_ambiguous"}

        shares, buckets = API["allocate_calls"](calls, [segment])

        self.assertEqual(shares["ambiguous"]["executor"]["calls"], 0)
        self.assertEqual(buckets["overlap_unattributed"]["calls"], 1)
        self.assertEqual(buckets["overlap_unattributed"]["values"]["total_input"], 10)
        activity = API["time_proxies"]([
            {"project": "p", "message_id": "first", "timestamp": 5},
            {"project": "p", "message_id": "second", "timestamp": 10},
        ], [segment], 0, 20)
        self.assertEqual(activity["segment_seconds"]["ambiguous"]["executor"], 0)
        self.assertEqual(activity["buckets"]["overlap_unattributed"]["executor"], 5)

    def test_reviewer_tokens_conserve_across_project_overlap_and_unique_segment(self):
        calls = [{"project": "reviewer", "message_id": "review", "timestamp": 10,
            "model": "synthetic-model",
            "usage": {"total_input": 12, "uncached_input": 12, "output": 0}}]
        segments = [
            {"segment_id": "a", "project": "p", "start": 0, "end": 20},
            {"segment_id": "b", "project": "p", "start": 5, "end": 15},
            {"segment_id": "c", "project": "q", "start": 0, "end": 20},
        ]

        shares, buckets = API["allocate_calls"](calls, segments)

        self.assertEqual(shares["a"]["reviewer"]["values"]["total_input"], 0)
        self.assertEqual(shares["b"]["reviewer"]["values"]["total_input"], 0)
        self.assertEqual(shares["c"]["reviewer"]["values"]["total_input"], 4)
        self.assertEqual(buckets["overlap_unattributed"]["values"]["total_input"], 8)
        self.assertEqual(shares["c"]["reviewer"]["values"]["total_input"] +
            buckets["overlap_unattributed"]["values"]["total_input"], 12)

    def test_origin_ambiguous_roots_remain_in_reviewer_share_denominator(self):
        call = {"project": "reviewer", "message_id": "review", "timestamp": 10,
            "model": "synthetic-model",
            "usage": {"total_input": 12, "uncached_input": 12, "output": 0}}
        segments = [
            {"segment_id": "a", "project": "p", "start": 0, "end": 20,
                "origin_status": "origin_candidate"},
            {"segment_id": "b", "project": "p", "start": 5, "end": 15,
                "origin_status": "origin_ambiguous"},
            {"segment_id": "c", "project": "q", "start": 0, "end": 20,
                "origin_status": "origin_candidate"},
        ]

        shares, buckets = API["allocate_calls"]([call], segments)

        self.assertEqual(shares["c"]["reviewer"]["values"]["total_input"], 4)
        self.assertEqual(buckets["overlap_unattributed"]["values"]["total_input"], 8)

    def test_ambiguous_roots_count_toward_cli_concurrency_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "reviewer.jsonl", root / "report.json"
            events = []
            for index in range(129):
                events.extend(event_call(index, "reviewer", "/synthetic/p",
                    f"root-{index}", "notice"))
            make_transcript(transcript, "reviewer", events)
            command = [sys.executable, "-I", str(CLI),
                "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:03:20Z",
                "--json-out", str(report)]
            result = subprocess.run(command, cwd=root,
                env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True,
                capture_output=True, timeout=20)

            self.assertEqual((result.returncode, result.stderr), (2, "error: resource_limit\n"))
            self.assertFalse(report.exists())

    def test_ambiguous_roots_remain_in_reviewer_activity_denominator(self):
        calls = [
            {"project": "reviewer", "message_id": "first", "timestamp": 0},
            {"project": "reviewer", "message_id": "second", "timestamp": 10},
        ]
        segments = [
            {"segment_id": "a", "project": "p", "start": 0, "end": 10,
                "origin_status": "origin_candidate"},
            {"segment_id": "b", "project": "p", "start": 0, "end": 10,
                "origin_status": "origin_ambiguous"},
            {"segment_id": "c", "project": "q", "start": 0, "end": 10,
                "origin_status": "origin_candidate"},
        ]

        result = API["time_proxies"](
            calls, segments, 0, 10)

        self.assertEqual(result["segment_seconds"]["c"]["reviewer"], Fraction(10, 3))
        self.assertEqual(result["buckets"]["overlap_unattributed"]["reviewer"], Fraction(20, 3))


class TestExitCodes(unittest.TestCase):
    def run_cli(self, root, transcript, report, since="1970-01-01T00:00:00Z", until="1970-01-01T00:00:01Z"):
        command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
            "--project", "p=/synthetic/p", "--transcript", f"reviewer={transcript}",
            "--since", since, "--until", until, "--json-out", str(report)]
        return subprocess.run(command, cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"),
            text=True, capture_output=True)

    def assert_no_samples(self, root, transcript, report, since, until):
        result = self.run_cli(root, transcript, report, since, until)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "Selected transcript usage (not a full bill)",
            "No samples in selected transcripts and window.",
            "Segments: 0",
            "Business: complete=0; first-pass=0/0; unmatched-terminal=0",
            "Time coverage: wall-clock=0s (0/0); active reviewer=0s (3/3), executor=0s (3/3)",
            "Coverage: total_input=0/0 uncached_input=0/0 output=0/0; timestamp=0/0 model=0/0",
            "Comparability: no comparable baseline.",
            "Attribution: reviewer shares are time-window estimates; overlap and outside usage are bucketed.",
        ])
        data = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(data["scan"]["status"], "no_samples")
        self.assertEqual(data["segments"], [])
        self.assertEqual(data["totals"]["business"], {
            "complete_count": 0, "first_pass_numerator": 0, "first_pass_denominator": 0,
            "unmatched_terminal_count": 0})
        for metric in ("total_input", "uncached_input", "output"):
            self.assertIsNone(data["totals"][metric]["value"])
            self.assertEqual((data["totals"][metric]["known_count"],
                data["totals"][metric]["eligible_count"]), (0, 0))

    def test_empty_transcript_reports_no_samples_without_zero_cost(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "empty.jsonl", root / "report.json"
            transcript.write_text("", encoding="utf-8")

            self.assert_no_samples(root, transcript, report,
                "1970-01-01T00:00:00Z", "1970-01-01T00:00:01Z")

    def test_empty_window_reports_no_samples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "outside.jsonl", root / "report.json"
            make_transcript(transcript, "reviewer", [usage_call(0, "outside-window", 41)])

            self.assert_no_samples(root, transcript, report,
                "1970-01-01T00:00:10Z", "1970-01-01T00:00:20Z")

    def test_bad_json_row_is_counted_without_echoing_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "bad.jsonl", root / "report.json"
            transcript.write_text('{"timestamp": invalid, "note": "BAD-ROW-SENTINEL"}\n', encoding="utf-8")

            result = self.run_cli(root, transcript, report)

            self.assertEqual(result.returncode, 1)
            report_text = report.read_text(encoding="utf-8")
            self.assertNotIn("BAD-ROW-SENTINEL", result.stdout + result.stderr + report_text)
            self.assertNotIn(str(root), result.stdout + result.stderr + report_text)
            data = json.loads(report_text)
            self.assertEqual((data["scan"]["status"], data["scan"]["bad_row_count"]), ("partial", 1))
            self.assertEqual(result.stdout.splitlines()[-1],
                "Partial: coverage loss (1 malformed source rows); reported-usage coverage "
                "total_input=0/0 uncached_input=0/0 output=0/0.")

    def test_unselected_sibling_is_not_scanned(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "selected.jsonl", root / "report.json"
            unselected = root / "unselected.jsonl"
            transcript.write_text("", encoding="utf-8")
            unselected.write_text('{"timestamp": invalid, "note": "UNSELECTED-SENTINEL"}\n',
                encoding="utf-8")

            self.assert_no_samples(root, transcript, report,
                "1970-01-01T00:00:00Z", "1970-01-01T00:00:01Z")
            self.assertNotIn("UNSELECTED-SENTINEL", report.read_text(encoding="utf-8"))
            self.assertNotIn(str(unselected), report.read_text(encoding="utf-8"))

    def test_bad_json_line_does_not_swallow_following_jsonl_row(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "mixed.jsonl", root / "report.json"
            bad_line = '{"timestamp": invalid, "note": "MULTILINE-BAD-ROW-SENTINEL"}\n'
            valid_line = json.dumps(usage_call(0, "valid-following-row", 41)) + "\n"
            transcript.write_text(bad_line + valid_line, encoding="utf-8")

            result = self.run_cli(root, transcript, report)

            self.assertEqual(result.returncode, 1, result.stderr)
            report_text = report.read_text(encoding="utf-8")
            self.assertNotIn("MULTILINE-BAD-ROW-SENTINEL", result.stdout + result.stderr + report_text)
            self.assertEqual(result.stdout.splitlines(), [
                "Selected transcript usage (not a full bill)",
                "Reported token usage: total input 41; uncached input 41; output 0",
                "API integrity unknown: 1; reported usage is not a full bill.",
                "Segments: 0",
                "Business: complete=0; first-pass=0/0; unmatched-terminal=0",
                "Time coverage: wall-clock=0s (0/0); active reviewer=0s (3/3), executor=0s (3/3)",
                "Coverage: total_input=1/1 uncached_input=1/1 output=1/1; timestamp=1/1 model=1/1",
                "Comparability: no comparable baseline.",
                "Attribution: reviewer shares are time-window estimates; overlap and outside usage are bucketed.",
                "Partial: coverage loss (1 malformed source rows); reported-usage coverage "
                "total_input=1/1 uncached_input=1/1 output=1/1.",
            ])
            data = json.loads(report_text)
            self.assertEqual((data["scan"]["status"], data["scan"]["bad_row_count"],
                data["sources"]["rows_in_window"]), ("partial", 1, 1))
            self.assertEqual(data["totals"]["total_input"]["value"], 41)

    def test_main_never_opens_an_unselected_sibling(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, unselected, report = (root / name for name in
                ("selected.jsonl", "unselected.jsonl", "report.json"))
            transcript.write_text("", encoding="utf-8")
            unselected.write_text('{"timestamp": invalid, "note": "UNSELECTED-OPEN-SENTINEL"}',
                encoding="utf-8")
            real_open = builtins.open
            allowed_paths = {transcript.resolve(), report.resolve()}

            def guarded_open(path, *args, **kwargs):
                if pathlib.Path(path).resolve() not in allowed_paths:
                    raise AssertionError("path outside explicit inputs opened")
                return real_open(path, *args, **kwargs)

            arguments = ["--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:00:01Z", "--json-out", str(report)]
            with patch("builtins.open", guarded_open):
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    exit_code = API["main"](arguments)

            self.assertEqual(exit_code, 0)
            data = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(data["scan"]["status"], "no_samples")
            self.assertNotIn("UNSELECTED-OPEN-SENTINEL", report.read_text(encoding="utf-8"))

    def test_missing_selected_transcript_fails_without_json_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            report = root / "report.json"

            result = self.run_cli(root, root / "missing.jsonl", report)

            self.assertEqual((result.returncode, result.stderr), (2, "error: input_unreadable\n"))
            self.assertFalse(report.exists())


class TestTranscriptList(unittest.TestCase):
    def test_multiple_selected_files_for_one_project_are_combined(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            first, second, report = root / "first.jsonl", root / "second.jsonl", root / "report.json"
            make_transcript(first, "reviewer", [usage_call(0, "private-a", 41)])
            make_transcript(second, "reviewer", [usage_call(0, "private-b", 41)])
            command = [sys.executable, "-I", str(CLI),
                "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={first}", "--transcript", f"reviewer={second}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:00:01Z",
                "--json-out", str(report)]

            result = subprocess.run(command, cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"),
                text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(data["sources"]["selected_file_count"], 2)
            self.assertEqual(data["totals"]["total_input"]["value"], 82)


class TestEndToEnd(unittest.TestCase):
    def test_synthetic_transcripts_flow_through_segments_shares_and_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            reviewer_file, p_file, q_file = (root / name for name in ("reviewer.jsonl", "p.jsonl", "q.jsonl"))
            paths = {"reviewer": "/synthetic/reviewer", "p": "/synthetic/p", "q": "/synthetic/q"}
            events = [
                event_call(0, "reviewer", paths["p"], "root-a", "notice", summary="ROOT-SUMMARY-SENTINEL"),
                event_call(5, "reviewer", paths["p"], "root-b", "notice"),
                event_call(0, "reviewer", paths["q"], "root-c", "notice"),
                event_call(15, "reviewer", paths["p"], "pass-b", "notice", "root-b", "验收通过：sentinel"),
                event_call(20, "reviewer", paths["p"], "pass-a", "notice", "root-a", "验收通过：sentinel"),
                event_call(20, "reviewer", paths["q"], "pass-c", "notice", "root-c", "验收通过：sentinel"),
            ]
            for event_call_pair in events:
                event_call_pair[0]["message"]["content"][0]["input"]["ref"] = "EVENT-REF-SENTINEL"
                event_call_pair[1]["message"]["content"][0]["content"] += "\nTOOL-RESULT-SENTINEL"
            reviewer_call = usage_call(10, "review-call", 12)
            reviewer_call["sessionId"] = "SESSION-ID-SENTINEL"
            reviewer_call["message"]["id"] = "MESSAGE-ID-SENTINEL"
            reviewer_rows = [reviewer_call, *events]
            make_transcript(reviewer_file, "reviewer", reviewer_rows)
            make_transcript(p_file, "p", [usage_call(2, "p-a", 5), usage_call(7, "p-overlap", 6)])
            make_transcript(q_file, "q", [usage_call(10, "q-c", 3)])
            report_path = root / "report.json"
            command = [sys.executable, "-I", str(CLI),
                "--project", f"reviewer={paths['reviewer']}",
                "--project", f"p={paths['p']}", "--project", f"q={paths['q']}",
                "--transcript", f"reviewer={reviewer_file}",
                "--transcript", f"p={p_file}", "--transcript", f"q={q_file}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(report_path)]
            environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
            environment.pop("EVENT_POLL_OWNER_PID", None)
            result = subprocess.run(command, cwd=root, env=environment, text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                "Selected transcript usage (not a full bill)",
                "Reported token usage: total input 26; uncached input 26; output 0",
                "API integrity unknown: 4; reported usage is not a full bill.",
                "Segments: 3",
                "Business: complete=3; first-pass=3/3; unmatched-terminal=0",
                "Time coverage: wall-clock=50s (3/3); active reviewer=0s (6/6), executor=5s (6/6)",
                "Coverage: total_input=4/4 uncached_input=4/4 output=4/4; timestamp=4/4 model=4/4",
                "Comparability: no comparable baseline.",
                "Attribution: reviewer shares are time-window estimates; overlap and outside usage are bucketed.",
            ])
            serialized = result.stdout + result.stderr + report_path.read_text(encoding="utf-8")
            for sensitive in ("SENTINEL", "sentinel", "MESSAGE-ID-SENTINEL", "SESSION-ID-SENTINEL",
                    "EVENT-REF-SENTINEL", "ROOT-SUMMARY-SENTINEL", "TOOL-RESULT-SENTINEL",
                    "PROMPT-SENTINEL", "/synthetic/p", "/synthetic/reviewer", str(root), "root-a"):
                self.assertNotIn(sensitive, serialized)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["scan"]["status"], "complete")
            self.assertEqual(report["comparability"], "no_comparable_baseline")
            self.assertEqual(report["totals"]["total_input"]["value"], 26)
            self.assertEqual(report["totals"]["integrity"]["integrity_unknown_count"], 4)
            self.assertEqual([(s.get("rework_count"), s.get("rounds"), s.get("first_pass"))
                for s in report["segments"]], [(0, 1, True), (0, 1, True), (0, 1, True)])
            self.assertEqual(report["totals"].get("business"), {
                "complete_count": 3, "first_pass_numerator": 3, "first_pass_denominator": 3,
                "unmatched_terminal_count": 0})
            self.assertEqual([(s["project"], s["start"], s["end"]) for s in report["segments"]], [
                ("p", "1970-01-01T00:00:00Z", "1970-01-01T00:00:20Z"),
                ("q", "1970-01-01T00:00:00Z", "1970-01-01T00:00:20Z"),
                ("p", "1970-01-01T00:00:05Z", "1970-01-01T00:00:15Z"),
            ])
            self.assertEqual([s["usage"]["total_input"]["reviewer"]["value"] for s in report["segments"]],
                [None, 4, None])
            self.assertEqual([s["usage"]["total_input"]["executor"]["value"] for s in report["segments"]],
                [5, 3, None])
            self.assertEqual(report["buckets"]["overlap_unattributed"]["total_input"]["value"], 14)
            outside = report["buckets"]["outside_unattributed"]["total_input"]
            self.assertEqual((outside["value"], outside["known_count"], outside["eligible_count"]),
                (None, 0, 0))

    def test_left_censored_cli_exports_null_start_and_observed_window(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report_path = root / "reviewer.jsonl", root / "report.json"
            make_transcript(transcript, "reviewer", [event_call(20, "reviewer",
                "/synthetic/p", "late-pass", "notice", "outside-root", "验收通过：done")])
            command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
                "--project", "p=/synthetic/p", "--transcript", f"reviewer={transcript}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(report_path)]
            environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
            environment.pop("EVENT_POLL_OWNER_PID", None)

            result = subprocess.run(command, cwd=root, env=environment, text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(len(report["segments"]), 1)
            segment = report["segments"][0]
            self.assertEqual((segment["status"], segment["start"], segment["end"]),
                ("left_censored", None, "1970-01-01T00:00:20Z"))
            self.assertEqual(segment["observed_interval"], {
                "from": "1970-01-01T00:00:00Z", "until": "1970-01-01T00:00:20Z"})
            self.assertEqual(segment["origin_status"], "origin_ambiguous")
            self.assertEqual(report["totals"]["business"]["first_pass_denominator"], 0)
            self.assertEqual(report["totals"]["business"]["unmatched_terminal_count"], 0)
            for private in ("outside-root", "/synthetic/", str(root)):
                self.assertNotIn(private, result.stdout + result.stderr + report_path.read_text())

    def test_failed_acceptance_keeps_work_open_until_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            reviewer_file, executor_file = root / "reviewer.jsonl", root / "p.jsonl"
            paths = {"reviewer": "/synthetic/reviewer", "p": "/synthetic/p"}
            events = [
                event_call(0, "reviewer", paths["p"], "root", "notice"),
                event_call(10, "reviewer", paths["p"], "reject", "handoff", "root", "验收不通过：retry"),
                event_call(20, "reviewer", paths["p"], "accept", "notice", "reject", "验收通过：done"),
            ]
            make_transcript(reviewer_file, "reviewer", [usage_call(15, "review-call", 12), *events])
            make_transcript(executor_file, "p", [usage_call(15, "executor-call", 5)])
            report_path = root / "report.json"
            command = [sys.executable, "-I", str(CLI),
                "--project", f"reviewer={paths['reviewer']}", "--project", f"p={paths['p']}",
                "--transcript", f"reviewer={reviewer_file}", "--transcript", f"p={executor_file}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(report_path)]
            environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
            environment.pop("EVENT_POLL_OWNER_PID", None)
            result = subprocess.run(command, cwd=root, env=environment, text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(len(report["segments"]), 1)
            segment = report["segments"][0]
            self.assertEqual(segment["end"], "1970-01-01T00:00:20Z")
            self.assertEqual((segment.get("rework_count"), segment.get("rounds"), segment.get("first_pass")), (1, 2, False))
            self.assertEqual(report["totals"].get("business"), {
                "complete_count": 1, "first_pass_numerator": 0, "first_pass_denominator": 1,
            "unmatched_terminal_count": 0})
            self.assertEqual(segment["usage"]["total_input"]["reviewer"]["value"], 12)
            self.assertEqual(segment["usage"]["total_input"]["executor"]["value"], 5)
            outside = report["buckets"]["outside_unattributed"]["total_input"]
            self.assertEqual((outside["value"], outside["known_count"], outside["eligible_count"]),
                (None, 0, 0))

    def test_failed_acceptance_without_success_leaves_segment_open(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript = root / "reviewer.jsonl"
            project_path = "/synthetic/p"
            events = [
                event_call(0, "reviewer", project_path, "root", "notice"),
                event_call(10, "reviewer", project_path, "reject", "handoff", "root", "验收不通过：retry"),
            ]
            make_transcript(transcript, "reviewer", events)
            result_path = root / "report.json"
            command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
                "--project", f"p={project_path}", "--transcript", f"reviewer={transcript}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(result_path)]
            result = subprocess.run(command, cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"),
                text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            segment = json.loads(result_path.read_text(encoding="utf-8"))["segments"][0]
            self.assertEqual(segment["status"], "right_censored")
            self.assertIsNone(segment["end"])
            self.assertEqual((segment.get("rework_count"), segment.get("rounds"), segment.get("first_pass")), (1, 1, None))
            self.assertEqual(json.loads(result_path.read_text(encoding="utf-8"))["totals"].get("business"), {
                "complete_count": 0, "first_pass_numerator": 0, "first_pass_denominator": 0,
            "unmatched_terminal_count": 0})

    def test_unmatched_acceptance_does_not_add_segment_or_business_denominator(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript = root / "reviewer.jsonl"
            project_path = "/synthetic/p"
            events = [
                event_call(0, "reviewer", project_path, "root-a", "notice"),
                event_call(5, "reviewer", project_path, "root-b", "notice"),
                event_call(20, "reviewer", project_path, "pass-a", "notice", "root-a", "验收通过：done"),
                event_call(30, "reviewer", project_path, "late-pass", "notice", summary="验收通过：late"),
            ]
            make_transcript(transcript, "reviewer", events)
            report_path = root / "report.json"
            command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
                "--project", f"p={project_path}", "--transcript", f"reviewer={transcript}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(report_path)]
            result = subprocess.run(command, cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"),
                text=True, capture_output=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(len(report["segments"]), 2)
            self.assertEqual([(segment["start"], segment["end"], segment["status"])
                for segment in report["segments"]], [
                    ("1970-01-01T00:00:00Z", "1970-01-01T00:00:20Z", "complete"),
                    ("1970-01-01T00:00:05Z", None, "right_censored"),
                ])
            self.assertEqual(report["totals"]["business"], {
                "complete_count": 1, "first_pass_numerator": 1, "first_pass_denominator": 1,
                "unmatched_terminal_count": 1})
            self.assertIn("Business: complete=1; first-pass=1/1; unmatched-terminal=1",
                result.stdout.splitlines())

    def test_usage_gap_is_partial_and_keeps_independent_metrics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript = root / "reviewer.jsonl"
            missing = usage_call(10, "missing-cache-read", 41)
            del missing["message"]["usage"]["cache_read_input_tokens"]
            conflict_a = usage_call(20, "conflicting-output", 2)
            conflict_b = usage_call(20, "conflicting-output", 2)
            conflict_b["message"]["usage"]["output_tokens"] = 8
            make_transcript(transcript, "reviewer", [missing, conflict_a, conflict_b])
            report_path = root / "report.json"
            command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
                "--project", "p=/synthetic/p", "--transcript", f"reviewer={transcript}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(report_path)]
            result = subprocess.run(command, cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"),
                text=True, capture_output=True)

            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(without_cost_summary(result.stdout.splitlines()), [
                "Selected transcript usage (not a full bill)",
                "Reported token usage: total input None; uncached input 43; output None",
                "API integrity unknown: 2; reported usage is not a full bill.",
                "Segments: 0",
                "Attribution: reviewer shares are time-window estimates; overlap and outside usage are bucketed.",
                "Partial: coverage loss (0 malformed source rows); reported-usage coverage total_input=1/2 uncached_input=2/2 output=1/2.",
            ])
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["scan"]["status"], "partial")
            self.assertIsNone(report["totals"]["total_input"]["value"])
            self.assertEqual(report["totals"]["uncached_input"]["value"], 43)
            self.assertIsNone(report["totals"]["output"]["value"])
            self.assertEqual(report["totals"]["integrity"]["integrity_unknown_count"], 2)

    def test_segment_and_bucket_coverage_counts_only_known_metric_calls(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            reviewer_file, executor_file, other_file = (root / name for name in (
                "reviewer.jsonl", "p.jsonl", "q.jsonl"))
            paths = {"reviewer": "/synthetic/reviewer", "p": "/synthetic/p", "q": "/synthetic/q"}
            events = [
                event_call(0, "reviewer", paths["p"], "root", "notice"),
                event_call(20, "reviewer", paths["p"], "accept", "notice", "root", "验收通过：done"),
                event_call(0, "reviewer", paths["q"], "root-q", "notice"),
                event_call(20, "reviewer", paths["q"], "accept-q", "notice", "root-q", "验收通过：done"),
            ]
            reviewer_call = usage_call(10, "reviewer-missing", 41)
            del reviewer_call["message"]["usage"]["cache_read_input_tokens"]
            reviewer_call["message"]["usage"]["output_tokens"] = 7
            make_transcript(reviewer_file, "reviewer", [reviewer_call, *events])
            executor_call = usage_call(10, "executor-missing", 41)
            del executor_call["message"]["usage"]["cache_read_input_tokens"]
            executor_call["message"]["usage"]["output_tokens"] = 7
            make_transcript(executor_file, "p", [executor_call])
            outside_missing = usage_call(30, "outside-missing", 2)
            del outside_missing["message"]["usage"]["cache_read_input_tokens"]
            outside_known = usage_call(31, "outside-known", 3)
            make_transcript(other_file, "q", [outside_missing, outside_known])
            report_path = root / "report.json"
            command = [sys.executable, "-I", str(CLI),
                "--project", f"reviewer={paths['reviewer']}", "--project", f"p={paths['p']}",
                "--project", f"q={paths['q']}", "--transcript", f"reviewer={reviewer_file}",
                "--transcript", f"p={executor_file}", "--transcript", f"q={other_file}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(report_path)]
            result = subprocess.run(command, cwd=root, env=dict(os.environ, LC_ALL="C", TZ="UTC"),
                text=True, capture_output=True)

            self.assertEqual(result.returncode, 1, result.stderr)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            segments = {item["project"]: item for item in report["segments"]}
            segment = segments["p"]
            for item in segments.values():
                metric = item["usage"]["total_input"]["reviewer"]
                self.assertEqual((metric["known_count"], metric["eligible_count"]), (0, 0.5))
                self.assertIsNone(metric["value"])
            executor_total = segment["usage"]["total_input"]["executor"]
            self.assertEqual((executor_total["known_count"], executor_total["eligible_count"]), (0, 1))
            self.assertIsNone(executor_total["value"])
            self.assertEqual((segment["usage"]["output"]["reviewer"]["known_count"],
                segment["usage"]["output"]["reviewer"]["eligible_count"],
                segment["usage"]["output"]["reviewer"]["value"]), (0.5, 0.5, 3.5))
            executor_usage = segment["usage"]
            self.assertEqual((executor_usage["uncached_input"]["executor"]["known_count"],
                executor_usage["uncached_input"]["executor"]["eligible_count"],
                executor_usage["uncached_input"]["executor"]["value"]), (1, 1, 41))
            self.assertEqual((executor_usage["output"]["executor"]["known_count"],
                executor_usage["output"]["executor"]["eligible_count"],
                executor_usage["output"]["executor"]["value"]), (1, 1, 7))
            bucket = report["buckets"]["outside_unattributed"]["total_input"]
            self.assertEqual((bucket["known_count"], bucket["eligible_count"]), (1, 2))
            self.assertIsNone(bucket["value"])


class TestUsageMatrix(unittest.TestCase):
    def message(self):
        return {"usage": {"input_tokens": 41, "cache_creation_input_tokens": 3,
            "cache_read_input_tokens": 5, "output_tokens": 7}}

    def test_explicit_zero_is_reported(self):
        message = self.message()
        message["usage"]["input_tokens"] = 0

        usage = API["parse_usage"](message)

        self.assertEqual(usage["recorded"]["input_tokens"], 0)
        self.assertEqual(usage["field_status"]["input_tokens"], "reported")

    def test_missing_field_is_not_zero(self):
        message = self.message()
        del message["usage"]["input_tokens"]

        usage = API["parse_usage"](message)

        self.assertIsNone(usage["recorded"]["input_tokens"])
        self.assertEqual(usage["field_status"]["input_tokens"], "missing")

    def test_each_field_distinguishes_zero_missing_and_invalid_values(self):
        for field in API["USAGE_FIELDS"]:
            with self.subTest(field=field, state="zero"):
                message = self.message()
                message["usage"][field] = 0
                usage = API["parse_usage"](message)
                self.assertEqual(usage["recorded"][field], 0)
                self.assertEqual(usage["field_status"][field], "reported")
            with self.subTest(field=field, state="missing"):
                message = self.message()
                del message["usage"][field]
                usage = API["parse_usage"](message)
                self.assertIsNone(usage["recorded"][field])
                self.assertEqual(usage["field_status"][field], "missing")
            for value in (True, -1, 1.5, "1"):
                with self.subTest(field=field, invalid=value):
                    message = self.message()
                    message["usage"][field] = value
                    usage = API["parse_usage"](message)
                    self.assertIsNone(usage["recorded"][field])
                    self.assertEqual(usage["field_status"][field], "invalid")

    def test_missing_and_invalid_dependencies_affect_only_dependent_metrics(self):
        expected = {
            "input_tokens": (None, None, 7),
            "cache_creation_input_tokens": (None, None, 7),
            "cache_read_input_tokens": (None, 44, 7),
            "output_tokens": (49, 44, None),
        }
        for field, metrics in expected.items():
            for state, value in (("missing", None), ("invalid", "bad")):
                with self.subTest(field=field, state=state):
                    message = self.message()
                    if state == "missing":
                        del message["usage"][field]
                    else:
                        message["usage"][field] = value
                    usage = API["parse_usage"](message)
                    self.assertEqual((usage["total_input"], usage["uncached_input"], usage["output"]),
                        metrics)
                    for other in set(API["USAGE_FIELDS"]) - {field}:
                        self.assertEqual(usage["field_status"][other], "reported")

    def test_integrity_unknown_does_not_filter_reported_usage(self):
        for message in (self.message(),
                {**self.message(), "stop_reason": "end_turn", "isMeta": True}):
            with self.subTest(message=message):
                usage = API["parse_usage"](message)
                self.assertEqual((usage["total_input"], usage["uncached_input"], usage["output"]),
                    (49, 44, 7))
                self.assertEqual(usage["integrity"], "integrity_unknown")

    def test_fixture_message_identity_does_not_change_reported_values(self):
        records = []
        for message_id in ("synthetic-a", "synthetic-b"):
            message = self.message()
            message["id"] = message_id
            records.append({"project": "reviewer", "message_id": message_id,
                "timestamp": 0, "model": "synthetic-model", "usage": message["usage"]})

        calls = API["canonical_usage"](records)

        self.assertEqual(len(calls), 2)
        self.assertEqual([(call["usage"]["total_input"], call["usage"]["uncached_input"],
            call["usage"]["output"], call["usage"]["integrity"]) for call in calls],
            [(49, 44, 7, "integrity_unknown"), (49, 44, 7, "integrity_unknown")])


class TestUsageCliMatrix(unittest.TestCase):
    def test_reported_normal_zero_and_missing_dependency_through_cli(self):
        cases = (
            ("normal", {"input_tokens": 41, "cache_creation_input_tokens": 3,
                "cache_read_input_tokens": 5, "output_tokens": 7}, 0, "complete",
                (49, 44, 7), ((1, 1), (1, 1), (1, 1))),
            ("partial-risk-zero-output", {"input_tokens": 41, "cache_creation_input_tokens": 3,
                "cache_read_input_tokens": 5, "output_tokens": 0}, 0, "complete",
                (49, 44, 0), ((1, 1), (1, 1), (1, 1))),
            ("missing-cache-read", {"input_tokens": 41, "cache_creation_input_tokens": 3,
                "output_tokens": 7}, 1, "partial", (None, 44, 7),
                ((0, 1), (1, 1), (1, 1))),
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for name, usage, exit_code, scan_status, values, coverage in cases:
                with self.subTest(case=name):
                    transcript, report_path = root / f"{name}.jsonl", root / f"{name}.json"
                    message = usage_call(0, name, usage["input_tokens"])
                    message["message"]["usage"] = usage
                    message["message"]["usage"]["cache_creation_input_tokens"] = usage["cache_creation_input_tokens"]
                    if "cache_read_input_tokens" in usage:
                        message["message"]["usage"]["cache_read_input_tokens"] = usage["cache_read_input_tokens"]
                    message["message"]["usage"]["output_tokens"] = usage["output_tokens"]
                    message["message"]["stop_reason"] = "end_turn"
                    make_transcript(transcript, "reviewer", [message])
                    command = [sys.executable, "-I", str(CLI),
                        "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                        "--transcript", f"reviewer={transcript}",
                        "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:00:01Z",
                        "--json-out", str(report_path)]
                    environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                        XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
                    environment.pop("EVENT_POLL_OWNER_PID", None)
                    result = subprocess.run(command, cwd=root, env=environment,
                        text=True, capture_output=True)

                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    report = json.loads(report_path.read_text(encoding="utf-8"))
                    self.assertEqual(report["scan"]["status"], scan_status)
                    for metric, value, counts in zip(
                            ("total_input", "uncached_input", "output"), values, coverage):
                        entry = report["totals"][metric]
                        self.assertEqual(entry["value"], value)
                        self.assertEqual((entry["known_count"], entry["eligible_count"]), counts)
                    self.assertEqual(report["totals"]["integrity"], {
                        "integrity_unknown_count": 1, "eligible_count": 1})


class TestUnsupportedUsageCli(unittest.TestCase):
    def test_non_dict_usage_is_reported_as_partial_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for name, usage in (("list", ["synthetic"]), ("string", "synthetic")):
                with self.subTest(shape=name):
                    transcript, report_path = root / f"{name}.jsonl", root / f"{name}.json"
                    message = usage_call(0, f"unsupported-{name}", 41)
                    message["message"]["usage"] = usage
                    make_transcript(transcript, "reviewer", [message])
                    command = [sys.executable, "-I", str(CLI),
                        "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                        "--transcript", f"reviewer={transcript}",
                        "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:00:01Z",
                        "--json-out", str(report_path)]
                    environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                        XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
                    environment.pop("EVENT_POLL_OWNER_PID", None)
                    result = subprocess.run(command, cwd=root, env=environment,
                        text=True, capture_output=True)

                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stderr, "")
                    self.assertEqual(without_cost_summary(result.stdout.splitlines()), [
                        "Selected transcript usage (not a full bill)",
                        "Reported token usage: total input None; uncached input None; output None",
                        "API integrity unknown: 1; reported usage is not a full bill.",
                        "Segments: 0",
                        "Attribution: reviewer shares are time-window estimates; overlap and outside usage are bucketed.",
                        "Partial: coverage loss (0 malformed source rows); reported-usage coverage "
                        "total_input=0/1 uncached_input=0/1 output=0/1.",
                    ])
                    self.assertTrue(report_path.is_file())
                    serialized = result.stdout + result.stderr + report_path.read_text(encoding="utf-8")
                    self.assertNotIn("synthetic", serialized)
                    self.assertNotIn(str(root), serialized)
                    report = json.loads(report_path.read_text(encoding="utf-8"))
                    self.assertEqual(report["scan"]["status"], "partial")
                    self.assertEqual(report["segments"], [])
                    for metric in ("total_input", "uncached_input", "output"):
                        self.assertEqual(report["totals"][metric], {
                            "value": None, "known_count": 0, "eligible_count": 1,
                            "unknown_reason_counts": {"missing_or_conflict": 1}})
                    self.assertEqual(report["totals"]["integrity"], {
                        "integrity_unknown_count": 1, "eligible_count": 1})


class TestUsageDuplicateMatrix(unittest.TestCase):
    fields = ("input_tokens", "cache_creation_input_tokens",
        "cache_read_input_tokens", "output_tokens")

    def record(self, project, message_id, usage):
        return {"project": project, "message_id": message_id, "timestamp": 0,
            "model": "synthetic-model", "usage": dict(usage)}

    def normal(self, output=7):
        return {"input_tokens": 41, "cache_creation_input_tokens": 3,
            "cache_read_input_tokens": 5, "output_tokens": output}

    def test_complete_identical_copies_count_once_for_one_two_or_three(self):
        record = self.record("p", "same-message", self.normal())
        reports = [API["canonical_usage"]([record] * count) for count in (1, 2, 3)]

        self.assertEqual(reports[0], reports[1])
        self.assertEqual(reports[1], reports[2])
        usage = reports[0][0]["usage"]
        self.assertEqual((usage["total_input"], usage["uncached_input"], usage["output"]),
            (49, 44, 7))
        report = API["build_report"](reports[0], [], 0, 1)
        self.assertEqual([(report["totals"][name]["value"],
            report["totals"][name]["known_count"], report["totals"][name]["eligible_count"])
            for name in ("total_input", "uncached_input", "output")],
            [(49, 1, 1), (44, 1, 1), (7, 1, 1)])

    def test_same_message_id_in_two_projects_remains_two_calls(self):
        records = [self.record("p", "shared-id", self.normal(7)),
            self.record("q", "shared-id", self.normal(9))]

        calls = API["canonical_usage"](records)
        report = API["build_report"](calls, [], 0, 1)

        self.assertEqual([(call["project"], call["message_id"]) for call in calls],
            [("p", "shared-id"), ("q", "shared-id")])
        self.assertEqual([(report["totals"][name]["value"],
            report["totals"][name]["known_count"], report["totals"][name]["eligible_count"])
            for name in ("total_input", "uncached_input", "output")],
            [(98, 2, 2), (88, 2, 2), (16, 2, 2)])
        self.assertEqual(report["totals"]["integrity"], {
            "integrity_unknown_count": 2, "eligible_count": 2})

    def test_single_field_conflicts_propagate_only_to_dependent_metrics_in_all_orders(self):
        dependencies = {
            "input_tokens": ((None, None, 7), "input_tokens"),
            "cache_creation_input_tokens": ((None, None, 7), "cache_creation_input_tokens"),
            "cache_read_input_tokens": ((None, 44, 7), "cache_read_input_tokens"),
            "output_tokens": ((49, 44, None), "output_tokens"),
        }
        for field, (expected_values, conflicted_field) in dependencies.items():
            with self.subTest(field=field):
                first = self.normal()
                second = dict(first)
                second[field] = first[field] + 2
                third = dict(first)
                records = [self.record("p", "conflict", usage)
                    for usage in (first, second, third)]
                results = [API["canonical_usage"](order) for order in itertools.permutations(records)]
                self.assertTrue(all(result == results[0] for result in results[1:]))
                usage = results[0][0]["usage"]
                self.assertEqual((usage["total_input"], usage["uncached_input"], usage["output"]),
                    expected_values)
                self.assertEqual(tuple(usage["field_status"][name] for name in self.fields),
                    tuple("conflict" if name == conflicted_field else "reported"
                        for name in self.fields))
                report = API["build_report"](results[0], [], 0, 1)
                for metric, value in zip(("total_input", "uncached_input", "output"), expected_values):
                    entry = report["totals"][metric]
                    self.assertEqual(entry["value"], value)
                    expected_known = 0 if value is None else 1
                    self.assertEqual((entry["known_count"], entry["eligible_count"]),
                        (expected_known, 1))
                self.assertEqual(report["totals"]["integrity"], {
                    "integrity_unknown_count": 1, "eligible_count": 1})


class TestUsageDuplicateCliMatrix(unittest.TestCase):
    def usage(self, output=7):
        return {"input_tokens": 41, "cache_creation_input_tokens": 3,
            "cache_read_input_tokens": 5, "output_tokens": output}

    def run_cli(self, root, name, transcripts):
        transcript_args = []
        for label, rows in transcripts.items():
            path = root / f"{name}-{label}.jsonl"
            make_transcript(path, label, rows)
            transcript_args.extend(("--transcript", f"{label}={path}"))
        report_path = root / f"{name}.json"
        command = [sys.executable, "-I", str(CLI),
            "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
            "--project", "q=/synthetic/q", *transcript_args,
            "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:00:01Z",
            "--json-out", str(report_path)]
        environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
            XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
        environment.pop("EVENT_POLL_OWNER_PID", None)
        result = subprocess.run(command, cwd=root, env=environment, text=True, capture_output=True)
        return result, report_path

    def call_row(self, message_id, usage):
        call = usage_call(0, message_id, usage["input_tokens"])
        call["message"]["usage"] = usage
        return call

    def metric_tuple(self, report):
        return [(report["totals"][name]["value"], report["totals"][name]["known_count"],
            report["totals"][name]["eligible_count"])
            for name in ("total_input", "uncached_input", "output")]

    def test_identical_duplicate_cli_counts_once_for_one_two_and_three_rows(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            reports = []
            for count in (1, 2, 3):
                rows = [self.call_row("same-message", self.usage()) for _ in range(count)]
                result, path = self.run_cli(root, f"copies-{count}", {"reviewer": rows})
                self.assertEqual((result.returncode, result.stderr), (0, ""))
                report = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(report["scan"]["status"], "complete")
                self.assertEqual(self.metric_tuple(report), [(49, 1, 1), (44, 1, 1), (7, 1, 1)])
                reports.append(self.metric_tuple(report))
                self.assertNotIn("same-message", path.read_text(encoding="utf-8"))
            self.assertEqual(reports, [reports[0]] * 3)

    def test_cross_project_duplicate_id_cli_keeps_both_reports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            result, path = self.run_cli(root, "cross-project", {
                "p": [self.call_row("shared-private-id", self.usage(7))],
                "q": [self.call_row("shared-private-id", self.usage(9))],
            })
            self.assertEqual((result.returncode, result.stderr), (0, ""))
            report = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(report["scan"]["status"], "complete")
            self.assertEqual(self.metric_tuple(report), [(98, 2, 2), (88, 2, 2), (16, 2, 2)])
            self.assertEqual(report["totals"]["integrity"], {
                "integrity_unknown_count": 2, "eligible_count": 2})
            serialized = path.read_text(encoding="utf-8") + result.stdout + result.stderr
            self.assertNotIn("shared-private-id", serialized)
            self.assertNotIn("/synthetic/", serialized)

    def test_single_field_conflicts_cli_are_stable_and_keep_independent_values(self):
        expected = {
            "input_tokens": (1, "partial", [(None, 0, 1), (None, 0, 1), (7, 1, 1)]),
            "cache_creation_input_tokens": (1, "partial", [(None, 0, 1), (None, 0, 1), (7, 1, 1)]),
            "cache_read_input_tokens": (1, "partial", [(None, 0, 1), (44, 1, 1), (7, 1, 1)]),
            "output_tokens": (1, "partial", [(49, 1, 1), (44, 1, 1), (None, 0, 1)]),
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            for field, (exit_code, status, metrics) in expected.items():
                with self.subTest(field=field):
                    first = self.usage()
                    second = dict(first)
                    second[field] += 2
                    third = dict(first)
                    rows = [self.call_row("private-conflict-id", usage)
                        for usage in (first, second, third)]
                    outputs = []
                    for index, order in enumerate(itertools.permutations(rows)):
                        result, path = self.run_cli(root, f"conflict-{field}-{index}", {"reviewer": order})
                        self.assertEqual(result.returncode, exit_code, result.stderr)
                        self.assertEqual(result.stderr, "")
                        report = json.loads(path.read_text(encoding="utf-8"))
                        self.assertEqual(report["scan"]["status"], status)
                        self.assertEqual(self.metric_tuple(report), metrics)
                        self.assertEqual(report["totals"]["integrity"], {
                            "integrity_unknown_count": 1, "eligible_count": 1})
                        serialized = path.read_text(encoding="utf-8") + result.stdout
                        self.assertNotIn("private-conflict-id", serialized)
                        self.assertNotIn("/synthetic/", serialized)
                        outputs.append(self.metric_tuple(report))
                    self.assertTrue(all(output == outputs[0] for output in outputs[1:]))


class TestUsageClosure(unittest.TestCase):
    def record(self, stamp=10, model="synthetic-model", message_id="private-call"):
        return {"project": "p", "message_id": message_id, "timestamp": stamp,
            "model": model, "usage": {"input_tokens": 41, "cache_creation_input_tokens": 3,
                "cache_read_input_tokens": 5, "output_tokens": 7}}

    def segment(self, project="p"):
        return {"segment_id": project, "project": project, "start": 0, "end": 60,
            "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}

    def test_duplicate_evidence_is_one_call(self):
        record = self.record()
        self.assertEqual(len(API["canonical_usage"]([record, record, dict(record)])), 1)

    def test_missing_token_is_unknown(self):
        record = self.record()
        del record["usage"]["output_tokens"]
        self.assertIsNone(API["canonical_usage"]([record])[0]["usage"]["output"])

    def test_unknown_segment_is_not_precise(self):
        records = [self.record(5), self.record(25), self.record(10, message_id="known")]
        report = API["build_report"](API["canonical_usage"](records), [self.segment()], 0, 60)
        self.assertIsNone(report["segments"][0]["usage"]["total_input"]["executor"]["value"])

    def test_unique_value_survives_missing_copy(self):
        first, missing = self.record(), self.record()
        del missing["usage"]["cache_creation_input_tokens"]
        calls = API["canonical_usage"]([missing, first])
        self.assertEqual(calls[0]["usage"]["total_input"], 49)

    def test_invalid_copy_does_not_hide_reported_zero(self):
        zero, invalid = self.record(), self.record()
        zero["usage"]["output_tokens"] = 0
        invalid["usage"]["output_tokens"] = -1
        calls = API["canonical_usage"]([invalid, zero])
        self.assertEqual(calls[0]["usage"]["output"], 0)

    def test_conflict_survives_bad_and_duplicate_copies(self):
        first, other, bad = self.record(), self.record(), self.record()
        first["usage"]["output_tokens"] = 0
        other["usage"]["output_tokens"] = 9
        bad["usage"]["output_tokens"] = "bad"
        calls = API["canonical_usage"]([first, bad, other, first])
        self.assertEqual(calls[0]["usage"]["field_status"]["output_tokens"], "conflict")

    def test_unknown_dependency_keeps_independent_metric(self):
        missing = self.record()
        del missing["usage"]["cache_read_input_tokens"]
        calls = API["canonical_usage"]([missing])
        self.assertEqual(calls[0]["usage"]["uncached_input"], 44)

    def test_evidence_matrix_is_order_independent_and_idempotent(self):
        for field in API["USAGE_FIELDS"]:
            normal = self.record()
            missing = self.record()
            del missing["usage"][field]
            for bad_value in (None, True, -1, 1.5, "1", [], {}):
                bad = self.record()
                bad["usage"][field] = bad_value
                orders = list(itertools.permutations([normal, missing, bad]))
                reference = API["canonical_usage"]([normal])
                for order in orders:
                    with self.subTest(field=field, bad=bad_value):
                        self.assertEqual(API["canonical_usage"](order), reference)
                        self.assertEqual(API["canonical_usage"]([*order, normal]), reference)
                conflicting = self.record()
                conflicting["usage"][field] += 1
                reference = API["canonical_usage"]([normal, conflicting])
                for order in itertools.permutations([normal, conflicting, bad]):
                    self.assertEqual(API["canonical_usage"](order), reference)
        for container in (None, {}, [], "bad", ["bad"], False):
            bad = self.record()
            bad["usage"] = container
            for order in ((bad, normal), (normal, bad)):
                self.assertEqual(API["canonical_usage"](order), API["canonical_usage"]([normal]))

    def test_no_legal_value_preserves_invalid_and_missing_reasons(self):
        missing, invalid = self.record(), self.record()
        del missing["usage"]["output_tokens"]
        invalid["usage"]["output_tokens"] = None
        calls = API["canonical_usage"]([missing, invalid])
        self.assertEqual(calls[0]["usage"]["field_status"]["output_tokens"], "invalid")
        calls = API["canonical_usage"]([missing])
        self.assertEqual(calls[0]["usage"]["field_status"]["output_tokens"], "missing")
        for container in ([], "bad", False):
            invalid["usage"] = container
            calls = API["canonical_usage"]([invalid])
            self.assertEqual(set(calls[0]["usage"]["field_status"].values()), {"invalid"})

    def test_metadata_unique_evidence_and_conflicts_are_independent(self):
        normal = self.record()
        for field, bad_values in (("model", (None, "", " ", [], {}, False)),
                ("timestamp", (None, [], {}, False, "bad"))):
            for bad_value in bad_values:
                bad = self.record()
                bad[field] = bad_value
                for order in ((normal, bad), (bad, normal)):
                    calls = API["canonical_usage"](order)
                    self.assertEqual(calls[0][field], normal[field])
                    self.assertEqual(calls[0][field + "_status"], "reported")
        conflict = self.record(20, "synthetic-other")
        calls = API["canonical_usage"]([normal, conflict])
        self.assertEqual((calls[0]["timestamp"], calls[0]["model"],
            calls[0]["timestamp_status"], calls[0]["model_status"]),
            (None, None, "conflict", "conflict"))
        self.assertEqual(calls[0]["usage"]["total_input"], 49)
        for field in ("model", "timestamp"):
            missing = self.record()
            del missing[field]
            self.assertEqual(API["canonical_usage"]([missing])[0][field + "_status"], "missing")

    def test_unknown_time_is_once_in_boundary_not_a_segment(self):
        segments = [self.segment(), self.segment("q")]
        segments[0]["end"] = 20
        segments.append({**self.segment(), "segment_id": "later", "start": 20, "end": 40})
        for project in ("p", "reviewer"):
            records = [self.record(5), self.record(25)]
            for record in records:
                record["project"] = project
            calls = API["canonical_usage"](records)
            for selected in ([segments[0]], segments[::2], segments):
                shares, buckets = API["allocate_calls"](calls, selected)
                self.assertEqual(buckets["boundary_unattributed"]["values"]["total_input"], 49)
                self.assertEqual(buckets["boundary_unattributed"]["calls"], 1)
                role = "reviewer" if project == "reviewer" else "executor"
                self.assertEqual(sum(item[role]["calls"] for item in shares.values()), 0)

    def test_combined_conflicts_do_not_cross_filter_dimensions(self):
        for time_conflict, model_conflict, usage_conflict in itertools.product((False, True), repeat=3):
            first = self.record(5, "synthetic-a")
            second = self.record(25 if time_conflict else 5,
                "synthetic-b" if model_conflict else "synthetic-a")
            if usage_conflict:
                second["usage"]["output_tokens"] = 9
            report = API["build_report"](API["canonical_usage"]([first, second]), [self.segment()], 0, 60)
            self.assertEqual([report["totals"][key]["value"] for key in ("total_input", "output")],
                [49, None if usage_conflict else 7])
            self.assertEqual([report["totals"]["dimensions"][key]["known_count"] for key in ("timestamp", "model")],
                [0 if time_conflict else 1, 0 if model_conflict else 1])
            self.assertEqual(report["totals"]["business"]["first_pass_denominator"], 1)

    def test_unknown_time_does_not_claim_complete_activity(self):
        records = [self.record(0, message_id="first"), self.record(50, message_id="last"),
            self.record(10), self.record(20)]
        calls = API["canonical_usage"](records)
        activity = API["time_proxies"](calls, [self.segment()], 0, 60)
        self.assertIsNone(activity["segment_seconds"]["p"]["executor"])

    def test_unknown_time_does_not_erase_raw_or_known_share(self):
        records = [self.record(5), self.record(25), self.record(10, message_id="known")]
        calls = API["canonical_usage"](records)
        report = API["build_report"](calls, [self.segment()], 0, 60)
        metric = report["segments"][0]["usage"]["total_input"]["executor"]
        self.assertEqual(metric["known_value"], 49)
        self.assertIsNone(metric["value"])
        self.assertIsNone(metric["eligible_count"])
        self.assertEqual(metric["unknown_reason_counts"], {"time_unknown": None})
        self.assertEqual(report["totals"]["total_input"]["value"], 98)
        self.assertEqual(metric["known_value"] +
            report["buckets"]["boundary_unattributed"]["total_input"]["value"], 98)
        self.assertIsNone(report["segments"][0]["calls"]["executor"])
        self.assertEqual(report["totals"]["dimensions"]["timestamp"], {
            "known_count": 1, "eligible_count": 2, "unknown_reason_counts": {"conflict": 1}})

    def test_unknown_time_is_scoped_and_business_stays_complete(self):
        records = [self.record(5), self.record(25)]
        for stamp in (0, 40):
            call = self.record(stamp, message_id=f"q-{stamp}")
            call["project"] = "q"
            records.append(call)
        report = API["build_report"](API["canonical_usage"](records),
            [self.segment(), self.segment("q")], 0, 60)
        p, q = report["segments"]
        self.assertEqual(p["quality"]["attribution_status"]["executor"], "time_unknown")
        self.assertEqual(q["quality"]["attribution_status"]["executor"], "known")
        self.assertEqual(q["active_seconds"]["executor"], 40)
        self.assertEqual(report["totals"]["business"]["first_pass_denominator"], 2)
        reviewer = self.record(None)
        reviewer["project"] = "reviewer"
        activity = API["time_proxies"]([reviewer, *records[2:]], [self.segment("q")], 0, 60)
        self.assertEqual(activity["segment_seconds"]["q"], {"reviewer": None, "executor": 40})

    def test_model_unknown_keeps_time_share_and_activity(self):
        records = [self.record(5, "synthetic-a"), self.record(5, "synthetic-b"),
            self.record(15, message_id="later")]
        report = API["build_report"](API["canonical_usage"](records), [self.segment()], 0, 60)
        self.assertEqual(report["segments"][0]["usage"]["total_input"]["executor"]["value"], 98)
        self.assertEqual(report["segments"][0]["active_seconds"]["executor"], 10)
        self.assertEqual(report["totals"]["dimensions"]["model"], {
            "known_count": 1, "eligible_count": 2, "unknown_reason_counts": {"conflict": 1}})


class TestUsageClosureCli(unittest.TestCase):
    def run_case(self, records, reverse_files=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript = root / "selected.jsonl"
            second = root / "copy.jsonl"
            report_path = root / "report.json"
            fixture = TestUsageClosure()
            events = [event_call(0, "reviewer", "/synthetic/p", "root-private", "notice"),
                event_call(60, "reviewer", "/synthetic/p", "pass-private", "notice",
                    "root-private", "验收通过：synthetic")]
            make_transcript(transcript, "p", [row(r["timestamp"], "p", {
                "id": r["message_id"], "model": r.get("model"), "usage": r.get("usage"),
                "content": [{"type": "text", "text": "CLOSURE-SENTINEL"}]}) for r in records])
            make_transcript(second, "reviewer", events)
            inputs = [("p", transcript), ("reviewer", second)]
            if reverse_files:
                inputs.reverse()
            command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
                "--project", "p=/synthetic/p", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:01:01Z", "--json-out", str(report_path)]
            for label, path in inputs:
                command.extend(("--transcript", f"{label}={path}"))
            environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                XDG_CONFIG_HOME=str(root / "xdg"))
            result = subprocess.run(command, cwd=root, env=environment, text=True,
                capture_output=True, timeout=20)
            self.assertTrue(report_path.is_file(), result.stderr)
            serialized = result.stdout + result.stderr + report_path.read_text(encoding="utf-8")
            for private in ("CLOSURE-SENTINEL", "private-call", "root-private", "pass-private",
                    "/synthetic/", str(root), "Traceback"):
                self.assertNotIn(private, serialized)
            self.assertEqual(result.stderr, "")
            return result, json.loads(report_path.read_text(encoding="utf-8"))

    def test_cli_prints_business_time_coverage_and_baseline_state(self):
        result, report = self.run_case([])

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Business: complete=1; first-pass=1/1; unmatched-terminal=0",
            result.stdout.splitlines())
        self.assertIn("Time coverage: wall-clock=60s (1/1); active reviewer=0s (4/4), executor=0s (4/4)",
            result.stdout.splitlines())
        self.assertIn("Coverage: total_input=0/0 uncached_input=0/0 output=0/0; timestamp=0/0 model=0/0",
            result.stdout.splitlines())
        self.assertIn("Comparability: no comparable baseline.", result.stdout.splitlines())
        self.assertEqual(report["groups"], [])
        self.assertEqual(len(report["rollups"]["weekly"]), 1)

    def test_mixed_evidence_cli_all_fields_and_containers(self):
        fixture = TestUsageClosure()
        for field in API["USAGE_FIELDS"]:
            normal, missing, invalid = (fixture.record() for _ in range(3))
            del missing["usage"][field]
            invalid["usage"][field] = False
            for order in itertools.permutations([normal, missing, invalid]):
                result, report = self.run_case(order)
                self.assertEqual(result.returncode, 0)
                self.assertEqual([report["totals"][m]["value"] for m in API["METRICS"]], [49, 44, 7])
                self.assertEqual(report["totals"]["total_input"]["eligible_count"], 1)
        for container in (None, {}, [], "bad", ["bad"], False):
            bad = fixture.record()
            bad["usage"] = container
            result, report = self.run_case([bad, fixture.record()])
            self.assertEqual(result.returncode, 0)
            self.assertEqual(report["totals"]["total_input"]["value"], 49)

    def test_time_conflict_cli_is_partial_and_conserves_with_known_value(self):
        fixture = TestUsageClosure()
        records = [fixture.record(5), fixture.record(25), fixture.record(10, message_id="known")]
        for order in (records, list(reversed(records))):
            result, report = self.run_case(order, reverse_files=order is not records)
            self.assertEqual(result.returncode, 1)
            output_lines = [line for line in result.stdout.splitlines()
                if not line.startswith(("Business:", "Time coverage:", "Coverage:", "Comparability:"))]
            self.assertEqual(output_lines, [
                "Selected transcript usage (not a full bill)",
                "Reported token usage: total input 98; uncached input 88; output 14",
                "API integrity unknown: 2; reported usage is not a full bill.",
                "Segments: 1",
                "Attribution: reviewer shares are time-window estimates; overlap and outside usage are bucketed.",
                "Dimension coverage: timestamp=1/2 model=2/2; unknown dimensions do not erase reported usage.",
                "Partial: coverage loss (0 malformed source rows); reported-usage coverage "
                "total_input=2/2 uncached_input=2/2 output=2/2."])
            entry = report["segments"][0]
            self.assertEqual(entry["usage"]["total_input"]["executor"]["known_value"], 49)
            self.assertIsNone(entry["usage"]["total_input"]["executor"]["value"])
            self.assertIsNone(entry["active_seconds"]["executor"])
            self.assertEqual(report["buckets"]["boundary_unattributed"]["total_input"]["value"], 49)
            self.assertEqual(report["totals"]["business"]["first_pass_denominator"], 1)

    def test_model_unknown_cli_does_not_erase_known_time(self):
        fixture = TestUsageClosure()
        for models in (("synthetic-a", "synthetic-b"), (None, None), ({}, [])):
            result, report = self.run_case([fixture.record(5, m) for m in models])
            self.assertEqual(result.returncode, 1)
            self.assertEqual(report["segments"][0]["usage"]["total_input"]["executor"]["value"], 49)
            self.assertEqual(report["totals"]["dimensions"]["timestamp"]["known_count"], 1)
            self.assertEqual(report["totals"]["dimensions"]["model"]["known_count"], 0)

    def test_cli_results_ignore_home_cwd_lane_and_owner_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript = root / "selected.jsonl"
            make_transcript(transcript, "reviewer", [usage_call(0, "private-call", 41)])
            reports = []
            for index, lane, owner in ((0, None, None), (1, "synthetic-lane", "987654321")):
                cwd, home, xdg = (root / f"{name}-{index}" for name in ("cwd", "home", "xdg"))
                cwd.mkdir()
                home.mkdir()
                xdg.mkdir()
                report_path = root / f"report-{index}.json"
                environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(home),
                    XDG_CONFIG_HOME=str(xdg))
                if lane is None:
                    environment.pop("DRSG_EVENT_LANES", None)
                else:
                    environment["DRSG_EVENT_LANES"] = lane
                if owner is None:
                    environment.pop("EVENT_POLL_OWNER_PID", None)
                else:
                    environment["EVENT_POLL_OWNER_PID"] = owner
                command = [sys.executable, "-I", str(CLI),
                    "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                    "--transcript", f"reviewer={transcript}", "--since", "1970-01-01T00:00:00Z",
                    "--until", "1970-01-01T00:00:01Z", "--json-out", str(report_path)]
                result = subprocess.run(command, cwd=cwd, env=environment, text=True, capture_output=True)
                self.assertEqual((result.returncode, result.stderr), (0, ""))
                reports.append((result.stdout, json.loads(report_path.read_text(encoding="utf-8"))))

            self.assertEqual(reports[0], reports[1])

    def test_window_and_equivalent_utc_representations_are_not_widened(self):
        fixture = TestUsageClosure()
        first, equivalent, outside = fixture.record(0), fixture.record(0), fixture.record(61)
        first["timestamp"] = "1970-01-01T00:00:00Z"
        equivalent["timestamp"] = "1970-01-01T00:00:00+00:00"
        outside["usage"]["input_tokens"] = 999
        for order in ((first, equivalent, outside), (outside, equivalent, first)):
            result, report = self.run_case(order)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(report["totals"]["total_input"]["value"], 49)
            self.assertEqual(report["totals"]["integrity"]["eligible_count"], 1)


class TestTerminalEventUsageAssociation(unittest.TestCase):
    def test_unique_terminal_event_call_is_attributed_at_half_open_end(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report_path = root / "reviewer.jsonl", root / "report.json"
            root_event = event_call(0, "reviewer", "/synthetic/p", "root", "notice")
            terminal_event = event_call(10, "reviewer", "/synthetic/p", "pass", "notice",
                "root", "验收通过：done")
            terminal_event[0]["message"].update(id="terminal-message", model="synthetic-model",
                usage={"input_tokens": 12, "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0, "output_tokens": 0})
            make_transcript(transcript, "reviewer", [*root_event, *terminal_event])
            command = [sys.executable, "-I", str(CLI),
                "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p",
                "--transcript", f"reviewer={transcript}",
                "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
                "--json-out", str(report_path)]
            result = subprocess.run(command, cwd=root,
                env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True,
                capture_output=True, timeout=20)

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["segments"][0]["end"], "1970-01-01T00:00:10Z")
            self.assertEqual(report["segments"][0]["usage"]["total_input"]["reviewer"]["value"], 12)
            self.assertEqual(report["buckets"]["outside_unattributed"]["total_input"]["eligible_count"], 0)


class TestCliInputBoundaries(unittest.TestCase):
    def run_cli(self, root, transcript, report, *extra):
        command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
            "--project", "p=/synthetic/p", "--transcript", f"reviewer={transcript}",
            "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z",
            "--json-out", str(report), *extra]
        return subprocess.run(command, cwd=root,
            env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)

    def test_unknown_option_does_not_echo_attacker_value(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "empty.jsonl", root / "report.json"
            transcript.write_text("", encoding="utf-8")

            result = self.run_cli(root, transcript, report, "--unknown-option", "ARGUMENT-SECRET-SENTINEL")

            self.assertEqual((result.returncode, result.stderr.splitlines()),
                (2, ["error: invalid_arguments"]))
            self.assertNotIn("ARGUMENT-SECRET-SENTINEL", result.stdout + result.stderr)
            self.assertFalse(report.exists())

    def test_malformed_tool_result_identifier_fails_closed_without_traceback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, report = root / "bad-result.jsonl", root / "report.json"
            row_data = {"timestamp": 0, "type": "user", "message": {"content": [{
                "type": "tool_result", "tool_use_id": [], "content": "BAD-ID-SENTINEL"}]}}
            transcript.write_text(json.dumps(row_data) + chr(10), encoding="utf-8")

            result = self.run_cli(root, transcript, report)

            self.assertEqual(result.returncode, 1)
            self.assertNotIn("Traceback", result.stdout + result.stderr)
            self.assertNotIn("BAD-ID-SENTINEL", result.stdout + result.stderr + report.read_text())

    def test_unmapped_transcript_label_is_rejected_before_reading_usage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            transcript, unmapped, report = (root / name for name in
                ("reviewer.jsonl", "unmapped.jsonl", "report.json"))
            transcript.write_text("", encoding="utf-8")
            make_transcript(unmapped, "hidden", [usage_call(0, "unmapped-call", 99)])
            command = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
                "--project", "p=/synthetic/p", "--transcript", f"reviewer={transcript}",
                "--transcript", f"hidden={unmapped}", "--since", "1970-01-01T00:00:00Z",
                "--until", "1970-01-01T00:01:00Z", "--json-out", str(report)]

            result = subprocess.run(command, cwd=root,
                env=dict(os.environ, LC_ALL="C", TZ="UTC"), text=True, capture_output=True)

            self.assertEqual((result.returncode, result.stderr.splitlines()),
                (2, ["error: invalid_arguments"]))
            self.assertFalse(report.exists())


class TestCrossFileEventPairing(unittest.TestCase):
    def test_event_result_pairs_across_selected_files_in_either_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            call_row, result_row = event_call(0, "reviewer", "/synthetic/p", "root-private", "notice")
            call_file, result_file, report_file = (root / name for name in
                ("call.jsonl", "result.jsonl", "report.json"))
            make_transcript(call_file, "reviewer", [call_row])
            make_transcript(result_file, "reviewer", [result_row])
            combined = root / "combined.jsonl"
            make_transcript(combined, "reviewer", [(call_row, result_row)])
            environment = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
                XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
            environment.pop("EVENT_POLL_OWNER_PID", None)

            for selected in ((combined,), (call_file, result_file), (result_file, call_file)):
                report_file.unlink(missing_ok=True)
                command = [sys.executable, "-I", str(CLI),
                    "--project", "reviewer=/synthetic/reviewer", "--project", "p=/synthetic/p"]
                for selected_file in selected:
                    command.extend(("--transcript", f"reviewer={selected_file}"))
                command.extend(("--since", "1970-01-01T00:00:00Z",
                    "--until", "1970-01-01T00:01:00Z", "--json-out", str(report_file)))
                result = subprocess.run(command, cwd=root, env=environment, text=True,
                    capture_output=True, timeout=20)

                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(report_file.read_text(encoding="utf-8"))
                self.assertEqual(len(report["segments"]), 1)
                self.assertEqual(report["segments"][0]["status"], "right_censored")


if __name__ == "__main__":
    unittest.main()

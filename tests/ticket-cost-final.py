#!/usr/bin/env python3
"""Final closure regressions using explicit synthetic transcripts only."""
import copy
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / "tools" / "ticket-cost.py"
API = runpy.run_path(str(CLI))


def usage(mid, timestamp, model="model-a"):
    return {"timestamp": timestamp, "type": "assistant", "message": {"id": mid,
        "model": model, "usage": {"input_tokens": 12, "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0, "output_tokens": 3}, "content": []}}


def exchange(key, target, timestamp, parent=None, summary="work"):
    inputs = {"recipient": "/synthetic/" + target, "kind": "notice", "summary": summary}
    if parent is not None:
        inputs["reply_to"] = parent
    call = {"timestamp": timestamp, "type": "assistant", "message": {"content": [{
        "type": "tool_use", "name": "mcp__drsg-events__event_post", "id": "tool-" + key,
        "input": inputs}]}}
    result = {"timestamp": timestamp, "type": "user", "message": {"content": [{
        "type": "tool_result", "tool_use_id": "tool-" + key,
        "content": "posted " + key + " to /synthetic/" + target}]}}
    return call, result


def run_cli(files, extra=()):
    with tempfile.TemporaryDirectory(prefix="ticket-cost-final-") as temporary:
        root = Path(temporary)
        args = [sys.executable, "-I", str(CLI), "--project", "reviewer=/synthetic/reviewer",
            "--project", "p=/synthetic/p", "--project", "q=/synthetic/q",
            "--since", "1970-01-01T00:00:00Z", "--until", "1970-01-01T00:01:00Z"]
        for index, (label, rows) in enumerate(files):
            source = root / f"source-{index}.jsonl"
            source.write_text("".join(json.dumps(row) + "\n" for row in rows))
            args.extend(("--transcript", label + "=" + str(source)))
        output = root / "report.json"
        args.extend(("--json-out", str(output), *extra))
        env = {"PATH": os.defpath, "HOME": str(root / "home"),
            "XDG_CONFIG_HOME": str(root / "xdg"), "LC_ALL": "C", "TZ": "UTC",
            "DRSG_EVENT_LANES": "independent-review", "EVENT_POLL_OWNER_PID": "987654321"}
        process = subprocess.run(args, cwd=root, env=env, text=True,
            capture_output=True, timeout=30)
        return process, json.loads(output.read_text()) if output.exists() else None


def with_usage(event, mid):
    event["message"].update({key: value for key, value in
        usage(mid, event["timestamp"])["message"].items() if key != "content"})
    return event


def segment(sid="s", start=0, end=20):
    return {"segment_id": sid, "project": "p", "start": start, "end": end,
        "status": "complete", "rework_count": 0, "rounds": 1, "first_pass": True}


class TestFinalClosure(unittest.TestCase):
    def test_legitimate_rollups_keep_no_usage_business_segment(self):
        process, report = run_cli([("reviewer", [*exchange("root", "p", 0),
            *exchange("pass", "p", 10, "root", "验收通过：done")])])
        self.assertEqual(process.returncode, 0, process.stderr)
        weekly = report["rollups"]["weekly"]
        self.assertEqual((len(weekly), weekly[0]["business"]["first_pass_denominator"],
            weekly[0]["time"]["wall_clock_seconds"]["value"]), (1, 1, 10))

    def test_time_unknown_linked_call_stays_in_boundary(self):
        call, result = exchange("work", "p", 5, "root")
        with_usage(call, "shared-call")
        rows = [*exchange("root", "p", 0), call, result, usage("shared-call", 15),
            *exchange("pass", "p", 20, "root", "验收通过：done")]
        process, report = run_cli([("reviewer", rows)])
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertEqual(report["buckets"]["boundary_unattributed"]["total_input"]["value"], 12)

    def test_multiple_segment_links_go_to_boundary(self):
        closing, result_a = exchange("pass-a", "p", 10, "root-a", "验收通过：done")
        opening, result_b = exchange("root-b", "p", 10)
        closing["message"]["content"].extend(opening["message"]["content"])
        with_usage(closing, "multi-event-call")
        process, report = run_cli([("reviewer", [*exchange("root-a", "p", 0),
            closing, result_a, result_b, *exchange("pass-b", "p", 30, "root-b", "验收通过：done")])])
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(report["buckets"]["boundary_unattributed"]["total_input"]["value"], 12)

    def test_interior_event_keeps_equal_time_window_shares(self):
        call, result = exchange("work", "p", 5, "root-p")
        with_usage(call, "interior-call")
        rows = [*exchange("root-p", "p", 0), *exchange("root-q", "q", 0), call, result,
            *exchange("pass-p", "p", 20, "root-p", "验收通过：done"),
            *exchange("pass-q", "q", 20, "root-q", "验收通过：done")]
        process, report = run_cli([("reviewer", rows)])
        self.assertEqual(process.returncode, 0, process.stderr)
        by_project = {row["project"]: row for row in report["segments"]}
        self.assertEqual([by_project[p]["usage"]["total_input"]["reviewer"]["value"]
            for p in ("p", "q")], [6, 6])

    def test_malformed_event_fields_are_partial_without_traceback(self):
        for field, value in (("reply_to", ["bad"]), ("supersedes", {"bad": 1}),
                ("kind", []), ("tree", []), ("files", [1]), ("summary", {})):
            with self.subTest(field=field):
                call, result = exchange("bad", "p", 0)
                call["message"]["content"][0]["input"][field] = value
                process, report = run_cli([("reviewer", [call, result])])
                self.assertEqual(process.returncode, 1, process.stderr)
                self.assertNotIn("Traceback", process.stderr)
                self.assertEqual(report["scan"]["status"], "partial")
                self.assertEqual(report["segments"], [])

    def test_duplicate_project_identity_is_rejected(self):
        process, report = run_cli([("p", [usage("one-call", 0)])],
            ("--project", "alias=/synthetic/p"))
        self.assertEqual((process.returncode, process.stderr), (2, "error: invalid_arguments\n"))
        self.assertIsNone(report)

    def test_model_display_never_overwrites_distinct_legal_models(self):
        for models in (("model-a+custom", "model-b+custom"),
                ("model-a custom", "model-b custom")):
            with self.subTest(models=models):
                calls = [{"project": "p", "message_id": str(i), "timestamp": i + 1,
                    "model": model, "usage": API["parse_usage"](usage(str(i), i + 1, model)["message"])}
                    for i, model in enumerate(models)]
                report = API["build_report"](calls, [segment()], 0, 60)
                detail = report["segments"][0]
                self.assertEqual(len(detail["model_usage"]), 2)
                self.assertEqual(sum(row["usage"]["total_input"]["executor"]["value"]
                    for row in detail["model_usage"]), 24)
                self.assertEqual({row["model"] for row in detail["model_usage"]},
                    {row["model"] for row in report["groups"]})
                self.assertEqual(set(detail["actual_models"]), {row["model"] for row in report["groups"]})

    def test_unknown_other_model_preserves_reviewer_group(self):
        rows = [*exchange("root", "p", 0), *exchange("pass", "p", 20, "root", "验收通过：done"),
            usage("review-call", 5, "review-model")]
        process, report = run_cli([("reviewer", rows), ("p", [usage("conflict", 5, "exec-model"),
            usage("conflict", 6, "exec-model")])])
        self.assertEqual(process.returncode, 1, process.stderr)
        group = next(group for group in report["groups"] if group["model"] == "review-model")
        self.assertEqual((group["total_input"]["value"], group["total_input"]["eligible_count"]), (12, 1))

    def test_unknown_same_model_still_taints_reviewer_group(self):
        rows = [*exchange("root", "p", 0), *exchange("pass", "p", 20, "root", "验收通过：done"),
            usage("review-call", 5, "shared-model")]
        process, report = run_cli([("reviewer", rows), ("p", [usage("conflict", 5, "shared-model"),
            usage("conflict", 6, "shared-model")])])
        self.assertEqual(process.returncode, 1, process.stderr)
        group = report["groups"][0]
        self.assertIsNone(group["total_input"]["value"])
        self.assertIsNone(group["total_input"]["eligible_count"])
        self.assertEqual(group["total_input"]["known_value"], 12)

    def test_time_rollup_reports_independent_mean_and_median(self):
        report = API["build_report"]([], [segment("a", 0, 10), segment("b", 20, 50)], 0, 60)
        metric = report["rollups"]["weekly"][0]["time"]["wall_clock_seconds"]
        self.assertEqual((metric.get("sample_count"), metric.get("mean"), metric.get("median")), (2, 20, 20))

    def test_authorization_copy_conflicts_include_fingerprint_fields(self):
        call, result = exchange("auth", "p", 0)
        block = call["message"]["content"][0]
        block["name"] = "mcp__drsg-events__commit_auth_post"
        block["input"].update(tree="a" * 40, parent="b" * 40, files=["example.py"])
        changed = copy.deepcopy(call)
        changed["message"]["content"][0]["input"]["tree"] = "c" * 40
        rows = [dict(row, _project="reviewer", _timestamp=0) for row in (call, changed, result)]
        events = API["parse_successful_events"](rows, {"reviewer": "/synthetic/reviewer", "p": "/synthetic/p"})
        self.assertEqual(len(events), 1)
        self.assertTrue(events[0].get("ambiguous"))


if __name__ == "__main__":
    unittest.main(verbosity=2)

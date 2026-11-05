#!/usr/bin/env python3
"""Run paired synthetic Event-result mutations in isolated copies."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "tools" / "ticket-cost.py"
TESTS = ROOT / "tests" / "ticket-cost.py"


def run_selector(root, selector):
    env = dict(os.environ, LC_ALL="C", TZ="UTC", HOME=str(root / "home"),
        XDG_CONFIG_HOME=str(root / "xdg"), DRSG_EVENT_LANES="")
    env.pop("EVENT_POLL_OWNER_PID", None)
    return subprocess.run([sys.executable, "-I", "tests/ticket-cost.py", selector, "-v"],
        cwd=root, env=env, text=True, capture_output=True)


def run_mutation(name, selector, replacements):
    with tempfile.TemporaryDirectory(prefix="ticket-cost-mutation-") as temporary:
        root = pathlib.Path(temporary)
        (root / "tools").mkdir()
        (root / "tests").mkdir()
        shutil.copyfile(CLI, root / "tools" / "ticket-cost.py")
        shutil.copyfile(TESTS, root / "tests" / "ticket-cost.py")
        baseline = run_selector(root, selector)
        baseline_output = baseline.stdout + baseline.stderr
        if baseline.returncode != 0 or "Ran 1 test" not in baseline_output or "skipped=" in baseline_output:
            print(f"{name}: not_run (paired baseline failed)\n{baseline_output}")
            return "not_run"
        source_path = root / "tools" / "ticket-cost.py"
        source = source_path.read_text(encoding="utf-8")
        for old, new in replacements:
            if source.count(old) != 1:
                print(f"{name}: not_run (mutation anchor count was {source.count(old)})")
                return "not_run"
            source = source.replace(old, new, 1)
        source_path.write_text(source, encoding="utf-8")
        mutant = run_selector(root, selector)
        output = mutant.stdout + mutant.stderr
        if mutant.returncode == 0:
            print(f"{name}: survived\n{output}")
            return "survived"
        if mutant.returncode == 1 and f"FAIL: {selector.split('.')[-1]}" in output and "FAILED (failures=1)" in output and "ERROR:" not in output:
            print(f"{name}: killed")
            return "killed"
        print(f"{name}: not_run (paired mutant did not reach the expected assertion)\n{output}")
        return "not_run"


def main():
    cases = [
        ("equivalent_success_representation", "TestEvents.test_real_cli_equivalent_copies_match_control_and_error_conflicts_stay_ambiguous", [
            ('semantic_result = [error_flag if type(error_flag) is bool else "invalid", first]',
             'semantic_result = [block.get("is_error"), text]')]),
        ("success_error_conflict", "TestEvents.test_real_cli_equivalent_copies_match_control_and_error_conflicts_stay_ambiguous", [
            ('semantic_result = [error_flag if type(error_flag) is bool else "invalid", first]',
             'semantic_result = [first]'),
            ('result_copies[signature] = block', 'result_copies.setdefault(signature, block)')]),
        ("strict_posted_first_line", "TestEvents.test_only_a_strict_posted_first_line_identifies_the_event", [
            ('r"posted ([A-Za-z0-9][A-Za-z0-9._:-]{0,127}) to (.+)"',
             'r"posted (.+) to (.+)"')]),
        ("repeated_terminal_closes_once", "TestSegments.test_late_and_repeated_terminals_only_close_their_linked_root_once", [
            ('close = min((event["timestamp"] for event in terminals), default=None)\n            failures =',
             'close = max((event["timestamp"] for event in terminals), default=None)\n            failures =')]),
        ("long_wait_not_truncated", "TestSegments.test_wait_longer_than_48_hours_is_not_truncated", [
            ('close = min((event["timestamp"] for event in terminals), default=None)\n            failures =',
             'close = min(min((event["timestamp"] for event in terminals), default=None),\n                root["timestamp"] + 172800)\n            failures =')]),
        ("reviewer_overlap_share_conservation", "TestAllocation.test_reviewer_tokens_conserve_across_project_overlap_and_unique_segment", [
            ('weight = Fraction(len(active_segments), total_active)', 'weight = Fraction(1)')]),
        ("missing_usage_not_zero", "TestUsageClosure.test_missing_token_is_unknown", [
            ('return None, "invalid" if any(status == "invalid" for _, status in pairs) else "missing"',
             'return 0, "reported"')]),
        ("actual_model_grouping", "TestGroups.test_groups_use_each_actual_model_once_per_project_and_week", [
            ('model = call["model"]', 'model = "primary"')]),
        ("sensitive_event_key_projection", "TestEndToEnd.test_synthetic_transcripts_flow_through_segments_shares_and_report", [
            ('"project": segment["project"],\n            "start":', '"project": segment["root_key"],\n            "start":')]),
        ("duplicate_call_identity", "TestDedup.test_identical_message_ids_in_distinct_projects_are_not_deduplicated", [
            ('fields(records[end])[:2] == (project, message_id)',
             'fields(records[end])[1:2] == (message_id,)')]),
        ("cross_file_event_pairing", "TestCrossFileEventPairing.test_event_result_pairs_across_selected_files_in_either_order", [
            ('elif (label, use_id) in all_event_use_ids:',
             'elif (label, use_id) in event_use_ids:')]),
        ("ambiguous_roots_count_toward_concurrency", "TestAllocation.test_ambiguous_roots_count_toward_cli_concurrency_limit", [
            ('for segment in segments:\n        start = segment["start"]',
             'for segment in segments:\n        if segment.get("origin_status") == "origin_ambiguous":\n            continue\n        start = segment["start"]')]),
        ("unknown_time_propagates_to_model_rows", "TestGroups.test_time_unknown_propagates_to_segment_model_and_group_rows", [
            ('if uncertain[role]:\n                    metric_data.update(value=None, known_value=value, eligible_count=None)',
             'if False and uncertain[role]:\n                    metric_data.update(value=None, known_value=value, eligible_count=None)')]),
        ("terminal_event_call_is_associated", "TestTerminalEventUsageAssociation.test_unique_terminal_event_call_is_attributed_at_half_open_end", [
            ('if len(linked) == 1:', 'if False and len(linked) == 1:')]),
        ("long_context_models_stay_distinct", "TestGroups.test_long_context_model_labels_remain_distinct_in_segment_details", [
            ('label = value[:-4] if value.endswith("[1m]") else value', 'label = value')]),
        ("business_rollup_keeps_no_usage_segments", "TestGroups.test_business_rollups_include_complete_segments_without_usage", [
            ('"weekly": [summarize(key, items, True)\n            for key, items in sorted(grouped["weekly"].items())]',
             '"weekly": []')]),
        ("unknown_option_value_is_not_echoed", "TestCliInputBoundaries.test_unknown_option_does_not_echo_attacker_value", [
            ('args, unknown_arguments = parser.parse_known_args(argv)\n    if unknown_arguments:',
             'args = parser.parse_args(argv)\n    unknown_arguments = []\n    if unknown_arguments:')]),
        ("malformed_result_id_does_not_crash", "TestCliInputBoundaries.test_malformed_tool_result_identifier_fails_closed_without_traceback", [
            ('if not isinstance(use_id, str):', 'if False:')]),
        ("unmapped_transcript_label_is_rejected", "TestCliInputBoundaries.test_unmapped_transcript_label_is_rejected_before_reading_usage", [
            ('or any(label not in projects for label, _ in transcripts):',
             ':')]),
    ]
    negative_control = "--negative-control" in sys.argv
    if negative_control:
        cases.extend([
            ("survived_negative_control", "TestUsageClosure.test_missing_token_is_unknown",
                [("return calls", "return calls")]),
            ("not_run_negative_control", "TestUsageClosure.test_missing_token_is_unknown",
                [("deliberately-missing-mutation-anchor", "still-missing")]),
        ])
    results = []
    for name, selector, replacements in cases:
        try:
            results.append(run_mutation(name, selector, replacements))
        except (OSError, subprocess.SubprocessError) as exc:
            print(f"{name}: not_run ({type(exc).__name__})")
            results.append("not_run")
    killed = results.count("killed")
    survived = results.count("survived")
    not_run = results.count("not_run")
    if killed == len(cases):
        print(f"mutations: {killed}/{len(cases)} killed")
        return 0
    print(f"mutations: {killed}/{len(cases)} killed; survived={survived}; not_run={not_run}")
    return 2 if not_run else 1


if __name__ == "__main__":
    raise SystemExit(main())

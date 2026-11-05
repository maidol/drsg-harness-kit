#!/usr/bin/env python3
"""Report selected-transcript usage and task-segment estimates."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import stat
import sys
from collections import defaultdict
from fractions import Fraction

USAGE_FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
METRICS = ("total_input", "uncached_input", "output")
EVENT_TOOLS = {"mcp__drsg-events__event_post", "mcp__drsg-events__commit_auth_post"}
MAX_LINE_BYTES = 4 * 1024 * 1024
MAX_FILES = 200
MAX_TOTAL_BYTES = 1024 * 1024 * 1024
MAX_CALLS = 100_000
MAX_EVENTS = 20_000
MAX_SEGMENTS = 20_000
MAX_EXECUTORS = 16
MAX_CONCURRENCY = 128
MAX_MODELS = 500
MAX_OUTPUT_ROWS = 100_000
MAX_SEGMENT_MODEL_CHECKS = 1_000_000


class InputFailure(Exception):
    def __init__(self, category):
        self.category = category


def parse_utc(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError) as exc:
        raise argparse.ArgumentTypeError("expected ISO-8601 UTC timestamp") from exc
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise argparse.ArgumentTypeError("timestamp must include UTC timezone")
    return int(parsed.timestamp())


def utc_text(timestamp):
    return dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).isoformat().replace("+00:00", "Z")


def parse_usage(message):
    raw = message.get("usage")
    raw = raw if isinstance(raw, dict) else {}
    recorded, field_status = {}, {}
    for field in USAGE_FIELDS:
        value = raw.get(field)
        if field not in raw:
            value, status = None, "missing"
        elif type(value) is int and value >= 0:
            status = "reported"
        else:
            value, status = None, "invalid"
        recorded[field], field_status[field] = value, status
    inp, created, cached, output = (recorded[name] for name in USAGE_FIELDS)
    return {"recorded": recorded,
        "total_input": inp + created + cached if None not in (inp, created, cached) else None,
        "uncached_input": inp + created if inp is not None and created is not None else None,
        "output": output, "field_status": field_status, "integrity": "integrity_unknown"}


def _merge_evidence(pairs):
    values = {value for value, status in pairs if status == "reported"}
    if len(values) > 1:
        return None, "conflict"
    if values:
        return next(iter(values)), "reported"
    return None, "invalid" if any(status == "invalid" for _, status in pairs) else "missing"


def _compact_usage(raw):
    values, status_bits = [], 0
    for index, field in enumerate(USAGE_FIELDS):
        if not isinstance(raw, dict) or field not in raw:
            value, status = None, 0 if raw is None or isinstance(raw, dict) else 2
        else:
            candidate = raw[field]
            valid = type(candidate) is int and candidate >= 0
            value, status = (candidate, 1) if valid else (None, 2)
        values.append(value)
        status_bits |= status << (index * 2)
    return (*values, status_bits)


def canonical_usage(records, consume=False):
    if not consume or not isinstance(records, list):
        records = list(records)

    def fields(row):
        if isinstance(row, tuple):
            return row
        return (row["project"], row["message_id"], row.get("timestamp"),
            row.get("model"), row.get("usage"))

    records.sort(key=lambda row: fields(row)[:2])
    calls, start = [], 0
    while start < len(records):
        first = fields(records[start])
        project, message_id = first[0], first[1]
        end = start + 1
        while end < len(records) and fields(records[end])[:2] == (project, message_id):
            end += 1
        result = parse_usage({})
        for field in USAGE_FIELDS:
            pairs = []
            for row in records[start:end]:
                raw = fields(row)[4]
                if isinstance(raw, tuple) and len(raw) == 5 and type(raw[4]) is int:
                    code = (raw[4] >> (USAGE_FIELDS.index(field) * 2)) & 3
                    value, status = raw[USAGE_FIELDS.index(field)], ("missing", "reported", "invalid")[code]
                elif raw is not None and not isinstance(raw, dict):
                    value, status = None, "invalid"
                elif not isinstance(raw, dict) or field not in raw:
                    value, status = None, "missing"
                else:
                    raw_value = raw[field]
                    value = raw_value if type(raw_value) is int and raw_value >= 0 else None
                    status = "reported" if value is not None else "invalid"
                pairs.append((value, status))
            value, status = _merge_evidence(pairs)
            result["recorded"][field], result["field_status"][field] = value, status
        i, c, r, o = (result["recorded"][field] for field in USAGE_FIELDS)
        result["total_input"] = i + c + r if None not in (i, c, r) else None
        result["uncached_input"] = i + c if i is not None and c is not None else None
        result["output"] = o
        call = {"project": project, "message_id": message_id, "usage": result}
        for field in ("timestamp", "model"):
            pairs = []
            for row in records[start:end]:
                value = fields(row)[2 if field == "timestamp" else 3]
                valid = type(value) is int if field == "timestamp" else (
                    isinstance(value, str) and bool(value.strip()))
                status = "missing" if value is None else "reported" if valid else "invalid"
                pairs.append((value, status))
            call[field], call[field + "_status"] = _merge_evidence(pairs)
        calls.append(call)
        for index in range(start, end):
            records[index] = None
        start = end
    return calls


def _event_inputs(block):
    inputs = block.get("input")
    if not isinstance(inputs, dict):
        return None
    for field in ("recipient", "kind", "summary", "reply_to", "supersedes",
            "tree", "parent", "target_branch"):
        if inputs.get(field) is not None and not isinstance(inputs[field], str):
            return None
    for field in ("files", "force_paths"):
        value = inputs.get(field)
        if value is not None and (not isinstance(value, list)
                or not all(isinstance(item, str) for item in value)):
            return None
    return inputs


def parse_successful_events(rows, project_paths):
    uses, results = defaultdict(list), defaultdict(list)
    for row in rows:
        message = row.get("message")
        if not isinstance(message, dict):
            continue
        project = row.get("_project")
        if row.get("type") == "assistant":
            content = message.get("content")
            for block in content if isinstance(content, list) else []:
                if (not isinstance(block, dict) or block.get("type") != "tool_use"
                        or not isinstance(block.get("name"), str)
                        or block["name"] not in EVENT_TOOLS or _event_inputs(block) is None):
                    continue
                use_id = block.get("id")
                if isinstance(use_id, str):
                    uses[(project, use_id)].append((row, block))
        elif row.get("type") == "user":
            content = message.get("content")
            for block in content if isinstance(content, list) else []:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    use_id = block.get("tool_use_id")
                    if isinstance(use_id, str):
                        results[(project, use_id)].append(block)
    path_labels = {os.path.realpath(path): label for label, path in project_paths.items()}
    candidates = []
    for identity in sorted(uses.keys() & results.keys()):
        use_copies = {}
        for row, block in uses[identity]:
            inputs = block.get("input") if isinstance(block.get("input"), dict) else {}
            summary = inputs.get("summary")
            summary_prefix = summary.split(":", 1)[0] if isinstance(summary, str) else ""
            semantic_use = [row.get("_timestamp"), block.get("name"), inputs.get("recipient"),
                inputs.get("kind"), inputs.get("reply_to"), inputs.get("supersedes"), summary_prefix,
                inputs.get("tree"), inputs.get("parent"), inputs.get("target_branch"),
                sorted(inputs.get("files") or []), sorted(inputs.get("force_paths") or [])]
            signature = json.dumps(semantic_use, sort_keys=True, ensure_ascii=False,
                separators=(",", ":"))
            use_copies[signature] = (row, block)
        result_copies = {}
        for block in results[identity]:
            text = block.get("content")
            first = text.splitlines()[0] if isinstance(text, str) and text.splitlines() else None
            error_flag = block.get("is_error", False)
            semantic_result = [error_flag if type(error_flag) is bool else "invalid", first]
            signature = json.dumps(semantic_result, ensure_ascii=False, separators=(",", ":"))
            result_copies[signature] = block
        ambiguous_exchange = len(use_copies) > 1 or len(result_copies) > 1
        row, block = use_copies[min(use_copies)]
        message = row.get("message") if isinstance(row.get("message"), dict) else {}
        inputs = block.get("input") if isinstance(block.get("input"), dict) else {}
        summary = inputs.get("summary")
        for result_signature in sorted(result_copies):
            result = result_copies[result_signature]
            error_flag = result.get("is_error", False)
            if type(error_flag) is not bool or error_flag:
                continue
            text = result.get("content")
            if not isinstance(text, str):
                continue
            first = text.splitlines()[0] if text.splitlines() else ""
            match = re.fullmatch(r"posted ([A-Za-z0-9][A-Za-z0-9._:-]{0,127}) to (.+)", first)
            if not match:
                continue
            key, target_path = match.groups()
            target = path_labels.get(os.path.realpath(target_path))
            recipient = inputs.get("recipient")
            recipient_label = path_labels.get(os.path.realpath(recipient)) \
                if isinstance(recipient, str) else None
            if not key or target is None or recipient_label != target:
                continue
            event = {"key": key, "sender": identity[0], "target": target,
                "kind": inputs.get("kind"), "reply_to": inputs.get("reply_to"),
                "supersedes": inputs.get("supersedes"),
                "summary_prefix": summary.split(":", 1)[0] if isinstance(summary, str) else "",
                "timestamp": row["_timestamp"], "tool": block.get("name"),
                "linked_message_ids": (message["id"],) if isinstance(message.get("id"), str) else ()}
            if any(field in inputs for field in ("tree", "parent", "files")):
                files = inputs.get("files")
                event.update(auth_tree=inputs.get("tree"), auth_parent=inputs.get("parent"),
                    auth_files=tuple(sorted(files)) if isinstance(files, list)
                    and all(isinstance(item, str) for item in files) else None)
            if ambiguous_exchange:
                event["ambiguous"] = True
            candidates.append(event)
    grouped = defaultdict(list)
    for event in candidates:
        grouped[(event["sender"], event["key"])].append(event)
    events = []
    for identity, copies in sorted(grouped.items()):
        copies = sorted(copies, key=lambda event: json.dumps(event, sort_keys=True,
            ensure_ascii=False, separators=(",", ":")))
        signatures = {tuple(sorted((name, value) for name, value in event.items()
            if name != "linked_message_ids")) for event in copies}
        if len(signatures) == 1:
            event = dict(copies[0])
            event["linked_message_ids"] = tuple(sorted({message_id for copy in copies
                for message_id in copy["linked_message_ids"]}))
            events.append(event)
        else:
            event = dict(copies[0])
            event["linked_message_ids"] = ()
            event["ambiguous"] = True
            events.append(event)
    return events


def build_segments(events, executor_labels, since, until, diagnostics=None):
    diagnostics = diagnostics if diagnostics is not None else {}

    def event_project(event):
        if event["sender"] == "reviewer":
            return event["target"]
        if event["target"] == "reviewer":
            return event["sender"]
        return None

    by_key, children = defaultdict(list), defaultdict(list)
    for event in events:
        if event.get("ambiguous"):
            continue
        project = event_project(event)
        by_key[(project, event["key"])].append(event)
        for parent in (event.get("reply_to"), event.get("supersedes")):
            if parent:
                children[(project, parent)].append(event)

    def event_chain(project, root_key):
        related, pending = {root_key}, [root_key]
        while pending:
            parent = pending.pop()
            for child in children[(project, parent)]:
                if len(by_key[(project, child["key"])]) != 1:
                    continue
                if child["key"] not in related:
                    related.add(child["key"])
                    pending.append(child["key"])
        return [by_key[(project, key)][0] for key in related
            if len(by_key[(project, key)]) == 1]

    def authorization_fingerprint(event):
        tree, parent, files = (event.get(name) for name in ("auth_tree", "auth_parent", "auth_files"))
        if not isinstance(tree, str) or not re.fullmatch(r"[0-9a-f]{40}", tree):
            return None
        if not isinstance(parent, str) or not re.fullmatch(r"[0-9a-f]{40}", parent):
            return None
        if not isinstance(files, (tuple, list)) or not files or not all(
                isinstance(item, str) and item and not item.startswith("/")
                and ".." not in item.split("/") for item in files):
            return None
        return tree, parent, tuple(sorted(files))

    terminal_events = defaultdict(list)
    for event in events:
        if (event.get("summary_prefix", "").startswith(("验收通过", "验收不通过"))
                or event.get("tool") == "mcp__drsg-events__commit_auth_post"):
            if event["sender"] == "reviewer" and event["target"] in executor_labels:
                terminal_events[event["target"]].append(event)

    segments = []
    matched_terminals = set()
    for project in sorted(executor_labels):
        roots = [event for event in events if not event.get("ambiguous")
            and ((event["sender"] == "reviewer" and event["target"] == project)
                or (event["sender"] == project and event["target"] == "reviewer"))
            and event.get("kind") in ("notice", "handoff")
            and event.get("tool") != "mcp__drsg-events__commit_auth_post"
            and not event.get("summary_prefix", "").startswith(("验收通过", "验收不通过"))
            and not event.get("reply_to") and not event.get("supersedes")
            and len(by_key[(project, event["key"])]) == 1 and event.get("timestamp") is not None]
        roots.sort(key=lambda event: (event["timestamp"], event["key"]))
        root_chains = {root["key"]: event_chain(project, root["key"]) for root in roots}
        owners = defaultdict(set)
        fingerprint_owners = defaultdict(set)
        for root_key, related_events in root_chains.items():
            for event in related_events:
                owners[event["key"]].add(root_key)
                fingerprint = authorization_fingerprint(event)
                if fingerprint is not None:
                    fingerprint_owners[fingerprint].add(root_key)
        for event in terminal_events.get(project, ()):
            if event.get("timestamp") is None:
                continue
            if event.get("ambiguous"):
                continue
            existing_owners = owners[event["key"]]
            if existing_owners:
                if len(existing_owners) == 1:
                    matched_terminals.add((event["sender"], event["key"]))
                continue
            explicit_owners = set()
            for reference in (event.get("reply_to"), event.get("supersedes")):
                if reference:
                    explicit_owners.update(owners[reference])
            candidates = explicit_owners
            if not candidates:
                fingerprint = authorization_fingerprint(event)
                candidates = fingerprint_owners.get(fingerprint, set()) if fingerprint else set()
            if len(candidates) == 1:
                root_key = next(iter(candidates))
                root_chains[root_key].append(event)
                owners[event["key"]].add(root_key)
                matched_terminals.add((event["sender"], event["key"]))
        previous_close = max((segment["end"] for segment in segments
            if segment["project"] == project and segment["end"] is not None), default=None)
        for root in roots:
            related_events = root_chains[root["key"]]
            related = {event["key"] for event in related_events}
            terminals = [event for event in related_events if event["target"] == project
                and event["sender"] == "reviewer"
                and event.get("timestamp") is not None
                and owners[event["key"]] == {root["key"]}
                and (event.get("summary_prefix", "").startswith("验收通过")
                    or event.get("tool") == "mcp__drsg-events__commit_auth_post")]
            close = min((event["timestamp"] for event in terminals), default=None)
            failures = [event for event in related_events if event["target"] == project
                and event["sender"] == "reviewer"
                and event.get("summary_prefix", "").startswith("验收不通过")
                and event.get("timestamp") is not None
                and owners[event["key"]] == {root["key"]}
                and (close is None or event["timestamp"] < close)]
            rework_count = len(failures)
            rounds = rework_count + int(close is not None)
            first_pass = (rework_count == 0) if close is not None else None
            has_prior_close = previous_close is not None and previous_close <= root["timestamp"]
            origin_status = "origin_candidate" if related - {root["key"]} or has_prior_close else "origin_ambiguous"
            linked_messages = tuple(sorted({(event["sender"], message_id) for event in related_events
                if owners[event["key"]] == {root["key"]}
                for message_id in event.get("linked_message_ids", ())}))
            segments.append({"project": project, "start": root["timestamp"], "end": close,
                "linked_messages": linked_messages,
                "status": "complete" if close is not None else "right_censored",
                "rework_count": rework_count, "rounds": rounds, "first_pass": first_pass,
                "root_key": root["key"], "segment_id": "", "origin_status": origin_status})
            if close is not None:
                previous_close = close if previous_close is None else max(previous_close, close)
    observed_keys = {(event_project(event), event["key"]) for event in events}
    for project in sorted(executor_labels):
        missing_parents = sorted({parent for event in events if not event.get("ambiguous")
            and event_project(event) == project
            for parent in (event.get("reply_to"), event.get("supersedes"))
            if parent and (project, parent) not in observed_keys})
        left_chains = {parent: event_chain(project, parent) for parent in missing_parents}
        left_chains = {parent: chain for parent, chain in left_chains.items() if chain}
        left_owners = defaultdict(set)
        left_fingerprints = defaultdict(set)
        for parent, chain in left_chains.items():
            for event in chain:
                left_owners[event["key"]].add(parent)
                fingerprint = authorization_fingerprint(event)
                if fingerprint is not None:
                    left_fingerprints[fingerprint].add(parent)
        for event in terminal_events.get(project, ()):
            if (event.get("ambiguous") or event.get("timestamp") is None
                    or (event["sender"], event["key"]) in matched_terminals
                    or left_owners[event["key"]]):
                continue
            candidates = set()
            for reference in (event.get("reply_to"), event.get("supersedes")):
                if reference:
                    candidates.update(left_owners[reference])
            if not candidates:
                fingerprint = authorization_fingerprint(event)
                candidates = left_fingerprints.get(fingerprint, set()) if fingerprint else set()
            if len(candidates) == 1:
                parent = next(iter(candidates))
                left_chains[parent].append(event)
                left_owners[event["key"]].add(parent)
                matched_terminals.add((event["sender"], event["key"]))
        for parent, linked in left_chains.items():
            for event in linked:
                if (event["sender"] == "reviewer" and event["target"] == project
                        and left_owners[event["key"]] == {parent}
                        and (event.get("summary_prefix", "").startswith(("验收通过", "验收不通过"))
                            or event.get("tool") == "mcp__drsg-events__commit_auth_post")):
                    matched_terminals.add((event["sender"], event["key"]))
            terminals = [event for event in linked if event["sender"] == "reviewer"
                and event["target"] == project and event.get("timestamp") is not None
                and left_owners[event["key"]] == {parent}
                and (event.get("summary_prefix", "").startswith("验收通过")
                    or event.get("tool") == "mcp__drsg-events__commit_auth_post")]
            close = min((event["timestamp"] for event in terminals), default=None)
            linked_messages = tuple(sorted({(event["sender"], message_id) for event in linked
                if left_owners[event["key"]] == {parent}
                for message_id in event.get("linked_message_ids", ())}))
            segments.append({"project": project, "start": since, "end": close,
                "linked_messages": linked_messages,
                "status": "left_censored" if close is not None else "left_and_right_censored",
                "rework_count": None, "rounds": None, "first_pass": None,
                "root_key": parent, "segment_id": "", "left_censored": True,
                "observed_from": since, "observed_until": close if close is not None else until,
                "origin_status": "origin_ambiguous"})
    unmatched_terminal_count = sum(1 for project_events in terminal_events.values()
        for event in project_events if event.get("timestamp") is not None
        and (event.get("ambiguous") or (event["sender"], event["key"]) not in matched_terminals))
    for project in sorted(executor_labels):
        indexes = [index for index, segment in enumerate(segments) if segment["project"] == project]
        indexes.sort(key=lambda index: (segments[index]["start"], segments[index]["root_key"]))
        farthest_end, farthest_index = None, None
        for index in indexes:
            segment = segments[index]
            segment_end = until if segment["end"] is None else min(until, segment["end"])
            if segment["start"] < segment_end and farthest_end is not None and segment["start"] < farthest_end:
                segment["overlap_status"] = "same_project_overlap"
                segments[farthest_index]["overlap_status"] = "same_project_overlap"
            if farthest_end is None or segment_end > farthest_end:
                farthest_end, farthest_index = segment_end, index
    segments.sort(key=lambda segment: (segment["start"], segment["root_key"], segment["project"]))
    for index, segment in enumerate(segments, 1):
        segment["segment_id"] = f"segment-{index:03d}"
    if diagnostics is not None:
        diagnostics["unmatched_terminal_count"] = unmatched_terminal_count
    return segments


def _max_concurrency(segments, until):
    changes = []
    for segment in segments:
        start = segment["start"]
        end = until if segment["end"] is None else min(until, segment["end"])
        if start < end:
            changes.extend(((start, 1), (end, -1)))
    active = maximum = 0
    for _, change in sorted(changes, key=lambda item: (item[0], item[1])):
        active += change
        maximum = max(maximum, active)
    return maximum


def _metric(values, unknown=0):
    known = sum(value for value in values if value is not None)
    eligible = len(values) + unknown
    return {"value": known if unknown == 0 and eligible else None, "known_count": len(values),
        "eligible_count": eligible, "unknown_reason_counts": {"missing_or_conflict": unknown} if unknown else {}}


def _model_record():
    return {"values": defaultdict(Fraction), "calls": Fraction(0), "known": defaultdict(Fraction),
        "eligible": defaultdict(Fraction), "unknown": defaultdict(Fraction),
        "integrity_unknown": Fraction(0), "integrity_eligible": Fraction(0)}


def _allocation_record():
    return {"values": defaultdict(Fraction), "calls": Fraction(0),
        "calls_by_role": defaultdict(Fraction), "known": defaultdict(Fraction),
        "eligible": defaultdict(Fraction), "unknown": defaultdict(Fraction),
        "models": defaultdict(_model_record)}


def allocate_calls(calls, segments):
    shares = {segment["segment_id"]: {role: _allocation_record() for role in ("reviewer", "executor")}
        for segment in segments}
    buckets = {name: _allocation_record()
        for name in ("outside_unattributed", "overlap_unattributed", "boundary_unattributed")}
    linked_segments = defaultdict(list)
    for segment in segments:
        for identity in segment.get("linked_messages", ()):
            linked_segments[identity].append(segment)
    changes = defaultdict(list)
    for index, segment in enumerate(segments):
        start, end = segment["start"], segment["end"]
        if end is not None and end <= start:
            continue
        changes[start].append((1, index, segment))
        if end is not None:
            changes[end].append((-1, index, segment))
    active_by_project = defaultdict(dict)
    active_count = 0
    boundary_times = sorted(changes)
    boundary_index = 0
    for call in sorted(calls, key=lambda item: (item["timestamp"] is None,
            item["timestamp"] if item["timestamp"] is not None else 0, item["project"], item["message_id"])):
        timestamp = call["timestamp"]
        while timestamp is not None and boundary_index < len(boundary_times) and boundary_times[boundary_index] <= timestamp:
            for action, index, segment in sorted(changes[boundary_times[boundary_index]], key=lambda item: item[0]):
                project = segment["project"]
                if action < 0:
                    if active_by_project[project].pop(index, None) is not None:
                        active_count -= 1
                    if not active_by_project[project]:
                        del active_by_project[project]
                else:
                    active_by_project[project][index] = segment
                    active_count += 1
            boundary_index += 1
        total_active = active_count
        project = call["project"]
        linked = linked_segments.get((project, call["message_id"]), ())
        if timestamp is None:
            destinations = [("bucket", "boundary_unattributed", Fraction(1))]
        elif any(timestamp == item["start"] or timestamp == item["end"] for item in linked):
            if len(linked) == 1:
                if linked[0].get("origin_status") == "origin_ambiguous":
                    destinations = [("bucket", "overlap_unattributed", Fraction(1))]
                else:
                    destinations = [("segment", linked[0]["segment_id"], Fraction(1))]
            else:
                destinations = [("bucket", "boundary_unattributed", Fraction(1))]
        elif not total_active:
            destinations = [("bucket", "outside_unattributed", Fraction(1))]
        elif project == "reviewer":
            destinations = []
            for label, active_segments in active_by_project.items():
                weight = Fraction(len(active_segments), total_active)
                if len(active_segments) == 1:
                    segment = next(iter(active_segments.values()))
                    if segment.get("origin_status") == "origin_ambiguous":
                        destinations.append(("bucket", "overlap_unattributed", weight))
                    else:
                        destinations.append(("segment", segment["segment_id"], weight))
                else:
                    destinations.append(("bucket", "overlap_unattributed", weight))
        elif len(active_by_project.get(project, {})) == 1:
            segment = next(iter(active_by_project[project].values()))
            if segment.get("origin_status") == "origin_ambiguous":
                destinations = [("bucket", "overlap_unattributed", Fraction(1))]
            else:
                destinations = [("segment", segment["segment_id"], Fraction(1))]
        elif active_by_project.get(project):
            destinations = [("bucket", "overlap_unattributed", Fraction(1))]
        else:
            destinations = [("bucket", "outside_unattributed", Fraction(1))]
        for destination_type, destination, weight in destinations:
            role = "reviewer" if project == "reviewer" else "executor"
            target = shares[destination][role] if destination_type == "segment" else buckets[destination]
            target["calls"] += weight
            target["calls_by_role"][role] += weight
            model = call["model"]
            model_record = target["models"][model]
            model_record["calls"] += weight
            values = call["usage"]
            model_record["integrity_eligible"] += weight
            if values.get("integrity", "integrity_unknown") == "integrity_unknown":
                model_record["integrity_unknown"] += weight
            for metric in METRICS:
                value = values[metric]
                target["eligible"][metric] += weight
                model_record["eligible"][metric] += weight
                if value is None:
                    target["unknown"][metric] += weight
                    model_record["unknown"][metric] += weight
                else:
                    target["known"][metric] += weight
                    target["values"][metric] += value * weight
                    model_record["known"][metric] += weight
                    model_record["values"][metric] += value * weight
    return shares, buckets


def time_proxies(calls, segments, since, until):
    segment_seconds = {segment["segment_id"]: {role: Fraction(0) for role in ("reviewer", "executor")}
        for segment in segments}
    buckets = {name: {role: Fraction(0) for role in ("reviewer", "executor")}
        for name in ("outside_unattributed", "overlap_unattributed", "boundary_unattributed")}
    changes = defaultdict(list)
    boundaries = {since, until}
    unknown_projects = {call["project"] for call in calls if call.get("timestamp") is None}
    for segment in segments:
        if "reviewer" in unknown_projects:
            segment_seconds[segment["segment_id"]]["reviewer"] = None
        if segment["project"] in unknown_projects:
            segment_seconds[segment["segment_id"]]["executor"] = None
        start = max(since, segment["start"])
        end = min(until, until if segment["end"] is None else segment["end"])
        if end <= start:
            continue
        boundaries.update((start, end))
        changes[start].append(("segment", 1, segment))
        changes[end].append(("segment", -1, segment))

    by_project = defaultdict(list)
    for call in calls:
        if call["project"] not in unknown_projects:
            by_project[call["project"]].append(call)
    for project, project_calls in by_project.items():
        project_calls.sort(key=lambda call: (call["timestamp"], call["message_id"]))
        for previous, current in zip(project_calls, project_calls[1:]):
            start, end = previous["timestamp"], current["timestamp"]
            if not 0 < end - start <= 300:
                continue
            start, end = max(start, since), min(end, until)
            if end <= start:
                continue
            boundaries.update((start, end))
            changes[start].append(("activity", 1, project))
            changes[end].append(("activity", -1, project))

    active_by_project, active_intervals = defaultdict(dict), defaultdict(int)
    points = sorted(boundaries)
    for index, point in enumerate(points[:-1]):
        for kind, delta, item in sorted(changes[point], key=lambda change: (change[0], change[1])):
            if kind == "segment":
                project, segment_id = item["project"], item["segment_id"]
                if delta < 0:
                    active_by_project[project].pop(segment_id, None)
                else:
                    active_by_project[project][segment_id] = item
            else:
                active_intervals[item] += delta
        next_point = points[index + 1]
        duration = next_point - point
        if not duration:
            continue
        for project, count in active_intervals.items():
            if count <= 0:
                continue
            role = "reviewer" if project == "reviewer" else "executor"
            if role == "executor":
                own = active_by_project.get(project, {})
                if not own:
                    buckets["outside_unattributed"][role] += duration
                elif len(own) == 1:
                    segment = next(iter(own.values()))
                    if segment.get("origin_status") == "origin_ambiguous":
                        buckets["overlap_unattributed"][role] += duration
                    else:
                        segment_seconds[segment["segment_id"]][role] += duration
                else:
                    buckets["overlap_unattributed"][role] += duration
                continue
            total_active = sum(len(project_segments) for project_segments in active_by_project.values())
            if not total_active:
                buckets["outside_unattributed"][role] += duration
                continue
            for active_project, project_segments in active_by_project.items():
                if len(project_segments) == 1:
                    segment = next(iter(project_segments.values()))
                    share = Fraction(duration, total_active)
                    if segment.get("origin_status") == "origin_ambiguous":
                        buckets["overlap_unattributed"][role] += share
                    else:
                        segment_seconds[segment["segment_id"]][role] += share
                elif project_segments:
                    buckets["overlap_unattributed"][role] += Fraction(
                        duration * len(project_segments), total_active)
    for data in buckets.values():
        if "reviewer" in unknown_projects:
            data["reviewer"] = None
        if unknown_projects - {"reviewer"}:
            data["executor"] = None
    return {"segment_seconds": segment_seconds, "buckets": buckets, "unknown_projects": unknown_projects}


def _display(value):
    if isinstance(value, Fraction):
        if value.denominator == 1:
            return value.numerator
        return round(value.numerator / value.denominator, 6)
    return round(value, 6) if isinstance(value, float) else value


def _safe_model(value):
    if not isinstance(value, str) or not value.strip():
        return None
    label = value[:-4] if value.endswith("[1m]") else value
    if (len(value) <= 128 and not value.startswith("/")
            and re.fullmatch(r"[A-Za-z0-9_.:/+-]{1,128}", label)):
        return value
    return "~model-" + hashlib.sha256(value.encode("utf-8", errors="surrogatepass")).hexdigest()


def _unknown_models(calls):
    models = defaultdict(set)
    for call in calls:
        if call.get("timestamp") is None:
            models[call["project"]].add(_safe_model(call.get("model")))
    return models


def _model_uncertainty(project, model, unknown_models):
    return {role: None in unknown_models.get(label, ()) or model in unknown_models.get(label, ())
        for role, label in (("reviewer", "reviewer"), ("executor", project))}


def _segment_model_usage(share, project, unknown_models):
    models = {}
    for role in ("reviewer", "executor"):
        for raw_model, data in share[role]["models"].items():
            model = _safe_model(raw_model)
            uncertain = _model_uncertainty(project, model, unknown_models)
            item = models.setdefault(model, {"model": model,
                "calls": {"reviewer": Fraction(0), "executor": Fraction(0)}, "usage": {}})
            item["calls"][role] += data["calls"]
            for metric in METRICS:
                reasons = {"missing_or_conflict": _display(data["unknown"][metric])} \
                    if data["unknown"][metric] else {}
                value = _display(data["values"][metric])
                if uncertain[role]:
                    reasons["time_unknown"] = None
                metric_data = {"value": value
                        if data["eligible"][metric] and not data["unknown"][metric] else None,
                    "known_count": _display(data["known"][metric]),
                    "eligible_count": _display(data["eligible"][metric]),
                    "unknown_reason_counts": reasons}
                if uncertain[role]:
                    metric_data.update(value=None, known_value=value, eligible_count=None)
                item["usage"].setdefault(metric, {})[role] = metric_data
    return [{"model": item["model"],
        "calls": {role: None if _model_uncertainty(project, item["model"], unknown_models)[role]
            else _display(item["calls"][role]) for role in ("reviewer", "executor")},
        "usage": item["usage"]}
        for _, item in sorted(models.items(), key=lambda pair: pair[0] or "")]


def _groups(segments, shares, unknown_models):
    grouped = {}
    for segment in segments:
        if segment["status"] != "complete" or segment["end"] is None:
            continue
        end_date = dt.datetime.fromtimestamp(segment["end"], dt.timezone.utc).date()
        week = (end_date - dt.timedelta(days=end_date.weekday())).isoformat()
        for role, allocation in shares[segment["segment_id"]].items():
            for raw_model, data in allocation["models"].items():
                model = _safe_model(raw_model)
                uncertain = _model_uncertainty(segment["project"], model, unknown_models)
                key = (week, segment["project"], model)
                group = grouped.setdefault(key, {"calls": defaultdict(Fraction),
                    "uncertain_roles": set(), "values": defaultdict(Fraction),
                    "known": defaultdict(Fraction), "eligible": defaultdict(Fraction),
                    "unknown": defaultdict(Fraction), "segment_metrics": {},
                    "integrity": {"integrity_unknown_count": Fraction(0), "eligible_count": Fraction(0)},
                    "attribution": {"known_count": Fraction(0), "eligible_count": Fraction(0)},
                    "business": {"complete_count": 0, "first_pass_numerator": 0,
                        "first_pass_denominator": 0}})
                group["calls"][role] += data["calls"]
                group["uncertain_roles"].update(name for name, value in uncertain.items() if value)
                group["integrity"]["integrity_unknown_count"] += data["integrity_unknown"]
                group["integrity"]["eligible_count"] += data["integrity_eligible"]
                group["attribution"]["known_count"] += data["calls"]
                group["attribution"]["eligible_count"] += data["calls"]
                new_segment = segment["segment_id"] not in group["segment_metrics"]
                segment_metrics = group["segment_metrics"].setdefault(segment["segment_id"], {
                    metric: {"value": Fraction(0), "eligible": Fraction(0), "unknown": Fraction(0),
                        "time_unknown": False} for metric in METRICS})
                if new_segment:
                    group["business"]["complete_count"] += 1
                    group["business"]["first_pass_denominator"] += 1
                    group["business"]["first_pass_numerator"] += int(segment["first_pass"] is True)
                for metric in METRICS:
                    group["values"][metric] += data["values"][metric]
                    group["known"][metric] += data["known"][metric]
                    group["eligible"][metric] += data["eligible"][metric]
                    group["unknown"][metric] += data["unknown"][metric]
                    segment_metrics[metric]["value"] += data["values"][metric]
                    segment_metrics[metric]["eligible"] += data["eligible"][metric]
                    segment_metrics[metric]["unknown"] += data["unknown"][metric]
                    segment_metrics[metric]["time_unknown"] |= any(uncertain.values())
    rows = []
    for (week, project, model), data in sorted(grouped.items(),
            key=lambda item: (item[0][0], item[0][1], item[0][2] or "")):
        metrics = {}
        for metric in METRICS:
            unknown, eligible = data["unknown"][metric], data["eligible"][metric]
            time_unknown = any(item[metric]["time_unknown"] for item in data["segment_metrics"].values())
            samples = sorted(item[metric]["value"] for item in data["segment_metrics"].values()
                if item[metric]["eligible"] and not item[metric]["unknown"]
                and not item[metric]["time_unknown"])
            middle = len(samples) // 2
            reasons = {"missing_or_conflict": _display(unknown)} if unknown else {}
            if time_unknown:
                reasons["time_unknown"] = None
            metrics[metric] = {"value": _display(data["values"][metric])
                    if not unknown and eligible and not time_unknown else None,
                "known_count": _display(data["known"][metric]),
                "eligible_count": None if time_unknown else _display(eligible),
                "unknown_reason_counts": reasons,
                "sample_count": len(samples),
                "mean": _display(sum(samples, Fraction(0)) / len(samples)) if samples else None,
                "median": _display(samples[middle] if len(samples) % 2 else
                    (samples[middle - 1] + samples[middle]) / 2) if samples else None}
            if time_unknown:
                metrics[metric]["known_value"] = _display(data["values"][metric])
        wall_eligible = len(data["segment_metrics"])
        rows.append({"week_start": week, "project": project, "model": model,
            "business": data["business"],
            "integrity": {"integrity_unknown_count": _display(data["integrity"]["integrity_unknown_count"]),
                "eligible_count": _display(data["integrity"]["eligible_count"])},
            "attribution": {"status": "segment_attributed_only",
                "known_count": _display(data["attribution"]["known_count"]),
                "eligible_count": _display(data["attribution"]["eligible_count"])},
            "wall_clock": {"value": None, "known_count": 0, "eligible_count": wall_eligible,
                "unknown_reason_counts": {"not_attributed_by_model": wall_eligible} if wall_eligible else {}},
            "calls": {role: None if role in data["uncertain_roles"] else _display(data["calls"][role])
                for role in ("reviewer", "executor")},
            **metrics, "wall_clock_seconds": None,
            "wall_clock_status": "not_attributed_by_model"})
    return rows


def _time_metric(values, unknown_reason):
    known = sorted(value for value in values if value is not None)
    unknown_count = len(values) - len(known)
    total = sum(known, Fraction(0))
    middle = len(known) // 2
    return {"value": _display(total) if not unknown_count else None,
        "known_value": _display(total), "known_count": len(known), "eligible_count": len(values),
        "unknown_reason_counts": {unknown_reason: unknown_count} if unknown_count else {},
        "sample_count": len(known), "mean": _display(total / len(known)) if known else None,
        "median": _display(known[middle] if len(known) % 2 else
            (known[middle - 1] + known[middle]) / 2) if known else None}


def _rollups(segments, activity):
    grouped = {"weekly": defaultdict(list), "projects": defaultdict(list)}
    for segment in segments:
        if segment["status"] != "complete" or segment["end"] is None:
            continue
        end_date = dt.datetime.fromtimestamp(segment["end"], dt.timezone.utc).date()
        week = (end_date - dt.timedelta(days=end_date.weekday())).isoformat()
        grouped["weekly"][(week, segment["project"])].append(segment)
        grouped["projects"][segment["project"]].append(segment)

    def summarize(key, items, weekly):
        business = {"complete_count": len(items),
            "first_pass_numerator": sum(item["first_pass"] is True for item in items),
            "first_pass_denominator": len(items)}
        wall = [item["end"] - item["start"] if not item.get("left_censored") else None
            for item in items]
        active = {role: [activity["segment_seconds"][item["segment_id"]][role] for item in items]
            for role in ("reviewer", "executor")}
        row = {"project": key[1] if weekly else key, "business": business,
            "time": {"wall_clock_seconds": _time_metric(wall, "left_censored"),
                "active_seconds": {role: _time_metric(values, "time_unknown")
                    for role, values in active.items()}}}
        if weekly:
            row["week_start"] = key[0]
        return row

    return {"weekly": [summarize(key, items, True)
            for key, items in sorted(grouped["weekly"].items())],
        "projects": [summarize(key, items, False)
            for key, items in sorted(grouped["projects"].items())]}


def build_report(calls, segments, since, until, context=None):
    context = context or {}
    shares, bucket_data = allocate_calls(calls, segments)
    activity = time_proxies(calls, segments, since, until)
    dimensions = {}
    for field in ("timestamp", "model"):
        reasons = defaultdict(int)
        for call in calls:
            if call.get(field) is None:
                reasons[call.get(field + "_status", "missing")] += 1
        dimensions[field] = {"known_count": len(calls) - sum(reasons.values()),
            "eligible_count": len(calls), "unknown_reason_counts": dict(sorted(reasons.items()))}
    reported = {}
    for metric in METRICS:
        values = [call["usage"][metric] for call in calls]
        unknown = sum(value is None for value in values)
        reported[metric] = _metric([value for value in values if value is not None], unknown)
    rows = []
    unknown_models = _unknown_models(calls)
    for segment in segments:
        sid, share = segment["segment_id"], shares[segment["segment_id"]]
        uncertain = {"reviewer": "reviewer" in activity["unknown_projects"],
            "executor": segment["project"] in activity["unknown_projects"]}
        usage, calls_by_role = {}, {}
        for metric in METRICS:
            usage[metric] = {}
            for role in ("reviewer", "executor"):
                unknown = share[role]["unknown"][metric]
                value = share[role]["values"][metric]
                known_count = _display(share[role]["known"][metric])
                eligible_count = _display(share[role]["eligible"][metric])
                usage[metric][role] = {"value": _display(value)
                    if share[role]["eligible"][metric] and not unknown else None,
                    "known_count": known_count, "eligible_count": eligible_count,
                    "unknown_reason_counts": {"missing_or_conflict": _display(unknown)} if unknown else {}}
                if uncertain[role]:
                    usage[metric][role].update(value=None, known_value=_display(value), eligible_count=None)
                    usage[metric][role]["unknown_reason_counts"]["time_unknown"] = None
            known = sum((share[role]["known"][metric] for role in ("reviewer", "executor")), Fraction(0))
            eligible = sum((share[role]["eligible"][metric] for role in ("reviewer", "executor")), Fraction(0))
            unknown = sum((share[role]["unknown"][metric] for role in ("reviewer", "executor")), Fraction(0))
            incomplete_time = any(uncertain.values())
            combined_value = sum((share[role]["values"][metric] for role in ("reviewer", "executor")), Fraction(0))
            reasons = {"missing_or_conflict": _display(unknown)} if unknown else {}
            if incomplete_time:
                reasons["time_unknown"] = None
            usage[metric]["combined"] = {"value": _display(combined_value)
                if eligible and not unknown and not incomplete_time else None,
                "known_count": _display(known),
                "eligible_count": None if incomplete_time else _display(eligible),
                "unknown_reason_counts": reasons}
        for role in ("reviewer", "executor"):
            calls_by_role[role] = None if uncertain[role] else _display(share[role]["calls"])
        observed_from = segment.get("observed_from", max(since, segment["start"]))
        observed_until = segment.get("observed_until", min(until,
            segment["end"] if segment["end"] is not None else until))
        executor_models = share["executor"]["models"]
        actual_models = sorted(_safe_model(model) for model, data in executor_models.items()
            if _safe_model(model) is not None and data["calls"])
        unknown_model = any(model is None and data["calls"] for model, data in executor_models.items())
        primary_model = actual_models[0] if len(actual_models) == 1 and not unknown_model else None
        usage_status = "unknown" if any(share[role]["unknown"][metric]
            for role in ("reviewer", "executor") for metric in METRICS) else "reported"
        rows.append({"segment_id": sid, "project": segment["project"],
            "start": None if segment.get("left_censored") else utc_text(segment["start"]),
            "end": utc_text(segment["end"]) if segment["end"] is not None else None,
            "observed_interval": {"from": utc_text(observed_from), "until": utc_text(observed_until)},
            "wall_clock_seconds": segment["end"] - segment["start"]
                if segment["end"] is not None and not segment.get("left_censored") else None,
            "status": segment["status"], "overlap_status": segment.get("overlap_status"),
            "origin_status": segment.get("origin_status"),
            "rework_count": segment["rework_count"], "rounds": segment["rounds"],
            "first_pass": segment["first_pass"],
            "active_seconds": {role: _display(activity["segment_seconds"][sid][role])
                for role in ("reviewer", "executor")},
            "calls": calls_by_role, "usage": usage,
            "primary_model": primary_model, "actual_models": actual_models,
            "model_usage": _segment_model_usage(share, segment["project"], unknown_models),
            "quality": {"business_status": segment["status"], "source_status": "complete",
                "usage_status": usage_status,
                "model_status": "mixed" if len(actual_models) > 1 else "unknown"
                    if primary_model is None else "known",
                "integrity_status": "integrity_unknown",
                "attribution_status": {role: "time_unknown" if value else "known"
                    for role, value in uncertain.items()},
                "activity_status": {role: "time_unknown" if value else "known"
                    for role, value in uncertain.items()}}})
    output_buckets = {}
    for name, data in bucket_data.items():
        output_buckets[name] = {metric: {
            "value": _display(data["values"][metric])
                if data["eligible"][metric] and not data["unknown"][metric] else None,
            "known_count": _display(data["known"][metric]),
            "eligible_count": _display(data["eligible"][metric]),
            "unknown_reason_counts": {"missing_or_conflict": _display(data["unknown"][metric])} if data["unknown"][metric] else {}}
            for metric in METRICS}
        output_buckets[name]["active_seconds"] = {
            role: _display(activity["buckets"][name][role]) for role in ("reviewer", "executor")}
    attribution = {}
    for role in ("reviewer", "executor"):
        known = sum((record[role]["calls"] for record in shares.values()), Fraction(0))
        buckets = {name: record["calls_by_role"][role] for name, record in bucket_data.items()
            if record["calls_by_role"][role]}
        eligible = known + sum(buckets.values(), Fraction(0))
        attribution[role] = {"known_count": _display(known), "eligible_count": _display(eligible),
            "bucket_reason_counts": {name: _display(value) for name, value in sorted(buckets.items())}}
    complete_wall = [segment["end"] - segment["start"] for segment in segments
        if segment["status"] == "complete" and segment["end"] is not None
        and not segment.get("left_censored")]
    incomplete_wall = defaultdict(int)
    for segment in segments:
        if segment["status"] != "complete" or segment.get("left_censored"):
            incomplete_wall[segment["status"]] += 1
    wall_known = sum(complete_wall)
    wall_eligible = len(segments)
    wall_time = {"value": wall_known if not incomplete_wall else None,
        "known_value": wall_known, "known_count": len(complete_wall), "eligible_count": wall_eligible,
        "unknown_reason_counts": dict(sorted(incomplete_wall.items()))}
    active_time = {}
    for role in ("reviewer", "executor"):
        values = [activity["segment_seconds"][segment["segment_id"]][role] for segment in segments]
        values.extend(activity["buckets"][name][role] for name in bucket_data)
        known_values = [value for value in values if value is not None]
        unknown_count = len(values) - len(known_values)
        active_time[role] = {"value": _display(sum(known_values, Fraction(0))) if not unknown_count else None,
            "known_value": _display(sum(known_values, Fraction(0))),
            "known_count": len(known_values), "eligible_count": len(values),
            "unknown_reason_counts": {"time_unknown": unknown_count} if unknown_count else {}}
    return {"schema_version": 1, "window_utc": {"since": utc_text(since), "until": utc_text(until)},
        "projects": [], "sources": {"selected_file_count": 0, "rows_in_window": 0},
        "scan": {"status": "complete", "bad_row_count": 0}, "segments": rows,
        "totals": {**reported, "business": {
            "complete_count": sum(segment["status"] == "complete" for segment in segments),
            "first_pass_numerator": sum(segment["first_pass"] is True for segment in segments),
            "first_pass_denominator": sum(segment["status"] == "complete" for segment in segments),
            "unmatched_terminal_count": context.get("unmatched_terminal_count", 0)},
            "time": {"wall_clock_seconds": wall_time, "active_seconds": active_time},
            "integrity": {"integrity_unknown_count": len(calls), "eligible_count": len(calls)},
            "dimensions": dimensions, "attribution": attribution},
        "groups": _groups(segments, shares, unknown_models),
        "rollups": _rollups(segments, activity), "buckets": output_buckets,
        "comparability": "no_comparable_baseline"}


def render_text(report):
    totals = report["totals"]
    business = totals["business"]
    time = totals["time"]
    wall = time["wall_clock_seconds"]
    active = time["active_seconds"]

    def format_seconds(value):
        return "unknown" if value is None else f"{value}s"

    coverage = " ".join(f"{name}={totals[name]['known_count']}/{totals[name]['eligible_count']}"
        for name in METRICS)
    dimensions = " ".join(f"{name}={item['known_count']}/{item['eligible_count']}"
        for name, item in totals["dimensions"].items())
    lines = ["Selected transcript usage (not a full bill)",
        "Reported token usage: total input %s; uncached input %s; output %s" % tuple(totals[key]["value"] for key in METRICS),
        "API integrity unknown: %d; reported usage is not a full bill." % totals["integrity"]["integrity_unknown_count"],
        "Segments: %d" % len(report["segments"]),
        "Business: complete=%d; first-pass=%d/%d; unmatched-terminal=%d" % (
            business["complete_count"], business["first_pass_numerator"],
            business["first_pass_denominator"], business["unmatched_terminal_count"]),
        "Time coverage: wall-clock=%s (%d/%d); active reviewer=%s (%d/%d), executor=%s (%d/%d)" % (
            format_seconds(wall["value"]), wall["known_count"], wall["eligible_count"],
            format_seconds(active["reviewer"]["value"]), active["reviewer"]["known_count"],
            active["reviewer"]["eligible_count"], format_seconds(active["executor"]["value"]),
            active["executor"]["known_count"], active["executor"]["eligible_count"]),
        f"Coverage: {coverage}; {dimensions}",
        "Comparability: no comparable baseline.",
        "Attribution: reviewer shares are time-window estimates; overlap and outside usage are bucketed."]
    if report["scan"]["status"] == "no_samples":
        return "\n".join((lines[0], "No samples in selected transcripts and window.", *lines[3:]))
    if any(item["known_count"] < item["eligible_count"] for item in totals["dimensions"].values()):
        lines.append(f"Dimension coverage: {dimensions}; unknown dimensions do not erase reported usage.")
    if report["scan"]["status"] == "partial":
        lines.append(f"Partial: coverage loss ({report['scan']['bad_row_count']} malformed source rows); reported-usage coverage {coverage}.")
    return "\n".join(lines)


def _pairs(values, name, multiple=False):
    pairs = {}
    for value in values:
        if "=" not in value:
            raise argparse.ArgumentTypeError(f"{name} must be LABEL=VALUE")
        label, path = value.split("=", 1)
        if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", label) or not path or (label in pairs and not multiple):
            raise argparse.ArgumentTypeError(f"invalid {name}")
        if multiple:
            pairs.setdefault(label, []).append(path)
        else:
            pairs[label] = path
    return pairs


def _event_call_ids(path, label, since, until):
    event_use_ids = set()
    with open(path, "rb") as stream:
        while True:
            raw = stream.readline(MAX_LINE_BYTES + 2)
            if not raw:
                break
            if len(raw) > MAX_LINE_BYTES + int(raw.endswith(b"\n")):
                raise InputFailure("resource_limit")
            try:
                row = json.loads(raw)
                if not isinstance(row, dict):
                    continue
                timestamp = row.get("timestamp")
                stamp = parse_utc(timestamp) if isinstance(timestamp, str) else timestamp
                if type(stamp) is not int or not since <= stamp < until or row.get("type") != "assistant":
                    continue
                message = row.get("message")
                content = message.get("content") if isinstance(message, dict) else None
                if isinstance(content, list):
                    event_use_ids.update((label, block["id"]) for block in content
                        if isinstance(block, dict) and block.get("type") == "tool_use"
                        and isinstance(block.get("name"), str) and block["name"] in EVENT_TOOLS
                        and isinstance(block.get("id"), str))
                if len(event_use_ids) > MAX_EVENTS:
                    raise InputFailure("resource_limit")
            except (ValueError, TypeError, argparse.ArgumentTypeError, UnicodeDecodeError):
                continue
    return event_use_ids


def _read(path, label, since, until, all_event_use_ids=None):
    rows, usage_records, bad_rows, rows_in_window = [], [], 0, 0
    event_use_ids, model_cache = set(), {}
    all_event_use_ids = all_event_use_ids or event_use_ids
    try:
        if not pathlib.Path(path).is_file():
            raise InputFailure("input_unreadable")
        with open(path, "rb") as stream:
            line_no = 0
            while True:
                raw = stream.readline(MAX_LINE_BYTES + 2)
                if not raw:
                    break
                line_no += 1
                if len(raw) > MAX_LINE_BYTES + int(raw.endswith(b"\n")):
                    raise InputFailure("resource_limit")
                try:
                    row = json.loads(raw)
                    if not isinstance(row, dict):
                        raise ValueError
                    timestamp = row.get("timestamp")
                    stamp = parse_utc(timestamp) if isinstance(timestamp, str) else timestamp
                    if type(stamp) is not int:
                        raise ValueError
                except (ValueError, TypeError, argparse.ArgumentTypeError, UnicodeDecodeError):
                    bad_rows += 1
                    continue
                if not since <= stamp < until:
                    continue
                rows_in_window += 1
                row["_project"], row["_timestamp"], row["_line"] = label, stamp, line_no
                message = row.get("message")
                if row.get("type") in ("assistant", "user") and not isinstance(message, dict):
                    bad_rows += 1
                    continue
                content = message.get("content") if isinstance(message, dict) else None
                if row.get("type") == "assistant" and isinstance(message, dict):
                    if isinstance(message.get("id"), str):
                        model = message.get("model")
                        if isinstance(model, str) and len(model) <= 80 and len(model_cache) < MAX_MODELS:
                            model = model_cache.setdefault(model, model)
                        usage_records.append((label, message["id"], stamp,
                            model, _compact_usage(message.get("usage"))))
                    event_blocks = []
                    for block in content if isinstance(content, list) else []:
                        if not isinstance(block, dict) or block.get("type") != "tool_use":
                            continue
                        name = block.get("name")
                        if not isinstance(name, str):
                            bad_rows += 1
                        elif name in EVENT_TOOLS:
                            if not isinstance(block.get("id"), str) or _event_inputs(block) is None:
                                bad_rows += 1
                            else:
                                event_blocks.append(block)
                    if event_blocks:
                        event_use_ids.update((label, block.get("id")) for block in event_blocks
                            if isinstance(block.get("id"), str))
                        event_row = dict(row)
                        event_row["message"] = dict(message, content=event_blocks)
                        rows.append(event_row)
                elif row.get("type") == "user" and isinstance(content, list):
                    result_blocks = []
                    if isinstance(content, list):
                        for block in content:
                            if not isinstance(block, dict) or block.get("type") != "tool_result":
                                continue
                            use_id = block.get("tool_use_id")
                            if not isinstance(use_id, str):
                                bad_rows += 1
                            elif (label, use_id) in all_event_use_ids:
                                result_blocks.append(block)
                    if result_blocks:
                        event_row = dict(row)
                        event_row["message"] = dict(message, content=result_blocks)
                        rows.append(event_row)
    except OSError as exc:
        raise InputFailure("input_unreadable") from exc
    return rows, usage_records, bad_rows, rows_in_window


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", action="append", default=[])
    parser.add_argument("--transcript", action="append", default=[])
    parser.add_argument("--since", required=True, type=parse_utc)
    parser.add_argument("--until", required=True, type=parse_utc)
    parser.add_argument("--json-out")
    args, unknown_arguments = parser.parse_known_args(argv)
    if unknown_arguments:
        print("error: invalid_arguments", file=sys.stderr)
        return 2
    try:
        projects = _pairs(args.project, "project")
        transcript_map = _pairs(args.transcript, "transcript", multiple=True)
        transcripts = [(label, path) for label, paths in transcript_map.items() for path in paths]
        executors = sorted(set(projects) - {"reviewer"})
        if "reviewer" not in projects or not executors or args.since >= args.until \
                or any(label not in projects for label, _ in transcripts):
            raise InputFailure("invalid_arguments")
        if len({os.path.realpath(path) for path in projects.values()}) != len(projects):
            raise InputFailure("invalid_arguments")
        identities = defaultdict(set)
        unique_transcripts = {}
        for label, path in transcripts:
            identity = os.path.realpath(path)
            identities[identity].add(label)
            unique_transcripts.setdefault((label, identity), path)
        if any(len(labels) > 1 for labels in identities.values()):
            raise InputFailure("duplicate_transcript_identity")
        transcripts = sorted((label, path) for (label, _), path in unique_transcripts.items())
        if len(executors) > MAX_EXECUTORS or len(transcripts) > MAX_FILES:
            raise InputFailure("resource_limit")
        total_bytes = 0
        for _, path in transcripts:
            try:
                file_stat = os.stat(path)
            except OSError as exc:
                raise InputFailure("input_unreadable") from exc
            if not stat.S_ISREG(file_stat.st_mode):
                raise InputFailure("input_unreadable")
            total_bytes += file_stat.st_size
            if total_bytes > MAX_TOTAL_BYTES:
                raise InputFailure("resource_limit")
        if args.json_out and pathlib.Path(args.json_out).exists():
            raise InputFailure("output_exists")
        event_use_ids = set()
        for label, path in transcripts:
            event_use_ids.update(_event_call_ids(path, label, args.since, args.until))
            if len(event_use_ids) > MAX_EVENTS:
                raise InputFailure("resource_limit")
        rows, records, bad_rows, rows_in_window = [], [], 0, 0
        for label, path in transcripts:
            chunk, usage, issues, row_count = _read(path, label, args.since, args.until,
                event_use_ids)
            rows.extend(chunk)
            records.extend(usage)
            bad_rows += issues
            rows_in_window += row_count
        events = parse_successful_events(rows, projects)
        if len(events) > MAX_EVENTS:
            raise InputFailure("resource_limit")
        event_diagnostics = {}
        segments = build_segments(events, executors, args.since, args.until, event_diagnostics)
        if len(segments) > MAX_SEGMENTS:
            raise InputFailure("resource_limit")
        del rows, events
        calls = canonical_usage(records, consume=True)
        del records
        if len(calls) > MAX_CALLS:
            raise InputFailure("resource_limit")
        concurrency = _max_concurrency(segments, args.until)
        models = {call["model"] for call in calls if call["model"] is not None}
        if concurrency > MAX_CONCURRENCY or len(models) > MAX_MODELS \
                or len(segments) * len(models) > MAX_SEGMENT_MODEL_CHECKS:
            raise InputFailure("resource_limit")
        report = build_report(calls, segments, args.since, args.until, event_diagnostics)
        output_rows = len(report["segments"]) + len(report["groups"]) \
            + len(report["rollups"]["weekly"]) + len(report["rollups"]["projects"]) \
            + len(report["buckets"]) \
            + sum(len(segment["model_usage"]) for segment in report["segments"])
        if output_rows > MAX_OUTPUT_ROWS:
            raise InputFailure("resource_limit")
        report["projects"] = [{"label": label, "role": "reviewer" if label == "reviewer" else "executor"}
            for label in sorted(projects)]
        report["sources"] = {"selected_file_count": len(transcripts), "rows_in_window": rows_in_window,
            "scope": "explicit_transcripts_only",
            "source_type_coverage": "caller_selected_not_inferred"}
        report["scan"]["bad_row_count"] = bad_rows
        for segment in report["segments"]:
            segment["quality"]["source_status"] = "partial" if bad_rows else "complete"
        usage_gap = any(report["totals"][metric]["known_count"] < report["totals"][metric]["eligible_count"]
            for metric in METRICS)
        dimension_gap = any(item["known_count"] < item["eligible_count"]
            for item in report["totals"]["dimensions"].values())
        if bad_rows or usage_gap or dimension_gap:
            report["scan"]["status"] = "partial"
        elif not calls and not segments:
            report["scan"]["status"] = "no_samples"
        output = render_text(report)
        if args.json_out:
            with open(args.json_out, "x", encoding="utf-8") as stream:
                json.dump(report, stream, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                stream.write("\n")
        print(output)
        return 1 if report["scan"]["status"] == "partial" else 0
    except InputFailure as exc:
        print(f"error: {exc.category}", file=sys.stderr)
        return 2
    except (argparse.ArgumentTypeError, OSError) as exc:
        print(f"error: {type(exc).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

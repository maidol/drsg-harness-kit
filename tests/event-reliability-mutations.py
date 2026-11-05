#!/usr/bin/env python3
"""Pair every mutation with its own test; native cases use local fake services."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = os.environ.get('RUN_EVENT_RELIABILITY_NATIVE') == '1'
MUTATIONS = [
    ('sender-check', 'tools/event.py', 'if canon_path(source_path) != sender_path:', 'if False:', ['bash', 'tests/event-supersedes.sh'], {'ONLY': 'test_refuse_not_sender'}),
    ('recipient-check', 'tools/event.py', 'if not matches:\n        res = rpc("plane.cypher", {"plane": PLANE,\n            "query": "MATCH (e:Event) WHERE key(e) = $key RETURN e",\n            "params": {"key": supersedes}}, token)', 'if False:\n        res = rpc("plane.cypher", {"plane": PLANE,\n            "query": "MATCH (e:Event) WHERE key(e) = $key RETURN e",\n            "params": {"key": supersedes}}, token)', ['bash', 'tests/event-supersedes.sh'], {'ONLY': 'test_refuse_other_recipient'}),
    ('drop-supersedes', 'tools/event.py', '("supersedes", supersedes, _supersedes_target)', '("supersedes", None, _supersedes_target)', ['python3', '-I', 'tests/event-reliability.py', 'TestProtocol.test_invalid_supersedes_is_not_silently_dropped'], {}),
    ('drop-extra-check', 'tools/mcp_events.py', '        if extra:\n            raise ev.FieldRejected("arguments",', '        if False:\n            raise ev.FieldRejected("arguments",', ['python3', '-I', 'tests/event-reliability.py', 'TestProtocol.test_reply_rejects_extra_fields_not_silently_discarded'], {}),
    ('ignore-prompt', 'tools/templates/hooks/event_retry_guard.py', 'digest([session, prompt, data.get("cwd")])', 'digest([session, data.get("cwd")])', ['python3', '-I', 'tests/event-retry-guard.py', 'TestRetryGuard.test_corrected_fields_other_recipient_session_and_prompt_are_not_denied'], {}),
    ('unknown-is-unposted', 'tools/templates/hooks/event_retry_guard.py', '    if result.get("posted") is not False:\n        return []', '    if False:\n        return []', ['python3', '-I', 'tests/event-retry-guard.py', 'TestRetryGuard.test_non_parameter_and_partial_delivery_errors_are_ignored'], {}),
    ('ignore-delivery-status', 'tools/templates/hooks/event_retry_guard.py', '    if prefix == "EVENT_POST_STATUS ":', '    if False:', ['python3', '-I', 'tests/event-retry-guard.py', 'TestRetryGuard.test_delivery_outcomes_stop_blind_resends_but_not_read_only_checks'], {}),
    ('no-symlink-check', 'tools/templates/hooks/event_retry_guard.py', ' | os.O_NOFOLLOW', '', ['python3', '-I', 'tests/event-retry-guard.py', 'TestRetryGuard.test_symlink_state_never_overwrites_target'], {}),
    ('ignore-node-record', 'tools/event.py', '    if not (node or {}).get("id"):', '    if False:', ['python3', '-I', 'tests/event-reliability.py', 'TestProtocol.test_missing_node_or_notify_never_claims_success'], {}),
    ('ignore-notify-record', 'tools/event.py', '    if not edge:', '    if False:', ['python3', '-I', 'tests/event-reliability.py', 'TestProtocol.test_missing_node_or_notify_never_claims_success'], {}),
    ('duplicate-delivery', 'tools/event.py', '    return report(result, target)', '    post(target, pid, summary, kind, ref, os.path.basename(sender), token, from_path=sender, reply_to=event_key)\n    return report(result, target)', ['python3', '-I', 'tests/event-reliability.py', 'TestProtocol.test_reply_uses_incoming_sender_and_never_closes_it'], {}),
    ('no-native-deny', 'tools/templates/hooks/event_retry_guard.py', '"permissionDecision": "deny"', '"permissionDecision": "allow"', ['python3', '-I', 'tests/fixtures/event-reliability-native.py', 'stop'], {}),
    ('no-native-stop', 'tools/templates/hooks/event_retry_guard.py', '"continue": False', '"continue": True', ['python3', '-I', 'tests/fixtures/event-reliability-native.py', 'stop'], {}),
]

if '--leave-survivor' in sys.argv:
    _, relative, old, _, command, extra = MUTATIONS[0]
    MUTATIONS = [('deliberate-survivor', relative, old, old, command, extra)]


def run(root, command, extra):
    for cache in root.rglob('__pycache__'):
        shutil.rmtree(cache)
    env = dict(os.environ, LC_ALL='C', TZ='UTC', PYTHONDONTWRITEBYTECODE='1', DRSG_MEM_DIR=str(root / 'state'), **extra)
    return subprocess.run(command, cwd=root, env=env, text=True, capture_output=True, timeout=65)


with tempfile.TemporaryDirectory(prefix='event-reliability-mutants-') as directory:
    root = Path(directory)
    shutil.copytree(ROOT / 'tools', root / 'tools')
    (root / 'tests/fixtures').mkdir(parents=True)
    for name in ('event-reliability.py', 'event-retry-guard.py', 'event-supersedes.sh'):
        shutil.copy2(ROOT / 'tests' / name, root / 'tests' / name)
    for name in ('event-reliability-native.py', 'event-reliability-mcp.py'):
        shutil.copy2(ROOT / 'tests/fixtures' / name, root / 'tests/fixtures' / name)
    control = run(root, ['python3', '-I', 'tests/event-reliability.py', 'TestProtocol.test_invalid_supersedes_is_not_silently_dropped'], {})
    if control.returncode:
        print('NOT_RUN: unmodified control failed')
        sys.exit(2)
    print('identity_control: survived (expected)')
    killed, skipped = 0, 0
    for name, relative, old, new, command, extra in MUTATIONS:
        if name.startswith('no-native-') and not NATIVE:
            print(name + ': not_run (native opt-in required)')
            skipped += 1
            continue
        path = root / relative
        original = path.read_text()
        if old not in original:
            print(name + ': NOT_RUN anchor missing')
            sys.exit(2)
        try:
            path.write_text(original.replace(old, new))
            result = run(root, command, extra)
        finally:
            path.write_text(original)
        output = result.stdout + result.stderr
        expected_failure = 'FAILED (failures=' in output or 'AssertionError: native repeat was not denied and stopped' in output
        if result.returncode == 0:
            print(name + ': survived (unexpected)')
            print(output)
            sys.exit(1)
        if not expected_failure:
            print(name + ': NOT_RUN unexpected execution error')
            sys.exit(2)
        print(name + ': killed')
        killed += 1
    print('unselected_control: not_run (intentionally not executed)')
    print('killed=' + str(killed) + '; required_not_run=' + str(skipped))
    sys.exit(2 if skipped else 0)

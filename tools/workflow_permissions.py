#!/usr/bin/env python3
"""Default Event and temporary-workspace permissions installed by kit.

Usage: workflow_permissions.py {apply,check} (--project DIR | --user)
Project scope only changes .claude/settings.local.json. User scope honors
CLAUDE_CONFIG_DIR. Existing ask/deny rules win and are never removed.
"""
import argparse
import fnmatch
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

EVENT_ALLOW = tuple('mcp__drsg-events__' + name for name in (
    'event_list', 'event_post', 'event_reply', 'event_done', 'event_take',
    'commit_auth_post', 'commit_auth_apply'))
TMP_ALLOW = 'Edit(//tmp/**)'
TMP_MARK = '(drsg-harness-kit temporary-workspace) '
TMP_POLICY = (
    TMP_MARK + 'For a user-requested task, creating, reading and '
    'editing this task\'s temporary scripts, intermediate files, logs and results under /tmp '
    'is authorized without a separate confirmation of the output path. For sources the user '
    'has already authorized reading and analyzing, saving non-sensitive aggregate statistics '
    'and necessary locator metadata under /tmp is also authorized; do not include source '
    'bodies, tool arguments, credentials or personal data values. This does not authorize '
    'reading otherwise unauthorized sensitive sources, copying raw sensitive content, '
    'overwriting or deleting other tasks\' files, or following symlinks outside /tmp. '
    'A script located in /tmp is not automatically trusted to execute: its source and all '
    'effects, including network access, production operations, deployment, publishing and '
    'writes outside /tmp, remain subject to the existing rules. No blanket shell or '
    'interpreter permission is granted.')


def validate(data):
    if not isinstance(data, dict):
        raise ValueError('invalid settings')
    for block, fields in [('permissions', ('allow', 'ask', 'deny')),
                          ('autoMode', ('allow', 'soft_deny', 'hard_deny', 'environment'))]:
        value = data.get(block, {})
        if not isinstance(value, dict):
            raise ValueError('invalid settings')
        for field in fields:
            items = value.get(field, [])
            if not isinstance(items, list) or any(not isinstance(x, str) for x in items):
                raise ValueError('invalid settings')


def load(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('invalid settings')
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        data = {}
    validate(data)
    return data


def conflicts(rule, required):
    if required.startswith('mcp__'):
        return rule == 'mcp__drsg-events' or fnmatch.fnmatchcase(required, rule)
    if rule in ('*', 'Edit', 'Write', 'NotebookEdit'):
        return True
    if rule.startswith('Edit(') and rule.endswith(')'):
        pattern = rule[5:-1]
        return (fnmatch.fnmatchcase('//tmp/probe', pattern) or
                pattern.startswith('//tmp/') or pattern == '//tmp')
    return False


def issues(data, user=False):
    validate(data)
    perms = data.get('permissions', {})
    required = (TMP_ALLOW,) if user else EVENT_ALLOW
    allow = perms.get('allow', [])
    result = []
    for rule in required:
        count = allow.count(rule)
        if not count:
            result.append('missing: ' + rule)
        elif count > 1:
            result.append('duplicate: ' + rule)
        for scope in ('ask', 'deny'):
            if any(conflicts(item, rule) for item in perms.get(scope, [])):
                # Never print arbitrary user rules: they may contain credentials.
                result.append('conflict: ' + scope + ' ' + rule)
    if user:
        marked = [x for x in data.get('autoMode', {}).get('allow', []) if x.startswith(TMP_MARK)]
        if marked != [TMP_POLICY]:
            result.append('missing or stale: temporary-workspace autoMode policy')
    return result


def check(path, user=False):
    try:
        return issues(load(path), user)
    except (OSError, ValueError, UnicodeError):
        return ['workflow permissions: unreadable or malformed configuration']


def apply(path, user=False):
    path = Path(path)
    data = load(path)
    before = json.dumps(data, sort_keys=True)
    perms = data.setdefault('permissions', {})
    allow = perms.setdefault('allow', [])
    required = (TMP_ALLOW,) if user else EVENT_ALLOW
    merged = []
    for rule in allow:
        if rule not in required or rule not in merged:
            merged.append(rule)
    merged.extend(rule for rule in required if rule not in merged)
    perms['allow'] = merged
    if user:
        auto = data.setdefault('autoMode', {})
        allow = auto.get('allow', ['$defaults'])
        auto['allow'] = [x for x in allow if not x.startswith(TMP_MARK)] + [TMP_POLICY]
    if json.dumps(data, sort_keys=True) != before:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as stream:
                os.fchmod(stream.fileno(), mode)
                json.dump(data, stream, ensure_ascii=False, indent=2)
                stream.write('\n')
            os.replace(name, path)
        finally:
            if os.path.exists(name):
                os.unlink(name)
    return issues(data, user)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('apply', 'check'))
    scope = parser.add_mutually_exclusive_group(required=True)
    scope.add_argument('--project', type=Path)
    scope.add_argument('--user', action='store_true')
    args = parser.parse_args()
    if args.project is not None:
        if not args.project.is_dir():
            parser.error('--project must be an existing directory')
        path = args.project / '.claude/settings.local.json'
    else:
        path = Path(os.environ.get('CLAUDE_CONFIG_DIR') or Path.home() / '.claude') / 'settings.json'
    try:
        result = apply(path, args.user) if args.action == 'apply' else issues(load(path), args.user)
    except (OSError, ValueError, UnicodeError):
        print('workflow permissions: invalid settings', file=sys.stderr)
        return 2
    for message in result:
        print(message)
    if not result:
        print('workflow permissions: ok')
    return 1 if result else 0


if __name__ == '__main__':
    sys.exit(main())

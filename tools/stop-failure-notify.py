#!/usr/bin/env python3
"""StopFailure hook: tell whoever is at the terminal that this session stopped.

A turn that ends in an API error (model unavailable, rate limit, auth) leaves
the session idle with nothing to wake it: StopFailure hooks cannot wake the
model, and Claude Code ignores their output except `terminalSequence`. So this
prints one terminalSequence carrying a window title (OSC 2), a desktop
notification (OSC 9 and OSC 777, for whichever the terminal speaks) and a bell.
Fail-open: any error prints nothing.
"""
import json
import os
import re
import sys


def clean(text, limit):
    """Printable text only. Claude Code drops the whole field if anything
    outside its allowlist of sequences gets in, and ';' would split OSC 777."""
    text = re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(text or ""))
    return re.sub(r"\s+", " ", text.replace(";", ",")).strip()[:limit]


def main():
    if os.environ.get("DRSG_STOP_FAILURE_NOTIFY_DISABLED") == "1":
        return
    try:
        hook = json.load(sys.stdin)
    except ValueError:
        hook = {}
    if not isinstance(hook, dict):
        hook = {}
    root = hook.get("cwd") or os.getcwd()
    project = clean(os.path.basename(os.path.realpath(root)), 40)
    error = clean(hook.get("error") or "unknown", 40)
    detail = clean(hook.get("error_details") or hook.get("last_assistant_message"), 120)
    title = clean("Claude stopped: %s (%s)" % (project, error), 100)
    body = detail or "turn ended on an API error; nothing will wake this session"
    seq = ("\x1b]2;%s\x07" % title
           + "\x1b]9;%s: %s\x07" % (title, body)
           + "\x1b]777;notify;%s;%s\x07" % (title, body)
           + "\x07")
    print(json.dumps({"terminalSequence": seq}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass

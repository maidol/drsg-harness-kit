#!/usr/bin/env python3
"""Mask secret-shaped substrings before text is stored or sent elsewhere.

Used at the three places where conversation or command text leaves the
session: l3_digest (before digest.run sends the transcript tail to an LLM
provider), session_end (commands_run on the Session node) and event.py
(which refuses a to-do whose summary or ref carries one). The path & token
gate (check-no-machine-paths.py) reads RULES too, so the two cannot drift.

Shapes, not meaning: a secret that looks like none of these passes through.
This narrows a leak; it does not close it. Placeholders (`<token>`,
`$TOKEN`, `${KEY}`, `*`) are never masked, so a sentence that already
followed the rule is left exactly as written.
"""
import re

MASK = "<hidden>"

# (kind, compiled pattern). When a pattern has a group named "v", only that
# group is masked and the rest (the variable name, `Bearer `, the user name of
# a URL) stays readable; otherwise the whole match is.
RULES = [
    ("private-key", re.compile(
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----(?:.*?-----END [A-Z ]*PRIVATE KEY-----|.*\Z)", re.S)),
    ("anthropic-key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{16,}")),
    ("api-key", re.compile(r"\bsk-[A-Za-z0-9_-]{16,}")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("bearer", re.compile(r"(?i)\bbearer\s+(?P<v>[A-Za-z0-9._~+/=-]{16,})")),
    ("url-password", re.compile(r"(?i)\b[a-z][a-z0-9+.-]*://[^/\s:@]+:(?P<v>[^@\s/<$*{]+)(?=@)")),
    # A value must mix letters and digits: that is what keeps code such as
    # `token = os.environ.get(...)` and examples such as `DRSG_TOKEN=change-me`
    # out, at the price of missing an all-letter password.
    ("assignment", re.compile(
        r"(?i)\b[A-Za-z0-9_]*(?:password|passwd|secret|token|api[_-]?key)\s*[=:]\s*[\"']?"
        r"(?P<v>(?![<$*{%])(?=[^\s\"',;]*\d)(?=[^\s\"',;]*[A-Za-z])[^\s\"',;]{6,})")),
]


def _mask(match):
    if "v" in match.re.groupindex and match.group("v") is not None:
        start, end = match.span("v")
        whole = match.group(0)
        offset = match.start()
        return whole[:start - offset] + MASK + whole[end - offset:]
    return MASK


def redact(text):
    """Return (masked text, sorted list of the kinds that were masked)."""
    if not text:
        return text, []
    kinds = set()
    for kind, pattern in RULES:
        text, n = pattern.subn(_mask, text)
        if n:
            kinds.add(kind)
    return text, sorted(kinds)

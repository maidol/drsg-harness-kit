#!/usr/bin/env python3
"""Print validated model IDs from the configured Claude gateway, if available."""
import ipaddress
import json
import os
import re
import signal
import sys
import time
import urllib.parse
import urllib.request

_DEADLINE_SECONDS = 2.0
_MODEL_ID = re.compile(r"^[A-Za-z0-9._:/@\[\]-]{1,128}$")


def _merged_env():
    values = dict(os.environ)
    cwd = os.getcwd()
    paths = (
        os.path.expanduser("~/.claude/settings.json"),
        os.path.join(cwd, ".claude", "settings.json"),
        os.path.join(cwd, ".claude", "settings.local.json"),
    )
    for path in paths:
        try:
            with open(path, encoding="utf-8") as settings_file:
                settings = json.load(settings_file)
        except (OSError, ValueError, UnicodeError):
            continue
        env = settings.get("env") if isinstance(settings, dict) else None
        if isinstance(env, dict):
            values.update(
                (key, value)
                for key, value in env.items()
                if isinstance(key, str) and isinstance(value, str)
            )
    return values


def _models_url(base_url):
    base_url = base_url.rstrip("/")
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return None
    suffix = "/models" if parsed.path.endswith("/v1") else "/v1/models"
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path + suffix, parsed.query, "")
    ), parsed.hostname


def _opener_for(hostname):
    if hostname.lower() == "localhost":
        return urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        if ipaddress.ip_address(hostname).is_loopback:
            return urllib.request.build_opener(urllib.request.ProxyHandler({}))
    except ValueError:
        pass
    return urllib.request.build_opener()


def _read_models():
    env = _merged_env()
    base_url = env.get("ANTHROPIC_BASE_URL", "")
    if not base_url:
        return None
    endpoint = _models_url(base_url)
    if endpoint is None:
        return None
    url, hostname = endpoint
    headers = {"anthropic-version": "2023-06-01"}
    api_key = env.get("ANTHROPIC_API_KEY")
    auth_token = env.get("ANTHROPIC_AUTH_TOKEN")
    if api_key:
        headers["x-api-key"] = api_key
    elif auth_token:
        headers["Authorization"] = "Bearer " + auth_token
    request = urllib.request.Request(url, headers=headers)
    remaining = max(0.1, _DEADLINE_SECONDS - (time.monotonic() - _started_at))
    with _opener_for(hostname).open(request, timeout=remaining) as response:
        if not 200 <= response.status < 300:
            return None
        payload = json.loads(response.read())
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list):
        return None
    result = []
    seen = set()
    for item in data:
        model_id = item.get("id") if isinstance(item, dict) else None
        if (
            isinstance(model_id, str)
            and _MODEL_ID.fullmatch(model_id)
            and model_id not in seen
        ):
            seen.add(model_id)
            result.append(model_id)
    return result or None


def main():
    global _started_at
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.setitimer(signal.ITIMER_REAL, _DEADLINE_SECONDS)
    _started_at = time.monotonic()
    try:
        models = _read_models()
    except Exception:
        models = None
    if not models:
        signal.setitimer(signal.ITIMER_REAL, 0)
        return 1
    output = "".join(model_id + "\n" for model_id in models)
    signal.setitimer(signal.ITIMER_REAL, 0)
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

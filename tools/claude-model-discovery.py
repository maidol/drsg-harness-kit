#!/usr/bin/env python3
"""Print validated model IDs and labels from the configured Claude gateway."""
import ipaddress
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import urllib.request

_DEADLINE_SECONDS = 2.0
_HELPER_SECONDS = 1.0
_HELPER_BYTES = 4096
_MODEL_ID = re.compile(r"^[A-Za-z0-9._:/@\[\]-]{1,256}$")
_CONSENT = (
    "Model discovery: apiKeyHelper ({source}) runs a shell command with your user permissions.\n"
    "Review that settings file first; its command and output are hidden here.\n"
    "Run it once for this model query? [y/N]\n"
)


def _claude_config_dir():
    """Claude Code's config directory: $CLAUDE_CONFIG_DIR, else ~/.claude."""
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")


def _configuration():
    values = dict(os.environ)
    helper, source = None, None
    cwd = os.getcwd()
    paths = (
        (os.path.join(_claude_config_dir(), "settings.json"), "user"),
        (os.path.join(cwd, ".claude", "settings.json"), "project"),
        (os.path.join(cwd, ".claude", "settings.local.json"), "project-local"),
    )
    for path, scope in paths:
        try:
            with open(path, encoding="utf-8") as settings_file:
                settings = json.load(settings_file)
        except (OSError, ValueError, UnicodeError):
            continue
        if not isinstance(settings, dict):
            continue
        if "apiKeyHelper" in settings:
            helper, source = settings["apiKeyHelper"], scope
        env = settings.get("env")
        if isinstance(env, dict):
            values.update(
                (key, value)
                for key, value in env.items()
                if isinstance(key, str) and isinstance(value, str)
            )
    return values, helper, source


def _merged_env():
    return _configuration()[0]


def _models_url(base_url):
    base_url = base_url.rstrip("/")
    parsed = urllib.parse.urlsplit(base_url)
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        return None
    suffix = "/models" if parsed.path.endswith("/v1") else "/v1/models"
    return urllib.parse.urlunsplit(
        (parsed.scheme, parsed.netloc, parsed.path + suffix, parsed.query, "")
    ), parsed.hostname


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _opener_for(hostname):
    handlers = [_NoRedirect()]
    loopback = hostname.lower() == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        pass
    if loopback:
        handlers.append(urllib.request.ProxyHandler({}))
    return urllib.request.build_opener(*handlers)


def _confirm_helper(source):
    if not sys.stdin.isatty() and os.environ.get("CLAUDE_PICK_FORCE_TTY") != "1":
        return False
    sys.stderr.write(_CONSENT.format(source=source))
    sys.stderr.flush()
    answer = bytearray()
    while True:
        char = os.read(0, 1)
        if char == b"":
            return False
        if char == b"\n":
            return bytes(answer).lower() == b"y"
        if len(answer) <= 16:
            answer.extend(char)


def _helper_key(command, env):
    deadline = time.monotonic() + _HELPER_SECONDS
    process = subprocess.Popen(
        command, shell=True, executable="/bin/sh", env=env,
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, start_new_session=True,
    )
    try:
        output = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    return None
                chunk = os.read(process.stdout.fileno(), 1024)
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > _HELPER_BYTES:
                    return None
        remaining = deadline - time.monotonic()
        if remaining <= 0 or process.wait(timeout=remaining) != 0:
            return None
        key = bytes(output)
        if key.endswith(b"\n"):
            key = key[:-1].removesuffix(b"\r")
        if not key or any(byte < 33 or byte > 126 for byte in key):
            return None
        return key.decode("ascii")
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.stdout.close()
        process.wait(timeout=0.2)


def _valid_input_capacity(value):
    if type(value) is int and 1 <= value <= 2_147_483_647:
        return value
    return None


def _safe_display_name(value, response_id):
    if not isinstance(value, str):
        return response_id
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return response_id
    if any(unicodedata.category(char) in ("Cc", "Cf") for char in value):
        return response_id
    value = unicodedata.normalize("NFC", value).strip()
    return value or response_id


def _truncate_utf8(value, byte_limit):
    result = []
    used = 0
    for char in value:
        size = len(char.encode("utf-8"))
        if used + size > byte_limit:
            break
        result.append(char)
        used += size
    return "".join(result)


def _normalize_models(rows):
    by_response_id = {}
    for row in rows:
        response_id = row.get("id") if isinstance(row, dict) else None
        if not isinstance(response_id, str) or not _MODEL_ID.fullmatch(response_id):
            continue
        capacity = _valid_input_capacity(row.get("max_input_tokens"))
        name = _safe_display_name(row.get("display_name"), response_id)
        by_response_id.setdefault(response_id, []).append((capacity, name))

    by_route_id = {}
    for response_id, sources in by_response_id.items():
        capacities = {capacity for capacity, _ in sources if capacity is not None}
        capacity = next(iter(capacities)) if len(capacities) == 1 else None
        name = min(name for _, name in sources)
        route_id = response_id
        if (
            capacity is not None
            and capacity >= 1_000_000
            and not response_id.endswith("[1m]")
        ):
            route_id += "[1m]"
        if not _MODEL_ID.fullmatch(route_id):
            continue
        by_route_id.setdefault(route_id, []).append((capacity, name))

    rows_by_route = []
    for route_id, sources in by_route_id.items():
        capacities = [capacity for capacity, _ in sources]
        known = capacities[0] if capacities and capacities[0] is not None else None
        if any(capacity != known for capacity in capacities):
            known = None
        name = min(name for _, name in sources)
        capacity_suffix = (
            f" [输入上限 {known:,}]"
            if known is not None
            else " [输入上限未知]"
        )
        rows_by_route.append((route_id, _truncate_utf8(name, 111), capacity_suffix))

    base_labels = {}
    for route_id, name, capacity_suffix in rows_by_route:
        label = name + capacity_suffix
        base_labels.setdefault(label, []).append((route_id, name, capacity_suffix))

    labels = {}
    for group in base_labels.values():
        ordered = sorted(group, key=lambda row: row[0])
        if len(ordered) == 1:
            route_id, name, capacity_suffix = ordered[0]
            labels[route_id] = name + capacity_suffix
            continue
        for index, (route_id, name, capacity_suffix) in enumerate(ordered, 1):
            disambiguator = f" (#{index})"
            name_budget = min(
                111,
                160 - len(capacity_suffix.encode("utf-8")) - len(disambiguator.encode("utf-8")),
            )
            labels[route_id] = _truncate_utf8(name, name_budget) + capacity_suffix + disambiguator
    return [(route_id, labels[route_id]) for route_id, _, _ in rows_by_route]


def _read_models(env, base_url, helper_key=None):
    endpoint = _models_url(base_url)
    if endpoint is None:
        return None
    url, hostname = endpoint
    headers = {"anthropic-version": "2023-06-01", "User-Agent": "claude-model-discovery/1"}
    api_key = env.get("ANTHROPIC_API_KEY")
    auth_token = env.get("ANTHROPIC_AUTH_TOKEN")
    if api_key:
        headers["x-api-key"] = api_key
    elif auth_token:
        headers["Authorization"] = "Bearer " + auth_token
    elif helper_key:
        headers["x-api-key"] = helper_key
        headers["Authorization"] = "Bearer " + helper_key
    request = urllib.request.Request(url, headers=headers)
    remaining = _DEADLINE_SECONDS - (time.monotonic() - _started_at)
    if remaining <= 0:
        return None
    with _opener_for(hostname).open(request, timeout=remaining) as response:
        if not 200 <= response.status < 300:
            return None
        payload = json.loads(response.read())
    data = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(data, list):
        return None
    result = _normalize_models(data)
    return result or None


def _timeout(signum, frame):
    raise TimeoutError("model discovery deadline")


def main():
    global _started_at
    models = None
    try:
        env, helper, source = _configuration()
        base_url = env.get("ANTHROPIC_BASE_URL", "")
        if not base_url or _models_url(base_url) is None:
            return 1
        need_helper = not env.get("ANTHROPIC_API_KEY") and not env.get("ANTHROPIC_AUTH_TOKEN")
        if need_helper and source is not None:
            if not isinstance(helper, str) or not helper.strip() or "\x00" in helper:
                return 1
            if not _confirm_helper(source):
                return 1
        _started_at = time.monotonic()
        signal.signal(signal.SIGALRM, _timeout)
        signal.setitimer(signal.ITIMER_REAL, _DEADLINE_SECONDS)
        key = _helper_key(helper, env) if need_helper and source is not None else None
        if need_helper and source is not None and key is None:
            return 1
        models = _read_models(env, base_url, key)
    except KeyboardInterrupt:
        return 130
    except Exception:
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
    if not models:
        return 1
    sys.stdout.write("".join(f"{model_id}\t{label}\n" for model_id, label in models))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

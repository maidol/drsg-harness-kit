#!/usr/bin/env python3
"""Read the Project paths registered in a drsg memory plane."""

import argparse
import json
import os
import sys
import urllib.request


# urllib sends even 127.0.0.1 through http_proxy unless no_proxy names it: the
# proxy would receive the daemon token. Loopback goes direct, anything else
# keeps the user's proxy.
_DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _urlopen(req, timeout):
    """urlopen that never proxies a loopback address."""
    host = urllib.parse.urlsplit(req.full_url).hostname or ""
    if host in ("localhost", "::1") or host.startswith("127."):
        return _DIRECT.open(req, timeout=timeout)
    return urllib.request.urlopen(req, timeout=timeout)


def known_projects(daemon_env, api, plane):
    """Return unique Project paths in the daemon's result order."""
    token = ""
    if os.path.exists(daemon_env):
        with open(daemon_env, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("DRSG_TOKEN="):
                    token = line.split("=", 1)[1].strip().strip('"').strip("'")
                    break

    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "plane.cypher",
                       "params": {"plane": plane,
                                  "query": "MATCH (p:Project) RETURN p"}}).encode()
    req = urllib.request.Request(
        api, data=body,
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + token})
    with _urlopen(req, 5) as response:
        out = json.load(response)
    if "error" in out:
        # Do not echo daemon error payloads: they may contain request details.
        raise RuntimeError("daemon returned an error listing projects")

    paths = []
    for node in out["result"].get("nodes", []):
        path = (node.get("properties") or {}).get("path")
        path = path.get("$value") if isinstance(path, dict) else path
        if path and path not in paths:
            paths.append(path)
    return paths


def main(argv=None):
    memory_dir = os.environ.get("DRSG_MEM_DIR") or os.path.join(
        os.path.expanduser("~"), ".drsg-memory")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", default=os.path.join(memory_dir, "env"),
                        help="daemon environment file (default: DRSG_MEM_DIR/env)")
    parser.add_argument("--api", default=os.environ.get(
        "DRSG_API", "http://127.0.0.1:7700/rpc"), help="daemon RPC URL")
    parser.add_argument("--plane", default=os.environ.get("DRSG_PLANE", "memory"),
                        help="memory plane name")
    parser.add_argument("--nul", action="store_true",
                        help="write paths separated by NUL bytes")
    args = parser.parse_args(argv)
    try:
        paths = known_projects(args.env, args.api, args.plane)
    except Exception as exc:
        print("cannot reach the daemon to list projects (%s)" % type(exc).__name__,
              file=sys.stderr)
        return 1

    if args.nul:
        sys.stdout.buffer.write("\0".join(paths).encode() + (b"\0" if paths else b""))
    else:
        for path in paths:
            print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

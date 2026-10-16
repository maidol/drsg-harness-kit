#!/usr/bin/env python3
"""Shared JSON-RPC transport for the memory tools."""
import ipaddress
import json
import urllib.parse
import urllib.request

_DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _urlopen(req, timeout):
    host = urllib.parse.urlsplit(req.full_url).hostname or ""
    loopback = host.lower() == "localhost"
    try:
        loopback = loopback or ipaddress.ip_address(host).is_loopback
    except ValueError:
        pass
    if loopback:
        return _DIRECT.open(req, timeout=timeout)
    return urllib.request.urlopen(req, timeout=timeout)


def rpc(api, token, method, params, timeout=5):
    body = json.dumps({"jsonrpc": "2.0", "id": 1,
                       "method": method, "params": params}).encode()
    req = urllib.request.Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    with _urlopen(req, timeout) as response:
        return json.load(response)

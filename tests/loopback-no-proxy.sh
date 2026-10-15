#!/usr/bin/env bash
# A loopback daemon is reached directly even when http_proxy is set and
# no_proxy does not name it: urllib otherwise sends 127.0.0.1 to the proxy.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
env -u no_proxy -u NO_PROXY http_proxy=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
python3 - "$REPO" <<'PY'
import http.server, importlib.util, json, os, sys, threading

repo = sys.argv[1]
tools = os.path.join(repo, "tools")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"ok": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
api = "http://127.0.0.1:%d/rpc" % server.server_port


def load(name):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), os.path.join(tools, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ran = ok = 0


def check(name, call):
    global ran, ok
    ran += 1
    try:
        got = call()
        good = got == {"ok": 1} or (isinstance(got, tuple) and got[0] is not None)
    except Exception as e:
        good, got = False, repr(e)[:120]
    ok += good
    print("%s %s%s" % ("ok  " if good else "FAIL", name, "" if good else ": %s" % got))


sys.argv = [os.path.join(tools, "x.py")]
ev = load("event")
ev.API = api
check("event.rpc reaches 127.0.0.1 past http_proxy", lambda: ev.rpc("m", {}, "t"))
mig = load("migrate")
check("migrate.rpc reaches 127.0.0.1 past http_proxy", lambda: mig.rpc(api, "t", "m", {}))
bf = load("backfill_text")
bf.API = api
check("backfill_text.rpc reaches 127.0.0.1 past http_proxy", lambda: bf.rpc("m", {}, "t"))
ae = load("analyze_events")
ae.API = api
check("analyze_events.rpc reaches 127.0.0.1 past http_proxy", lambda: ae.rpc("m", {}, "t"))
ar = load("analyze_recall")
check("analyze_recall.rpc reaches 127.0.0.1 past http_proxy", lambda: ar.rpc(api, "m", {}, "t"))
router = load("codegraph-router")
check("codegraph-router._post reaches 127.0.0.1 past http_proxy",
      lambda: router._post(api, "Bearer t", {"jsonrpc": "2.0", "id": 1}, None, 5))

# The other half: a non-loopback host still goes to the proxy (port 9 refuses;
# sent direct, the .invalid name would fail to resolve instead).
import urllib.request
ran += 1
try:
    ev._urlopen(urllib.request.Request("http://daemon.example.invalid/rpc", data=b"{}"), 5)
    why = "no error"
except Exception as e:
    why = repr(e)
proxied = "Connection refused" in why
ok += proxied
print("%s event._urlopen still proxies a non-loopback host%s" % (
    "ok  " if proxied else "FAIL", "" if proxied else ": " + why[:120]))

server.shutdown()
print("PASS %d/%d" % (ok, ran))
sys.exit(0 if ok == ran else 1)
PY

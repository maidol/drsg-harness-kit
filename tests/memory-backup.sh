#!/usr/bin/env bash
# S-1 contract tests use disposable libraries and test-only credentials.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
[ -x "$BIN" ] || BIN="$(command -v drsg || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "SKIP memory-backup: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "SKIP memory-backup: missing python3"; exit 0; }
T="$(mktemp -d)"
chmod 700 "$T"
mkdir -m 700 "$T/tmp" "$T/source-root"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
TEST_AUTH="$(python3 -c 'import secrets; print("s1-test-" + secrets.token_hex(16))')"
API="http://127.0.0.1:$PORT/rpc"
DB="$T/source-root/source.drsg"
SCRIPT="${MEMORY_BACKUP_SCRIPT:-$REPO/tools/memory-backup.py}"
printf 'DRSG_TOKEN=%s\nDRSG_API=%s\n' "$TEST_AUTH" "$API" > "$T/source-root/env"
chmod 600 "$T/source-root/env"
cd "$T"
DRSG_TOKEN="$TEST_AUTH" "$BIN" --db "$DB" serve --addr "127.0.0.1:$PORT" >"$T/source-daemon.log" 2>&1 &
DAEMON=$!
cleanup() {
  local rc=$?
  set +e
  kill "$DAEMON" 2>/dev/null
  wait "$DAEMON" 2>/dev/null
  python3 - "$T" <<'PY'
import os, pathlib, signal, sys, time
root = sys.argv[1]
def matching():
    found=[]
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit(): continue
        try: args=(entry/"cmdline").read_bytes().split(bytes([0]))
        except OSError: continue
        if b"--db" in args:
            path=args[args.index(b"--db")+1].decode(errors="replace")
            if path.startswith(root+"/"):
                found.append(int(entry.name))
    return found
for pid in matching():
    try: os.kill(pid,signal.SIGTERM)
    except ProcessLookupError: pass
for _ in range(20):
    if not matching(): break
    time.sleep(.05)
for pid in matching():
    try: os.kill(pid,signal.SIGKILL)
    except ProcessLookupError: pass
PY
  if ps -eo pid,args | grep "[d]rsg --db $T/" >/dev/null 2>&1; then
    echo "FAIL memory-backup: temporary drsg process leaked under $T" >&2
    rc=1
  fi
  rm -rf "$T"
  exit "$rc"
}
trap cleanup EXIT
export S1_TEST_ROOT="$T" S1_TEST_BIN="$BIN" S1_TEST_SCRIPT="$SCRIPT"
export S1_TEST_API="$API" S1_TEST_TOKEN="$TEST_AUTH" S1_TEST_DB="$DB"
export DRSG_MEM_DIR="$T/source-root" DRSG_MEM_BIN="$BIN" TMPDIR="$T/tmp"
for _ in $(seq 1 100); do
  if python3 - <<'PY' >/dev/null 2>&1
import json, os, urllib.request
req = urllib.request.Request(os.environ["S1_TEST_API"],
    data=json.dumps({"jsonrpc":"2.0","id":1,"method":"db.stats","params":{}}).encode(),
    headers={"Content-Type":"application/json","Authorization":"Bearer "+os.environ["S1_TEST_TOKEN"]})
with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=1) as r:
    json.load(r)
PY
  then break; fi
  sleep 0.1
done
python3 - <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import time
import urllib.request

root = Path(os.environ["S1_TEST_ROOT"])
script = Path(os.environ["S1_TEST_SCRIPT"])
bin_path = os.environ["S1_TEST_BIN"]
api = os.environ["S1_TEST_API"]
source_token = os.environ["S1_TEST_TOKEN"]
source_db = Path(os.environ["S1_TEST_DB"])
only = os.environ.get("S1_ONLY_CASE", "")
passed = 0
ran = 0

def check(condition, name, detail=""):
    global passed, ran
    ran += 1
    if condition:
        passed += 1
        print("PASS " + name)
    else:
        print("FAIL " + name + (": " + detail if detail else ""))

def rpc(url, token, method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type":"application/json", "Authorization":"Bearer "+token})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=5) as response:
        result = json.load(response)
    if "error" in result:
        raise AssertionError("fixture RPC failed: " + str(result["error"].get("code")))
    return result["result"]

def daemon_left(db_path):
    return daemon_prefix_left(db_path)

def daemon_prefix_left(db_prefix):
    result = subprocess.run(["bash", "-c",
        'ps -eo pid,args | grep "[d]rsg --db ' + str(db_prefix) + '" >/dev/null'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return result.returncode == 0

def run_cli(args, memdir, proxy=False):
    env = os.environ.copy()
    env["DRSG_MEM_DIR"] = str(memdir)
    env["DRSG_MEM_BIN"] = bin_path
    if proxy:
        env["HTTP_PROXY"] = env["http_proxy"] = "http://127.0.0.1:9"
        env.pop("NO_PROXY", None)
        env.pop("no_proxy", None)
    proc = subprocess.Popen([sys.executable, str(script), *args], cwd=str(root), env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    alive = proc.poll() is None
    cmdline = Path("/proc") / str(proc.pid) / "cmdline"
    try:
        observed = cmdline.read_bytes().replace(b"\0", b" ") if cmdline.exists() else b""
    except OSError:
        observed = b""
    out, err = proc.communicate(timeout=90)
    return proc.returncode, out, err, (observed, alive)

def import_module():
    spec = importlib.util.spec_from_file_location("memory_backup_under_test", script)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def fixture():
    rpc(api, source_token, "plane.create", {"name":"memory", "properties":{"scope":"shared"}})
    rpc(api, source_token, "plane.create", {"name":"bench-test", "properties":{"fixture":True}})
    a = rpc(api, source_token, "node.create", {"plane":"memory", "key":"fact-alpha",
        "labels":["Fact"], "properties":{"text":"s1uniquephrase alpha", "score":7}})
    b = rpc(api, source_token, "node.create", {"plane":"memory", "labels":["Fact"],
        "properties":{"text":"s1uniquephrase beta", "score":8,
                      "embedding":{"$vector":[0.1,0.2,0.3]}}})
    c = rpc(api, source_token, "node.create", {"plane":"memory", "key":"isolated",
        "labels":["Session"], "properties":{"note":"isolated-node"}})
    rpc(api, source_token, "edge.create", {"plane":"memory", "src":a["id"], "dst":b["id"],
        "type":"MENTIONS", "properties":{"weight":2}})
    rpc(api, source_token, "edge.create", {"plane":"memory", "src":b["id"], "dst":b["id"],
        "type":"SELF", "properties":{"self":True}})
    rpc(api, source_token, "node.create", {"plane":"bench-test", "key":"bench-node",
        "labels":["Bench"], "properties":{"text":"bench-only"}})
    rpc(api, source_token, "index.ensure", {"plane":"memory", "label":"Fact",
        "property":"text", "kind":"keyword", "language":"english"})
    rpc(api, source_token, "index.ensure", {"plane":"memory", "label":"Fact",
        "property":"embedding", "kind":"vector", "metric":"cosine"})
    return {"memory":(3,2), "bench-test":(1,0), "startup":(0,0)}, c["id"]

def backup_dirs(memdir):
    backup_root = memdir / "backups"
    if not backup_root.exists():
        return []
    import re
    pattern = re.compile(r"^backup-\d{8}T\d{12}Z-[0-9a-f]{8}$")
    return sorted(p for p in backup_root.iterdir()
                  if pattern.fullmatch(p.name) and not p.is_symlink() and p.is_dir())

def assert_no_token(paths):
    needle = source_token.encode()
    for path in paths:
        if path.is_file():
            if needle in path.read_bytes():
                return False
        elif path.is_dir():
            for child in path.rglob("*"):
                if child.is_file() and needle in child.read_bytes():
                    return False
    return True

def setup_restore_root():
    restore_root = root / "restore-root"
    restore_root.mkdir(mode=0o700, exist_ok=True)
    restore_token = "restore-env-" + secrets.token_hex(16)
    (restore_root / "env").write_text("DRSG_TOKEN="+restore_token+"\nDRSG_API="+api+"\n", encoding="utf-8")
    os.chmod(restore_root / "env", 0o600)
    backup_root = restore_root / "backups"
    backup_root.mkdir(mode=0o700)
    shutil.copytree(backup_dirs(root/"source-root")[-1], backup_root/backup_dirs(root/"source-root")[-1].name)
    return restore_root, restore_token


def case_main():
    expected, isolated_id = fixture()
    result = run_cli(["backup", "--keep", "7"], root / "source-root", proxy=True)
    dirs = backup_dirs(root / "source-root")
    check(result[0] == 0 and "backup created" in result[1], "online backup succeeds through proxy trap",
          "rc=%d stdout=%s stderr=%s" % result[:3])
    check(daemon_left(source_db), "source daemon remains running after backup")
    check(result[3][1] and source_token.encode() not in result[3][0] and
          source_token not in result[1]+result[2],
          "token absent from running backup argv and output")
    manifest = json.loads((dirs[-1] / "manifest.json").read_text(encoding="utf-8")) if dirs else {}
    counts = {p["name"]:(p["nodes"],p["edges"]) for p in manifest.get("planes", [])}
    check(counts == expected, "every plane including empty startup is backed up", str(counts))
    check(all((dirs[-1]/p["data_file"]).exists() for p in manifest.get("planes", [])),
          "manifest lists every plane data file")
    check(all(__import__("hashlib").sha256((dirs[-1]/p["data_file"]).read_bytes()).hexdigest()==p["sha256"]
              for p in manifest.get("planes", [])), "all data file hashes match manifest")
    modes = (dirs and dirs[-1].stat().st_mode & 0o777 == 0o700 and
             all((x.stat().st_mode & 0o777) == 0o600 for x in dirs[-1].iterdir() if x.is_file()))
    check(bool(modes), "backup directory/files use 0700/0600")
    check(bool(dirs) and assert_no_token([dirs[-1]]), "token absent from backup contents")

    restore_root, _restore_env_token = setup_restore_root()
    proc = subprocess.Popen([sys.executable, str(script), "restore", "--latest"], cwd=str(root),
        env={**os.environ, "DRSG_MEM_DIR":str(restore_root), "DRSG_MEM_BIN":bin_path},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = proc.communicate(timeout=120)
    check(proc.returncode == 0 and "restore verified and published" in out,
          "restore publishes a verified database directory", "rc=%d stdout=%s stderr=%s"%(proc.returncode,out,err))
    restored_db = restore_root / "memory.drsg"
    check(restored_db.is_dir() and not Path(str(restored_db)+".bm25").exists() and
          not Path(str(restored_db)+".hnsw").exists(), "restore publishes directory without stale sidecars")
    check(not daemon_prefix_left(restore_root/".memory-restore-"),
          "restore daemon is stopped before returning; no stage process remains")
    # Start the restored directory as a daemon directly, never through a subshell/cd chain.
    port = int(os.environ["S1_TEST_API"].rsplit(":",1)[1].split("/",1)[0])
    with __import__("socket").socket() as sock:
        sock.bind(("127.0.0.1",0)); restore_port=sock.getsockname()[1]
    restore_api = "http://127.0.0.1:%d/rpc" % restore_port
    check_token = "serve-test-" + secrets.token_hex(16)
    restored_log = root / "restored-daemon.log"
    daemon = subprocess.Popen([bin_path,"--db",str(restored_db),"serve","--addr","127.0.0.1:%d"%restore_port],
        cwd=str(root), env={**os.environ,"DRSG_TOKEN":check_token}, stdout=restored_log.open("wb"), stderr=subprocess.STDOUT)
    try:
        for _ in range(100):
            try:
                cards=rpc(restore_api,check_token,"plane.list",{})
                break
            except Exception:
                if daemon.poll() is not None: raise AssertionError("restored daemon exited")
                time.sleep(.1)
        actual={p["name"]:(p["nodes"],p["edges"]) for p in cards}
        check(actual==expected, "directory restore retains all plane counts", str(actual))
        hit=rpc(restore_api,check_token,"plane.hybrid",{"plane":"memory","q":"s1uniquephrase",
            "label":"Fact","keyword_prop":"text","k":5})
        check(bool(hit), "Fact.text BM25 index searches after restore")
        indexes=rpc(restore_api,check_token,"plane.indexes",{"plane":"memory"})
        check(any(i.get("property")=="text" for i in indexes.get("keyword",[])),
              "keyword index declaration survives restore")
        check(any(i.get("property")=="embedding" for i in indexes.get("vector",[])),
              "vector index declaration survives restore")
        node=rpc(restore_api,check_token,"node.get",{"plane":"memory","key":"isolated","lean":False})
        check(node is not None and node["properties"].get("note")=="isolated-node",
              "keyed isolated node and properties restore")
    finally:
        daemon.terminate()
        try: daemon.wait(timeout=10)
        except subprocess.TimeoutExpired: daemon.kill(); daemon.wait(timeout=10)
        check(not daemon_left(restored_db), "restored test daemon is stopped after verification")

    # The source DB path itself was a directory throughout the backup and remains open.
    check(source_db.is_dir() and daemon_left(source_db), "2.17 source library is a directory and stays online")
    # Test the isolated drill while source DB is open; production-path memory.drsg stays absent.
    check(not (root/"source-root"/"memory.drsg").exists(), "drill precondition keeps production target absent")
    dr=run_cli(["drill"], root/"source-root")
    check(dr[0]==0 and "drill passed" in dr[1] and not (root/"source-root"/"memory.drsg").exists(),
          "drill restores in disposable database without production target", "rc=%d stdout=%s stderr=%s"%dr[:3])
    check(not daemon_prefix_left(root/"tmp"/"drsg-memory-drill-"),
          "drill daemon is stopped and no process remains after cleanup")
    return True


def case_temp_daemon_boundary():
    module=import_module()
    source_root=root/"source-root"
    if not backup_dirs(source_root):
        fixture()
        rc,_,_,_=run_cli(["backup","--keep","7"],source_root)
        if rc!=0:
            check(False,"temporary-daemon fixture backup succeeds")
            return
    token,_=module.credentials(source_root)
    _,loaded=module.load_backup(backup_dirs(source_root)[-1],token)
    database=root/"temp-daemon-check.drsg"
    captured={}
    original=subprocess.Popen
    def observe(argv,*args,**kwargs):
        if len(argv)>3 and argv[1]=="--db" and "serve" in argv:
            captured["cwd"]=kwargs.get("cwd")
            child_env=kwargs.get("env",{})
            captured["token"]=child_env.get("DRSG_TOKEN","")
            captured["passed_mem_token"]="DRSG_MEM_TOKEN" in child_env
            captured["passed_config"]="DRSG_CONFIG" in child_env
        return original(argv,*args,**kwargs)
    prior_mem_token=os.environ.get("DRSG_MEM_TOKEN")
    prior_config=os.environ.get("DRSG_CONFIG")
    os.environ["DRSG_MEM_TOKEN"]=token
    os.environ["DRSG_CONFIG"]=str(root/"should-not-load.toml")
    try:
        module.subprocess.Popen=observe
        module.create_and_verify(database,loaded,module.binary_path(source_root))
    finally:
        module.subprocess.Popen=original
        if prior_mem_token is None: os.environ.pop("DRSG_MEM_TOKEN",None)
        else: os.environ["DRSG_MEM_TOKEN"]=prior_mem_token
        if prior_config is None: os.environ.pop("DRSG_CONFIG",None)
        else: os.environ["DRSG_CONFIG"]=prior_config
        if database.is_dir(): shutil.rmtree(database)
        for suffix in (".bm25",".hnsw"):
            sidecar=Path(str(database)+suffix)
            if sidecar.exists(): sidecar.unlink()
    cwd=captured.get("cwd","")
    local_token=captured.get("token","")
    check(cwd.startswith(str(root/"tmp"/"drsg-memory-daemon-")) and cwd!=str(script.parent.parent) and
          __import__("re").fullmatch(r"[0-9a-f]{32}",local_token) is not None and local_token!=token and
          not captured.get("passed_mem_token",True) and not captured.get("passed_config",True),
          "temporary daemon uses a private cwd, fresh token and no inherited config secret",
          "cwd=%s token_len=%d matches_source=%s inherited_mem=%s config=%s"%
          (cwd,len(local_token),local_token==token,captured.get("passed_mem_token"),captured.get("passed_config")))
    check(not daemon_prefix_left(database), "temporary daemon process is gone after populate")


def case_truncated():
    module=import_module()
    module_root=root/"source-root"
    original=module.rpc
    before = {p.name for p in backup_dirs(module_root)}
    def fake(api_value,token,method,params):
        result=original(api_value,token,method,params)
        if method=="graph.seed":
            result["truncated"]=True
        return result
    module.rpc=fake
    from contextlib import redirect_stderr, redirect_stdout
    from io import StringIO
    out,err=StringIO(),StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc=module.backup(type("Args",(),{"keep":7})())
    after = {p.name for p in backup_dirs(module_root)}
    check(rc!=0 and "plane 0 truncated" in err.getvalue().lower() and after == before,
          "truncated plane fails with reason and no new final directory", "rc=%s stderr=%s"%(rc,err.getvalue()))
    return True


def case_permissions():
    old=os.umask(0o022)
    try:
        result=run_cli(["backup","--keep","7"],root/"source-root")
    finally:
        os.umask(old)
    dirs=backup_dirs(root/"source-root")
    good=bool(dirs) and dirs[-1].stat().st_mode&0o777==0o700 and all(
        p.stat().st_mode&0o777==0o600 for p in dirs[-1].iterdir() if p.is_file())
    check(result[0]==0 and good,"permission case: backup directory 0700 and files 0600")
    return True


def case_retention_boundary():
    module=import_module()
    broot=root/"source-root"/"backups"
    broot.mkdir(mode=0o700,exist_ok=True)
    manual=broot/"backup-0-manual-keep"
    manual.mkdir(exist_ok=True)
    (manual/"marker").write_text("keep",encoding="utf-8")
    (manual/"manifest.json").write_text(json.dumps({"tool":"drsg-memory-backup","schema_version":1}),encoding="utf-8")
    legacy=broot/"manual.bak-2026"
    legacy.mkdir(exist_ok=True)
    outside=root/"outside-marker"
    outside.mkdir(exist_ok=True)
    (outside/"marker").write_text("keep",encoding="utf-8")
    link=broot/"backup-20200101T000000000000Z-deadbeef"
    try: link.symlink_to(outside,target_is_directory=True)
    except FileExistsError: pass
    created=[]
    for _ in range(3):
        rc,out,err,_=run_cli(["backup","--keep","2"],root/"source-root")
        if rc!=0: break
        current=backup_dirs(root/"source-root")
        created.append(current[-1].name)
        time.sleep(.002)
    dirs=backup_dirs(root/"source-root")
    survivors={path.name for path in dirs}
    check(rc==0 and len(created)==3 and survivors==set(created[-2:]) and created[0] not in survivors and
          manual.is_dir() and (manual/"marker").read_text()=="keep" and
          legacy.is_dir() and outside.is_dir() and (outside/"marker").read_text()=="keep" and link.is_symlink(),
          "retention only removes strict-name ordinary backup directories",
          "rc=%d backups=%s stderr=%s"%(rc,[p.name for p in dirs],err))
    return True


def case_write_failure():
    module=import_module()
    before={p.name for p in backup_dirs(root/"source-root")}
    original=module.write_data_file
    module.write_data_file=lambda *args,**kwargs: (_ for _ in ()).throw(OSError("injected write failure"))
    from contextlib import redirect_stderr, redirect_stdout
    from io import StringIO
    out,err=StringIO(),StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc=module.backup(type("Args",(),{"keep":7})())
    after={p.name for p in backup_dirs(root/"source-root")}
    check(rc!=0 and "write failed" in err.getvalue().lower() and after==before,
          "write failure is nonzero and publishes no final directory", "rc=%s stderr=%s"%(rc,err.getvalue()))


def case_rpc_failure():
    module=import_module()
    before={p.name for p in backup_dirs(root/"source-root")}
    original=module.rpc
    def fake(api_value,token,method,params):
        if method=="node.get":
            raise module.BackupError("rpc node.get failed")
        return original(api_value,token,method,params)
    module.rpc=fake
    from contextlib import redirect_stderr, redirect_stdout
    from io import StringIO
    out,err=StringIO(),StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc=module.backup(type("Args",(),{"keep":7})())
    after={p.name for p in backup_dirs(root/"source-root")}
    check(rc!=0 and "rpc node.get failed" in err.getvalue() and after==before,
          "RPC failure names the method and publishes no directory", "rc=%s stderr=%s"%(rc,err.getvalue()))


def case_count_mismatch():
    module=import_module()
    before={p.name for p in backup_dirs(root/"source-root")}
    original=module.rpc
    def fake(api_value,token,method,params):
        result=original(api_value,token,method,params)
        if method=="graph.seed":
            result["total"]=int(result["total"])+1
        return result
    module.rpc=fake
    from contextlib import redirect_stderr, redirect_stdout
    from io import StringIO
    out,err=StringIO(),StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc=module.backup(type("Args",(),{"keep":7})())
    after={p.name for p in backup_dirs(root/"source-root")}
    check(rc!=0 and "node count mismatch" in err.getvalue().lower() and after==before,
          "count mismatch has a fixed reason and no final directory", "rc=%s stderr=%s"%(rc,err.getvalue()))


def case_env_read_failure():
    missing=root/"missing-env-root"
    missing.mkdir(mode=0o700,exist_ok=True)
    rc,out,err,_=run_cli(["backup"],missing)
    check(rc!=0 and "env read failed" in err.lower() and not backup_dirs(missing),
          "missing env file reports a fixed error and no final directory")


def case_changed_once():
    module=import_module()
    original=module.rpc
    stats=[0]
    def fake(api_value,token,method,params):
        result=original(api_value,token,method,params)
        if method=="db.stats":
            stats[0]+=1
            if stats[0]==2:
                result={**result,"commit_seq":int(result["commit_seq"])+1}
        return result
    module.rpc=fake
    from contextlib import redirect_stderr, redirect_stdout
    from io import StringIO
    out,err=StringIO(),StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc=module.backup(type("Args",(),{"keep":7})())
    check(rc==0 and stats[0]>=4 and "backup created" in out.getvalue(),
          "one commit_seq conflict retries and then succeeds", "rc=%s calls=%s stderr=%s"%(rc,stats[0],err.getvalue()))


def case_changed_always():
    module=import_module()
    original=module.rpc
    stats=[0]
    before={p.name for p in backup_dirs(root/"source-root")}
    def fake(api_value,token,method,params):
        result=original(api_value,token,method,params)
        if method=="db.stats":
            stats[0]+=1
            if stats[0]%2==0:
                result={**result,"commit_seq":int(result["commit_seq"])+1}
        return result
    module.rpc=fake
    from contextlib import redirect_stderr, redirect_stdout
    from io import StringIO
    out,err=StringIO(),StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        rc=module.backup(type("Args",(),{"keep":7})())
    after={p.name for p in backup_dirs(root/"source-root")}
    check(rc!=0 and "library changed during export (3 attempts)" in err.getvalue().lower() and
          stats[0]==6 and after==before,
          "three commit_seq conflicts fail with fixed reason and no publication",
          "rc=%s calls=%s stderr=%s"%(rc,stats[0],err.getvalue()))


def case_target_conflicts():
    blocked=root/"blocked-root"
    blocked.mkdir(mode=0o700,exist_ok=True)
    (blocked/"env").write_text("DRSG_TOKEN=blocked-test-token\nDRSG_API="+api+"\n",encoding="utf-8")
    os.chmod(blocked/"env",0o600)
    target=blocked/"memory.drsg"
    target.mkdir(exist_ok=True)
    marker=target/"keep"
    marker.write_text("keep",encoding="utf-8")
    sidecar=Path(str(target)+".hnsw")
    sidecar.write_text("keep-sidecar",encoding="utf-8")
    rc,out,err,_=run_cli(["restore","--latest"],blocked)
    check(rc!=0 and "target already exists" in err.lower() and marker.read_text()=="keep" and
          sidecar.read_text()=="keep-sidecar", "restore refuses existing target without changing it")
    check(not daemon_left(target), "refused restore starts no daemon")
    collision=root/"source-root"/"memory.drsg.bm25"
    collision.write_text("keep-sidecar",encoding="utf-8")
    rc,out,err,_=run_cli(["restore","--latest"],root/"source-root")
    check(rc!=0 and "target already exists" in err.lower() and collision.read_text()=="keep-sidecar" and
          not (root/"source-root"/"memory.drsg").exists(),
          "restore refuses stale target sidecar even when database directory is absent")
    collision.unlink()


def case_docs():
    readme=(script.parent/"README.md").read_text(encoding="utf-8")
    zh=(script.parent/"README.zh-CN.md").read_text(encoding="utf-8")
    okay=all(x in readme for x in ("memory-backup.py backup","memory-backup.py restore","memory-backup.py drill","memory-backup.py restore --from /path/to/backup-directory","serve.sh stop","snapshot \"$SNAPSHOT\"","serve.sh start"))
    okay=okay and all(x in zh for x in ("memory-backup.py backup","memory-backup.py restore","memory-backup.py drill","memory-backup.py restore --from /path/to/backup-directory","serve.sh stop","snapshot \"$SNAPSHOT\"","serve.sh start"))
    okay=okay and "crontab -e" not in readme.lower() and "23 3 * * *" not in readme
    okay=okay and "Before upgrading DrSG" in readme and "large migration" in readme
    okay=okay and "定时任务" in zh and "升级 DrSG 之前" in zh and "大批迁移" in zh
    check(okay,"both READMEs document commands, manual timing and cold-backup steps")
    return True

cases={"main":case_main,"temporary-daemon":case_temp_daemon_boundary,
       "truncated":case_truncated,"permissions":case_permissions,
       "retention-boundary":case_retention_boundary,"write-failure":case_write_failure,
       "rpc-failure":case_rpc_failure,"count-mismatch":case_count_mismatch,
       "env-read-failure":case_env_read_failure,"changed-once":case_changed_once,
       "changed-always":case_changed_always,"target-conflicts":case_target_conflicts,
       "docs":case_docs}
try:
    if not script.is_file():
        check(False,"backup CLI exists before integration tests",str(script))
    else:
        if only:
            cases[only]()
        else:
            case_main()
            case_temp_daemon_boundary()
            case_truncated()
            case_rpc_failure()
            case_count_mismatch()
            case_env_read_failure()
            case_write_failure()
            case_changed_once()
            case_changed_always()
            case_target_conflicts()
            case_permissions()
            case_retention_boundary()
            case_docs()
except Exception as exc:
    print("FAIL memory-backup test runner: " + type(exc).__name__)
    raise
finally:
    print("SUMMARY memory-backup: %d/%d"%(passed,ran))
if passed != ran:
    raise SystemExit(1)
print("PASS memory-backup integration")
PY

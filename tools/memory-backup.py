#!/usr/bin/env python3
"""Online backup, empty-library restore and isolated drill for DrSG memory."""
import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import ProxyHandler, Request, build_opener, urlopen

BACKUP_RE = re.compile(r"^backup-\d{8}T\d{12}Z-[0-9a-f]{8}$")
STAGE_RE = re.compile(r"^\.drsg-backup-staging-[0-9a-f]{16}$")
DATA_RE = re.compile(r"^plane-\d{3}\.jsonl$")
TIMEOUT = 30


class BackupError(Exception):
    """An operational failure with a safe, fixed diagnostic."""


def root_dir():
    return Path(os.path.expanduser(os.environ.get("DRSG_MEM_DIR", "~/.drsg-memory")))


def read_env(root, wanted):
    values = {}
    try:
        lines = (root / "env").read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        raise BackupError("env read failed") from None
    for line in lines:
        key, sep, value = line.partition("=")
        if sep and key in wanted:
            if key in values or not value or value != value.strip():
                raise BackupError("env read failed")
            values[key] = value
    return values


def credentials(root):
    values = read_env(root, {"DRSG_TOKEN", "DRSG_API"})
    token, api = values.get("DRSG_TOKEN"), values.get("DRSG_API")
    if not token or not api:
        raise BackupError("env read failed")
    parts = urlsplit(api)
    if (parts.scheme not in ("http", "https") or not parts.hostname or
            parts.username or parts.password or parts.path != "/rpc" or
            parts.query or parts.fragment):
        raise BackupError("env read failed")
    return token, api


def binary_path(root):
    configured = os.environ.get("DRSG_MEM_BIN")
    if not configured:
        configured = read_env(root, {"DRSG_MEM_BIN"}).get("DRSG_MEM_BIN")
    return configured or "drsg"


def rpc(api, token, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params}, ensure_ascii=False).encode("utf-8")
    request = Request(api, data=body, headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + token})
    host = urlsplit(api).hostname or ""
    try:
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = host.lower() == "localhost"
        if loopback:
            response = build_opener(ProxyHandler({})).open(request, timeout=TIMEOUT)
        else:
            response = urlopen(request, timeout=TIMEOUT)
        with response:
            result = json.load(response)
    except (OSError, HTTPError, URLError, ValueError):
        raise BackupError("rpc %s failed" % method) from None
    if not isinstance(result, dict) or "error" in result or "result" not in result:
        raise BackupError("rpc %s failed" % method)
    return result["result"]


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"))


def commit_seq(api, token):
    stats = rpc(api, token, "db.stats", {})
    try:
        return int(stats["commit_seq"])
    except (KeyError, TypeError, ValueError):
        raise BackupError("rpc db.stats failed") from None


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_data_file(path, records, token):
    digest = hashlib.sha256()
    try:
        with path.open("xb") as stream:
            os.chmod(path, 0o600)
            for record in records:
                line = (canonical(record) + "\n").encode("utf-8")
                if token.encode("utf-8") in line:
                    raise BackupError("credential value found in exported data")
                stream.write(line)
                digest.update(line)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        raise BackupError("write failed") from None
    return digest.hexdigest()


def export_plane(api, token, card, stage, ordinal):
    name = card.get("name")
    if not isinstance(name, str) or not name:
        raise BackupError("plane %d metadata invalid" % ordinal)
    try:
        node_count = int(card["nodes"])
        edge_count = int(card["edges"])
    except (KeyError, TypeError, ValueError):
        raise BackupError("node or edge count mismatch") from None

    seed = rpc(api, token, "graph.seed", {
        "plane": name, "limit": node_count + 1, "order": "scan"})
    if not isinstance(seed, dict):
        raise BackupError("rpc graph.seed failed")
    if seed.get("truncated"):
        raise BackupError("plane %d truncated" % ordinal)
    seed_nodes, seed_edges = seed.get("nodes"), seed.get("edges")
    try:
        total = int(seed.get("total", -1))
    except (TypeError, ValueError):
        raise BackupError("node count mismatch") from None
    if not isinstance(seed_nodes, list) or total != node_count or len(seed_nodes) != node_count:
        raise BackupError("node count mismatch")
    if not isinstance(seed_edges, list) or len(seed_edges) != edge_count:
        raise BackupError("edge count mismatch")
    try:
        node_ids = {int(node["id"]) for node in seed_nodes}
        edge_by_id = {int(edge["id"]): edge for edge in seed_edges}
    except (KeyError, TypeError, ValueError):
        raise BackupError("node or edge count mismatch") from None
    if len(node_ids) != node_count or len(edge_by_id) != edge_count:
        raise BackupError("node or edge count mismatch")

    nodes = []
    for ident in sorted(node_ids):
        node = rpc(api, token, "node.get", {
            "plane": name, "id": ident, "lean": False})
        if not isinstance(node, dict) or int(node.get("id", -1)) != ident:
            raise BackupError("node count mismatch")
        nodes.append(node)

    edges = {}
    for ident in sorted(node_ids):
        rows = rpc(api, token, "plane.neighbors", {
            "plane": name, "id": ident, "direction": "out",
            "hydrate": True, "lean": False})
        if not isinstance(rows, list):
            raise BackupError("edge count mismatch")
        for row in rows:
            try:
                edge, neighbour = row["edge"], row["node"]
                edge_id = int(edge["id"])
                record = {"id": edge_id, "src": ident,
                          "dst": int(neighbour["id"]), "type": edge["type"],
                          "properties": edge.get("properties", {})}
            except (KeyError, TypeError, ValueError):
                raise BackupError("edge count mismatch") from None
            if edge_id in edges and canonical(edges[edge_id]) != canonical(record):
                raise BackupError("edge count mismatch")
            edges[edge_id] = record

    if set(edges) != set(edge_by_id):
        raise BackupError("edge count mismatch")
    for edge_id, edge in edges.items():
        original = edge_by_id[edge_id]
        try:
            matches = (int(original["src"]) == edge["src"] and
                       int(original["dst"]) == edge["dst"] and
                       original["type"] == edge["type"])
        except (KeyError, TypeError, ValueError):
            matches = False
        if not matches:
            raise BackupError("edge count mismatch")

    records = ([{"kind": "node", "record": node} for node in nodes] +
               [{"kind": "edge", "record": edges[i]} for i in sorted(edges)])
    filename = "plane-%03d.jsonl" % ordinal
    digest = write_data_file(stage / filename, records, token)
    indexes = rpc(api, token, "plane.indexes", {"plane": name})
    if not isinstance(indexes, dict):
        raise BackupError("rpc plane.indexes failed")
    return {"name": name, "nodes": node_count, "edges": edge_count,
            "data_file": filename, "sha256": digest,
            "properties": card.get("properties") or {}, "indexes": indexes}


def formal_dirs(root):
    if not root.is_dir() or root.is_symlink():
        return []
    found = []
    for path in root.iterdir():
        if path.is_symlink() or not path.is_dir() or not BACKUP_RE.fullmatch(path.name):
            continue
        manifest_path = path / "manifest.json"
        if manifest_path.is_symlink() or not manifest_path.is_file():
            continue
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError):
            continue
        if manifest.get("schema_version") == 1 and manifest.get("tool") == "drsg-memory-backup":
            found.append(path)
    return sorted(found, key=lambda path: path.name)


def clean_staging(root):
    for path in root.iterdir():
        if STAGE_RE.fullmatch(path.name) and not path.is_symlink() and path.is_dir():
            shutil.rmtree(path)


def prune(root, keep):
    for path in formal_dirs(root)[:-keep]:
        shutil.rmtree(path)


def make_stage(root):
    path = root / (".drsg-backup-staging-" + secrets.token_hex(8))
    path.mkdir(mode=0o700)
    os.chmod(path, 0o700)
    return path


def get_version(binary):
    try:
        result = subprocess.run([binary, "--version"], check=True,
                                 capture_output=True, text=True, timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        raise BackupError("drsg version query failed") from None
    version = result.stdout.strip()
    if not version:
        raise BackupError("drsg version query failed")
    return version


def publish_manifest(stage, manifest, token):
    raw = (json.dumps(manifest, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    if token.encode("utf-8") in raw:
        raise BackupError("credential value found in manifest")
    try:
        path = stage / "manifest.json"
        with path.open("xb") as stream:
            os.chmod(path, 0o600)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        fsync_dir(stage)
    except OSError:
        raise BackupError("write failed") from None


def backup(args):
    root = root_dir()
    backup_root = root / "backups"
    stage = None
    published = False
    try:
        if backup_root.is_symlink():
            raise BackupError("backup directory invalid")
        backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(backup_root, 0o700)
        lock_path = backup_root / ".backup.lock"
        with lock_path.open("a") as lock:
            os.chmod(lock_path, 0o600)
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise BackupError("backup already running") from None
            clean_staging(backup_root)
            token, api = credentials(root)
            binary = binary_path(root)
            for attempt in range(3):
                stage = None
                start_seq = commit_seq(api, token)
                cards = rpc(api, token, "plane.list", {})
                if not isinstance(cards, list) or not cards:
                    raise BackupError("rpc plane.list failed")
                if len(cards) > 1000:
                    raise BackupError("plane count exceeds supported limit")
                stage = make_stage(backup_root)
                try:
                    planes = [export_plane(api, token, card, stage, i)
                              for i, card in enumerate(cards)]
                    end_seq = commit_seq(api, token)
                    if end_seq != start_seq:
                        shutil.rmtree(stage)
                        stage = None
                        if attempt == 2:
                            raise BackupError("library changed during export (3 attempts)")
                        continue
                    version = get_version(binary)
                    for plane in planes:
                        data = (stage / plane["data_file"]).read_bytes()
                        if token.encode("utf-8") in data:
                            raise BackupError("credential value found in exported data")
                        if hashlib.sha256(data).hexdigest() != plane["sha256"]:
                            raise BackupError("write failed")
                    now = datetime.now(timezone.utc)
                    manifest = {"tool": "drsg-memory-backup", "schema_version": 1,
                                "backup_time": now.isoformat(timespec="microseconds").replace("+00:00", "Z"),
                                "drsg_version": version, "commit_seq_start": start_seq,
                                "commit_seq_end": end_seq, "planes": planes}
                    publish_manifest(stage, manifest, token)
                    stamp = now.strftime("%Y%m%dT%H%M%S%fZ")
                    final = backup_root / ("backup-%s-%s" % (stamp, secrets.token_hex(4)))
                    os.rename(stage, final)
                    stage = None
                    published = True
                    try:
                        prune(backup_root, args.keep)
                    except OSError:
                        raise BackupError("old backup cleanup failed") from None
                    print("backup created")
                    return 0
                except OSError:
                    raise BackupError("write failed") from None
                finally:
                    if stage is not None:
                        shutil.rmtree(stage, ignore_errors=True)
            raise BackupError("library changed during export (3 attempts)")
    except BackupError as error:
        print(error.args[0] if error.args else "backup failed", file=sys.stderr)
        return 2
    except OSError:
        message = "old backup cleanup failed" if published else "write failed"
        print(message, file=sys.stderr)
        return 2
    except Exception:
        print("backup failed", file=sys.stderr)
        return 2


def load_backup(path, token):
    if path.is_symlink() or not path.is_dir() or not BACKUP_RE.fullmatch(path.name):
        raise BackupError("invalid backup")
    try:
        manifest_path = path / "manifest.json"
        if manifest_path.is_symlink() or not manifest_path.is_file():
            raise BackupError("invalid backup")
        raw = manifest_path.read_bytes()
        if token.encode("utf-8") in raw:
            raise BackupError("credential value found in backup")
        manifest = json.loads(raw)
        if (manifest.get("tool") != "drsg-memory-backup" or
                manifest.get("schema_version") != 1 or
                not isinstance(manifest.get("planes"), list) or not manifest["planes"]):
            raise BackupError("invalid backup")
        seen_files, seen_planes, loaded = set(), set(), []
        for plane in manifest["planes"]:
            name = plane["name"]
            if name in seen_planes:
                raise BackupError("invalid backup")
            seen_planes.add(name)
            filename = plane["data_file"]
            if not DATA_RE.fullmatch(filename) or filename in seen_files:
                raise BackupError("invalid backup")
            seen_files.add(filename)
            data_path = path / filename
            if data_path.is_symlink() or not data_path.is_file():
                raise BackupError("invalid backup")
            payload = data_path.read_bytes()
            if token.encode("utf-8") in payload:
                raise BackupError("credential value found in backup")
            if hashlib.sha256(payload).hexdigest() != plane["sha256"]:
                raise BackupError("backup checksum mismatch")
            records = [json.loads(line) for line in payload.splitlines()]
            if any(not isinstance(record, dict) or record.get("kind") not in ("node", "edge")
                   or not isinstance(record.get("record"), dict) for record in records):
                raise BackupError("invalid backup")
            nodes = [record["record"] for record in records if record["kind"] == "node"]
            edges = [record["record"] for record in records if record["kind"] == "edge"]
            if len(nodes) != int(plane["nodes"]):
                raise BackupError("node count mismatch")
            if len(edges) != int(plane["edges"]):
                raise BackupError("edge count mismatch")
            ids = {int(node["id"]) for node in nodes}
            edge_ids = {int(edge["id"]) for edge in edges}
            if len(ids) != len(nodes) or len(edge_ids) != len(edges):
                raise BackupError("invalid backup")
            if any(int(edge["src"]) not in ids or int(edge["dst"]) not in ids for edge in edges):
                raise BackupError("invalid backup")
            loaded.append((plane, nodes, edges))
        return manifest, loaded
    except BackupError:
        raise
    except (OSError, UnicodeError, ValueError, KeyError, TypeError):
        raise BackupError("invalid backup") from None


def free_port():
    sock = socket.socket()
    try:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]
    finally:
        sock.close()


def wait_rpc(api, token, proc):
    for _ in range(100):
        if proc.poll() is not None:
            raise BackupError("temporary daemon failed")
        try:
            rpc(api, token, "db.stats", {})
            return
        except BackupError:
            time.sleep(0.1)
    raise BackupError("temporary daemon failed")


def create_and_verify(db_path, loaded, binary):
    daemon_auth = secrets.token_hex(16)
    port = free_port()
    address = "127.0.0.1:%d" % port
    api = "http://%s/rpc" % address
    env = os.environ.copy()
    env.pop("DRSG_MEM_TOKEN", None)
    env.pop("DRSG_CONFIG", None)
    env["DRSG_TOKEN"] = daemon_auth
    with tempfile.TemporaryDirectory(prefix="drsg-memory-daemon-") as cwd:
        try:
            proc = subprocess.Popen([binary, "--db", str(db_path), "serve", "--addr", address],
                                    cwd=cwd, env=env, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            raise BackupError("temporary daemon failed") from None
        try:
            wait_rpc(api, daemon_auth, proc)
            initial = rpc(api, daemon_auth, "plane.list", {})
            if not isinstance(initial, list):
                raise BackupError("rpc plane.list failed")
            if any(int(plane["nodes"]) or int(plane["edges"]) for plane in initial):
                raise BackupError("target database is not empty")
            present = {plane["name"] for plane in initial}
            id_maps = {}
            for plane, nodes, edges in loaded:
                name = plane["name"]
                properties = plane.get("properties") or {}
                if name not in present:
                    rpc(api, daemon_auth, "plane.create", {"name": name, "properties": properties})
                    present.add(name)
                rpc(api, daemon_auth, "plane.set_props", {"plane": name, "properties": properties})
                mapping = {}
                for node in nodes:
                    params = {"plane": name, "labels": node.get("labels", []),
                              "properties": node.get("properties", {})}
                    if node.get("external_key") is not None:
                        params["key"] = node["external_key"]
                    created = rpc(api, daemon_auth, "node.create", params)
                    mapping[int(node["id"])] = int(created["id"])
                for edge in edges:
                    rpc(api, daemon_auth, "edge.create", {
                        "plane": name, "src": mapping[int(edge["src"])],
                        "dst": mapping[int(edge["dst"])], "type": edge["type"],
                        "properties": edge.get("properties", {})})
                for kind in ("keyword", "vector"):
                    for declaration in plane.get("indexes", {}).get(kind, []):
                        params = {"plane": name, "label": declaration["label"],
                                  "property": declaration["property"], "kind": kind}
                        if kind == "keyword":
                            params["language"] = declaration.get("language", "english")
                        else:
                            params["metric"] = declaration.get("metric", "cosine")
                        rpc(api, daemon_auth, "index.ensure", params)
                id_maps[name] = mapping

            actual_planes = rpc(api, daemon_auth, "plane.list", {})
            if not isinstance(actual_planes, list):
                raise BackupError("rpc plane.list failed")
            actual = {plane["name"]: plane for plane in actual_planes}
            for plane, nodes, edges in loaded:
                name = plane["name"]
                card = actual.get(name)
                if card is None:
                    raise BackupError("node or edge count mismatch")
                if int(card["nodes"]) != int(plane["nodes"]):
                    raise BackupError("node count mismatch")
                if int(card["edges"]) != int(plane["edges"]):
                    raise BackupError("edge count mismatch")
                if canonical(card.get("properties") or {}) != canonical(plane.get("properties") or {}):
                    raise BackupError("plane metadata mismatch")
                indexes = rpc(api, daemon_auth, "plane.indexes", {"plane": name})
                if canonical(indexes) != canonical(plane.get("indexes", {})):
                    raise BackupError("index declaration mismatch")
                mapping = id_maps[name]
                for node in nodes:
                    restored = rpc(api, daemon_auth, "node.get", {
                        "plane": name, "id": mapping[int(node["id"])], "lean": False})
                    if (restored.get("labels") != node.get("labels") or
                            restored.get("external_key") != node.get("external_key") or
                            canonical(restored.get("properties", {})) != canonical(node.get("properties", {}))):
                        raise BackupError("node data mismatch")
                expected_edges = sorted((mapping[int(edge["src"])], mapping[int(edge["dst"])],
                                         edge["type"], canonical(edge.get("properties", {})))
                                        for edge in edges)
                actual_edges = []
                for node in nodes:
                    source_id = mapping[int(node["id"])]
                    rows = rpc(api, daemon_auth, "plane.neighbors", {
                        "plane": name, "id": source_id, "direction": "out",
                        "hydrate": True, "lean": False})
                    for row in rows:
                        actual_edges.append((source_id, int(row["node"]["id"]),
                                             row["edge"]["type"],
                                             canonical(row["edge"].get("properties", {}))))
                if sorted(actual_edges) != expected_edges:
                    raise BackupError("edge data mismatch")
        except BackupError:
            raise
        except Exception:
            raise BackupError("restore verification failed") from None
        finally:
            if proc.poll() is None:
                try:
                    proc.terminate()
                except ProcessLookupError:
                    pass
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)


def daemon_answers(api):
    """True when something accepts connections at the env file's daemon address.

    Restore runs only against a stopped daemon. If the library was moved aside
    while the daemon kept running, the daemon still holds the moved directory
    open and keeps writing there; publishing a restored library beside it loses
    every one of those writes without an error."""
    parts = urlsplit(api)
    port = parts.port or (443 if parts.scheme == "https" else 80)
    try:
        with socket.create_connection((parts.hostname, port), timeout=2):
            return True
    except OSError:
        return False


def lexists(path):
    return os.path.lexists(path)


def restore(args, drill=False):
    root = root_dir()
    target = root / "memory.drsg"
    if not drill and any(lexists(Path(str(target) + suffix))
                         for suffix in ("", ".bm25", ".hnsw")):
        raise BackupError("target already exists")
    token, api = credentials(root)
    if not drill and daemon_answers(api):
        raise BackupError("daemon still running")
    backup_root = root / "backups"
    if args.latest:
        choices = formal_dirs(backup_root)
        if not choices:
            raise BackupError("no valid backup found")
        source = choices[-1]
    else:
        source = Path(args.from_dir).expanduser()
    _manifest, loaded = load_backup(source, token)
    binary = binary_path(root)
    if drill:
        with tempfile.TemporaryDirectory(prefix="drsg-memory-drill-") as temp:
            create_and_verify(Path(temp) / "memory.drsg", loaded, binary)
        print("drill passed")
        return 0

    stage = root / (".memory-restore-" + secrets.token_hex(8) + ".drsg")
    stage_sidecars = [Path(str(stage) + suffix) for suffix in (".bm25", ".hnsw")]
    try:
        create_and_verify(stage, loaded, binary)
        if not stage.is_dir():
            raise BackupError("restore verification failed")
        for sidecar in stage_sidecars:
            if lexists(sidecar):
                sidecar.unlink()
        if any(lexists(Path(str(target) + suffix))
               for suffix in ("", ".bm25", ".hnsw")):
            raise BackupError("target already exists")
        os.rename(stage, target)
        print("restore verified and published")
        return 0
    except OSError:
        raise BackupError("write failed") from None
    finally:
        if stage.is_dir() and not stage.is_symlink():
            shutil.rmtree(stage, ignore_errors=True)
        for sidecar in stage_sidecars:
            if lexists(sidecar):
                try:
                    sidecar.unlink()
                except OSError:
                    pass


def latest_args():
    return argparse.Namespace(latest=True, from_dir=None)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    backup_parser = sub.add_parser("backup")
    backup_parser.add_argument("--keep", type=int, default=7)
    restore_parser = sub.add_parser("restore")
    selection = restore_parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--from", dest="from_dir")
    selection.add_argument("--latest", action="store_true")
    sub.add_parser("drill")
    args = parser.parse_args(argv)
    try:
        if args.command == "backup":
            if args.keep < 1:
                print("invalid retention count", file=sys.stderr)
                return 2
            return backup(args)
        if args.command == "restore":
            try:
                return restore(args)
            except BackupError as error:
                print(error.args[0] if error.args else "restore failed", file=sys.stderr)
                return 2
            except OSError:
                print("write failed", file=sys.stderr)
                return 2
            except Exception:
                print("restore failed", file=sys.stderr)
                return 2
        try:
            return restore(latest_args(), drill=True)
        except BackupError as error:
            print(error.args[0] if error.args else "drill failed", file=sys.stderr)
            return 2
        except OSError:
            print("write failed", file=sys.stderr)
            return 2
        except Exception:
            print("drill failed", file=sys.stderr)
            return 2
    except Exception:
        print("operation failed", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

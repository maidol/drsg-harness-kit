#!/usr/bin/env bash
# The TTL cleanup gate has one focused assertion and no other early failure.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
python3 - "$REPO" <<'PY'
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import time

repo = pathlib.Path(sys.argv[1])
source = pathlib.Path(os.environ.get(
    "COMPACT_HANDOFF_SOURCE", repo / "tools/templates/hooks/compact_handoff.py"))
spec = importlib.util.spec_from_file_location("compact_handoff_expiry", source)
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)
with tempfile.TemporaryDirectory() as temp:
    now = time.time()
    directory = pathlib.Path(temp) / "project-hash"
    directory.mkdir(mode=0o700)
    path = directory / "old.json"
    path.write_text(json.dumps({"created_at_epoch": now - hook.ttl_seconds() - 1,
                                "consumed": False}), encoding="utf-8")
    hook.cleanup(str(directory), now)
    if path.exists():
        print("FAIL expired record cleanup prunes file")
        raise SystemExit(1)
print("ok   expired record cleanup prunes file")
PY

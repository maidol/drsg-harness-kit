#!/usr/bin/env bash
# Each mutation runs only the integration assertion that should catch it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0

run_mutation() {
  local name="$1" only="$2" variant="$3"
  if ! cp "$REPO/tools/mcp_events.py" "$T/mcp_events.py" ||
     ! cp "$REPO/tools/event.py" "$T/event.py" ||
     ! cp "$REPO/tools/drsg_rpc.py" "$T/drsg_rpc.py" ||
     ! cp "$REPO/tools/templates/hooks/secret_redact.py" "$T/secret_redact.py"; then
    printf 'MUTATION NOT RUN %s (source copy failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  local control="$T/$name.control.out" control_rc=0
  ONLY="$only" EVENT_SOURCE="$T/event.py" MCP_EVENTS_SOURCE="$T/mcp_events.py" \
    bash "$HERE/event-open-window.sh" >"$control" 2>&1 || control_rc=$?
  if [ "$control_rc" -ne 0 ] ||
     grep -Eq '^(SKIP|FAIL )|No module named|Traceback' "$control" ||
     ! grep -Fq 'PASS 1/1' "$control"; then
    printf 'MUTATION NOT RUN %s (unmutated paired case did not pass; exit %s)\n' "$name" "$control_rc"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if [ "$variant" != no-op ]; then
    if ! python3 - "$T" "$variant" <<'PY'
import pathlib
import sys

root, variant = pathlib.Path(sys.argv[1]), sys.argv[2]
targets = {
    "no-mcp-list-canon": (
        root / "mcp_events.py",
        'path = ev.canon_path(args.get("project") or proj)',
        'path = os.path.abspath(os.path.normpath(args.get("project") or proj))'),
    "no-orphan-delete": (
        root / "event.py",
        '            deleted = rpc("node.delete", {"plane": PLANE, "key": key}, token)',
        '            deleted = {"deleted": True}'),
    "edge-exception-unhandled": (
        root / "event.py",
        '    except Exception as e:\n        edge = None\n        edge_error = str(e)',
        '    except Exception as e:\n        raise e'),
}
if variant not in targets:
    raise SystemExit("unknown mutation")
path, old, new = targets[variant]
text = path.read_text(encoding="utf-8")
if text.count(old) != 1:
    raise SystemExit("mutation target not unique: " + variant)
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
    then
      printf 'MUTATION NOT RUN %s (mutation setup failed)\n' "$name"
      NOT_RUN=$((NOT_RUN + 1))
      return
    fi
  fi

  printf '\n== %s: ONLY=%s ==\n' "$name" "$only"
  local output="$T/$name.out" rc
  ONLY="$only" EVENT_SOURCE="$T/event.py" MCP_EVENTS_SOURCE="$T/mcp_events.py" \
    bash "$HERE/event-open-window.sh" >"$output" 2>&1
  rc=$?
  python3 - "$output" <<'PY'
import pathlib
import sys
sys.stdout.write(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
PY
  if python3 - "$output" <<'PY'
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
raise SystemExit(0 if "SKIP event-open-window:" in text else 1)
PY
  then
    printf 'MUTATION NOT RUN %s (real daemon unavailable)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
  elif [ "$rc" -eq 0 ]; then
    printf 'MUTATION SURVIVED %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  elif python3 - "$output" "$only" <<'PY'
import pathlib
import sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
raise SystemExit(0 if "FAIL " + sys.argv[2] in text and "PASS 0/1" in text else 1)
PY
  then
    printf 'killed %s\n' "$name"
    KILLED=$((KILLED + 1))
  else
    printf 'MUTATION NOT RUN %s (target assertion did not fail)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
  fi
}

run_mutation no-mcp-list-canon 'MCP event_list resolves symlink alias' no-mcp-list-canon
run_mutation no-orphan-delete 'edge failure removes orphan node' no-orphan-delete
run_mutation edge-exception-unhandled 'edge failure removes orphan node' edge-exception-unhandled
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop 'edge failure removes orphan node' no-op
fi

if [ "$NOT_RUN" -gt 0 ] || [ "$KILLED" -ne 3 ]; then
  printf 'MUTATION RESULT: NOT RUN (%d; killed %d/3)\n' "$NOT_RUN" "$KILLED"
  exit 2
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
printf 'MUTATION RESULT: ALL KILLED (%d)\n' "$KILLED"

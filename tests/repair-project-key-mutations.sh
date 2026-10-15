#!/usr/bin/env bash
# Each isolated mutation is exercised only by its paired ONLY assertion.
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
  local source="$T/$name.py" output="$T/$name.out" rc
  if ! cp "$REPO/tools/repair_project_key.py" "$source"; then
    printf 'MUTATION NOT RUN %s (source copy failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if [ "$variant" != no-op ]; then
    if ! python3 - "$source" "$variant" <<'PY'
from pathlib import Path
import sys

path, variant = Path(sys.argv[1]), sys.argv[2]
mutations = {
    "no-api-binding": (
        '    u.API = os.environ.get("DRSG_API", u.API)\n',
        ''),
    "keyed-about-belongs-only": (
        '    edges = incident_edges(seed.get("edges", []), old_id)\n',
        '    nodes_by_id = {node.get("id"): node for node in nodes}\n'
        '    edges = [edge for edge in seed.get("edges", [])\n'
        '             if edge.get("dst") == old_id\n'
        '             and edge.get("type") in ("ABOUT", "BELONGS_TO")\n'
        '             and nodes_by_id.get(edge.get("src"), {}).get("external_key")]\n'),
    "snapshot-after-delete": (
        '    snapshot = snapshot_path(key, requested_snapshot)\n'
        '    try:\n'
        '        write_snapshot(snapshot, old, edges)\n'
        '    except Exception as error:\n'
        '        print("refused: could not write snapshot %s (%s)" %\n'
        '              (snapshot, error), file=sys.stderr)\n'
        '        raise SystemExit(3)\n'
        '    print("snapshot: %s" % snapshot)\n'
        '\n'
        '    # Delete the orphan first. Creating first and deleting after risks the\n'
        '    # delete taking the freshly-written index entry down with it — the very\n'
        '    # failure this whole repair exists to undo.\n'
        '    deleted = u.rpc("node.delete", {"plane": plane, "id": old_id}, tok)\n',
        '    snapshot = snapshot_path(key, requested_snapshot)\n'
        '    # Mutant: delete before writing the snapshot.\n'
        '    deleted = u.rpc("node.delete", {"plane": plane, "id": old_id}, tok)\n'
        '    try:\n'
        '        write_snapshot(snapshot, old, edges)\n'
        '    except Exception as error:\n'
        '        print("refused: could not write snapshot %s (%s)" %\n'
        '              (snapshot, error), file=sys.stderr)\n'
        '        raise SystemExit(3)\n'
        '    print("snapshot: %s" % snapshot)\n'),
    "no-edge-result-id-check": (
        '        try:\n'
        '            result = u.rpc("edge.create", params, tok)\n'
        '            if not isinstance(result, dict) or result.get("id") is None:\n'
        '                failed.append(edge)\n',
        '        try:\n'
        '            u.rpc("edge.create", params, tok)\n'),
    "about-only-verify": (
        '    want = edge_counts(expected_edges, new_id)\n'
        '    got = edge_counts(incident_edges(edges, new_id), new_id)\n',
        '    want_all = edge_counts(expected_edges, new_id)\n'
        '    got_all = edge_counts(incident_edges(edges, new_id), new_id)\n'
        '    want = Counter({sig: count for sig, count in want_all.items()\n'
        '                    if sig[0] == "in" and sig[1] == "ABOUT"})\n'
        '    got = Counter({sig: count for sig, count in got_all.items()\n'
        '                   if sig[0] == "in" and sig[1] == "ABOUT"})\n'),
    "ignore-verify-result": (
        '    if not verify(plane, path, key, tok, old, edges, old_id, new_id):\n'
        '        print("verify failed; snapshot: %s" % snapshot, file=sys.stderr)\n'
        '        raise SystemExit(1)\n',
        '    verify(plane, path, key, tok, old, edges, old_id, new_id)\n'),
    "ignore-truncated": (
        '    if seed.get("truncated"):\n'
        '        print("refused: graph.seed result is truncated; increase its limit before repair",\n'
        '              file=sys.stderr)\n'
        '        raise SystemExit(3)\n',
        ''),
}
if variant not in mutations:
    raise SystemExit("unknown mutation: " + variant)
text = path.read_text(encoding="utf-8")
old, new = mutations[variant]
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
  REPAIR_SCRIPT="$source" ONLY="$only" bash "$HERE/repair-project-key.sh" \
    >"$output" 2>&1
  rc=$?
  python3 - "$output" <<'PY'
from pathlib import Path
import sys
sys.stdout.write(Path(sys.argv[1]).read_text(encoding="utf-8"))
PY
  if python3 - "$output" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
raise SystemExit(0 if "SKIP repair-project-key:" in text else 1)
PY
  then
    printf 'MUTATION NOT RUN %s (real daemon unavailable)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
  elif [ "$rc" -eq 0 ]; then
    printf 'MUTATION SURVIVED %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  elif python3 - "$output" "$only" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
case = sys.argv[2]
raise SystemExit(0 if "FAIL " + case + ":" in text and "PASS 0/1" in text else 1)
PY
  then
    printf 'killed %s\n' "$name"
    KILLED=$((KILLED + 1))
  else
    printf 'MUTATION NOT RUN %s (paired assertion did not fail)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
  fi
}

run_mutation no-api-binding full-edge-preservation no-api-binding
run_mutation keyed-about-belongs-only full-edge-preservation keyed-about-belongs-only
run_mutation snapshot-after-delete snapshot-failure-no-delete snapshot-after-delete
run_mutation no-edge-result-id-check edge-create-empty no-edge-result-id-check
run_mutation about-only-verify edge-create-fake-success about-only-verify
run_mutation ignore-verify-result edge-create-fake-success ignore-verify-result
run_mutation ignore-truncated seed-truncated ignore-truncated
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop edge-create-fake-success no-op
fi

if [ "$NOT_RUN" -gt 0 ]; then
  printf 'MUTATION NOT RUN (%d)\n' "$NOT_RUN"
  exit 1
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
printf 'ALL MUTATIONS KILLED (%d)\n' "$KILLED"

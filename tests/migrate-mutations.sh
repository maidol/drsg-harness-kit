#!/usr/bin/env bash
# Run each migration mutation only against the regression case that kills it.
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
  if ! cp "$REPO/tools/migrate.py" "$source" ||
     ! cp "$REPO/tools/drsg_rpc.py" "$T/drsg_rpc.py"; then
    printf 'MUTATION NOT RUN %s (source copy failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if [ "$variant" != no-op ]; then
    if ! python3 - "$source" "$variant" <<'PY'
from pathlib import Path
import sys

path, variant = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")

def replace_once(old, new, label):
    global text
    if text.count(old) != 1:
        raise SystemExit("mutation target not unique: " + label)
    text = text.replace(old, new, 1)

if variant == "no-existing-edge-skip":
    replace_once('        if signature in edge_set:\n',
                 '        if False and signature in edge_set:\n', variant)
elif variant == "ignore-properties":
    replace_once('    props = json.dumps(properties or {}, sort_keys=True, ensure_ascii=False,\n'
                 '                        separators=(",", ":"))\n',
                 '    props = json.dumps({}, sort_keys=True, ensure_ascii=False,\n'
                 '                        separators=(",", ":"))\n', variant)
elif variant == "ignore-dump-truncated":
    replace_once('    if res.get("truncated"):\n',
                 '    if False and res.get("truncated"):\n', variant)
elif variant == "late-target-truncation-check":
    guard = ('    if target.get("truncated"):\n'
             '        print("graph.seed truncated: target plane exceeds the limit; increase --limit",\n'
             '              file=sys.stderr)\n'
             '        return 3\n')
    replace_once(guard, '', variant + " remove pre-write guard")
    replace_once('    edges_created = edges_skipped = edges_failed = 0\n',
                 '    if target.get("truncated"):\n'
                 '        print("graph.seed truncated: target plane exceeds the limit; increase --limit",\n'
                 '              file=sys.stderr)\n'
                 '        return 3\n'
                 '    edges_created = edges_skipped = edges_failed = 0\n',
                 variant + " check after node writes")
elif variant == "ignore-load-return":
    replace_once('    return args.func(args)\n',
                 '    args.func(args)\n    return 0\n', variant)
else:
    raise SystemExit("unknown mutation: " + variant)
path.write_text(text, encoding="utf-8")
PY
    then
      printf 'MUTATION NOT RUN %s (mutation setup failed)\n' "$name"
      NOT_RUN=$((NOT_RUN + 1))
      return
    fi
  fi

  printf '\n== %s: ONLY=%s ==\n' "$name" "$only"
  MIGRATE_SCRIPT="$source" ONLY="$only" bash "$HERE/migrate.sh" >"$output" 2>&1
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
raise SystemExit(0 if "SKIP migrate:" in text else 1)
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

run_mutation no-existing-edge-skip load-rerun-no-duplicate no-existing-edge-skip
run_mutation ignore-properties properties-distinguish-edges ignore-properties
run_mutation ignore-dump-truncated dump-truncated ignore-dump-truncated
run_mutation late-target-truncation-check load-target-truncated late-target-truncation-check
run_mutation ignore-load-return load-write-failure ignore-load-return
if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_mutation self-test-noop load-write-failure no-op
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

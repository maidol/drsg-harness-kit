#!/usr/bin/env bash
# Each mutant runs only the contract case that kills it.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SOURCE="$REPO/tools/memory-backup.py"
TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT
LEAVE_ALIVE=""
if [ "${1:-}" = "--leave-alive" ]; then
  [ "$#" -eq 2 ] || { echo "MUTATION RUNNER DID NOT START: expected one case"; exit 2; }
  LEAVE_ALIVE="$2"
fi
KILLED=()
SURVIVED=()
DID_NOT_START=""

run_case() {
  local name="$1" case_name="$2" expected="$3" old="$4" new="$5"
  local candidate="$TMP/$name.py" log="$TMP/$name.out" rc=0
  if ! cp "$SOURCE" "$candidate"; then
    DID_NOT_START="$name source copy failed"
    return
  fi
  local control="$TMP/$name.control.out" control_rc=0
  S1_ONLY_CASE="$case_name" MEMORY_BACKUP_SCRIPT="$candidate" \
    bash "$HERE/memory-backup.sh" >"$control" 2>&1 || control_rc=$?
  if [ "$control_rc" -ne 0 ] || grep -Eq '^(SKIP|FAIL )|No module named|Traceback' "$control" ||
     ! grep -q '^SUMMARY memory-backup:' "$control"; then
    DID_NOT_START="$name unmutated paired case did not pass (exit $control_rc)"
    return
  fi
  if [ "$name" != "$LEAVE_ALIVE" ]; then
    if ! python3 - "$candidate" "$old" "$new" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old, new = sys.argv[2], sys.argv[3]
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
if source.count(old) != 1:
    raise SystemExit(2)
path.write_text(source.replace(old, new, 1), encoding="utf-8")
PY
    then
      DID_NOT_START="$name mutation did not apply uniquely"
      return
    fi
  fi
  S1_ONLY_CASE="$case_name" MEMORY_BACKUP_SCRIPT="$candidate" \
    bash "$HERE/memory-backup.sh" >"$log" 2>&1 || rc=$?
  if grep -q '^SKIP memory-backup:' "$log"; then
    DID_NOT_START="$name test prerequisites unavailable"
  elif grep -q '^FAIL memory-backup test runner:' "$log" ||
       ! grep -q '^SUMMARY memory-backup:' "$log"; then
    DID_NOT_START="$name test did not reach its assertion"
  else
    local failures
    failures="$(grep -c '^FAIL ' "$log" || true)"
    if [ "$rc" -ne 0 ] && [ "$failures" -eq 1 ] && grep -Fq "$expected" "$log"; then
      KILLED+=("$name")
    elif [ "$rc" -eq 0 ] && [ "$failures" -eq 0 ]; then
      SURVIVED+=("$name")
    else
      DID_NOT_START="$name failed outside its paired assertion"
      python3 - "$log" <<'PY'
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text(errors="replace").splitlines()
print("\\n".join(lines[-12:]))
PY
    fi
  fi
}

run_case truncated truncated \
  'FAIL truncated plane fails with reason and no new final directory' \
  'if seed.get("truncated"):' \
  'if False and seed.get("truncated"): '
run_case permissions permissions \
  'FAIL permission case: backup directory 0700 and files 0600' \
  '            os.chmod(path, 0o600)\n            for record in records:' \
  '            pass # mutation: file mode is left to the caller umask\n            for record in records:'
run_case retention-boundary retention-boundary \
  'FAIL retention only removes strict-name ordinary backup directories' \
  'for path in root.iterdir():\n        if path.is_symlink() or not path.is_dir() or not BACKUP_RE.fullmatch(path.name):' \
  'for path in root.iterdir():\n        if not path.is_dir() or not path.name.startswith("backup-"): '

if [ -n "$DID_NOT_START" ] || [ "${#KILLED[@]}" -ne 3 ]; then
  printf 'MUTATION RESULT: NOT RUN (%s; killed %d/3)\n' "${DID_NOT_START:-incomplete mutation count}" "${#KILLED[@]}"
  exit 2
fi
if [ "${#SURVIVED[@]}" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED (%s)\n' "${SURVIVED[*]}"
  exit 1
fi
printf 'MUTATION RESULT: ALL KILLED (%d)\n' "${#KILLED[@]}"

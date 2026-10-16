#!/usr/bin/env bash
# The suites that start a throwaway drsg daemon must leave no daemon behind.
# `(cd "$T" && drsg serve …) &` hands $! the subshell, not drsg: the trap's
# kill reaches the subshell only, drsg is reparented to init and keeps running.
# Each run of the suite leaked one daemon per such launch (261 had piled up,
# about 3 GB of resident memory, by 2026-10-16).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BIN="${DRSG_MEM_BIN:-$HOME/.drsg-memory/bin/drsg}"
[ -x "$BIN" ] || BIN="$(command -v drsg || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  echo "SKIP daemon-cleanup: no drsg binary (set DRSG_MEM_BIN)"
  exit 0
fi

ROOT="$(mktemp -d)"
leftovers() {
  ps -eo pid=,args= | awk -v root="$ROOT/" 'index($0, " --db " root) {print $1}'
}
cleanup() {
  local pids
  pids="$(leftovers)"
  [ -n "$pids" ] && kill $pids 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

pass=0; fail=0
for suite in event-open-window hook-upkeep; do
  mkdir -p "$ROOT/$suite"
  TMPDIR="$ROOT/$suite" bash "$REPO/tests/$suite.sh" >"$ROOT/$suite.out" 2>&1
  rc=$?
  sleep 1
  left="$(ps -eo pid=,args= | awk -v root="$ROOT/$suite/" 'index($0, " --db " root) {print $1}')"
  if [ "$rc" -ne 0 ]; then
    fail=$((fail + 1)); echo "FAIL $suite: suite itself failed (rc=$rc)"; tail -3 "$ROOT/$suite.out"
  elif [ -n "$left" ]; then
    fail=$((fail + 1)); echo "FAIL $suite: drsg daemon still running after the suite exited (pid $left)"
  else
    pass=$((pass + 1)); echo "ok   $suite leaves no daemon behind"
  fi
done

echo "PASS $pass/$((pass + fail))"
[ "$fail" -eq 0 ]

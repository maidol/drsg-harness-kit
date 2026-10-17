#!/usr/bin/env bash
# Each mutation of the supersedes path runs only the case that must catch it.
# Before mutating, the same case runs on an unmutated copy and must pass, so a
# kill always comes from the assertion, never from a broken fixture.
# SELF_TEST=1 adds a comment-only sentinel that must survive (exit 1).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0

copy_tools() {  # $1 = destination tools directory
  mkdir -p "$1" &&
    cp "$REPO/tools/event.py" "$REPO/tools/mcp_events.py" "$REPO/tools/drsg_rpc.py" \
       "$REPO/tools/event-poller.py" "$REPO/tools/templates/hooks/secret_redact.py" "$1/"
}

run_case() {  # $1 = tools dir, $2 = test name, $3 = output file
  ONLY="$2" EVENT_TOOLS_DIR="$1" bash "$HERE/event-supersedes.sh" >"$3" 2>&1
}

run_mutation() {
  local name="$1" only="$2" old="$3" new="$4"
  local dir="$T/$name" rc
  if ! copy_tools "$dir/control" || ! copy_tools "$dir/tools"; then
    printf 'MUTATION NOT RUN %s (source copy failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! run_case "$dir/control" "$only" "$dir/control.out"; then
    printf 'MUTATION NOT RUN %s (control %s fails without the mutation)\n' "$name" "$only"
    cat "$dir/control.out"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! python3 - "$dir/tools" "$old" "$new" <<'PY'
import pathlib
import sys
root, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
hits = [p for p in (root / "event.py", root / "mcp_events.py")
        if old in p.read_text(encoding="utf-8")]
if len(hits) != 1 or hits[0].read_text(encoding="utf-8").count(old) != 1:
    raise SystemExit("mutation target not unique")
text = hits[0].read_text(encoding="utf-8")
hits[0].write_text(text.replace(old, new, 1), encoding="utf-8")
PY
  then
    printf 'MUTATION NOT RUN %s (mutation setup failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  run_case "$dir/tools" "$only" "$dir/out"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'MUTATION SURVIVED %s (%s still passes)\n' "$name" "$only"
    SURVIVED=$((SURVIVED + 1))
  elif grep -Eq "^$only \(__main__\.SupersedesTests\) \.\.\. (FAIL|ERROR)$|^(FAIL|ERROR): $only " "$dir/out"; then
    printf 'KILLED %s by %s\n' "$name" "$only"
    KILLED=$((KILLED + 1))
  else
    printf 'MUTATION NOT RUN %s (%s did not report a failure of its own)\n' "$name" "$only"
    cat "$dir/out"
    NOT_RUN=$((NOT_RUN + 1))
  fi
}

run_mutation no-missing-check test_refuse_missing \
  '            raise ValueError("supersedes 目标 Event 不存在或不是 Event；请核对 key，或去掉 supersedes 重发。")' \
  '            pass'
run_mutation no-recipient-check test_refuse_other_recipient \
  '        raise ValueError("supersedes 目标 Event 不是发给 recipient 的；只能取代发给同一收件方的单。")' \
  '        pass'
run_mutation no-legacy-check test_refuse_legacy \
  '        raise ValueError("supersedes 指向的 Event 是旧格式（没有 from_path），无法核对是不是本项目发的；请去掉 supersedes 重发，旧单请收件方手动关。")' \
  '        pass'
run_mutation no-sender-check test_refuse_not_sender \
  '        raise ValueError("supersedes 目标 Event 不是本项目发出的；只能取代自己发出的单。")' \
  '        pass'
run_mutation no-status-check test_refuse_done \
  $'    if props.get("status") != "open":\n        raise ValueError("supersedes 目标 Event 已经是' \
  $'    if False:\n        raise ValueError("supersedes 目标 Event 已经是'
run_mutation no-close test_valid_supersede \
  '        _close_superseded(supersedes, key, token)' \
  '        pass'
run_mutation no-readback test_readback_mismatch_reports \
  '    if "Event" not in (node.get("labels") or []) or status != "done":' \
  '    if False:'
run_mutation close-error-swallowed test_close_failure_keeps_new_event \
  '        raise RuntimeError(f"新单 {new} 已发出；旧单 {old} 没关上（{e}），请收件方手动关。") from e' \
  '        return'
run_mutation close-through-owner-check test_owner_lease_not_consulted \
  '        _close_superseded(supersedes, key, token)' \
  '        close(supersedes, token, project=target)'
run_mutation no-mcp-list-line test_list_shows_superseded_line \
  '                rows.append("%-6s ↳ 取代 %s" % ("", pr["supersedes"]))' \
  '                pass'
if [ "${SELF_TEST:-}" = 1 ]; then
  run_mutation sentinel test_valid_supersede \
    '    # New first, old second: if closing the old one fails, the recipient still' \
    '    # (sentinel) New first, old second: if closing the old one fails, the recipient still'
fi

printf '\nkilled %d, survived %d, not run %d\n' "$KILLED" "$SURVIVED" "$NOT_RUN"
if [ "$NOT_RUN" -gt 0 ]; then
  echo "MUTATION RESULT: NOT RUN ($NOT_RUN)"
  exit 2
elif [ "$SURVIVED" -gt 0 ]; then
  echo "MUTATION RESULT: SURVIVED ($SURVIVED)"
  exit 1
fi
echo "MUTATION RESULT: ALL KILLED ($KILLED)"

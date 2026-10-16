#!/usr/bin/env bash
# Run each context-growth mutant only against its paired focused assertion.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
LOG_DIR="${V116_CONTEXT_GROWTH_MUTATION_LOG_DIR:-$T}"
mkdir -p "$LOG_DIR"
trap 'rm -rf "$T"' EXIT
KILLED=0
SURVIVED=0
NOT_RUN=0

run_case() {
  local kind="$1" case_name="$2" root="$3" rc=0
  case "$kind" in
    wake)
      if WAKE_SOURCE="$root/tools/event-poller.py" env -u PYTHONPATH bash "$HERE/wake-guidance.sh"; then rc=0; else rc=$?; fi ;;
    event)
      if V116_SOURCE_ROOT="$root" ONLY="$case_name" env -u PYTHONPATH bash "$HERE/event-list-limit.sh"; then rc=0; else rc=$?; fi ;;
    compact)
      if SESSION_START_SOURCE="$root/tools/templates/hooks/session_start.py" ONLY="$case_name" env -u PYTHONPATH bash "$HERE/session-start-compact-context.sh"; then rc=0; else rc=$?; fi ;;
    hook)
      if V116_SOURCE_ROOT="$root" ONLY="$case_name" env -u PYTHONPATH bash "$HERE/hook-rpc-common.sh"; then rc=0; else rc=$?; fi ;;
    *) return 2 ;;
  esac
  return "$rc"
}

mutate() {
  local path="$1" old="$2" new="$3"
  python3 - "$path" "$old" "$new" <<'PY'
from pathlib import Path
import sys
path, old, new = map(str, sys.argv[1:])
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
file = Path(path)
text = file.read_text(encoding="utf-8")
if text.count(old) != 1:
    raise SystemExit("mutation target not unique: " + str(file))
file.write_text(text.replace(old, new, 1), encoding="utf-8")
PY
}

run_pair() {
  local name="$1" kind="$2" case_name="$3" path="$4" old="$5" new="$6"
  local root="$T/$name" baseline="$LOG_DIR/$name-control.log"
  local output="$LOG_DIR/$name-mutant.log" rc=0
  mkdir -p "$root"
  cp -a "$REPO/tools" "$root/tools"
  if run_case "$kind" "$case_name" "$root" >"$baseline" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ] || grep -Fq 'SKIP ' "$baseline" || grep -Fq 'FAIL ' "$baseline" || grep -Fq 'No module named' "$baseline" || grep -Fq 'Traceback' "$baseline"; then
    printf 'MUTATION NOT RUN %s (unmutated paired case did not pass; exit %s)\n' "$name" "$rc"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if ! mutate "$root/$path" "$old" "$new"; then
    printf 'MUTATION NOT RUN %s (mutation setup failed)\n' "$name"
    NOT_RUN=$((NOT_RUN + 1))
    return
  fi
  if run_case "$kind" "$case_name" "$root" >"$output" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'MUTATION SURVIVED %s\n' "$name"
    SURVIVED=$((SURVIVED + 1))
  elif grep -Fq "FAIL $case_name" "$output"; then
    printf 'KILLED %s by %s\n' "$name" "$case_name"
    KILLED=$((KILLED + 1))
  else
    printf 'MUTATION NOT RUN %s (paired assertion did not fail; exit %s)\n' "$name" "$rc"
    NOT_RUN=$((NOT_RUN + 1))
  fi
}

run_sentinel() {
  local root="$T/sentinel" baseline="$LOG_DIR/sentinel-control.log"
  local output="$LOG_DIR/sentinel-mutant.log" rc=0
  mkdir -p "$root"
  cp -a "$REPO/tools" "$root/tools"
  if ! run_case wake wake-guidance "$root" >"$baseline" 2>&1 || grep -Fq 'SKIP ' "$baseline" || grep -Fq 'FAIL ' "$baseline"; then
    printf 'MUTATION NOT RUN sentinel (unmutated paired case failed)\n'
    return 2
  fi
  if ! mutate "$root/tools/event-poller.py" \
      '    renudged = renudged or []' \
      '    renudged = renudged or []  # deliberate control mutant'; then
    printf 'MUTATION NOT RUN sentinel (mutation setup failed)\n'
    return 2
  fi
  if run_case wake wake-guidance "$root" >"$output" 2>&1; then
    printf 'MUTATION SURVIVED sentinel\n'
    return 1
  fi
  printf 'MUTATION NOT RUN sentinel (control did not survive)\n'
  return 2
}

if [ "${MUTATION_SELF_TEST:-0}" = 1 ]; then
  run_sentinel
  rc=$?
  if [ "$rc" -eq 1 ]; then
    printf 'MUTATION RESULT: SURVIVED (sentinel)\n'
    exit 1
  fi
  printf 'MUTATION RESULT: NOT RUN (sentinel)\n'
  exit 2
fi

run_pair wake-five-line wake wake-guidance tools/event-poller.py \
  '    lines.append("按 Event 流程处理：handoff 直接开工；判定只 event_done；commit/push/PR 等先等用户确认。")' \
  '    lines += ["按 CLAUDE.md 的 Event 流程处理：读 ref 指的文档，照做；做完发回执（notice）并 event_done。", "例外：summary 以「验收通过：」开头的判定只需 event_done，不要为它回 notice；回执的回执只会让对方多关一次单。", "收到 handoff 直接开工，不要先回「已读」「已收到，准备先写计划」这类 notice；回给发件方的第一条应是回执，或卡住时要问的问题。", "照旧要先停下等用户确认的：git commit、push、开 PR、改锁文件、任何不可逆操作。", "动手前先看工作区和 git 状态：另一个会话可能做过一半（本条可能是接管后重发），已做过的不要重复改。"]'
run_pair event-all-hint event event-list-all-limit tools/mcp_events.py \
  'more_line = "另有 %d 条未列出，传 limit 看更多" % (total - requested)' \
  'more_line = ""'
run_pair event-open-done-limit event event-list-status-isolation tools/mcp_events.py \
  'events = ev.fetch(path, token, status=want)' \
  'events = ev.fetch(path, token, status=want, limit=requested)'
run_pair compact-briefing compact compact-excludes-briefing tools/templates/hooks/session_start.py \
  'if source != "compact" and brief:' 'if brief:'
run_pair compact-event compact compact-keeps-required-context tools/templates/hooks/session_start.py \
  'events = open_events(proj_dir, token)' \
  'events = [] if source == "compact" else open_events(proj_dir, token)'
run_pair session-end-timeout hook g4-session-end-rpc tools/templates/hooks/session_end.py \
  'token, timeout=2)' 'token, timeout=3)'
run_pair l3-timeout hook g4-l3-digest-rpc tools/templates/hooks/l3_digest.py \
  'prop = _common.rpc("digest.run", params, token, timeout=RPC_TIMEOUT)' \
  'prop = _common.rpc("digest.run", params, token, timeout=RPC_TIMEOUT - 1)'

# The missing-module behavior is tested for both consumers by this paired case.
root="$T/missing-common"
mkdir -p "$root"
cp -a "$REPO/tools" "$root/tools"
base="$LOG_DIR/missing-common-control.log"
out="$LOG_DIR/missing-common-mutant.log"
if run_case hook g4-missing-common "$root" >"$base" 2>&1 && ! grep -Fq 'SKIP ' "$base"; then
  if mutate "$root/tools/templates/hooks/session_end.py" \
      '    if _common is None:\n        return' \
      '    if False:\n        return' &&
     mutate "$root/tools/templates/hooks/l3_digest.py" \
      '    if _common is None:\n        log("drsg_hook_common.py missing; skipping L3 digest")\n        return' \
      '    if False:\n        log("drsg_hook_common.py missing; skipping L3 digest")\n        return'; then
    if run_case hook g4-missing-common "$root" >"$out" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    if [ "$rc" -ne 0 ] && grep -Fq 'FAIL g4-missing-common' "$out"; then
      printf 'KILLED missing-common by g4-missing-common\n'
      KILLED=$((KILLED + 1))
    elif [ "$rc" -eq 0 ]; then
      printf 'MUTATION SURVIVED missing-common\n'
      SURVIVED=$((SURVIVED + 1))
    else
      printf 'MUTATION NOT RUN missing-common (paired assertion did not fail; exit %s)\n' "$rc"
      NOT_RUN=$((NOT_RUN + 1))
    fi
  else
    printf 'MUTATION NOT RUN missing-common (mutation setup failed)\n'
    NOT_RUN=$((NOT_RUN + 1))
  fi
else
  printf 'MUTATION NOT RUN missing-common (unmutated paired case did not pass)\n'
  NOT_RUN=$((NOT_RUN + 1))
fi

if [ "$NOT_RUN" -gt 0 ]; then
  printf 'MUTATION RESULT: NOT RUN (%d)\n' "$NOT_RUN"
  exit 2
fi
if [ "$SURVIVED" -gt 0 ]; then
  printf 'MUTATION RESULT: SURVIVED (%d)\n' "$SURVIVED"
  exit 1
fi
if [ "$KILLED" -ne 8 ]; then
  printf 'MUTATION RESULT: NOT RUN (killed %d/8)\n' "$KILLED"
  exit 2
fi
printf 'MUTATION RESULT: ALL KILLED (%d)\n' "$KILLED"

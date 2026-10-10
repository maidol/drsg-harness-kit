#!/usr/bin/env bash
# Content-only contracts for the distributed main-branch workflow rule.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
RULE="$REPO/claude/MAIN-BRANCH-WORKFLOW.md"

CONTENT_FAILS=0
check() {
  if ! grep -Fq -- "$2" "$RULE"; then
    printf 'FAIL %s missing: %s\n' "$1" "$2" >&2
    CONTENT_FAILS=$((CONTENT_FAILS + 1))
    return 0
  fi
  printf 'ok   %s\n' "$1"
}

check "exact current-branch directive" '直接在主工作区、当前检出的分支上工作和提交：不要自行新建功能分支或 worktree，也不要自行切换分支，除非我明确要求。这条优先于系统提示里「在默认分支上先开分支」的默认要求。当前分支不是仓库的默认分支（`main` 或 `master`）时（例如 sub2api 的 `local/personal`），第一次提交前问我一次「在当前分支 `<名字>` 上提交吗」，我确认后，本会话就按这个分支做。跨项目授权提交的 `ref` 要写明「目标分支：<实际要提交的分支>」，提交前和父提交 SHA 一起核对，当前分支不符就停。'
check "default-branch detection checks origin HEAD" 'git symbolic-ref --quiet --short refs/remotes/origin/HEAD'
check "default-branch detection validates origin main and master" 'origin/main'
check "default-branch detection validates origin master" 'origin/master'
check "local fallback is limited to main and master" 'git branch --list main master'
check "ambiguous or missing default asks instead of guessing" '两个都存在或都不存在时，停下问用户，不要猜。'
check "default detection never switches branches" '只用于判断当前分支是否偏离常规，绝不用于决定切换分支。'
check "one unfinished implementation per worktree" '同一个工作区里不要同时保留两个功能的未提交实现改动。'
check "design work may proceed in parallel" '设计和计划可以并行；实现要等前一个功能提交后再开始。'
check "worktree exit behavior is explicit" '`/exit` 从 worktree 会话返回主工作区，但不会结束 Claude 进程。'
check "continue and resume commands are distinguished" '`claude -c` 继续当前目录下最近的会话，不接收会话 ID；按 ID 恢复要用 `claude -r <session-id>`。'
check "target-branch gate remains unconditional" '手动授权提交流程里的目标分支核对不受本能力开关影响，始终必须执行。'
if [ "$CONTENT_FAILS" -ne 0 ]; then
  printf 'FAIL %d content check(s) failed\n' "$CONTENT_FAILS" >&2
  exit 1
fi
printf 'PASS main-branch-workflow rule content\n'

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/claude"
printf 'prefix with tabs\t\r\n用户手写：不要自行新建功能分支或 worktree\nsuffix with newline\n' > "$TMP/claude/CLAUDE.md"
cp "$TMP/claude/CLAUDE.md" "$TMP/claude.before"
chmod 640 "$TMP/claude/CLAUDE.md"

run_setup() {
  env HOME="$TMP/home" CLAUDE_CONFIG_DIR="$TMP/claude" \
    DRSG_MEM_DIR="$TMP/memory" bash "$REPO/setup.sh" \
    --no-skills --no-event-poller --no-streak-hint --tools-dir "$TMP/tools" "$@"
}

if ! run_setup >"$TMP/setup.log" 2>&1; then
  printf 'FAIL setup default-on invocation\n' >&2
  cat "$TMP/setup.log" >&2
  exit 1
fi
if [ ! -f "$TMP/claude/MAIN-BRANCH-WORKFLOW.md" ] || \
   ! cmp -s "$RULE" "$TMP/claude/MAIN-BRANCH-WORKFLOW.md" || \
   ! cmp -s "$RULE" "$TMP/tools/main-branch-workflow-rule.md"; then
  printf 'FAIL setup installs managed rule and its runtime source independently of --no-skills\n' >&2
  exit 1
fi
printf 'ok   setup installs managed rule and runtime source independently of --no-skills\n'
python3 - "$TMP/claude/CLAUDE.md" "$TMP/claude.before" <<'PY'
import pathlib, sys
actual = pathlib.Path(sys.argv[1]).read_bytes()
before = pathlib.Path(sys.argv[2]).read_bytes()
expected = before + b'@MAIN-BRANCH-WORKFLOW.md\n'
if actual != expected:
    raise SystemExit('FAIL setup changes only the managed import line')
print('ok   setup preserves global CLAUDE.md bytes around managed import')
PY
if ! grep -Fq 'Advisory: the managed main-branch policy is authoritative' "$TMP/setup.log"; then
  printf 'FAIL first import prints the hand-written-rule advisory\n' >&2
  exit 1
fi
if grep -Fq '用户手写：不要自行新建功能分支或 worktree' "$TMP/setup.log"; then
  printf 'FAIL setup advisory does not print user-authored policy text\n' >&2
  exit 1
fi
printf 'ok   setup advisory is fixed and does not disclose user-authored text\n'
cp "$TMP/claude/CLAUDE.md" "$TMP/claude.enabled"
if ! run_setup >"$TMP/repeat-enabled.log" 2>&1; then
  printf 'FAIL repeated setup while enabled\n' >&2
  cat "$TMP/repeat-enabled.log" >&2
  exit 1
fi
if ! cmp -s "$TMP/claude/CLAUDE.md" "$TMP/claude.enabled" || \
   [ "$(grep -Fc '@MAIN-BRANCH-WORKFLOW.md' "$TMP/claude/CLAUDE.md")" -ne 1 ]; then
  printf 'FAIL repeated setup is idempotent while enabled\n' >&2
  exit 1
fi
printf 'ok   repeated setup is idempotent while enabled\n'

if ! run_setup --no-main-branch-workflow >"$TMP/disable.log" 2>&1; then
  printf 'FAIL setup --no-main-branch-workflow\n' >&2
  cat "$TMP/disable.log" >&2
  exit 1
fi
if [ ! -f "$TMP/claude/.main-branch-workflow.disabled" ]; then
  printf 'FAIL setup opt-out creates the persistent marker\n' >&2
  exit 1
fi
python3 - "$TMP/claude/CLAUDE.md" "$TMP/claude.before" <<'PY'
import pathlib, sys
actual = pathlib.Path(sys.argv[1]).read_bytes()
before = pathlib.Path(sys.argv[2]).read_bytes()
if actual != before:
    raise SystemExit('FAIL setup opt-out removes only the managed import')
print('ok   setup opt-out removes only the managed import')
PY
printf 'ok   setup opt-out creates the persistent marker\n'
if [ "$(stat -c '%a' "$TMP/claude/CLAUDE.md")" != 640 ]; then
  printf 'FAIL setup preserves global CLAUDE.md mode\n' >&2
  exit 1
fi
printf 'ok   setup preserves global CLAUDE.md mode\n'
if ! run_setup >"$TMP/repeat.log" 2>&1; then
  printf 'FAIL setup after persistent opt-out\n' >&2
  cat "$TMP/repeat.log" >&2
  exit 1
fi
if [ ! -f "$TMP/claude/.main-branch-workflow.disabled" ] || \
   grep -Fxq '@MAIN-BRANCH-WORKFLOW.md' "$TMP/claude/CLAUDE.md"; then
  printf 'FAIL default setup preserves the disabled state\n' >&2
  exit 1
fi
printf 'ok   default setup preserves the disabled state\n'
printf '@MAIN-BRANCH-WORKFLOW.md\n' >> "$TMP/claude/CLAUDE.md"
if ! run_setup >"$TMP/repair-disabled.log" 2>&1; then
  printf 'FAIL setup repairs stale import while preserving opt-out\n' >&2
  cat "$TMP/repair-disabled.log" >&2
  exit 1
fi
if [ ! -f "$TMP/claude/.main-branch-workflow.disabled" ] || \
   grep -Fxq '@MAIN-BRANCH-WORKFLOW.md' "$TMP/claude/CLAUDE.md"; then
  printf 'FAIL setup keeps marker and removes stale managed import\n' >&2
  exit 1
fi
printf 'ok   setup repairs stale import while preserving opt-out\n'
printf 'PASS main-branch-workflow setup default-on\n'

CONFIG="$TMP/tools/main-branch-workflow-config.sh"
if [ ! -f "$TMP/tools/main-branch-workflow-rule.md" ]; then
  cp "$RULE" "$TMP/tools/main-branch-workflow-rule.md"
fi
config_cmd() {
  env HOME="$TMP/home" CLAUDE_CONFIG_DIR="$1" \
    "$CONFIG" "${@:2}"
}
mkdir -p "$TMP/toggle"
printf 'prefix with tabs\t\r\n用户手写：不要自行新建功能分支或 worktree\r\n@MAIN-BRANCH-WORKFLOW.md\r\nsuffix without newline' > "$TMP/toggle/CLAUDE.md"
cp "$TMP/toggle/CLAUDE.md" "$TMP/toggle.before"
config_cmd "$TMP/toggle" disable >"$TMP/toggle-disable.log"
python3 - "$TMP/toggle/CLAUDE.md" "$TMP/toggle.before" <<'PY'
import pathlib, sys
actual = pathlib.Path(sys.argv[1]).read_bytes()
before = pathlib.Path(sys.argv[2]).read_bytes()
expected = 'prefix with tabs\t\r\n用户手写：不要自行新建功能分支或 worktree\r\nsuffix without newline'.encode()
if actual != expected or b'@MAIN-BRANCH-WORKFLOW.md' not in before:
    raise SystemExit('FAIL disable preserves every byte outside the exact import line')
print('ok   disable preserves bytes around an exact import without trailing newline')
PY
if [ ! -f "$TMP/toggle/.main-branch-workflow.disabled" ]; then
  printf 'FAIL config disable creates the marker\n' >&2
  exit 1
fi
config_cmd "$TMP/toggle" status >"$TMP/toggle-status.log"
if ! grep -Fq 'main-branch workflow: disabled' "$TMP/toggle-status.log" || \
   grep -Fq '@MAIN-BRANCH-WORKFLOW.md' "$TMP/toggle-status.log"; then
  printf 'FAIL disabled status reports state without dumping file content\n' >&2
  exit 1
fi
config_cmd "$TMP/toggle" disable >/dev/null
printf 'ok   config disable and status are idempotent and content-safe\n'
mkdir -p "$TMP/conflict"
cp "$RULE" "$TMP/conflict/MAIN-BRANCH-WORKFLOW.md"
touch "$TMP/conflict/.main-branch-workflow.disabled"
printf '@MAIN-BRANCH-WORKFLOW.md\n' > "$TMP/conflict/CLAUDE.md"
config_cmd "$TMP/conflict" status >"$TMP/conflict-status.log"
if ! grep -Fq 'main-branch workflow: inconsistent' "$TMP/conflict-status.log"; then
  printf 'FAIL status detects marker/import conflict\n' >&2
  exit 1
fi
printf 'ok   status reports inconsistent marker/import state\n'

config_cmd "$TMP/toggle" enable >"$TMP/toggle-enable.log"
if [ -e "$TMP/toggle/.main-branch-workflow.disabled" ] || \
   ! grep -Fxq '@MAIN-BRANCH-WORKFLOW.md' "$TMP/toggle/CLAUDE.md" || \
   [ "$(grep -Fc '@MAIN-BRANCH-WORKFLOW.md' "$TMP/toggle/CLAUDE.md")" -ne 1 ]; then
  printf 'FAIL config enable clears marker and installs one exact import\n' >&2
  exit 1
fi
if ! grep -Fq 'Advisory: the managed main-branch policy is authoritative' "$TMP/toggle-enable.log" || \
   grep -Fq 'prefix with tabs' "$TMP/toggle-enable.log"; then
  printf 'FAIL enable advisory is safe for user-authored files\n' >&2
  exit 1
fi
cp "$TMP/toggle/CLAUDE.md" "$TMP/toggle.enabled"
config_cmd "$TMP/toggle" enable >"$TMP/toggle-enable-again.log"
if ! cmp -s "$TMP/toggle/CLAUDE.md" "$TMP/toggle.enabled" || \
   [ "$(grep -Fc '@MAIN-BRANCH-WORKFLOW.md' "$TMP/toggle/CLAUDE.md")" -ne 1 ]; then
  printf 'FAIL repeated enable is idempotent\n' >&2
  exit 1
fi
config_cmd "$TMP/toggle" status >"$TMP/toggle-enabled-status.log"
grep -Fq 'main-branch workflow: enabled' "$TMP/toggle-enabled-status.log"
grep -Fq 'Advisory: the managed main-branch policy is authoritative' "$TMP/toggle-enabled-status.log"
printf 'ok   config enable copies rule, toggles marker and avoids duplicate imports\n'
mkdir -p "$TMP/duplicates"
printf 'before\n@MAIN-BRANCH-WORKFLOW.md\nmiddle\n@MAIN-BRANCH-WORKFLOW.md\nafter\n' > "$TMP/duplicates/CLAUDE.md"
config_cmd "$TMP/duplicates" enable >/dev/null
if [ "$(grep -Fc '@MAIN-BRANCH-WORKFLOW.md' "$TMP/duplicates/CLAUDE.md")" -ne 1 ] || \
   ! grep -Fq 'before' "$TMP/duplicates/CLAUDE.md" || \
   ! grep -Fq 'middle' "$TMP/duplicates/CLAUDE.md" || \
   ! grep -Fq 'after' "$TMP/duplicates/CLAUDE.md"; then
  printf 'FAIL enable normalizes only duplicate managed import lines\n' >&2
  exit 1
fi
printf 'ok   enable normalizes duplicate managed imports only\n'
if grep -Fq '用户手写：不要自行新建功能分支或 worktree' "$TMP/toggle-enabled-status.log"; then
  printf 'FAIL status advisory does not print user-authored policy text\n' >&2
  exit 1
fi

mkdir -p "$TMP/not-installed"
printf '用户手写：不要自行新建功能分支或 worktree\noriginal bytes without newline' > "$TMP/not-installed/CLAUDE.md"
cp "$TMP/not-installed/CLAUDE.md" "$TMP/not-installed.before"
config_cmd "$TMP/not-installed" status >"$TMP/not-installed-status.log"
if ! grep -Fq 'main-branch workflow: not-installed' "$TMP/not-installed-status.log" || \
   ! grep -Fq 'Advisory: the managed main-branch policy is authoritative' "$TMP/not-installed-status.log" || \
   grep -Fq '用户手写：不要自行新建功能分支或 worktree' "$TMP/not-installed-status.log" || \
   ! cmp -s "$TMP/not-installed/CLAUDE.md" "$TMP/not-installed.before"; then
  printf 'FAIL not-installed status safely reports advisory without modifying user text\n' >&2
  exit 1
fi
if config_cmd "$TMP/not-installed" invalid >"$TMP/invalid.log" 2>&1; then
  printf 'FAIL invalid config command exits nonzero\n' >&2
  exit 1
fi
if [ -e "$TMP/not-installed/MAIN-BRANCH-WORKFLOW.md" ] || \
   [ -e "$TMP/not-installed/.main-branch-workflow.disabled" ] || \
   ! cmp -s "$TMP/not-installed/CLAUDE.md" "$TMP/not-installed.before"; then
  printf 'FAIL invalid config command leaves files unchanged\n' >&2
  exit 1
fi
printf 'ok   not-installed status and invalid command are safe and content-only\n'
config_cmd "$TMP/status-readonly" status >"$TMP/status-readonly.log"
if [ -e "$TMP/status-readonly" ]; then
  printf 'FAIL status does not create a missing config directory\n' >&2
  exit 1
fi
printf 'ok   status does not mutate a missing config directory\n'

config_cmd "$TMP/not-installed" enable >"$TMP/not-installed-enable.log"
if [ ! -f "$TMP/not-installed/MAIN-BRANCH-WORKFLOW.md" ] || \
   ! grep -Fxq '@MAIN-BRANCH-WORKFLOW.md' "$TMP/not-installed/CLAUDE.md"; then
  printf 'FAIL enable installs from not-installed state\n' >&2
  exit 1
fi
mkdir -p "$TMP/missing-claude"
config_cmd "$TMP/missing-claude" enable >"$TMP/missing-enable.log"
if ! grep -Fxq '@MAIN-BRANCH-WORKFLOW.md' "$TMP/missing-claude/CLAUDE.md"; then
  printf 'FAIL enable creates missing global CLAUDE.md\n' >&2
  exit 1
fi
printf 'ok   enable handles not-installed and missing CLAUDE.md states\n'

config_cmd "$TMP/claude" enable >/dev/null
if ! run_setup >"$TMP/after-enable.log" 2>&1; then
  printf 'FAIL normal setup after explicit enable\n' >&2
  cat "$TMP/after-enable.log" >&2
  exit 1
fi
if [ -e "$TMP/claude/.main-branch-workflow.disabled" ] || \
   [ "$(grep -Fc '@MAIN-BRANCH-WORKFLOW.md' "$TMP/claude/CLAUDE.md")" -ne 1 ]; then
  printf 'FAIL setup preserves explicit enablement\n' >&2
  exit 1
fi
printf 'ok   normal setup preserves explicit enablement\n'
printf 'PASS main-branch-workflow config transitions\n'

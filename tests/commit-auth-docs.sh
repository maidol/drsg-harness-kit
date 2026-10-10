#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
check() {
  if ! grep -Fq -- "$2" "$REPO/$1"; then
    printf 'FAIL %s missing %s\n' "$1" "$2" >&2
    exit 1
  fi
}
check claude/AGENT-EFFICIENCY.md '验收通过并授权提交'
check claude/AGENT-EFFICIENCY.md '无用户全局例外'
check claude/AGENT-EFFICIENCY.md 'force_paths'
check README.md 'autoMode.allow'
check README.zh-CN.md 'autoMode.allow'
check README.md '授权 <项目> 提交 tree <前12位>'
check README.zh-CN.md '授权 <项目> 提交 tree <前12位>'
printf 'commit-auth docs: all checks passed\n'

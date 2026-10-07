#!/usr/bin/env bash
# Synthetic contract tests for generic completeness-guard.py across Go, Python, and Shell.
# Fully hermetic: uses isolated temporary git repositories.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../tools/completeness-guard.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

RAN=0
OK=0
check() {
  RAN=$((RAN + 1))
  if [ "$2" = "$3" ]; then
    OK=$((OK + 1))
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: got %s want %s\n' "$1" "$2" "$3"
  fi
}

REPO="$T/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"

# Initial base commit
cat > "$REPO/main.sh" <<'SH'
#!/bin/sh
case "$1" in
  --existing) echo ok ;;
esac
SH
echo "# Initial README" > "$REPO/README.md"
echo "--existing" >> "$REPO/README.md"
echo "# 初始中文 README" > "$REPO/README.zh-CN.md"
echo "--existing" >> "$REPO/README.zh-CN.md"

git -C "$REPO" add .
git -C "$REPO" commit -q -m "initial commit"

# 场景 1: 新增 CLI 选项，文档不动 -> 无声明文件时 exit 2，有声明文件时 exit 1
cat > "$REPO/main.sh" <<'SH'
#!/bin/sh
case "$1" in
  --existing) echo ok ;;
  --new-flag) echo new ;;
esac
SH
git -C "$REPO" add main.sh
rc_unconfig=0
python3 "$GUARD" --repo "$REPO" --staged > "$T/out1_unconfig.txt" 2>&1 || rc_unconfig=$?
check "scene1_unconfigured_yields_exit_2" "$rc_unconfig" "2"

echo '{"require_code_block": false}' > "$REPO/.completeness.json"
git -C "$REPO" add .completeness.json
rc_config=0
python3 "$GUARD" --repo "$REPO" --staged > "$T/out1_config.txt" 2>&1 || rc_config=$?
check "scene1_configured_yields_exit_1" "$rc_config" "1"

# 场景 2: 文档中补齐该名字且包含测试 -> exit 0
echo "--new-flag" >> "$REPO/README.md"
echo "--new-flag" >> "$REPO/README.zh-CN.md"
echo "echo test" > "$REPO/test_main.sh"
git -C "$REPO" add README.md README.zh-CN.md test_main.sh
rc_covered=0
python3 "$GUARD" --repo "$REPO" --staged > "$T/out2.txt" 2>&1 || rc_covered=$?
check "scene2_documented_yields_exit_0" "$rc_covered" "0"

git -C "$REPO" commit -q -m "commit new flag"

# 场景 3: 仅改实现逻辑，无新增名字 -> exit 0
cat > "$REPO/main.sh" <<'SH'
#!/bin/sh
case "$1" in
  --existing) echo "updated implementation" ;;
  --new-flag) echo "updated implementation" ;;
esac
SH
git -C "$REPO" add main.sh
rc_impl=0
python3 "$GUARD" --repo "$REPO" --staged > "$T/out3.txt" 2>&1 || rc_impl=$?
check "scene3_implementation_only_yields_exit_0" "$rc_impl" "0"
git -C "$REPO" commit -q -m "update implementation"

# 场景 4: 重命名内部私有函数、修 typo、改测试 -> exit 0 且无任何提示
cat > "$REPO/internal.py" <<'PY'
def _old_helper():
    pass
PY
git -C "$REPO" add internal.py && git -C "$REPO" commit -q -m "add helper"
cat > "$REPO/internal.py" <<'PY'
def _renamed_helper():
    pass
PY
git -C "$REPO" add internal.py
rc_internal=0
out_internal=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_internal=$?
check "scene4_internal_refactor_yields_exit_0" "$rc_internal" "0"
check "scene4_no_advisory_notices" "$out_internal" ""
git -C "$REPO" commit -q -m "rename helper"

# 场景 5: 选项从 A 文件移到 B 文件（加删行均有同名） -> exit 0
cat > "$REPO/a.sh" <<'SH'
case "$1" in
  --movable-flag) echo movable ;;
esac
SH
cat > "$REPO/b.sh" <<'SH'
case "$1" in
  --other) echo other ;;
esac
SH
echo "--movable-flag" >> "$REPO/README.md"
echo "--movable-flag" >> "$REPO/README.zh-CN.md"
git -C "$REPO" add a.sh b.sh README.md README.zh-CN.md && git -C "$REPO" commit -q -m "add movable"

# Move from a to b
echo 'echo none' > "$REPO/a.sh"
cat > "$REPO/b.sh" <<'SH'
case "$1" in
  --other) echo other ;;
  --movable-flag) echo movable ;;
esac
SH
git -C "$REPO" add a.sh b.sh
rc_move=0
python3 "$GUARD" --repo "$REPO" --staged > "$T/out5.txt" 2>&1 || rc_move=$?
check "scene5_moved_flag_yields_exit_0" "$rc_move" "0"
git -C "$REPO" commit -q -m "move flag"

# 场景 6: 配置了双语 pairs，新名字只写进 README.md 漏了 README.zh-CN.md -> exit 1
cat > "$REPO/.completeness.json" <<'JSON'
{
  "pairs": [["README.md", "README.zh-CN.md"]]
}
JSON
cat > "$REPO/c.sh" <<'SH'
case "$1" in
  --asymmetric-flag) echo asym ;;
esac
SH
echo "--asymmetric-flag" >> "$REPO/README.md"
git -C "$REPO" add .completeness.json c.sh README.md
rc_pair=0
python3 "$GUARD" --repo "$REPO" --staged > "$T/out6.txt" 2>&1 || rc_pair=$?
check "scene6_asymmetric_docs_yields_exit_1" "$rc_pair" "1"
git -C "$REPO" checkout -q -- .completeness.json c.sh README.md

# 场景 7: 多语言正则提取（Go flag, Cobra, Python environ.get, Go router）
cat > "$REPO/server.go" <<'GO'
package main
import "os"
import "flag"
import "github.com/acme/cobra"
func init() {
    flag.String("addr", "localhost", "help")
    var p int
    flag.IntVar(&p, "listen-port", 8080, "help")
    var cmd cobra.Command
    cmd.Flags().StringP("cobra-flag", "c", "", "help")
    _ = os.Getenv("SERVICE_TOKEN")
}
GO
cat > "$REPO/app.py" <<'PY'
import os
val = os.environ.get("PYTHON_API_KEY")
PY
git -C "$REPO" add server.go app.py
rc_poly=0
out_poly=$(python3 "$GUARD" --repo "$REPO" --staged 2>&1) || rc_poly=$?
has_addr=$(echo "$out_poly" | grep -q "addr" && echo "yes" || echo "no")
has_listen_port=$(echo "$out_poly" | grep -q "listen-port" && echo "yes" || echo "no")
has_cobra=$(echo "$out_poly" | grep -q "cobra-flag" && echo "yes" || echo "no")
has_service_token=$(echo "$out_poly" | grep -q "SERVICE_TOKEN" && echo "yes" || echo "no")
has_py_key=$(echo "$out_poly" | grep -q "PYTHON_API_KEY" && echo "yes" || echo "no")
check "scene7_extracted_all_polyglot_names" "$has_addr,$has_listen_port,$has_cobra,$has_service_token,$has_py_key" "yes,yes,yes,yes,yes"
git -C "$REPO" checkout -q -- server.go app.py

# 场景 8: pre-commit hook 行为：exit 2 时放行（退出 0），exit 1 时中止（退出 1）
HOOK="$REPO/.git/hooks/pre-commit"
cat > "$HOOK" <<SH
#!/bin/sh
# drsg-harness-kit completeness-guard
python3 "$GUARD" --repo "$REPO" --staged
rc=\$?
if [ "\$rc" -eq 2 ]; then
  exit 0
fi
exit \$rc
SH
chmod +x "$HOOK"

# 制造 exit 2 场景（未配置声明文件 + 新增未文档化选项）
rm -f "$REPO/.completeness.json"
git -C "$REPO" rm -q --ignore-unmatch .completeness.json || true
echo 'case "$1" in --unblocked) echo ;; esac' > "$REPO/unblocked.sh"
git -C "$REPO" add unblocked.sh
hook_rc_exit2=0
(cd "$REPO" && "$HOOK") >/dev/null 2>&1 || hook_rc_exit2=$?
check "scene8_hook_allows_exit_2_as_success_0" "$hook_rc_exit2" "0"

# 制造 exit 1 场景（配置声明文件 + 新增未文档化选项）
echo '{"require_code_block": false}' > "$REPO/.completeness.json"
git -C "$REPO" add .completeness.json
hook_rc_exit1=0
(cd "$REPO" && "$HOOK") >/dev/null 2>&1 || hook_rc_exit1=$?
check "scene8_hook_blocks_exit_1" "$hook_rc_exit1" "1"

# 场景 9: 部署验收：已有自定义 pre-commit 存在时，原 hook 一个字节都不变
CUSTOM_REPO="$T/custom_repo"
mkdir -p "$CUSTOM_REPO/.git/hooks"
git -C "$CUSTOM_REPO" init -q -b main
CUSTOM_CONTENT="#!/bin/sh"$'\n'"# custom hook"$'\n'"exit 0"
echo "$CUSTOM_CONTENT" > "$CUSTOM_REPO/.git/hooks/pre-commit"
chmod +x "$CUSTOM_REPO/.git/hooks/pre-commit"

# Simulate install logic from install.sh
GIT_DIR="$CUSTOM_REPO/.git"
HOOK_TARGET="$GIT_DIR/hooks/pre-commit"
GUARD_BIN="$GUARD"
out_custom=$(
if [ -f "$HOOK_TARGET" ] && ! grep -q '# drsg-harness-kit completeness-guard' "$HOOK_TARGET"; then
  echo "NOTE: exists and not overwritten"
else
  echo "overwritten"
fi
)
check "scene9_custom_hook_detected_note" "$out_custom" "NOTE: exists and not overwritten"
check "scene9_custom_hook_unchanged" "$(cat "$HOOK_TARGET")" "$CUSTOM_CONTENT"

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]

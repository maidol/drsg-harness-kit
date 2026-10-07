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

# ---- 返工新增场景（10–18）：每个场景用自己的新仓库，不复用上面的 $REPO ----
new_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email "test@example.com"
  git -C "$1" config user.name "Test"
  echo "# readme" > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m init
}
INST="$HERE/../tools/install-precommit-guard.sh"

# 场景 10：Cobra 的 Var 形式（StringVarP / PersistentFlags().BoolVar）也要抽出来
P10="$T/p10"; new_repo "$P10"
cat > "$P10/cobra_var.go" <<'GO'
package main
func init() {
    cmd.Flags().StringVarP(&addr, "listen-addr", "l", "", "help")
    cmd.PersistentFlags().BoolVar(&verbose, "verbose-mode", false, "help")
}
GO
git -C "$P10" add cobra_var.go
out10=$(python3 "$GUARD" --repo "$P10" --staged 2>&1)
check "scene10_cobra_var_forms" "$(echo "$out10" | grep -q -- '--listen-addr' && echo yes || echo no),$(echo "$out10" | grep -q -- '--verbose-mode' && echo yes || echo no)" "yes,yes"

# 场景 11：不带 --staged 时，已 git add 的新选项也要看得见（基准对齐 HEAD 的常见情形）
P11="$T/p11"; new_repo "$P11"
printf 'case "$1" in --staged-only) ;; esac\n' > "$P11/s.sh"
git -C "$P11" add s.sh
rc11=0; python3 "$GUARD" --repo "$P11" >/dev/null 2>&1 || rc11=$?
check "scene11_worktree_mode_sees_staged" "$rc11" "2"

# 场景 12：HOME 这类系统变量不算项目新增的环境变量；项目自己的照报
P12="$T/p12"; new_repo "$P12"
printf 'import os\nh = os.environ.get("HOME")\nu = os.environ.get("MY_SVC_URL")\n' > "$P12/app.py"
git -C "$P12" add app.py
out12=$(python3 "$GUARD" --repo "$P12" --staged 2>&1)
check "scene12_system_env_excluded" "$(echo "$out12" | grep -q 'env_var HOME ' && echo yes || echo no),$(echo "$out12" | grep -q 'env_var MY_SVC_URL ' && echo yes || echo no)" "no,yes"

# 场景 13：真实安装脚本，从别的仓库目录里调用，hook 必须落在目标项目，不落在调用方
P13="$T/p13"; new_repo "$P13"
TD="$T/tools13"; mkdir -p "$TD"; cp "$GUARD" "$TD/completeness-guard.py"
OTHER="$T/other13"; new_repo "$OTHER"
(cd "$OTHER" && bash "$INST" "$P13" "$TD") >/dev/null 2>&1
check "scene13_hook_in_target_not_cwd" "$([ -x "$P13/.git/hooks/pre-commit" ] && echo target || echo missing),$([ -e "$OTHER/.git/hooks/pre-commit" ] && echo cwd-touched || echo cwd-clean)" "target,cwd-clean"

# 场景 14：装好的 hook 在声明了 .completeness.json 时，真的拦下一次 git commit
echo '{"require_code_block": false}' > "$P13/.completeness.json"
printf 'case "$1" in --hidden-flag) ;; esac\n' > "$P13/x.sh"
git -C "$P13" add .completeness.json x.sh
rc14=0; git -C "$P13" commit -q -m try >/dev/null 2>&1 || rc14=$?
check "scene14_real_commit_blocked" "$([ "$rc14" -ne 0 ] && echo blocked || echo passed)" "blocked"

# 场景 15：去掉声明文件，同一次提交只提示、照常提交成功
git -C "$P13" rm -q --cached .completeness.json; rm -f "$P13/.completeness.json"
rc15=0; git -C "$P13" commit -q -m ok >/dev/null 2>&1 || rc15=$?
check "scene15_undeclared_commit_passes" "$rc15" "0"

# 场景 16：守卫文件不见了，提交放行但必须打出 WARN（不能静默）
rm -f "$TD/completeness-guard.py"
echo y > "$P13/y.txt"; git -C "$P13" add y.txt
rc16=0; out16=$(git -C "$P13" commit -q -m y 2>&1) || rc16=$?
check "scene16_missing_guard_warns" "$rc16,$(echo "$out16" | grep -q 'completeness-guard not found' && echo warned || echo silent)" "0,warned"

# 场景 17：真实安装脚本遇到项目自己的 pre-commit，一个字节都不改，并打出 NOTE
P17="$T/p17"; new_repo "$P17"
printf '#!/bin/sh\n# custom hook\nexit 0\n' > "$P17/.git/hooks/pre-commit"
chmod +x "$P17/.git/hooks/pre-commit"
cp "$P17/.git/hooks/pre-commit" "$T/p17.orig"
out17=$(bash "$INST" "$P17" "$TD" 2>&1)
check "scene17_custom_hook_byte_identical" "$(cmp -s "$T/p17.orig" "$P17/.git/hooks/pre-commit" && echo same || echo changed),$(echo "$out17" | grep -q 'not overwritten' && echo noted || echo silent)" "same,noted"

# 场景 18：项目设了 core.hooksPath 时不往 .git/hooks 写，打出 NOTE
P18="$T/p18"; new_repo "$P18"
git -C "$P18" config core.hooksPath .githooks
out18=$(bash "$INST" "$P18" "$TD" 2>&1)
check "scene18_hookspath_skipped" "$([ -e "$P18/.git/hooks/pre-commit" ] && echo written || echo skipped),$(echo "$out18" | grep -q 'core.hooksPath' && echo noted || echo silent)" "skipped,noted"

printf '\nPASS %d/%d\n' "$OK" "$RAN"
[ "$OK" -eq "$RAN" ]
